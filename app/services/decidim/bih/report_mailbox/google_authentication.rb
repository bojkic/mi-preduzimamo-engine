# frozen_string_literal: true

module Decidim
  module Bih
    module ReportMailbox
      module GoogleAuthentication
        def self.parse(mail)
          # Only the first receiving authentication stamp may confer trust. A
          # lower Google-looking stamp can have been supplied by the sender.
          stamp = mail.header.fields.find { |field| field.name.casecmp?("Authentication-Results") }&.value.to_s
          return {} unless stamp.split(";", 2).first.to_s.strip.casecmp?("mx.google.com")
          dkim = stamp.scan(/dkim=(\w+)[^;]*?header\.(?:d|i)=@?([\w.-]+)/i)
          dmarc = stamp.match(/dmarc=(\w+)[^;]*?header\.from=([\w.-]+)/i)
          { "dkim" => dkim.any? { |result, _| result.casecmp?("pass") } ? "pass" : "none",
            "dkim_domains" => dkim.select { |result, _| result.casecmp?("pass") }.map { |_, domain| domain.downcase },
            "dmarc" => dmarc && dmarc[1].downcase, "from_domain" => dmarc && dmarc[2].downcase }
        end
      end
    end
  end
end
