# frozen_string_literal: true

module Decidim
  module Bih
    module Onboarding
      # The single answer to "where does this citizen go next?" after
      # registration, e-mail confirmation, a consumed magic link, a typed code
      # or a komšiluk assignment. Every redirect in the onboarding chain asks
      # here so the order (phone → komšiluk → account) lives in one place.
      #
      # This resolver is SIDE-EFFECT FREE and must stay that way: it is
      # consulted from GET-time redirects, so it reads and never writes.
      # In particular it must not go through CitizenProfile.for_user, which is
      # a find_or_create_by! and would INSERT a profile row for every
      # phone-verified citizen who has not yet picked a komšiluk. The row is
      # created where the citizen actually picks one, not where we ask.
      module NextStep
        # Decidim mounts the verifications engine at "/" and each workflow at
        # "/<name>", so the core SMS phone form is a fixed path. Engine
        # services have no route helpers, exactly like the hero cell's host
        # paths, so this is a literal.
        #
        # decidim-verifications registers the :sms workflow — and mounts these
        # routes — only when the host sets `Decidim.sms_gateway_service` (this
        # app does, in config/initializers/decidim_sms.rb). The rails harness's
        # generated host now does the same: script/decidim_bih_rails_test writes
        # config/initializers/decidim_bih_generated_host_sms.rb into it, so the
        # path really resolves there and rails_test/phone_first_registration_test.rb
        # proves it by following the sign-up redirect to a 200. A host that has
        # NOT opted into phone-first registers no such workflow, which is why
        # every caller gates this destination on
        # Decidim::Bih.phone_first_registration.
        SMS_NEW_PATH = "/sms/authorizations/new"

        module_function

        def for(user, organization:)
          authorization = Decidim::Authorization.find_by(user:, name: "sms")
          return SMS_NEW_PATH if authorization.nil?
          return Decidim::Bih.public_path("verifikacija/telefon") unless authorization.granted?

          # Read-only lookup, and nil-safe on purpose: "no profile row yet" and
          # "row exists but komsiluk_id is nil" are the same answer — send the
          # citizen to the picker.
          profile = Decidim::Bih::CitizenProfile.find_by(
            decidim_organization_id: organization.id,
            decidim_user_id: user.id
          )
          return "#{Decidim::Bih.public_path("komsiluk")}?setup=1" unless profile&.assigned?

          # The welcome page is the last step of the chain: it keeps answering
          # until the citizen presses "Krenimo" (and accounts verified before
          # the release are stamped once by
          # rake decidim_bih:registration:backfill_welcomed). Asking here must
          # not consume it — Welcome.mark! is called by the WelcomeController's
          # POST, never by this resolver; see the side-effect-free contract above.
          return Decidim::Bih.public_path("moj-nalog") if Decidim::Bih.simplified_registration

          return Decidim::Bih.public_path("dobrodosli") unless Welcome.welcomed?(user)

          "#{Decidim::Bih.public_path("moj-nalog")}?setup=1"
        end
      end
    end
  end
end
