# frozen_string_literal: true

require "uri"

module Decidim
  module Bih
    module Komsiluk
      # Only a board GET destination survives sign-in/verification/assignment.
      module ReturnPath
        KEY = :bih_board_return

        module_function

        def valid?(path)
          value = path.to_s
          return false if value.length > 600 || value.match?(/[\\\x00-\x20]/)

          parsed = URI.parse(value)
          base = Regexp.escape(Decidim::Bih.public_path("komsiluk-board"))
          decoded_path = URI.decode_www_form_component(parsed.path.to_s)
          parsed.host.nil? && parsed.scheme.nil? && decoded_path.match?(%r{\A#{base}(?:/\d+(?:/edit)?|/objava/[A-Za-z0-9_:\-]+)?\z})
        rescue URI::InvalidURIError, ArgumentError
          false
        end

        def store(session, organization:, path:)
          return unless valid?(path)

          session[KEY] = { "path" => path, "organization_id" => organization.id, "expires_at" => 2.hours.from_now.to_i }
        end

        def consume(session, organization:)
          entry = session.delete(KEY).to_h.stringify_keys
          return unless entry["organization_id"].to_i == organization.id && entry["expires_at"].to_i > Time.current.to_i && valid?(entry["path"])

          entry["path"]
        end
      end
    end
  end
end
