# frozen_string_literal: true
module Decidim
  module Bih
    module Race
      module MembershipTracker
        module_function
        # Edition -> profile is the common lock order for baseline and assignment.
        def track(profile)
          return yield unless profile.organization
          edition = Edition.ensure_for!(profile.organization)
          edition.with_lock do
            previous = profile.persisted? ? profile.class.find(profile.id) : nil
            Membership.capture!(edition, previous, provenance: "cutover_baseline") if edition.baseline_at && previous
            changed = profile.new_record? || profile.will_save_change_to_komsiluk_id?
            result = yield
            if changed
              edition.record!("profile_assignment", user_id: profile.decidim_user_id,
                              before: previous&.komsiluk_id, after: profile.komsiluk_id,
                              assigned_at: profile.assigned_at&.iso8601, source: profile.source)
            end
            Membership.capture!(edition, profile) if edition.baseline_at
            result
          end
        end
      end
    end
  end
end
