# frozen_string_literal: true

require "json"

module Decidim
  module Bih
    module ReportMailbox
      class Config
        class InsecureFile < StandardError; end
        class Invalid < StandardError; end
        attr_reader :host, :port, :tls, :username
        def self.load(path = ENV["MI_REPORT_MAILBOX_CONFIG"])
          return nil if path.to_s.empty? || !File.exist?(path)
          File.open(path, "r") do |file|
            raise InsecureFile, "Mailbox configuration must not be world accessible" unless (file.stat.mode & 0o007).zero?
            new(JSON.parse(file.read))
          end
        rescue JSON::ParserError, TypeError, ArgumentError
          raise Invalid, "Invalid mailbox configuration"
        end
        def initialize(data)
          raise Invalid unless %w(host port tls username password).all? { |key| data.key?(key) }
          @host, @port, @tls, @username, @password = data.values_at("host", "port", "tls", "username", "password")
          raise Invalid unless host.is_a?(String) && host.present? && port.is_a?(Integer) && port.between?(1, 65535) && tls == true && username.to_s.match?(URI::MailTo::EMAIL_REGEXP) && @password.is_a?(String) && @password.present?
        end
        def smtp_settings
          { address: "smtp.gmail.com", port: 587, enable_starttls_auto: true, authentication: :plain,
            user_name: username, password: @password, domain: username.split("@", 2).last,
            open_timeout: 30, read_timeout: 30 }
        end
        def login(imap) = imap.login(username, @password)
        def inspect = "#<#{self.class} host=#{host.inspect} port=#{port} password=[REDACTED]>"
      end
    end
  end
end
