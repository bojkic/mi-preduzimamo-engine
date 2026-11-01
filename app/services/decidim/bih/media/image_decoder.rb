# frozen_string_literal: true
require "mini_magick"
require "open3"
require "tmpdir"
require "fileutils"

module Decidim
  module Bih
    module Media
      # Untrusted raster decoding happens in bounded child processes, never by
      # mutating MiniMagick's process-global configuration in a web request.
      class ImageDecoder
        InvalidImage = Class.new(StandardError)
        CODECS = { "image/png" => "PNG", "image/jpeg" => "JPEG", "image/webp" => "WEBP" }.freeze
        MAX_DIMENSION = 8192
        MAX_PIXELS = 32_000_000
        MAX_OUTPUT_BYTES = 5 * 1024 * 1024
        WALL_SECONDS = 8
        CPU_SECONDS = 5
        ADDRESS_BYTES = 1024 * 1024 * 1024
        CACHE_BYTES = 256 * 1024 * 1024
        CAPTURE_BYTES = 4096
        LIMITS = { "thread" => "1", "memory" => "128MiB", "map" => "256MiB", "disk" => "256MiB",
                   "width" => MAX_DIMENSION.to_s, "height" => MAX_DIMENSION.to_s,
                   "area" => "32MP", "list-length" => "1", "time" => CPU_SECONDS.to_s }.freeze

        def self.call(**options)
          new.call(**options)
        end

        def call(input_path:, output_path:, content_type:)
          codec = CODECS.fetch(content_type) { raise InvalidImage, "unsupported_type" }
          deadline = monotonic + WALL_SECONDS
          Dir.mktmpdir("decidim-bih-image-cache-") do |cache|
            identify = command("identify") + limit_arguments +
                       ["-ping", "-format", "%m %w %h %n\n", "#{codec}:#{input_path}"]
            dimensions = run(identify, deadline:, cache:)
            verify_geometry!(dimensions, codec)

            # ImageMagick opens an internal output pixel cache while the one
            # admitted input is still alive. Two cache slots are necessary;
            # accepted input frames remain exactly one by verify_geometry!.
            convert = command + limit_arguments(list_length: 2) +
                      ["#{codec}:#{input_path}", "-auto-orient", "-strip", "#{codec}:#{output_path}"]
            run(convert, deadline:, cache:)
            raise InvalidImage, "output_over_limit" unless File.size(output_path).between?(1, MAX_OUTPUT_BYTES)
          end
          true
        end

        private

        def command(subcommand = nil)
          # ImageMagick7 is an explicit prerequisite. Avoid MiniMagick's lazy
          # version-probing subprocess outside this decoder's resource budget.
          binary = MiniMagick.cli_path ? File.join(MiniMagick.cli_path, "magick") : "magick"
          [*Array(MiniMagick.cli_prefix), binary, subcommand].compact
        end

        def limit_arguments(list_length: 1)
          LIMITS.merge("list-length" => list_length.to_s).flat_map { |name, value| ["-limit", name, value] }
        end

        def verify_geometry!(text, codec)
          rows = text.lines
          raise InvalidImage, "multiple_or_missing_frames" unless rows.size == 1

          format, width, height, frames, extra = rows.first.split
          unless format == codec && !extra && [width, height, frames].all? { |v| v && v.match?(/\A[0-9]+\z/) }
            raise InvalidImage, "invalid_geometry"
          end
          width, height, frames = [width, height, frames].map(&:to_i)
          unless frames == 1 && width.between?(1, MAX_DIMENSION) && height.between?(1, MAX_DIMENSION) && width * height <= MAX_PIXELS
            raise InvalidImage, "geometry_over_limit"
          end
        end

        def run(command, deadline:, cache:)
          raise InvalidImage, "decode_timeout" if monotonic >= deadline

          # The private directory also contains ImageMagick's transient pixel
          # cache. No shell, caller filename, image bytes or decoder stderr log.
          env = { "MAGICK_TEMPORARY_PATH" => cache, "OMP_NUM_THREADS" => "1" }
          result = nil
          Open3.popen3(env, *command, pgroup: true,
                       rlimit_cpu: [CPU_SECONDS, CPU_SECONDS],
                       rlimit_as: [ADDRESS_BYTES, ADDRESS_BYTES],
                       rlimit_fsize: [CACHE_BYTES, CACHE_BYTES]) do |input, output, errors, child|
            input.close
            streams = { output => +"".b, errors => +"".b }
            open_streams = streams.keys.dup
            begin
              until open_streams.empty? && !child.alive?
                remaining = deadline - monotonic
                raise InvalidImage, "decode_timeout" unless remaining.positive?

                if open_streams.empty?
                  child.join([remaining, 0.05].min)
                  next
                end
                readable = IO.select(open_streams, nil, nil, remaining)&.first
                raise InvalidImage, "decode_timeout" unless readable

                readable.each do |stream|
                  begin
                    chunk = stream.read_nonblock(1024)
                    streams.fetch(stream) << chunk
                    raise InvalidImage, "decoder_output_over_limit" if streams.fetch(stream).bytesize > CAPTURE_BYTES
                  rescue IO::WaitReadable
                    next
                  rescue EOFError
                    open_streams.delete(stream)
                    stream.close
                  end
                end
              end
              raise InvalidImage, "decoder_failed" unless child.value.success?

              result = streams.fetch(output)
            ensure
              # Kill the whole decoder group on timeout/error, including a
              # descendant retaining a pipe after its parent exits.
              if child.alive? || open_streams.any?
                begin
                  Process.kill("KILL", -child.pid)
                rescue Errno::ESRCH
                  nil
                end
              end
              [output, errors].each { |io| io.close unless io.closed? }
              child.join
            end
          end
          result
        end

        def monotonic
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
