# frozen_string_literal: true

module Decidim
  module Bih
    module ReportMailbox
      module ReplyText
        MARKER = /\A(?:>|On .+ wrote:|Dana .+ je napisa(?:o|la):|[-]+Original Message[-]+|Od:.*Poslano:)/i
        def self.full_text(mail)
          part = mail.text_part || (mail.multipart? ? nil : mail)
          return "" unless part

          charset = begin
            Encoding.find(part.charset.presence || "UTF-8")
          rescue ArgumentError
            Encoding::UTF_8
          end
          part.body.decoded.to_s.dup.force_encoding(charset).encode("UTF-8", invalid: :replace, undef: :replace)
        end

        def self.new_part(mail)
          full_text(mail).lines.take_while { |line| !line.strip.match?(MARKER) }.join.strip
        end
      end
    end
  end
end
