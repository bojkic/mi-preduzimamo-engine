# frozen_string_literal: true
module Decidim
  module Bih
    module Race
      module QualificationTracking
        extend ActiveSupport::Concern
        included do
          around_save :capture_first_race_qualification
        end

        private

        def capture_first_race_qualification
          return yield unless name == "sms" && granted_at && (new_record? || will_save_change_to_granted_at?) && user&.organization
          edition = Edition.ensure_for!(user.organization)
          edition.with_lock do
            result = yield
            if edition.baseline_at
              profile = Decidim::Bih::CitizenProfile.find_by(user:, organization: user.organization)
              Membership.capture!(edition, profile, provenance: "first_qualification") if profile
            end
            result
          end
        end
      end
    end
  end
end
