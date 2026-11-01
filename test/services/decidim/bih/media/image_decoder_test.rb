# frozen_string_literal: true
require "test_helper"
require "minitest/mock"
require "tmpdir"
require "tempfile"
require "zlib"
require "rbconfig"
require_relative "../../../../../app/services/decidim/bih/media/image_decoder"

class ImageDecoderTest < Minitest::Test
  Decoder = Decidim::Bih::Media::ImageDecoder

  def setup
    @directory = Dir.mktmpdir("synthetic-image-decoder-")
    @input = File.join(@directory, "input.png")
    @output = File.join(@directory, "output.png")
    chunk = ->(type, data) { [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N") }
    png = "\x89PNG\r\n\x1a\n".b + chunk.call("IHDR", [1, 1, 8, 6, 0, 0, 0].pack("NNCCCCC")) +
          chunk.call("IDAT", Zlib::Deflate.deflate("\x00\xff\x00\x00\xff".b)) + chunk.call("IEND", "")
    File.binwrite(@input, png)
  end

  def teardown
    FileUtils.remove_entry_secure(@directory) if @directory && File.directory?(@directory)
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def run_ruby(source, *args, deadline: now + 2)
    Decoder.new.send(:run, [RbConfig.ruby, "--disable-gems", "-e", source, *args], deadline:, cache: @directory)
  end

  def test_small_authored_png_roundtrips_through_the_real_bounded_decoder
    assert Decoder.call(input_path: @input, output_path: @output, content_type: "image/png")
    assert File.size(@output).positive?
    assert_equal "\x89PNG\r\n\x1a\n".b, File.binread(@output, 8)
  end

  def test_only_conversion_has_two_internal_cache_slots_while_input_frames_stay_one
    decoder = Decoder.new
    assert_includes decoder.send(:limit_arguments).each_slice(3).to_a, ["-limit", "list-length", "1"]
    assert_includes decoder.send(:limit_arguments, list_length: 2).each_slice(3).to_a, ["-limit", "list-length", "2"]
    assert_raises(Decoder::InvalidImage) { decoder.send(:verify_geometry!, "PNG 1 1 2\n", "PNG") }
  end

  def test_declared_jpeg_cannot_make_the_forced_jpeg_decoder_accept_png_bytes
    assert_raises(Decoder::InvalidImage) do
      Decoder.call(input_path: @input, output_path: @output, content_type: "image/jpeg")
    end
  end

  def test_multiple_frames_are_refused_using_two_tiny_authored_webp_frames
    path = File.join(@directory, "two-frames.webp")
    tool = MiniMagick::Tool::Convert.new
    tool.merge!(["-size", "1x1", "xc:red", "xc:blue", "-loop", "0", path])
    Decoder.new.send(:run, tool.command, deadline: now + 2, cache: @directory)
    assert_raises(Decoder::InvalidImage) do
      Decoder.call(input_path: path, output_path: File.join(@directory, "out.webp"), content_type: "image/webp")
    end
  end

  def test_oversized_geometry_is_rejected_before_conversion_without_allocating_a_large_image
    ["PNG 8193 1 1\n", "PNG 6000 6000 1\n", "PNG 1 1 2\n"].each do |metadata|
      decoder = Decoder.new
      calls = []
      decoder.define_singleton_method(:run) do |command, **|
        calls << command
        raise "Conversion must not follow rejected metadata" if calls.size > 1
        metadata
      end
      assert_raises(Decoder::InvalidImage) { decoder.call(input_path: @input, output_path: @output, content_type: "image/png") }
      assert_equal 1, calls.size
    end
  end

  def test_process_timeout_reaps_the_exact_child
    pid = nil
    original = Open3.method(:popen3)
    observe_child = lambda do |*arguments, **options, &block|
      original.call(*arguments, **options) do |input, output, errors, child|
        pid = child.pid
        block.call(input, output, errors, child)
      end
    end
    started = now
    Open3.stub(:popen3, observe_child) do
      assert_raises(Decoder::InvalidImage) { run_ruby("sleep 5", deadline: started + 0.5) }
    end
    assert_operator now - started, :<, 2
    refute_nil pid
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
  end

  def test_excessive_error_output_is_bounded_without_leaking_its_contents
    raised = assert_raises(Decoder::InvalidImage) { run_ruby('STDERR.write("PRIVATE" * 1000); STDERR.flush; sleep 2') }
    refute_includes raised.message, "PRIVATE"
  end

  def test_failed_commands_are_refused
    assert_raises(Decoder::InvalidImage) { run_ruby("exit 7") }
  end

  def test_small_command_output_and_deadline_refusal_are_deterministic
    assert_equal "safe", run_ruby('STDOUT.write("safe")')
    assert_raises(Decoder::InvalidImage) { run_ruby('abort "must not execute"', deadline: now - 1) }
  end
end
