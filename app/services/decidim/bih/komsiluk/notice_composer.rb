# frozen_string_literal: true

require "digest"
require "securerandom"

module Decidim
  module Bih
    module Komsiluk
      # A preview is a persisted, encrypted proposal; GET never sends or records
      # consent. Confirmation rereads its exact facts and claims it once.
      class NoticeComposer
        class Refused < StandardError; end
        PREVIEW_TTL = 10.minutes
        attr_reader :organization, :actor

        class << self
          attr_accessor :source_provider
        end

        def source_prefill(kind:, id:)
          authorize!(:broadcast_preview)
          raise Refused, "source_review_required" unless self.class.source_provider

          result = self.class.source_provider.call(organization:, actor:, kind:, id:)
          raise Refused, "source_review_required" unless result

          result.to_h.deep_symbolize_keys.slice(:title, :body, :area_ids, :details)
        end

        def initialize(organization:, actor:)
          @organization = organization
          @actor = actor
        end

        def correction_context(post:)
          correction.context(post:)
        end

        def preview_correction(post:, attributes:)
          correction.preview(post:, attributes:)
        end

        def preview_publication(attributes)
          authorize!(:broadcast_preview)
          payload = attributes.to_h.symbolize_keys.slice(:title, :body, :category, :expires_at, :area_ids, :source_kind, :source_id)
          payload[:title] = payload[:title].to_s.strip
          payload[:body] = payload[:body].to_s.strip
          payload[:category] = payload[:category].to_s.presence || "general"
          payload[:expires_at] = parse_time(payload[:expires_at]).iso8601
          payload[:area_ids] = Array(payload[:area_ids]).map(&:to_i).select(&:positive?).uniq.sort
          payload[:publication_key] = SecureRandom.uuid
          if payload[:source_kind].present? || payload[:source_id].present?
            source = source_prefill(kind: payload[:source_kind], id: payload[:source_id])
            payload[:details] = source[:details] || {}
            payload[:source_revision] = digest(source)
          end
          if Array(attributes.to_h.symbolize_keys[:channels]).compact_blank.any?
            probe = KomsilukPost.new(organization:, origin: "staff", publication_key: payload[:publication_key],
                                     content_revision: 1, expires_at: payload[:expires_at], details: payload[:details] || {})
            values = attributes.to_h.symbolize_keys
            values[:text] = "#{payload[:title]}\n#{payload[:body].truncate(600)}" if values[:text].blank?
            values[:sms_text] = payload[:title] if values[:sms_text].blank?
            payload[:phone] = prepare_phone_payload(post: probe, values:)
          end
          validate_publication!(payload)
          save_preview(kind: "publication", payload:, preview: publication_preview(payload))
        end

        def preview_phone(post:, attributes:)
          authorize!(:broadcast_preview)
          raise Refused, "post_unavailable" unless post.organization == organization && NoticePublishing.current_post?(post)

          authorize!(:city_alerts_manage) if post.display_origin == "city_service"

          payload = prepare_phone_payload(post:, values: attributes.to_h.symbolize_keys)
          save_preview(kind: "phone", payload:, preview: phone_preview(payload))
        end

        def confirm!(token)
          intent = KomsilukSendIntent.find_signed(token, purpose: :komsiluk_send_confirmation)
          raise Refused, "preview_expired" unless intent && intent.organization == organization && intent.actor == actor

          return correction.confirm!(intent) if intent.kind == "correction"

          # The same organization lock protects phone-area policy changes.
          # Acquire it before intent/source/post locks through confirmation.
          organization.with_lock("FOR NO KEY UPDATE") do
            confirm_intent!(intent)
          end
          intent
        end

        def confirm_intent!(intent)
          intent.with_lock do
            next intent if intent.state == "confirmed"
            raise Refused, "preview_expired" unless intent.state == "preview" && intent.expires_at > Time.current

            authorize!(:broadcast_send_bell)
            payload = intent.payload
            if intent.kind == "publication"
              with_publication_source_lock(payload) do
                validate_publication!(payload)
                preview = publication_preview(payload)
                confirm_preview!(intent, preview)
                authorize!(:broadcast_send_viber) if payload[:phone]
                posts = publish!(payload, audience: preview[:rows])
                if payload[:phone]
                  phone_preview = preview[:phone].deep_dup
                  receipts = PlatformDelivery.where(komsiluk_post_id: posts.map(&:id)).index_by(&:decidim_user_id)
                  phone_preview[:rows] = phone_preview[:rows].map do |user_id, _board_id, destination, channels, reason|
                    receipt = receipts[user_id]
                    raise Refused, "preview_changed" unless receipt

                    [receipt.id, user_id, destination, channels, reason, receipt.deadline_at.iso8601(6)]
                  end
                  confirm_phone!(intent, payload[:phone], phone_preview)
                end
              end
            else
              authorize!(:broadcast_send_viber)
              posts = NoticePhonePolicy.related_posts(scoped_post(payload.fetch(:post_id))).order(:id).lock.to_a
              raise Refused, "post_unavailable" if posts.empty?

              authorize!(:city_alerts_manage) if posts.any? { |post| post.display_origin == "city_service" }

              preview = phone_preview(payload)
              confirm_preview!(intent, preview)
              confirm_phone!(intent, payload, preview)
            end
            intent.update!(state: "confirmed", confirmed_at: Time.current)
          end
          intent
        end
        private :confirm_intent!

        def view(intent)
          return correction.view(intent) if intent.kind == "correction"

          raise Refused, "preview_unavailable" unless intent.organization == organization && intent.actor == actor

          payload = intent.payload
          preview = intent.kind == "publication" ? publication_preview(payload) : phone_preview(payload)
          { intent:, payload:, summary: public_summary(preview), areas: areas_for(payload[:area_ids] || []),
            posts: intent.kind == "phone" ? NoticePhonePolicy.related_posts(scoped_post(payload[:post_id])).to_a : [] }
        end

        private

        def correction
          StaffNoticeCorrection.new(organization:, actor:)
        end

        def with_publication_source_lock(payload)
          reference = payload.to_h.deep_symbolize_keys.dig(:details, :source_record)
          return yield unless reference

          provider = self.class.source_provider
          raise Refused, "source_review_required" unless provider.respond_to?(:with_reviewed_source_lock)

          entered = false
          result = provider.with_reviewed_source_lock(organization:, actor:, kind: reference[:kind], id: reference[:id], revision: reference[:revision]) do
            entered = true
            yield
          end
          raise Refused, "source_changed" unless entered

          result
        end

        def prepare_phone_payload(post:, values:)
          requested_channels = Array(values[:channels]).map(&:to_s).compact_blank
          raise Refused, "invalid_channel_plan" if (requested_channels - NoticePhonePolicy::CHANNELS).any?

          channels = NoticePhonePolicy::CHANNELS & requested_channels
          mode = values[:mode].to_s.presence || "fallback"
          expires = parse_time(values[:expires_at].presence || post.expires_at || 1.day.from_now)
          expires = [expires, post.expires_at].min if post.expires_at
          payload = { post_id: post.id, publication_key: post.publication_key.presence || "post-#{post.id}",
                      content_revision: post.content_revision, channels:, mode:, text: phone_copy(values[:text], post),
                      sms_text: channels.include?("sms") ? phone_copy(values[:sms_text], post) : "", urgency_reason: values[:urgency_reason].to_s.strip,
                      expires_at: expires.iso8601, retry_failed: ActiveModel::Type::Boolean.new.cast(values[:retry_failed]) }
          raise Refused, "phone_text_required" if payload[:text].blank? || payload[:text].length > 1000
          raise Refused, "urgent_reason_required" if mode != "fallback" && (payload[:urgency_reason].blank? || payload[:urgency_reason].length > 300)
          raise Refused, "sms_text_required" if channels.include?("sms") && payload[:sms_text].blank?

          payload[:phone_area_policy] = PhoneAreaHolds.snapshot(organization)
          payload[:sms] = NoticePhonePolicy.sms_config(organization)
          payload[:segment_estimate] = SmsSegments.estimate(payload[:sms_text])
          raise Refused, "sms_too_long" if payload[:segment_estimate][:segments] > 10

          payload[:template] = NoticePhonePolicy.template(payload[:text]) if channels.include?("whatsapp")
          payload
        end

        def public_summary(preview)
          result = preview.except(:rows)
          result[:phone] = result[:phone].except(:rows) if result[:phone]
          result
        end

        def save_preview(kind:, payload:, preview:)
          intent = KomsilukSendIntent.create!(organization:, actor:, kind:, publication_key: payload.fetch(:publication_key),
                                              preview_digest: digest(preview), payload:, expires_at: PREVIEW_TTL.from_now,
                                              recipients_count: preview.fetch(:total))
          { intent:, payload:, summary: public_summary(preview), areas: areas_for(payload[:area_ids] || []),
            posts: kind == "phone" ? NoticePhonePolicy.related_posts(scoped_post(payload[:post_id])).to_a : [] }
        end

        def authorize!(permission)
          raise Refused, "permission_required" unless OperatorAuthorization.allowed?(actor, permission, organization:)
        end

        def phone_copy(value, post)
          text = value.to_s.strip
          return "" if text.blank?

          url = NoticePublishing.board_url(post)
          text.include?(url) ? text : "#{text}\n#{url}"
        end

        def parse_time(value)
          time = value.respond_to?(:iso8601) ? value : Time.find_zone!("Europe/Sarajevo").parse(value.to_s)
          raise Refused, "invalid_expiry" unless time && time > Time.current && time <= 90.days.from_now

          time
        rescue ArgumentError
          raise Refused, "invalid_expiry"
        end

        def scoped_post(id)
          KomsilukPost.find_by!(organization:, id:)
        end

        def areas_for(ids)
          LocalArea.where(organization:, id: ids).order(:id).to_a
        end

        def boards_for(ids)
          areas = areas_for(ids)
          raise Refused, "area_required" if areas.empty? || areas.size != ids.size

          mzs = areas.select { |area| area.kind == "mz" }
          boards = areas.select { |area| area.kind == "komsiluk" }
          if mzs.any?
            slugs = mzs.map(&:slug)
            boards += LocalArea.komsiluci.where(organization:).select do |board|
              ([board.primary_mz_slug] + Array(board.overlapping_mz_slugs)).compact.intersect?(slugs)
            end
          end
          boards.uniq(&:id).sort_by(&:id)
        end

        def publication_preview(payload)
          boards = boards_for(payload.fetch(:area_ids))
          rows = boards.flat_map do |board|
            MembershipResolver.for_komsiluk(organization:, komsiluk_id: board.id).recipient_ids(honor_opt_out: false).map { |id| [id, board.id] }
          end.sort
          result = { rows:, total: rows.map(&:first).uniq.size, board_ids: boards.map(&:id),
                     boundaries: boards.map { |board| [board.id, board.updated_at.iso8601(6)] }, blockers: [] }
          if payload[:phone]
            phone = publication_phone_preview(rows, payload[:phone])
            result[:phone] = phone
            result[:blockers] += phone[:blockers]
          end
          result
        end

        def publication_phone_preview(audience, payload)
          blockers = NoticePhonePolicy.readiness(organization:, channels: payload[:channels], mode: payload[:mode], text: payload[:text])
          blockers << "template_changed" if payload[:channels].include?("whatsapp") && canonical(payload[:template]) != canonical(NoticePhonePolicy.template(payload[:text]))
          blockers << "phone_area_policy_changed" unless payload[:phone_area_policy] == PhoneAreaHolds.snapshot(organization)
          blockers << "expiry_before_fallback" if payload[:mode] != "urgent_sms_now" && Time.iso8601(payload[:expires_at]) <= PlatformDelivery::ACK_WAIT.from_now
          excluded = Hash.new(0)
          users = Decidim::User.where(organization:, id: audience.map(&:first)).index_by(&:id)
          rows = audience.map do |user_id, board_id|
            decision = NoticePhonePolicy.eligible(user: users.fetch(user_id), organization:, channels: payload[:channels], text: payload[:text], template: payload[:template],
                                                  sms_text: payload[:sms_text])
            reason = if payload.fetch(:phone_area_policy, {}).fetch(:komsiluk_ids, []).include?(board_id)
                       "phone_area_held"
                     elsif decision[:channels].empty?
                       decision[:reason]
                     end
            excluded[reason] += 1 if reason
            [user_id, board_id, decision[:destination_digest], decision[:channels], reason]
          end
          eligible = rows.count { |row| row[4].nil? }
          sms_count = rows.count { |row| row[4].nil? && row[3].include?("sms") }
          blockers << "no_eligible_recipients" if eligible.zero?
          { rows:, total: rows.size, eligible:, excluded:, sms_count:, deadline_at: nil,
            channel_counts: payload[:channels].index_with { |channel| rows.count { |row| row[4].nil? && row[3].include?(channel) } },
            blockers: blockers.uniq }
        end

        def validate_publication!(payload)
          raise Refused, "invalid_content" unless payload[:title].present? && payload[:title].length <= KomsilukPost::TITLE_MAX &&
                                                  payload[:body].present? && payload[:body].length <= KomsilukPost::BODY_MAX &&
                                                  KomsilukPost::CATEGORIES.include?(payload[:category])

          parse_time(payload[:expires_at])
          if payload[:source_revision]
            source = source_prefill(kind: payload[:source_kind], id: payload[:source_id])
            raise Refused, "source_changed" unless digest(source) == payload[:source_revision]
          end
          raise Refused, "area_required" if boards_for(payload[:area_ids]).empty?
        end

        def publish!(payload, audience:)
          boards_for(payload.fetch(:area_ids)).map do |board|
            post = KomsilukPost.create!(organization:, author: nil, komsiluk: board, origin: "staff",
                                        title: payload.fetch(:title), body: payload.fetch(:body), category: payload.fetch(:category),
                                        expires_at: payload.fetch(:expires_at), published_at: Time.current,
                                        publication_key: payload.fetch(:publication_key), content_revision: 1,
                                        details: (payload[:details] || {}).deep_stringify_keys.merge(
                                          "staff" => { "publisher" => (organization.name.is_a?(Hash) ? organization.name.values.first : organization.name).to_s }
                                        ))
            NoticePublishing.publish!(post:, captured_recipient_ids: audience.filter_map { |user_id, board_id| user_id if board_id == board.id })
            post
          end
        end

        def phone_preview(payload)
          post = scoped_post(payload.fetch(:post_id))
          blockers = NoticePhonePolicy.readiness(organization:, channels: payload.fetch(:channels), mode: payload.fetch(:mode), text: payload.fetch(:text))
          blockers << "publication_changed" unless post.content_revision == payload[:content_revision] && NoticePublishing.current_post?(post)
          source_reason = NoticePhonePolicy.source_reason(post)
          blockers << source_reason if source_reason
          blockers << "expired" if Time.iso8601(payload.fetch(:expires_at)) <= Time.current
          blockers << "template_changed" if payload[:channels].include?("whatsapp") && canonical(payload[:template]) != canonical(NoticePhonePolicy.template(payload[:text]))
          blockers << "phone_area_policy_changed" unless payload[:phone_area_policy] == PhoneAreaHolds.snapshot(organization)
          posts = NoticePhonePolicy.related_posts(post).where(content_revision: payload[:content_revision]).order(:id).to_a
          receipts = PlatformDelivery.where(organization:, komsiluk_post_id: posts.map(&:id), publication_revision: payload[:content_revision]).includes(:user,
                                                                                                                                                         :komsiluk_post).order(:id)
          existing = KomsilukPhoneDelivery.where(platform_delivery_id: receipts.select(:id)).index_by(&:platform_delivery_id)
          excluded = Hash.new(0)
          rows = receipts.map do |receipt|
            decision = NoticePhonePolicy.eligible(user: receipt.user, organization:, channels: payload[:channels], text: payload[:text], template: payload[:template],
                                                  sms_text: payload[:sms_text])
            reason = eligibility_reason(receipt, existing[receipt.id], payload, decision)
            excluded[reason] += 1 if reason
            [receipt.id, receipt.decidim_user_id, decision[:destination_digest], decision[:channels], reason, receipt.deadline_at.iso8601(6)]
          end
          eligible = rows.count { |row| row[4].nil? }
          sms_count = rows.count { |row| row[4].nil? && row[3].include?("sms") }
          { rows:, total: rows.size, eligible:, excluded:, sms_count:,
            channel_counts: payload[:channels].index_with { |channel| rows.count { |row| row[4].nil? && row[3].include?(channel) } }, board_ids: posts.map(&:komsiluk_id),
            boundaries: posts.map do |item|
              [item.id, item.content_revision, item.komsiluk.updated_at.iso8601(6), Digest::SHA256.hexdigest([item.title, item.body, item.expires_at].join("\0"))]
            end,
            deadline_at: rows.filter_map { |row| row[5] if row[4].nil? }.min,
            blockers: blockers.uniq }
        end

        def eligibility_reason(receipt, existing, payload, decision)
          return "phone_area_held" if payload.fetch(:phone_area_policy, {}).fetch(:komsiluk_ids, []).include?(receipt.komsiluk_post&.komsiluk_id)
          return "publication_or_membership_changed" unless NoticePublishing.current_receipt?(receipt)
          return "source_audience_unverified" if NoticePhonePolicy.source_reason(receipt.komsiluk_post, user: receipt.user)
          return "expiry_before_fallback" if payload[:mode] != "urgent_sms_now" && receipt.deadline_at >= Time.iso8601(payload[:expires_at])
          return "platform_acknowledged" if receipt.acknowledged_at && payload[:mode] != "urgent_sms_now"
          return "legacy_delivery_exists" if receipt.account_notification_id || (receipt.fallback_requested_at && existing.nil?)
          return "already_requested" if existing && !(payload[:retry_failed] && %w(rejected skipped).include?(existing.status) && existing.previous_attempts.size < 5)
          return decision[:reason] if decision[:channels].empty?

          nil
        end

        def confirm_preview!(intent, preview)
          raise Refused, preview[:blockers].first if preview[:blockers].any?
          raise Refused, "preview_changed" unless ActiveSupport::SecurityUtils.secure_compare(intent.preview_digest, digest(preview))
        end

        def confirm_phone!(intent, payload, preview)
          raise Refused, "no_eligible_recipients" if preview[:eligible].zero?

          preview[:rows].each do |receipt_id, user_id, destination_digest, channels, reason|
            next if reason

            receipt = PlatformDelivery.find(receipt_id)
            due_at = payload[:mode] == "urgent_sms_now" ? Time.current : receipt.deadline_at
            expires_at = [Time.iso8601(payload[:expires_at]), receipt.expires_at].min
            delivery = KomsilukPhoneDelivery.find_or_initialize_by(platform_delivery: receipt)
            if delivery.persisted?
              delivery.previous_attempts += [{ "send_intent_id" => delivery.send_intent_id, "status" => delivery.status,
                                               "attempted_at" => delivery.attempted_at&.iso8601, "reason" => delivery.reason,
                                               "provider_message_ids" => delivery.provider_message_ids }]
            end
            delivery.assign_attributes(organization:, decidim_user_id: user_id, send_intent: intent,
                                       destination_digest:, channels:, due_at:, expires_at:, status: "pending", reason: nil,
                                       attempted_at: nil, delivered_at: nil, provider_checked_at: nil, provider_status: nil, provider_message_ids: [], budget_released_at: nil,
                                       reserved_minor: 0)
            new_record = delivery.new_record?
            delivery.save!
            receipt.update!(fallback_requested_at: receipt.fallback_requested_at || Time.current)
            ActiveRecord.after_all_transactions_commit { delivery.enqueue } unless new_record
          end
        end

        def canonical(value)
          case value
          when Hash then value.stringify_keys.sort.to_h.transform_values { |item| canonical(item) }
          when Array then value.map { |item| canonical(item) }
          else value
          end
        end

        def digest(preview)
          Digest::SHA256.hexdigest(JSON.generate(canonical(preview)))
        end
      end
    end
  end
end
