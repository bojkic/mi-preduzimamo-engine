# frozen_string_literal: true
require "test_helper"
require "stringio"
require "zlib"
require "tempfile"
require "logger"

class ImageNormalizerInputBoundsTest < ActiveSupport::TestCase
  Normalizer = Decidim::Bih::Media::ImageNormalizer
  class ChunkedInput
    attr_reader :requests, :delivered
    def initialize(size)
      @size, @offset, @delivered = size, 0, 0
      @requests = []
    end
    def rewind = @offset = 0
    def read(length = nil)
      raise "unbounded_read" unless length
      @requests << length
      return nil if @offset >= @size

      bytes = [length, @size - @offset].min
      @offset += bytes
      @delivered += bytes
      "x" * bytes
    end
  end

  def without_decoder
    Decidim::Bih::Media::ImageDecoder.stub(:call, ->(**) { flunk "Rejected input reached the image decoder" }) { yield }
  end

  def recorded_tempfiles
    files = []
    original = Tempfile.method(:new)
    Tempfile.stub(:new, ->(*args, **kwargs) { original.call(*args, **kwargs).tap { |file| files << [file, file.path] } }) do
      yield files
    end
  ensure
    files&.each { |file, _path| file.close! rescue nil }
  end

  def png
    chunk = ->(type, data) { [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N") }
    "\x89PNG\r\n\x1a\n".b + chunk.call("IHDR", [1, 1, 8, 6, 0, 0, 0].pack("NNCCCCC")) +
      chunk.call("IDAT", Zlib::Deflate.deflate("\x00\xff\x00\x00\xff".b)) + chunk.call("IEND", "")
  end

  test "claimed image MIME cannot admit a vector document to the decoder" do
    io = StringIO.new('<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"></svg>')
    without_decoder { assert_nil Normalizer.call(io:, filename: "photo.png", content_type: "image/png") }
    assert_equal 0, io.pos
  end

  test "unsupported MIME and empty input stop before image processing" do
    io = ChunkedInput.new(1)
    without_decoder { assert_nil Normalizer.call(io:, filename: "photo.txt", content_type: "text/plain") }
    assert_empty io.requests
    without_decoder { assert_nil Normalizer.call(io: StringIO.new(""), filename: "photo.png", content_type: "image/png") }
  end

  test "actual bytes are bounded even if an upload does not declare its size" do
    io = ChunkedInput.new(Normalizer::MAX_INPUT_BYTES + 2)
    recorded_tempfiles do |files|
      without_decoder { assert_nil Normalizer.call(io:, filename: "photo.png", content_type: "image/png") }
      assert_equal Normalizer::MAX_INPUT_BYTES + 1, io.delivered
      assert io.requests.all? { |size| size.positive? && size <= Normalizer::READ_CHUNK_BYTES }
      assert files.all? { |file, path| file.closed? && !File.exist?(path) }
    end
  end

  test "read failures remove private temporary input and do not log exception text" do
    io = Object.new
    def io.read(*) = raise(IOError, "PRIVATE-READ-MESSAGE")
    logs = StringIO.new
    recorded_tempfiles do |files|
      Rails.stub(:logger, Logger.new(logs)) do
        assert_nil Normalizer.call(io:, filename: "private-name.png", content_type: "image/png")
      end
      assert files.any?
      assert files.all? { |file, path| file.closed? && !File.exist?(path) }
    end
    assert_includes logs.string, "IOError"
    assert_not_includes logs.string, "PRIVATE-READ-MESSAGE"
    assert_not_includes logs.string, "private-name"
  end

  test "decoder failure closes both private input and unreturned output" do
    decoder = ->(**) { raise IOError, "synthetic decoder failure" }
    recorded_tempfiles do |files|
      Decidim::Bih::Media::ImageDecoder.stub(:call, decoder) do
        assert_nil Normalizer.call(io: StringIO.new(png), filename: "photo.svg", content_type: "image/png")
      end
      assert_equal 2, files.size
      assert files.all? { |file, path| file.closed? && !File.exist?(path) }
      assert files.all? { |_file, path| path.end_with?(".png") }
    end
  end
end
