# frozen_string_literal: true

require "digest"
require "active_support/core_ext/time"
require_relative "../durable_effects"
require_relative "volunteer_daily_awards"

module Decidim
  module Bih
    module Goodwill
      # Builds and enqueues Goodwill award payloads for Decidim adapter seams.
      # The Decidim overrides keep callback timing and transition guards; this
      # service owns the Goodwill action names, metadata, and idempotency keys.
      module AwardDispatch
        module_function

        def comment_created(comment, author:, job: GoodwillAwardJob)
          enqueue(
            job,
            owner: author,
            action: "comment",
            idempotency_key: IdempotencyKey.comment(comment.id),
            metadata: { resource_gid: resource_gid(comment.commentable) }
          )
        end

        def proposal_published(proposal, author:, job: GoodwillAwardJob)
          enqueue(
            job,
            owner: author,
            action: "proposal",
            idempotency_key: IdempotencyKey.proposal(proposal.id, author.id),
            metadata: { resource_gid: resource_gid(proposal), occurred_at: proposal.respond_to?(:published_at) ? proposal.published_at&.iso8601 : nil }.compact
          )
        end

        def resource_liked(resource, liker:, job: GoodwillAwardJob)
          enqueue(
            job,
            owner: liker,
            action: "like",
            idempotency_key: IdempotencyKey.like(resource&.to_gid, liker.id),
            metadata: { resource_gid: resource_gid(resource) }
          )
        end

        def debate_created(debate, author:, job: GoodwillAwardJob)
          enqueue(
            job,
            owner: author,
            action: "debate",
            idempotency_key: IdempotencyKey.debate(debate.id, author.id),
            metadata: { resource_gid: resource_gid(debate) }
          )
        end

        def proposal_vote(vote, job: GoodwillAwardJob)
          enqueue(
            job,
            owner: vote.author,
            action: "vote",
            idempotency_key: IdempotencyKey.proposal_vote(vote.decidim_proposal_id, vote.decidim_author_id),
            metadata: { resource_gid: resource_gid(vote.proposal) }
          )
        end

        def budget_checkout(order, job: GoodwillAwardJob)
          enqueue(
            job,
            owner: order.user,
            action: "budget_vote",
            idempotency_key: IdempotencyKey.budget_vote(order.decidim_budgets_budget_id, order.decidim_user_id),
            metadata: { resource_gid: resource_gid(order.budget) }
          )
        end

        def verification_welcome(user, user_id: user.id, job: GoodwillAwardJob)
          enqueue(
            job,
            owner: user,
            action: "verification",
            idempotency_key: IdempotencyKey.verification(user_id)
          )
        end

        def postal_verified(user, user_id: user.id, job: GoodwillAwardJob)
          enqueue(
            job,
            owner: user,
            action: "postal_verified",
            idempotency_key: IdempotencyKey.postal_verified(user_id)
          )
        end

        def komsiluk_selected(user, job: GoodwillAwardJob)
          enqueue(
            job,
            owner: user,
            action: "komsiluk_selected",
            idempotency_key: IdempotencyKey.komsiluk_selected(user.id)
          )
        end

        def report_created(report, author:, earning_rules: EarningRules.new)
          return nil unless author

          earning_rules.award(
            author,
            :report,
            idempotency_key: IdempotencyKey.report(report.id)
          )
        end

        def volunteer_availability_registered(record, user:, earning_rules: EarningRules.new)
          earning_rules.award(
            user,
            :volunteer_availability,
            idempotency_key: IdempotencyKey.volunteer_availability(record.id),
            metadata: { volunteer_availability_id: record.id }
          )
        end

        def volunteer_opportunity_approved(opportunity, reviewer:, earning_rules: EarningRules.new)
          return nil unless opportunity.author

          if Decidim::Bih.volunteer_proposal_award_unit.to_sym == :proposal
            return volunteer_proposal_approved(opportunity, reviewer:, earning_rules:)
          end

          earning_rules.award(
            opportunity.author,
            :volunteer_opportunity,
            idempotency_key: IdempotencyKey.volunteer_opportunity(opportunity.id),
            metadata: { volunteer_opportunity_id: opportunity.id, reviewed_by_id: reviewer.id }
          )
        end

        def volunteer_log_verified(log, ledger: Ledger.new, earning_rules: nil)
          if Decidim::Bih.volunteer_work_award_unit.to_sym == :day
            return VolunteerDailyAwards.award_for(log, ledger:, earning_rules:)
          end

          earning_rules ||= EarningRules.new
          points_per_hour = earning_rules.points_for(:volunteer_hour)

          ledger.award(
            log.user,
            log.hours * points_per_hour,
            reason: "volunteer_hour",
            idempotency_key: IdempotencyKey.volunteer_log(log.id),
            metadata: { volunteer_log_id: log.id, hours: log.hours }
          )
        end

        def volunteer_proposal_approved(opportunity, reviewer:, earning_rules:)
          identity = opportunity.reward_proposal_identity
          organization = opportunity.organization

          VolunteerProposalAward.transaction do
            # Different terms lock different opportunity rows. This shared
            # transaction lock serializes the award for their proposal identity.
            sql = ActiveRecord::Base.sanitize_sql_array(
              ["SELECT pg_advisory_xact_lock(?, hashtext(?))", organization.id, "volunteer-proposal:#{identity}"]
            )
            ActiveRecord::Base.connection.execute(sql)
            return nil if VolunteerProposalAward.exists?(organization:, proposal_identity: identity)

            # The coordinated host cutover can follow approvals made while
            # the new schema was already present. Detect their old term keys
            # here as well as in the migration's initial backfill.
            terms = VolunteerOpportunity.where(organization:)
            terms = if opportunity.series_key.present?
                      terms.where("proposal_identity = ? OR series_key = ?", identity, opportunity.series_key)
                    else
                      terms.where(proposal_identity: identity)
                    end
            term_ids = terms.pluck(:id)
            term_ids << opportunity.id unless term_ids.include?(opportunity.id)
            legacy = Transaction.where(
              organization:, reason: "volunteer_opportunity",
              idempotency_key: term_ids.map { |id| IdempotencyKey.volunteer_opportunity(id) }
            ).order(:id).first
            if legacy
              VolunteerProposalAward.create!(
                organization:, proposal_identity: identity, first_opportunity_id: opportunity.id,
                legacy_transaction_id: legacy.id
              )
              return nil
            end

            transaction = earning_rules.award(
              opportunity.author,
              :volunteer_opportunity,
              idempotency_key: IdempotencyKey.volunteer_proposal(identity),
              metadata: { volunteer_opportunity_id: opportunity.id,
                          proposal_identity: identity, reviewed_by_id: reviewer.id }
            )
            VolunteerProposalAward.create!(
              organization:, proposal_identity: identity, first_opportunity_id: opportunity.id
            )
            transaction
          end
        end

        def contribution_offer_recognized(offer, reviewer:, earning_rules: EarningRules.new)
          return nil unless reviewer
          return nil unless offer.personal? && offer.contributor

          earning_rules.award(
            offer.contributor,
            :contribution_offer,
            idempotency_key: IdempotencyKey.contribution_offer(offer.id),
            metadata: {
              contribution_offer_id: offer.id,
              contribution_need_id: offer.contribution_need_id
            }
          )
        end

        def komsiluk_post_created(post, author:, earning_rules: EarningRules.new)
          earning_rules.award(
            author,
            :komsiluk_post,
            idempotency_key: IdempotencyKey.komsiluk_post(post.id)
          )
        end

        def referral_rewarded(referral, invitee:, ledger: Ledger.new, earning_rules: EarningRules.new)
          ledger.award(
            referral.referrer,
            earning_rules.points_for(:referral),
            reason: "referral",
            idempotency_key: IdempotencyKey.referral(invitee.id),
            metadata: { invitee_id: invitee.id }
          )
        end

        def manual_award(owner, amount:, admin:, reason:, ledger: Ledger.new, request_key: SecureRandom.uuid)
          ledger.award(
            owner,
            amount,
            reason: "manual",
            idempotency_key: RequestIdentity.key("manual", admin, request_key),
            metadata: {
              admin_id: admin.id,
              admin_reason: reason
            }
          )
        end

        def reverse_transaction(transaction, ledger: Ledger.new, actor: nil, **fulfillment_options)
          ledger.reverse(transaction, actor:, **fulfillment_options)
        end

        def resource_gid(resource)
          resource&.to_gid&.to_s
        end

        def enqueue(job, **payload)
          Decidim::Bih::DurableEffects.enqueue(job, **payload)
        end

        def manual_idempotency_key(owner, amount:, admin:, reason:, at:)
          reason_digest = Digest::SHA256.hexdigest(reason)
          minute = at.strftime("%Y%m%d%H%M")

          "manual:#{admin.id}:#{owner.id}:#{minute}:#{amount}:#{reason_digest}"
        end
        private_class_method :resource_gid
        private_class_method :enqueue
        private_class_method :manual_idempotency_key
      end
    end
  end
end
