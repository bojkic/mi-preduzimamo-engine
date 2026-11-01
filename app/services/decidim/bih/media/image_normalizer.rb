# frozen_string_literal: true

require "mini_magick"
require "marcel"
require "tempfile"
require_relative "image_decoder"

module Decidim
  module Bih
    module Media
      # Normalizes citizen-supplied report photos before ActiveStorage persists
      # them. This strips EXIF/GPS/device metadata and applies orientation while
      # preserving the original content type/filename contract expected by the
      # report model.
      class ImageNormalizer
        MAX_INPUT_BYTES = 5 * 1024 * 1024
        READ_CHUNK_BYTES = 64 * 1024
        InvalidInput = Class.new(StandardError)
        ALLOWED_CONTENT_TYPES = %w(image/png image/jpeg image/webp).freeze
        EXTENSION_FOR = { "image/png" => ".png", "image/jpeg" => ".jpg", "image/webp" => ".webp" }.freeze

        def self.call(attachable)
          new.call(attachable)
        end

        def call(attachable)
          content_type = content_type_for(attachable)
          return nil unless ALLOWED_CONTENT_TYPES.include?(content_type)

          input = input_tempfile(attachable)
          detected = Marcel::MimeType.for(input, name: nil, declared_type: nil)
          raise InvalidInput, "content_type_mismatch" unless detected == content_type
          input.rewind
          output = Tempfile.new(["decidim-bih-image", extension_for(attachable, content_type)], binmode: true)

          ImageDecoder.call(input_path: input.path, output_path: output.path, content_type:)
          output.rewind

          completed = true
          { io: output, filename: filename_for(attachable, content_type), content_type: content_type }
        rescue StandardError => e
          Rails.logger.warn("[ImageNormalizer] dropping unprocessable image (#{e.class})")
          nil
        ensure
          input&.close! if defined?(input) && input.respond_to?(:close!)
          output&.close! if defined?(output) && output && !completed
        end

        private

        def input_tempfile(attachable)
          io, close_io = source_io(attachable)
          io.rewind if io.respond_to?(:rewind)

          file = Tempfile.new(["decidim-bih-input", extension_for(attachable, content_type_for(attachable))], binmode: true)
          total = 0
          loop do
            chunk = io.read([READ_CHUNK_BYTES, MAX_INPUT_BYTES - total + 1].min)
            break if chunk.nil? || chunk.empty?

            total += chunk.bytesize
            raise InvalidInput, "input_over_limit" if total > MAX_INPUT_BYTES

            file.write(chunk)
          end
          raise InvalidInput, "empty_image" if total.zero?

          file.rewind
          complete = true
          file
        ensure
          file&.close! if defined?(file) && file && !complete
          io&.rewind if io.respond_to?(:rewind) && !close_io
          io&.close if close_io
        end

        def source_io(attachable)
          return [attachable.tempfile, false] if attachable.respond_to?(:tempfile) && attachable.tempfile.respond_to?(:read)
          return [attachable, false] if attachable.respond_to?(:read)
          return [File.open(attachable.path, "rb"), true] if attachable.respond_to?(:path)
          return [attachable[:io], false] if attachable.is_a?(Hash)

          [attachable, false]
        end

        def filename_for(attachable, content_type)
          filename =
            if attachable.is_a?(Hash)
              attachable[:filename]
            elsif attachable.respond_to?(:original_filename)
              attachable.original_filename
            end

          filename.presence || "report_photo#{EXTENSION_FOR.fetch(content_type)}"
        end

        def content_type_for(attachable)
          if attachable.is_a?(Hash)
            attachable[:content_type]
          elsif attachable.respond_to?(:content_type)
            attachable.content_type
          end.to_s.split(";").first.to_s.strip.downcase
        end

        def extension_for(_attachable, content_type)
          # Processing suffixes come from the accepted type, never the filename.
          EXTENSION_FOR.fetch(content_type)
        end
      end
    end
  end
end
