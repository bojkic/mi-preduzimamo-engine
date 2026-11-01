# frozen_string_literal: true

module Decidim
  module Bih
    module Onboarding
      module ReturnPath
        KEY = :bih_onboarding_return

        module_function

        def valid?(path)
          Komsiluk::ReturnPath.valid?(path) || CitizenReturnPath.valid?(path) || path == Decidim::Bih.public_path("prijave/new")
        end

        def store(session, user:, organization:, path:)
          return unless valid?(path)

          session[KEY] = { "path" => path, "user_id" => user.id, "organization_id" => organization.id, "expires_at" => 2.hours.from_now.to_i }
        end

        def consume(session, user:, organization:)
          entry = session.delete(KEY).to_h.stringify_keys
          unless entry["user_id"].to_i == user.id && entry["organization_id"].to_i == organization.id && entry["expires_at"].to_i > Time.current.to_i && valid?(entry["path"])
            return
          end

          entry["path"]
        end
      end
    end
  end
end
