# frozen_string_literal: true
require 'open3'
require 'tempfile'
require 'timeout'
module Decidim
  module Bih
    module Ai
      # No shell, no network, bounded CPU/memory/output, transient private file.
      class PdfText
        Unreadable = Class.new(StandardError)
        MAX_BYTES = 8 * 1024 * 1024
        MAX_TEXT_BYTES = 32_000
        def call(bytes)
          raise Unreadable, 'oversized_pdf' unless bytes.bytesize <= MAX_BYTES && bytes.start_with?('%PDF-')
          Tempfile.create(['case-evidence-', '.pdf'], binmode: true) do |file|
            file.chmod(0o600)
            file.write(bytes)
            file.flush
            result = nil
            Open3.popen3('/usr/bin/pdftotext', '-nopgbrk', '-layout', file.path, '-', pgroup: true, rlimit_cpu: [5, 5], rlimit_as: [256 * 1024 * 1024, 256 * 1024 * 1024]) do |input, output, errors, child|
              input.close
              # Discard bounded stderr: PDF content/provider detail must never log.
              reader = Thread.new { errors.read(4096) }
              begin
                Timeout.timeout(6) do
                  result = output.read(MAX_TEXT_BYTES + 1).to_s
                  raise Unreadable, 'oversized_pdf_text' if result.bytesize > MAX_TEXT_BYTES
                  raise Unreadable, 'unreadable_pdf' unless child.value.success?
                end
              rescue Timeout::Error
                raise Unreadable, 'pdf_timeout'
              ensure
                if child.alive?
                  Process.kill('KILL', -child.pid) rescue Errno::ESRCH
                end
                reader.kill if reader.alive?
                reader.join
              end
            end
            result.force_encoding('UTF-8').scrub
          end
        rescue Errno::ENOENT
          raise Unreadable, 'pdf_extractor_unavailable'
        end
      end
    end
  end
end
