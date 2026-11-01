# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Operator decision for organization spending requests. Approval posts the
      # immutable ledger movement; rejection only stamps workflow state.
      class DecideOrganizationSpendingRequest < Decidim::Command
        def initialize(request, decision:, decider:, rejection_reason: nil)
          @request = request
          @decision = decision.to_s
          @decider = decider
          @rejection_reason = rejection_reason.to_s.strip.presence
        end

        def call
          return broadcast(:invalid) unless request&.pending? && decider && decider.organization == request.organization
          return reject! if decision == "rejected"
          return approve! if decision == "approved"

          broadcast(:invalid)
        rescue Decidim::Bih::Goodwill::InsufficientBalanceError
          broadcast(:insufficient)
        rescue ActiveRecord::RecordInvalid, ArgumentError => e
          Rails.logger.warn(
            "[Goodwill] organization spending decision failed for request #{request&.id}: #{e.class}: #{e.message}"
          )
          broadcast(:invalid)
        end

        private

        attr_reader :request, :decision, :decider, :rejection_reason

        def reject!
          request.with_lock do
            return broadcast(:invalid) unless request.pending?

            request.update!(status: "rejected", decided_by: decider, decided_at: Time.current, rejection_reason:)
            audit_decision!
          end
          broadcast(:ok, request)
        end

        def approve!
          ActiveRecord::Base.transaction do
            request.lock!
            return broadcast(:invalid) unless request.pending?

            transaction = post_ledger_movement
            reward = create_reward! if request.reward_sponsorship?
            request.update!(
              status: "approved",
              decided_by: decider,
              decided_at: Time.current,
              metadata: request.metadata.merge(
                "ledger_transaction_id" => transaction&.id,
                "reward_id" => reward&.id
              ).compact
            )
            audit_decision!
          end

          broadcast(:ok, request)
        end

        def audit_decision!
          Decidim::Bih::OperatorAuditEvent.record!(
            organization: request.organization, actor: decider,
            event_type: "organization_spending_decision_committed", permission: "organization_spending_decide",
            resource: request, metadata: { decision:, ledger_transaction_id: request.metadata["ledger_transaction_id"] }
          )
        end

        def post_ledger_movement
          if request.inter_org_support?
            Ledger.new.transfer(
              from_owner: source_owner,
              to_owner: target_owner,
              amount: request.points,
              kind: "gift",
              reason: "inter_org_support",
              idempotency_key: IdempotencyKey.organization_spending_request(request.id),
              metadata: base_metadata
            )
          else
            Ledger.new.spend(
              owner: source_owner,
              amount: request.points,
              kind: "redeem",
              reason: "org_reward_sponsorship",
              idempotency_key: IdempotencyKey.organization_spending_request(request.id),
              metadata: base_metadata
            )
          end
        end

        def create_reward!
          Reward.create!(
            organization: request.organization,
            sponsor_partner_profile: request.source_partner_profile,
            key: sponsored_reward_key,
            title: localized_text(request.reward_title),
            description: localized_text(request.reward_description),
            cost: request.reward_cost,
            stock: request.reward_stock,
            active: true
          )
        end

        def sponsored_reward_key
          "org-#{request.source_partner_profile.slug.to_s.first(180)}-#{request.id}"
        end

        def localized_text(value)
          text = value.to_s.strip
          return {} if text.blank?

          {
            "sr" => text,
            "sr-Cyrl" => Decidim::Bih::Transliterator.call(text),
            "bs" => text,
            "hr" => text,
            "en" => text
          }
        end

        def source_owner
          PartnerOwner.owner_for(request.source_partner_profile)
        end

        def target_owner
          PartnerOwner.owner_for(request.target_partner_profile)
        end

        def base_metadata
          {
            organization_spending_request_id: request.id,
            request_type: request.request_type,
            category: request.category,
            source_partner_profile_id: request.source_partner_profile_id,
            target_partner_profile_id: request.target_partner_profile_id,
            requested_by_id: request.requested_by_id,
            decided_by_id: decider&.id
          }.compact
        end
      end
    end
  end
end
