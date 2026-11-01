# frozen_string_literal: true

module Decidim
  module Bih
    module Komsiluk
      # A read-only, per-publication work list. Recipient and provider identities
      # stay in the delivery ledger; every query starts from accessible posts.
      class DeliveryOperations
        PAGE_SIZE = 25
        ISSUE_KEYS = %w(inbox_stalled push_stalled push_failed push_uncertain phone_stalled phone_failed phone_unknown phone_expired expiry_backlog).freeze
        Entry = Struct.new(:post, :issues, keyword_init: true)

        class << self
          attr_accessor :source_provider
        end

        attr_reader :counts, :entries, :page, :total, :source_groups

        def initialize(organization:, actor:, scope:, page: 1, at: Time.current)
          @organization = organization
          @scope = scope.where(organization:)
          @at = at
          @issues = Hash.new { |hash, id| hash[id] = {} }
          collect_issues
          @counts = ISSUE_KEYS.index_with { |key| @issues.values.sum { |issues| issues.fetch(key, 0) } }
          @total = @issues.size
          @page = page.to_i.clamp(1, pages)
          posts = @scope.where(id: @issues.keys).includes(:komsiluk).order(updated_at: :desc, id: :desc).offset((@page - 1) * PAGE_SIZE).limit(PAGE_SIZE)
          @entries = posts.map { |post| Entry.new(post:, issues: @issues.fetch(post.id)) }
          @source_groups = Array(self.class.source_provider&.call(organization:, actor:))
        end

        def pages
          [(@total.to_f / PAGE_SIZE).ceil, 1].max
        end

        private

        def receipts
          @receipts ||= PlatformDelivery.where(organization: @organization, komsiluk_post_id: @scope.select(:id))
        end

        def active_receipts
          receipts.where(cancelled_at: nil).where("expires_at > ?", @at)
        end

        def collect_issues
          pending = active_receipts.where(notification_dispatched_at: nil, created_at: ...(@at - 15.minutes))
          add("inbox_stalled", pending.where(inbox_created_at: nil).group(:komsiluk_post_id).count)
          collect_push_issues(pending)
          collect_phone_issues
          add("expiry_backlog", @scope.where(status: "open", expires_at: ..@at).group(:id).count)
        end

        def collect_push_issues(pending)
          attempts = Messaging::Attempt.where(channel: "push", intent_id: active_receipts.select(:push_intent_id))
          intent_posts = active_receipts.where.not(push_intent_id: nil).pluck(:push_intent_id, :komsiluk_post_id).to_h
          %w(failed uncertain).each do |status|
            attempts.where(status:).group(:intent_id).count.each do |intent_id, count|
              post_id = intent_posts[intent_id]
              add("push_#{status}", { post_id => count }) if post_id
            end
          end
          queued = active_receipts.where(push_queued_at: ...(@at - 15.minutes)).where.not(push_intent_id: nil)
          no_attempt = queued.where.not(push_intent_id: attempts.select(:intent_id))
          claimed = queued.where(push_intent_id: attempts.where(status: %w(queued claimed), updated_at: ...(@at - 15.minutes)).select(:intent_id))
          stalled_ids = pending.where.not(inbox_created_at: nil).pluck(:id) | no_attempt.pluck(:id) | claimed.pluck(:id)
          add("push_stalled", active_receipts.where(id: stalled_ids).group(:komsiluk_post_id).count)
        end

        def collect_phone_issues
          phones = KomsilukPhoneDelivery.where(organization: @organization, platform_delivery_id: receipts.select(:id))
          add_phone("phone_failed", phones.where(status: %w(failed rejected)))
          add_phone("phone_unknown", phones.where(status: "unknown"))
          add_phone("phone_expired", phones.where(status: "pending", expires_at: ..@at))
          live = phones.where("expires_at > ?", @at)
          stalled = live.where(status: "pending", due_at: ...(@at - 15.minutes))
                        .or(live.where(status: "sending", attempted_at: ...(@at - 30.minutes)))
          awaiting_report = phones.where(status: "accepted").where(
            "provider_checked_at < :cutoff OR (provider_checked_at IS NULL AND updated_at < :cutoff)", cutoff: @at - 1.hour
          )
          add_phone("phone_stalled", phones.where(id: stalled.select(:id)).or(phones.where(id: awaiting_report.select(:id))))
        end

        def add_phone(key, scope)
          counts = scope.group(:platform_delivery_id).count
          receipts.where(id: counts.keys).pluck(:id, :komsiluk_post_id).each do |id, post_id|
            add(key, { post_id => counts.fetch(id) })
          end
        end

        def add(key, counts)
          counts.each do |post_id, count|
            @issues[post_id][key] = @issues[post_id].fetch(key, 0) + count
          end
        end
      end
    end
  end
end
