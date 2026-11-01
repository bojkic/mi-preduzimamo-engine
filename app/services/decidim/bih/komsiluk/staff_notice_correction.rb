# frozen_string_literal: true

require "digest"

module Decidim
  module Bih
    module Komsiluk
      # An explicit correction keeps the publication and placements. Its preview
      # binds every placement version, reviewed source and optional new audience.
      class StaffNoticeCorrection
        def initialize(organization:, actor:)
          @organization = organization
          @actor = actor
        end

        def context(post:)
          authorize!(:broadcast_preview)
          posts = placements(post)
          source = current_source(post)
          { posts:, source:, source_required: post.details.to_h["source_record"].present? }
        end

        def preview(post:, attributes:)
          authorize!(:broadcast_preview)
          values = attributes.to_h.symbolize_keys
          posts = placements(post)
          source = current_source(post)
          payload = {
            post_id: post.id, publication_key: post.publication_key,
            title: values[:title].to_s.strip, body: values[:body].to_s.strip, category: values[:category].to_s,
            expires_at: expiry(values[:expires_at]).iso8601,
            notify: ActiveModel::Type::Boolean.new.cast(values[:notify]),
            placements: placement_snapshot(posts), source_record: source&.dig(:details, :source_record)
          }
          validate_content!(payload)
          validate_change!(posts, payload)
          summary = preview_facts(posts, payload, source:)
          raise NoticeComposer::Refused, summary[:blockers].first if summary[:blockers].any?

          intent = KomsilukSendIntent.create!(
            organization: @organization, actor: @actor, kind: "correction", publication_key: post.publication_key,
            payload:, preview_digest: digest(summary), expires_at: NoticeComposer::PREVIEW_TTL.from_now,
            recipients_count: summary[:total]
          )
          presentation(intent, posts, source, summary)
        end

        def view(intent)
          authorize!(:broadcast_preview)
          raise NoticeComposer::Refused, "preview_unavailable" unless intent.organization == @organization && intent.actor == @actor

          payload = intent.payload
          posts = placements(scoped_post(payload.fetch(:post_id)))
          source = current_source(posts.find { |post| post.id == payload[:post_id] })
          presentation(intent, posts, source, preview_facts(posts, payload, source:))
        end

        def confirm!(intent)
          authorize!(:broadcast_send_bell)
          raise NoticeComposer::Refused, "preview_unavailable" unless intent.organization == @organization && intent.actor == @actor && intent.kind == "correction"

          intent.with_lock do
            next intent if intent.state == "confirmed"
            raise NoticeComposer::Refused, "preview_expired" unless intent.state == "preview" && intent.expires_at > Time.current

            payload = intent.payload
            validate_content!(payload)
            reference = scoped_post(payload.fetch(:post_id))
            with_source_lock(reference, payload) do
              posts = placements(reference, lock: true)
              source = current_source(posts.find { |post| post.id == payload[:post_id] })
              summary = preview_facts(posts, payload, source:)
              raise NoticeComposer::Refused, summary[:blockers].first if summary[:blockers].any?
              raise NoticeComposer::Refused, "preview_changed" unless digest(summary) == intent.preview_digest

              validate_change!(posts, payload)
              posts.each do |post|
                NoticePublishing.cancel_pending_phone_for!(post:, reason: "publication_changed")
                details = { "staff" => { "last_correction_intent_id" => intent.id } }
                details["source_record"] = payload[:source_record] if payload[:source_record]
                post.correct!(
                  by: @actor, expected_revision: post.content_revision,
                  attributes: payload.slice(:title, :body, :category, :expires_at).merge(details:),
                  notify: payload[:notify],
                  captured_recipient_ids: summary[:rows].filter_map { |user_id, post_id| user_id if post_id == post.id }
                )
              end
              intent.update!(state: "confirmed", confirmed_at: Time.current)
            end
          end
          intent
        rescue KomsilukPost::StaleRevision, ActiveRecord::StaleObjectError
          raise NoticeComposer::Refused, "preview_changed"
        rescue KomsilukPost::NotEditable
          raise NoticeComposer::Refused, "post_unavailable"
        end

        private

        def placements(post, lock: false)
          raise NoticeComposer::Refused, "post_unavailable" unless post && post.organization == @organization && post.origin == "staff" && post.publication_key.present?

          scope = NoticePhonePolicy.related_posts(post).order(:id)
          rows = (lock ? scope.lock : scope).to_a
          identity = source_identity(post)
          invalid = rows.any? { |row| row.origin != "staff" || row.body.blank? || source_identity(row) != identity }
          raise NoticeComposer::Refused, "post_unavailable" if invalid || rows.none? { |row| row.id == post.id }

          rows
        end

        def source_identity(post)
          record = post.details.to_h.deep_symbolize_keys[:source_record]
          raise NoticeComposer::Refused, "source_review_required" if record.present? && !record.is_a?(Hash)

          record ? [record[:kind].to_s, record[:id].to_s] : nil
        end

        def current_source(post)
          record = post.details.to_h.deep_symbolize_keys[:source_record]
          return unless record
          return unless NoticeComposer.source_provider

          NoticeComposer.source_provider.call(organization: @organization, actor: @actor, kind: record[:kind], id: record[:id])&.to_h&.deep_symbolize_keys
        end

        def with_source_lock(post, payload)
          return yield unless source_identity(post)

          provider = NoticeComposer.source_provider
          raise NoticeComposer::Refused, "source_review_required" unless provider.respond_to?(:with_reviewed_source_lock)

          entered = false
          reference = payload.fetch(:source_record)
          result = provider.with_reviewed_source_lock(
            organization: @organization, actor: @actor, kind: reference[:kind], id: reference[:id], revision: reference[:revision]
          ) do
            entered = true
            yield
          end
          raise NoticeComposer::Refused, "source_changed" unless entered

          result
        end

        def preview_facts(posts, payload, source:)
          blockers = []
          blockers << "preview_changed" unless canonical(placement_snapshot(posts)) == canonical(payload[:placements])
          source_required = source_identity(posts.first).present?
          blockers << "source_review_required" if source_required && source.nil?
          blockers << "source_changed" if source_required && canonical(source&.dig(:details, :source_record)) != canonical(payload[:source_record])
          visible = posts.select { |post| post.current? && post.details.to_h.dig("moderation", "source_hold") != true }
          blockers << "correction_no_visible" if payload[:notify] && visible.empty?
          rows = if payload[:notify]
                   visible.flat_map do |post|
                     MembershipResolver.for_komsiluk(organization: @organization, komsiluk_id: post.komsiluk_id)
                                       .recipient_ids(exclude_user_id: post.decidim_user_id, honor_opt_out: false).map { |id| [id, post.id] }
                   end.sort
                 else
                   []
                 end
          {
            rows:, total: rows.map(&:first).uniq.size, blockers: blockers.uniq,
            board_ids: posts.map(&:komsiluk_id), placements: placement_snapshot(posts),
            hidden_count: posts.count(&:hidden?), archived_count: posts.count { |post| %w(closed expired).include?(post.effective_status) },
            source_revision: source&.dig(:details, :source_record, :revision)
          }
        end

        def placement_snapshot(posts)
          posts.map do |post|
            [post.id, post.lock_version, post.content_revision, post.status, post.expires_at&.iso8601(6),
             post.komsiluk_id, post.publication_key, digest(post.details.to_h)]
          end
        end

        def presentation(intent, posts, source, facts)
          { intent:, payload: intent.payload, summary: facts.except(:rows), posts:, source: }
        end

        def validate_content!(payload)
          unless payload[:title].present? && payload[:title].length <= KomsilukPost::TITLE_MAX &&
                 payload[:body].present? && payload[:body].length <= KomsilukPost::BODY_MAX &&
                 KomsilukPost::CATEGORIES.include?(payload[:category])
            raise NoticeComposer::Refused, "invalid_content"
          end

          expiry(payload[:expires_at])
        end

        def validate_change!(posts, payload)
          changed = posts.any? do |post|
            post.title != payload[:title] || post.body != payload[:body] || post.category != payload[:category] ||
              post.expires_at != Time.iso8601(payload[:expires_at]) ||
              (payload[:source_record] && canonical(post.details.to_h["source_record"]) != canonical(payload[:source_record]))
          end
          raise NoticeComposer::Refused, "correction_unchanged" unless changed
        end

        def expiry(value)
          time = value.respond_to?(:iso8601) ? value : Time.find_zone!("Europe/Sarajevo").parse(value.to_s)
          raise NoticeComposer::Refused, "invalid_expiry" unless time && time > Time.current && time <= 90.days.from_now

          time
        rescue ArgumentError, TypeError
          raise NoticeComposer::Refused, "invalid_expiry"
        end

        def scoped_post(id)
          KomsilukPost.find_by(organization: @organization, id:)
        end

        def authorize!(permission)
          raise NoticeComposer::Refused, "permission_required" unless OperatorAuthorization.allowed?(@actor, permission, organization: @organization)
        end

        def canonical(value)
          case value
          when Hash then value.stringify_keys.sort.to_h.transform_values { |item| canonical(item) }
          when Array then value.map { |item| canonical(item) }
          else value
          end
        end

        def digest(value)
          Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
        end
      end
    end
  end
end
