# frozen_string_literal: true

module Decidim
  module Bih
    module Sistem48
      # Resolves the destination e-mail for a forwarded "Bice riseno" report.
      #
      # Some municipalities run Sistem 48 with a single public intake address.
      # Host apps can configure that central address and still route specific
      # categories to department mailboxes.
      #
      # Resolution precedence (DB wins, empty store == previous behavior):
      #   1. per-organization DB override (Decidim::Bih::Setting, W4.4 admin UI)
      #   2. per-category ENV override   (SISTEM48_EMAIL_<CATEGORY>)
      #   3. central intake DB override  (Decidim::Bih::Setting, "central_intake")
      #   4. central intake ENV/host config (SISTEM48_CENTRAL_INTAKE)
      #
      # Categories are the symbols from
      # Decidim::Bih::ReportTaxonomy::CATEGORIES.
      module DepartmentRouting
        # The Setting namespace W4.4 reads/writes.
        NAMESPACE = "sistem48_routing"
        # Key under NAMESPACE holding the central-intake override.
        CENTRAL_INTAKE_KEY = "central_intake"

        module_function

        # Destination address for a report category, scoped to an organization
        # when given. Precedence is described in the module comment; with no org
        # / an empty Settings store this is identical to the ENV/default routing.
        def email_for(category, organization = nil)
          overrides = Decidim::Bih::Setting.namespace_for(organization, NAMESPACE)

          db_category = overrides[category.to_s]
          return db_category if db_category.present?

          env_category = ENV.fetch(env_key(category), nil)
          return env_category if env_category.present?

          db_central = overrides[CENTRAL_INTAKE_KEY]
          return db_central if db_central.present?

          central_intake_default
        end

        # The effective central intake (DB override → ENV/host config). Surfaced
        # by the admin form to show the operator the current value.
        def central_intake(organization = nil)
          db = Decidim::Bih::Setting.namespace_for(organization, NAMESPACE)[CENTRAL_INTAKE_KEY]
          db.presence || central_intake_default
        end

        # ENV var name for a category override, e.g. :putevi => "SISTEM48_EMAIL_PUTEVI".
        def env_key(category)
          "SISTEM48_EMAIL_#{category.to_s.upcase}"
        end

        def central_intake_default
          ENV.fetch("SISTEM48_CENTRAL_INTAKE", nil).presence ||
            Decidim::Bih.sistem48_central_intake
        end
      end
    end
  end
end
