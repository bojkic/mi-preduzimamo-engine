# frozen_string_literal: true

module Decidim
  module Bih
    module Komsiluk
      # Capture only when a publication is created. Recovery consumes these
      # existing receipts, so a later member never receives a historical replay.
      module NoticePublishing
        module_function

        def identity_for(post)
          "komsiluk:#{post.publication_key.presence || "post-#{post.id}"}:#{post.content_revision}"
        end

        def publish!(post:, identity: nil, expires_at: nil, context: {}, captured_recipient_ids: nil)
          return unless current_post?(post)

          post.with_lock do
            # The lock reloads persisted state: a concurrent hide/close must not
            # capture an audience that could become dispatchable after restore.
            next unless current_post?(post)

            identity ||= identity_for(post)
            next identity if post.notification_capture_identity == identity

            deadline = expires_at || post.expires_at || 30.days.from_now
            next if deadline <= Time.current

            cancel_pending_phone_for!(post:, reason: "publication_changed") if post.notification_capture_identity.present?

            users = captured_recipient_ids || MembershipResolver.for_komsiluk(organization: post.organization, komsiluk_id: post.komsiluk_id)
                                                                .recipient_ids(exclude_user_id: post.decidim_user_id, honor_opt_out: false)
            Decidim::User.where(organization: post.organization, id: users).find_each do |user|
              receipt = PlatformDelivery.for!(user:, identity:, expires_at: deadline)
              if receipt.komsiluk_post_id.nil?
                receipt.update!(komsiluk_post_id: post.id, publication_revision: post.content_revision,
                                fallback_context: receipt.fallback_context.merge(context.stringify_keys))
              end
              ActiveRecord.after_all_transactions_commit { enqueue(receipt.id) }
            end
            # Internal receipt bookkeeping must not trigger a content revision.
            post.update_columns(notification_capture_identity: identity) # rubocop:disable Rails/SkipsModelValidations
            identity
          end
        end

        def current_post?(post)
          post && post.status == "open" && post.details.to_h.dig("moderation", "source_hold") != true &&
            (post.expires_at.nil? || post.expires_at > Time.current)
        end

        def current_receipt?(receipt)
          return false if receipt.cancelled_at || receipt.expires_at <= Time.current

          post = receipt.komsiluk_post
          return false unless current_post?(post) && post.decidim_organization_id == receipt.decidim_organization_id
          return false unless post.content_revision == receipt.publication_revision
          return false unless source_current?(post)

          user = receipt.user
          return false unless user.decidim_organization_id == receipt.decidim_organization_id
          return false if user.deleted? || user.blocked? || user.confirmed_at.nil?

          CitizenProfile.exists?(decidim_organization_id: receipt.decidim_organization_id,
                                 decidim_user_id: receipt.decidim_user_id, komsiluk_id: post.komsiluk_id)
        end

        def with_current_receipt(receipt)
          post = receipt.komsiluk_post
          return false unless post

          post.with_lock do
            receipt.with_lock do
              receipt.user.with_lock do
                profile = CitizenProfile.find_by(organization: receipt.organization, user: receipt.user)
                next false unless profile

                profile.with_lock do
                  next false unless current_receipt?(receipt)

                  yield
                  true
                end
              end
            end
          end
        end

        def refresh_existing_revision!(post:, previous_revision:)
          return if post.notification_capture_identity.blank?

          receipts = PlatformDelivery.where(komsiluk_post_id: post.id, identity: post.notification_capture_identity,
                                            publication_revision: previous_revision)
          return unless receipts.exists?

          cancel_pending_phone_for!(post:, reason: "publication_changed")
          # Preserve each captured identity and terminal state without callbacks.
          receipts.update_all(publication_revision: post.content_revision, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        end

        # Called from the host's existing privacy sweep. Keep unresolved provider
        # handoffs available for reconciliation; no routine export gets members.
        def purge_expired_private_data!(organization:, before:, dry_run: false)
          raise ArgumentError, "cutoff must be at least 90 days old" if before > 90.days.ago

          KomsilukSendIntent.transaction do
            terminal_ids = KomsilukPhoneDelivery.where(organization:, status: %w(delivered rejected failed skipped))
                                                .where(expires_at: ...before).pluck(:id)
            remaining_phone = KomsilukPhoneDelivery.where(organization:).where.not(id: terminal_ids)
            receipt_ids = PlatformDelivery.where(organization:).where.not(publication_revision: nil)
                                          .where(expires_at: ...before)
                                          .where.not(id: remaining_phone.select(:platform_delivery_id)).pluck(:id)
            intents = KomsilukSendIntent.where(organization:).where(expires_at: ...before)
            retained_keys = KomsilukPost.where(organization:).where("expires_at IS NULL OR expires_at >= ?", before)
                                        .where.not(publication_key: nil).select(:publication_key)
            deleted_intent_ids = intents.where.not(id: remaining_phone.select(:send_intent_id))
                                        .where.not(publication_key: retained_keys).pluck(:id)
            # Reconciliation of accepted/unknown work uses provider IDs only.
            # Its recipient evidence stays; expired message copy can be scrubbed.
            active_ids = remaining_phone.where(status: %w(pending sending)).select(:send_intent_id)
            scrubbed_intent_ids = intents.where.not(id: active_ids).where.not(id: deleted_intent_ids)
                                         .where(payload_scrubbed_at: nil).pluck(:id)
            count = terminal_ids.size + receipt_ids.size + deleted_intent_ids.size + scrubbed_intent_ids.size
            unless dry_run
              KomsilukPhoneDelivery.where(id: terminal_ids).delete_all
              PlatformDelivery.where(id: receipt_ids).delete_all
              # Scrub without decrypting or revalidating expired message copy.
              KomsilukSendIntent.where(id: scrubbed_intent_ids)
                                .update_all(payload_ciphertext: nil, payload_scrubbed_at: Time.current, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
              KomsilukSendIntent.where(id: deleted_intent_ids).delete_all
            end
            count
          end
        end

        def source_current?(post)
          record = post.details.to_h.deep_stringify_keys["source_record"]
          return true if record.blank?
          return false unless NoticeComposer.source_provider

          intent = KomsilukSendIntent.where(organization: post.organization, publication_key: post.publication_key, kind: %w(publication correction), state: "confirmed")
                                     .order(confirmed_at: :desc, id: :desc).first
          return false unless intent

          source = NoticeComposer.source_provider.call(organization: post.organization, actor: intent.actor,
                                                       kind: record["kind"], id: record["id"])
          current = source.to_h.deep_stringify_keys.dig("details", "source_record")
          current && current["revision"] == record["revision"]
        rescue StandardError => e
          Rails.logger.warn("[komsiluk_delivery] source unavailable #{e.class}")
          false
        end

        def cancel_pending_for!(post:, reason:)
          scope = PlatformDelivery.where(komsiluk_post_id: post.id, cancelled_at: nil)
          # Cancellation changes receipt evidence only, never publication copy.
          scope.update_all(cancelled_at: Time.current, cancellation_reason: reason.to_s.first(80)) # rubocop:disable Rails/SkipsModelValidations
          cancel_pending_phone_for!(post:, reason:)
        end

        def cancel_pending_phone_for!(post:, reason:)
          receipts = PlatformDelivery.where(komsiluk_post_id: post.id)
          KomsilukPhoneDelivery.where(platform_delivery_id: receipts.select(:id), status: "pending").find_each do |delivery|
            delivery.with_lock do
              next unless delivery.status == "pending"

              delivery.update!(status: "skipped", reason: reason.to_s.first(80))
              NoticePhonePolicy.release_budget!(delivery)
            end
          end
        end

        def replay_captured!(post:, identity: post.notification_capture_identity)
          return 0 if identity.blank? || post.notification_capture_identity != identity

          receipts = PlatformDelivery.where(organization: post.organization, komsiluk_post_id: post.id, identity:, cancelled_at: nil)
                                     .where("expires_at > ?", Time.current)
          count = 0
          receipts.find_each do |receipt|
            KomsilukNoticeDeliveryJob.perform_now(receipt.id)
            count += 1
          end
          count
        end

        def recover_pending!
          PlatformDelivery.where.not(komsiluk_post_id: nil).where(notification_dispatched_at: nil, cancelled_at: nil)
                          .where("expires_at > ?", Time.current).order(:id).limit(200).pluck(:id).each do |id|
            enqueue(id)
          end
          KomsilukPhoneDelivery.where(status: "pending").where("due_at <= ? OR expires_at <= ?", Time.current, Time.current)
                               .limit(200).each(&:enqueue)
          KomsilukPhoneDelivery.where(status: %w(accepted unknown)).where.not(provider_message_ids: [])
                               .where("provider_checked_at IS NULL OR provider_checked_at < ?", 1.hour.ago)
                               .where("expires_at > ?", 7.days.ago).limit(100).pluck(:id).each do |id|
            KomsilukPhoneReconciliationJob.perform_later(id)
          end
          # A stale committed claim is unresolved; it must never be requeued.
          KomsilukPhoneDelivery.where(status: "sending").where(attempted_at: ...30.minutes.ago)
                               .update_all(status: "unknown", reason: "worker_interrupted", updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        end

        def enqueue(receipt_id)
          KomsilukNoticeDeliveryJob.perform_later(receipt_id)
        rescue StandardError => e
          Rails.logger.warn("[komsiluk_delivery] enqueue unavailable #{e.class}")
        end

        def board_url(post)
          helpers = Engine.routes.url_helpers
          options = { host: post.organization.host, protocol: "https", script_name: Decidim::Bih.normalized_public_mount_path }
          post.publication_key.present? ? helpers.komsiluk_publication_url(post.publication_key, **options) : helpers.komsiluk_board_url(post, **options)
        end
      end
    end
  end
end
