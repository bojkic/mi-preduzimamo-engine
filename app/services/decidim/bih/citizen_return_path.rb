# frozen_string_literal: true

module Decidim
  module Bih
    # Preserve a small set of citizen GET destinations across passwordless
    # sign-in. Never store a report status token, arbitrary query, or action URL.
    module CitizenReturnPath
      KEY = :bih_citizen_return
      EXPIRY_SECONDS = 2 * 60 * 60

      module_function

      def allowed_paths
        %w(moj-nalog moj-nalog/poruke moj-doprinos organizacije/nova projekti/novi).map { |path| Decidim::Bih.public_path(path) } +
          ["#{Decidim::Bih.public_path('prijave')}?view=mine"] +
          %w(dostupnost predlozi moje).map { |tab| "#{Decidim::Bih.public_path('volontiranje')}?tab=#{tab}" }
      end

      def valid?(path)
        allowed_paths.include?(path.to_s)
      end

      def store(session, organization:, path:)
        return false unless valid?(path)

        session[KEY] = { "path" => path, "organization_id" => organization.id, "expires_at" => Time.now.to_i + EXPIRY_SECONDS }
        true
      end

      def consume(session, organization:)
        entry = session.delete(KEY).to_h
        return unless entry["organization_id"].to_i == organization.id && entry["expires_at"].to_i > Time.now.to_i
        return unless valid?(entry["path"])

        entry["path"]
      end
    end
  end
end
