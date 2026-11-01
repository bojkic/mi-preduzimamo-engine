# frozen_string_literal: true

module Decidim
  module Bih
    module Komsiluk
      # Separate from legacy urgent-bell preferences. Only explicit phone
      # escalation consumes this policy; platform inbox and push do not.
      module PhoneAreaHolds
        NAMESPACE = "komsiluk_delivery"
        IDS_KEY = "phone_held_komsiluk_ids"
        VERSION_KEY = "phone_area_hold_version"
        PERMISSION = :komsiluk_notification_policy_manage

        module_function

        def snapshot(organization)
          # A failed read must stop phone dispatch, so do not use the generic
          # Setting.namespace_for fallback that turns read errors into defaults.
          values = Setting.in_namespace(NAMESPACE).where(organization:).where(key: [IDS_KEY, VERSION_KEY]).pluck(:key, :value).to_h
          { komsiluk_ids: Array(values[IDS_KEY]).map(&:to_s).grep(/\A[1-9]\d*\z/).map(&:to_i).uniq.sort,
            version: values[VERSION_KEY].to_s }
        end

        def save!(organization:, actor:, komsiluk_ids:)
          authorize!(organization, actor)
          # Serialize policy changes without blocking source-publication FK checks.
          organization.with_lock("FOR NO KEY UPDATE") do
            authorize!(organization, actor)
            ids = validated_ids(organization, komsiluk_ids)
            previous = snapshot(organization)
            next previous if previous[:komsiluk_ids] == ids

            version = SecureRandom.hex(16)
            Setting.put(organization, NAMESPACE, IDS_KEY, ids)
            Setting.put(organization, NAMESPACE, VERSION_KEY, version)
            OperatorAuditEvent.record!(
              organization:, actor:, event_type: "komsiluk_phone_area_holds_updated", permission: PERMISSION,
              role: OperatorAuthorization.role_for(actor, PERMISSION, organization:), resource: organization,
              metadata: { previous_held_komsiluk_ids: previous[:komsiluk_ids], held_komsiluk_ids: ids, version: }
            )
            { komsiluk_ids: ids, version: }
          end
        end

        def authorize!(organization, actor)
          return if OperatorAuthorization.allowed?(actor, PERMISSION, organization:)

          raise NoticeComposer::Refused, "permission_required"
        end
        private_class_method :authorize!

        def validated_ids(organization, raw)
          raise NoticeComposer::Refused, "invalid_areas" unless raw.is_a?(Array)

          values = raw.compact_blank.map(&:to_s)
          raise NoticeComposer::Refused, "invalid_areas" unless values.all? { |value| value.match?(/\A[1-9]\d*\z/) }

          ids = values.map(&:to_i).uniq.sort
          valid = LocalArea.komsiluci.where(organization:, id: ids).pluck(:id).sort
          raise NoticeComposer::Refused, "invalid_areas" unless ids == valid

          ids
        end
        private_class_method :validated_ids
      end
    end
  end
end
