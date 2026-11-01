# frozen_string_literal: true

require "openssl"

module Decidim
  module Bih
    module Concierge
      # JSON endpoint behind the public floating "MI bot" chat widget.
      #
      #   POST /chat   { "message": "kad se odvozi smeće" }
      #   => 200 { "reply": "...", "quick_replies": [...], "sticker_url": "...",
      #            "sticker_alt": "...",
      #            "feedback": { "id": "...", "url": "/chat/feedback", "token": "..." } }
      #
      # The widget is same-origin (served from the host's /public), so this is a
      # normal CSRF-protected, session-backed Decidim request — it inherits from
      # Decidim::ApplicationController for current_organization (host-derived) and
      # the standard forgery protection. There is NO authentication: the public
      # bot answers anonymous visitors, exactly like the /prijave intake.
      #
      # The brain is host-wired via Decidim::Bih.concierge_resolver (see the
      # config_accessor). This controller never contains intent logic; it only
      # adapts the JSON request to a Concierge::WebMessage, calls #respond, and
      # serialises the Reply. EVERY failure degrades to a friendly fallback reply
      # with HTTP 200 — the widget must never see a 500 or a stack trace, and a
      # cold/misconfigured brain must not break the page.
      class WebChatController < Decidim::ApplicationController
        include Decidim::Bih::CurrentOrganizationUser
        include WebRegistrationResume

        before_action :verify_same_origin!

        # Max characters we accept from the widget. Long enough for a real civic
        # question, short enough that the brain (and any LLM classifier) is never
        # fed an abusive payload.
        MAX_MESSAGE_LENGTH = 1000
        MAX_REPLY_ID_LENGTH = 64
        MAX_FEEDBACK_TOKEN_LENGTH = 16_384
        FEEDBACK_TOKEN_TTL = 24.hours
        MAX_FEEDBACK_REPLY_TEXT_LENGTH = 4_000
        MAX_CONTEXT_USER_TEXT_LENGTH = 500
        MAX_CONTEXT_BOT_TEXT_LENGTH = 800
        MAX_CONVERSATION_TURNS = 6
        MAX_SESSION_CONTEXT_BYTES = 1500
        MAX_TONE_HISTORY = 10
        CONVERSATION_CONTEXT_TTL = 30.minutes
        VALID_ANSWER_INTENTS = Decidim::Bih::Concierge::AnswerIntents::VALUES
        NOTIFICATION_EVENT = "decidim_bih.web_chat"
        FEEDBACK_EVENT = "decidim_bih.web_chat.feedback"
        # The aggregate's historical outcome bucket is derived from the typed
        # dialogue resolution: a resolved or guided turn is a "success", every
        # other resolution (unsupported, source_unavailable, provider_unavailable,
        # busy, delivery_failed) a "fallback". Blank input is "blank" and a
        # rescued exception "error"; a reply without a typed outcome (the legacy
        # brain path) keeps the historical "success" bucket.
        #
        # The membership is Dialogue::Resolution's, not a second list kept in
        # step by hand: the module that decides which label a turn carries is
        # the module that decides which bucket that label belongs to. The
        # bucket vocabulary itself is frozen for legacy comparability.
        SUCCESS_RESOLUTIONS = Dialogue::Resolution::SUCCEEDED
        # A turn that ends unresolved offers the citizen one button to keep the
        # question for review; so does the second clarification in a row.
        CAPTURE_RESOLUTIONS = %w(unsupported provider_unavailable).freeze
        CAPTURE_CLARIFICATION_COUNT = 2
        TURN_LOG_TAG = "[MilicaTurn]"
        LOG_CLASS_NAME = /\A[A-Za-z0-9_:]{1,80}\z/

        def create
          @turn_started_at = monotonic_now
          text = ""
          text = message_param
          resume_task = registration_resume_for(text)
          rotated = ensure_conversation_actor_scope!
          if resume_task
            reset_conversation_scope! unless rotated
            restore_registration_task(resume_task, message: text)
          end
          return clear_conversation_reply if Dialogue::StateStore.clear_command?(text)
          return credential_guidance_reply(text) if Dialogue::StateStore.sensitive_text?(text)

          location = location_param
          context = conversation_context

          if text.blank?
            reply = fallback_reply
            instrument_web_chat(text, outcome: "blank", reply: reply, context: { location:, conversation_turns: context.length })
            return render_json(reply, outcome: "blank", citizen_message: text)
          end

          reply = resolve_reply(text, location:, conversation_context: context)
          reply = prepare_registration_return(reply)
          outcome = turn_outcome(reply)
          instrument_web_chat(text, outcome:, reply: reply, context: { location:, conversation_turns: context.length })
          remember_conversation_turn(text, reply, location:)
          render_json(reply, outcome:, citizen_message: text)
        rescue StandardError => e
          # Brain blew up (bad wiring, downstream timeout, anything): log it and
          # answer with the offline fallback so the widget stays usable. The
          # aggregate records the honest "error" bucket, not a fallback.
          Rails.logger.error("[WebChat] #{e.class}: #{Decidim::Bih::LogRedactor.error_message(e)}")
          reply = fallback_reply
          instrument_web_chat(text, outcome: "error", reply: reply, exception: e, context: { location: nil, conversation_turns: 0 })
          render_json(reply, outcome: "error", citizen_message: text)
        end

        # Restore the widget's retained-location indicator after a reload. This
        # reads the same actor-scoped dialogue state as a message without
        # extending its inactivity lifetime or returning the saved point.
        def state
          response.headers["Cache-Control"] = "no-store"
          ensure_conversation_actor_scope!
          status = if ENV["MILICA_CONVERSATION_SLOTS_ENABLED"] == "1" && ENV["MILICA_CONVERSATION_LOCATION_ENABLED"] == "1"
                     location_memory_status(Dialogue::StateStore.new.read(context: trusted_dialogue_context))
                   else
                     { location_memory_state: "inactive" }
                   end
          render json: status
        rescue StandardError => e
          Rails.logger.warn("[WebChatState] #{e.class}: #{Decidim::Bih::LogRedactor.error_message(e)}")
          render json: { location_memory_state: "unknown" }
        end

        def feedback
          value = feedback_value_param
          reply_id = feedback_reply_id_param
          token_payload = verified_feedback_payload

          unless Decidim::Bih::ConciergeFeedback::VALUES.include?(value) && valid_reply_id?(reply_id) &&
                 authorized_feedback_token?(token_payload, reply_id:, value:)
            instrument_feedback(reply_id:, value:, outcome: "invalid")
            return render json: { status: "invalid", reason: "feedback_unavailable" }, status: :unprocessable_entity
          end

          feedback = Decidim::Bih::ConciergeFeedback.find_or_initialize_by(
            organization: current_organization,
            reply_id: reply_id,
            session_digest: feedback_session_digest
          )
          feedback.user = nil
          feedback.value = value
          feedback.locale = I18n.locale.to_s
          feedback.metadata = feedback_metadata(token_payload)
          feedback.citizen_message = feedback_transcript_text(token_payload[:citizen_message], MAX_MESSAGE_LENGTH)
          feedback.bot_reply_text = feedback_transcript_text(token_payload[:bot_reply_text], MAX_FEEDBACK_REPLY_TEXT_LENGTH)
          feedback.save!

          instrument_feedback(reply_id:, value:, outcome: "ok")
          render json: { status: "ok" }
        rescue StandardError => e
          Rails.logger.error("[WebChatFeedback] #{e.class}: #{Decidim::Bih::LogRedactor.error_message(e)}")
          instrument_feedback(reply_id: nil, value: nil, outcome: "error", exception: e)
          render json: { status: "error" }, status: :ok
        end

        private

        # Same-origin guard for a state-changing JSON endpoint. The widget always
        # sends the X-Requested-With header (it is a same-origin fetch); a
        # cross-site form post cannot set custom headers without a CORS
        # preflight, which we never grant. The widget also sends Rails'
        # X-CSRF-Token, so normal forgery protection rejects forged JSON posts.
        def verify_same_origin!
          return if request.headers["X-Requested-With"] == "XMLHttpRequest"

          head :forbidden
        end

        # The trimmed, length-capped user message, or "" when absent/blank.
        def message_param
          raw = params[:message]
          raw = params.dig(:web_chat, :message) if raw.blank?
          raw.to_s.strip.first(MAX_MESSAGE_LENGTH).to_s
        end

        def feedback_value_param
          raw = params[:value]
          raw = params.dig(:web_chat, :value) if raw.blank?
          raw.to_s.strip
        end

        def feedback_reply_id_param
          raw = params[:reply_id]
          raw = params.dig(:web_chat, :reply_id) if raw.blank?
          raw.to_s.strip.first(MAX_REPLY_ID_LENGTH).to_s
        end

        def feedback_token_param
          raw = params[:token]
          raw = params.dig(:web_chat, :token) if raw.blank?
          raw.to_s.strip.first(MAX_FEEDBACK_TOKEN_LENGTH).to_s
        end

        def location_param
          raw = raw_location_param
          return nil unless raw.respond_to?(:key?) && raw.respond_to?(:[])

          latitude = bounded_float(location_value(raw, :latitude, :lat), -90, 90)
          longitude = bounded_float(location_value(raw, :longitude, :lon, :lng), -180, 180)
          return nil if latitude.nil? || longitude.nil?

          accuracy_value = location_value(raw, :accuracy)
          accuracy = bounded_float(accuracy_value, 0, 1_000_000)
          return nil if accuracy_value.present? && accuracy.nil?

          provenance = location_provenance(raw)
          return nil unless provenance
          return nil if WebMessage.location_refused?(message_param)

          # A fresh payload with explicit current-turn browser consent/purpose
          # is authoritative; destination corrections need not repeat a phrase
          # from the legacy language whitelist. No location is read from session
          # history here. Metadata-free old clients still need explicit text.
          if provenance == "legacy_explicit_location" && !WebMessage.location_requested?(message_param)
            return nil
          end

          { latitude:, longitude:, accuracy:, purpose: "current_location", consent: true, provenance:,
            acquired_at: location_value(raw, :acquired_at),
            retain_for_conversation: location_value(raw, :retain_for_conversation) == true }
        end

        def location_provenance(raw)
          metadata_present = [:consent, :purpose, :provenance].any? { |key| raw.has_key?(key) || raw.has_key?(key.to_s) }
          if metadata_present
            return nil unless location_value(raw, :consent) == true
            return nil unless location_value(raw, :purpose) == "current_location"
            return nil unless location_value(raw, :provenance) == "browser_geolocation"
          end

          metadata_present ? "browser_geolocation" : "legacy_explicit_location"
        end

        def raw_location_param
          raw = params[:location]
          raw = params.dig(:web_chat, :location) if raw.blank?
          raw.presence || {
            latitude: params[:latitude] || params[:lat],
            longitude: params[:longitude] || params[:lon] || params[:lng]
          }
        end

        def location_value(raw, *keys)
          keys.filter_map { |key| raw[key] || raw[key.to_s] }.first
        end

        def bounded_float(value, min, max)
          return nil if value.to_s.strip.blank?

          numeric = Float(value)
          numeric.between?(min, max) ? numeric : nil
        rescue ArgumentError, TypeError
          nil
        end

        def valid_reply_id?(reply_id)
          reply_id.match?(Decidim::Bih::ConciergeFeedback::REPLY_ID_FORMAT)
        end

        def authorized_feedback_token?(payload, reply_id:, value:)
          payload&.[](:reply_id) == reply_id &&
            payload&.[](:organization_id).to_i == current_organization&.id &&
            feedback_token_session_matches?(payload) &&
            (value != "share_question" || payload&.[](:offer_capture) == true)
        end

        # Pre-upgrade tokens lack an origin binding and cannot safely establish
        # which browser received the answer. They expire closed on upgrade.
        def feedback_token_session_matches?(payload)
          digest = payload&.[](:session_digest)
          digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/) &&
            ActiveSupport::SecurityUtils.secure_compare(digest, feedback_session_digest)
        end

        def verified_feedback_payload
          token = feedback_token_param
          return nil if token.blank?

          payload = feedback_verifier.verify(token)
          payload.respond_to?(:with_indifferent_access) ? payload.with_indifferent_access : nil
        rescue ActiveSupport::MessageVerifier::InvalidSignature
          nil
        end

        # Routes the text through the host-wired brain. Falls back when no brain
        # is configured (engine used standalone, or boot misorder).
        def resolve_reply(text, location:, conversation_context:)
          brain = concierge
          return fallback_reply if brain.nil?

          # Pass the logged-in user (or nil) so the brain can answer the personal
          # "moji bodovi" goodwill intent for an authenticated visitor. Anonymous
          # visitors get the graceful verify/sign-in fallback. This is the ONLY
          # use of identity on the web channel — reports are never created here.
          message = Decidim::Bih::Concierge::WebMessage.new(
            text,
            user: current_organization_user,
            location:,
            conversation_context:,
            trusted_context: trusted_dialogue_context
          )
          observe_model_calls { brain.respond(message) }
        end

        # Diagnostic mode only (MILICA_DIAGNOSTIC=1): count the provider
        # requests this thread makes while the brain answers. Off by default,
        # and then the block runs untouched.
        def observe_model_calls
          return yield unless TurnDiagnostics.enabled?

          @diag_model_calls = 0
          thread = Thread.current
          callback = ->(*) { @diag_model_calls += 1 if Thread.current.equal?(thread) }
          ActiveSupport::Notifications.subscribed(callback, TurnDiagnostics::MODEL_EVENT) { yield }
        end

        # Resolves Decidim::Bih.concierge_resolver to the actual brain object.
        # The accessor may hold the object directly or a callable returning it
        # (so the host can defer building it until the DB/org is available).
        def concierge
          resolver = Decidim::Bih.concierge_resolver
          resolver.respond_to?(:call) ? resolver.call : resolver
        end

        # Serialises a Reply (anything with #text and optionally #quick_replies /
        # #sticker) to the widget's JSON contract. +offer_capture+ tells the
        # widget to offer optional unanswered-question capture. Every explicit
        # feedback click shares the disclosed, signed transcript boundary.
        def render_json(reply, outcome:, citizen_message:)
          reply_id = SecureRandom.uuid
          memory_status = location_memory_status_for_reply(reply)
          render json: {
            reply: reply_text(reply),
            quick_replies: reply_quick_replies(reply),
            sticker_url: reply_sticker_url(reply),
            sticker_static_url: reply_sticker_static_url(reply),
            sticker_alt: reply_sticker_alt(reply),
            offer_capture: offer_capture?(reply),
            location_memory_state: memory_status.fetch(:location_memory_state),
            **(memory_status[:expires_at] ? { location_memory_expires_at: memory_status.fetch(:expires_at) } : {}),
            feedback: {
              id: reply_id,
              url: Decidim::Bih.public_path("chat/feedback"),
              token: feedback_token(reply, reply_id:, outcome:, citizen_message:)
            }
          }
        end

        # The widget may assert retained GPS only when this reply carries a
        # successfully persisted dialogue state. Fallback HTTP 200 responses
        # have no such state and leave the prior UI status unconfirmed.
        def location_memory_state(reply)
          location_memory_status_for_reply(reply).fetch(:location_memory_state)
        end

        def location_memory_status_for_reply(reply)
          return { location_memory_state: "unknown" } unless reply.respond_to?(:dialogue_outcome)

          state = reply.dialogue_outcome&.state
          location_memory_status(state)
        rescue StandardError
          { location_memory_state: "unknown" }
        end

        def location_memory_status(state)
          return { location_memory_state: "unknown" } unless state.is_a?(Hash)

          location = state.dig(Dialogue::ConversationSlots::KEY, "location")
          return { location_memory_state: "inactive" } unless location.is_a?(Hash) && location["kind"] == "exact"

          expires_at = location["expires_at"]
          expires_at = [expires_at, state["expires_at"]].min if expires_at.is_a?(Numeric) && state["expires_at"].is_a?(Numeric)
          return { location_memory_state: "inactive" } unless expires_at.is_a?(Numeric) && expires_at > Time.current.to_f

          { location_memory_state: "active", expires_at: expires_at }
        end

        def feedback_token(reply, reply_id:, outcome:, citizen_message:)
          bot_reply_text = reply_text(reply)
          omit_transcript = Dialogue::StateStore.sensitive_text?(citizen_message) || Dialogue::StateStore.sensitive_text?(bot_reply_text)

          feedback_verifier.generate(
            {
              reply_id:,
              organization_id: current_organization&.id,
              session_digest: feedback_session_digest,
              offer_capture: offer_capture?(reply),
              outcome:,
              answer_intent: reply_answer_intent(reply),
              topic: reply_dialogue_topic(reply),
              reply_length: bot_reply_text.to_s.length,
              quick_replies_count: reply_quick_replies(reply).length,
              sticker: (reply.respond_to?(:sticker) ? reply.sticker&.to_s : nil),
              issued_at: Time.current.to_i,
              citizen_message: omit_transcript ? nil : feedback_transcript_text(citizen_message, MAX_MESSAGE_LENGTH),
              bot_reply_text: omit_transcript ? nil : feedback_transcript_text(bot_reply_text, MAX_FEEDBACK_REPLY_TEXT_LENGTH)
            },
            expires_in: FEEDBACK_TOKEN_TTL
          )
        end

        def feedback_verifier
          Rails.application.message_verifier(:decidim_bih_web_chat_feedback)
        end

        def feedback_metadata(token_payload)
          {
            "source" => "web_chat",
            "outcome" => token_payload[:outcome].to_s,
            "answer_intent" => sanitize_answer_intent(token_payload[:answer_intent]),
            "topic" => AnswerOutcome.topic(token_payload[:topic]),
            "reply_length" => token_payload[:reply_length].to_i,
            "quick_replies_count" => token_payload[:quick_replies_count].to_i,
            "sticker" => token_payload[:sticker].presence,
            "issued_at" => token_payload[:issued_at].to_i
          }.compact
        end

        def feedback_transcript_text(value, limit)
          return if Dialogue::StateStore.sensitive_text?(value)

          value.to_s.first(limit).presence
        end

        def reply_text(reply)
          text = reply.respond_to?(:text) ? reply.text : reply.to_s
          text.presence || I18n.t("decidim.bih.concierge.help")
        end

        # Optional list of suggested follow-up chips. The Reply struct does not
        # carry these in v1, so this is forward-compatible: it surfaces them when
        # a future reply object responds to #quick_replies, else [].
        def reply_quick_replies(reply)
          return [] unless reply.respond_to?(:quick_replies)

          Array(reply.quick_replies)
        end

        # Resolves the Reply's named sticker (e.g. :prijavljeno) to its
        # host-served, organization-scoped /mi/stickers/<id>.png URL, or nil.
        def reply_sticker_url(reply)
          sticker = reply.respond_to?(:sticker) ? reply.sticker : nil
          return nil if sticker.blank?

          Decidim::Bih::Concierge::Stickers.url_for(
            sticker,
            organization: current_organization,
            variant: :animated
          )
        end

        def reply_sticker_alt(reply)
          sticker = reply.respond_to?(:sticker) ? reply.sticker : nil
          return "" if sticker.blank?

          I18n.t(
            "decidim.bih.concierge.media.#{sticker}.alt",
            default: ""
          ).to_s
        end

        def reply_sticker_static_url(reply)
          sticker = reply.respond_to?(:sticker) ? reply.sticker : nil
          return nil if sticker.blank?

          Decidim::Bih::Concierge::Stickers.url_for(
            sticker,
            organization: current_organization,
            variant: :static
          )
        end

        def reply_answer_intent(reply)
          return "unknown" unless reply.respond_to?(:answer_intent)

          sanitize_answer_intent(reply.answer_intent)
        end

        def sanitize_answer_intent(value)
          Decidim::Bih::Concierge::AnswerIntents.sanitize(value)
        end

        def reply_dialogue_topic(reply)
          reply_outcome_value(reply)&.topic || "unknown"
        end

        # The typed, server-owned facts of this turn (topic, resolution,
        # active task, pending slot, clarification count, entity keys), or nil
        # for a reply without a dialogue outcome.
        def reply_outcome_value(reply)
          return unless reply.respond_to?(:dialogue_outcome)

          ReplyOutcome.from(reply.dialogue_outcome)
        end

        def turn_outcome(reply)
          resolution = reply_outcome_value(reply)&.dimensions&.resolution
          return "success" if resolution.nil? || SUCCESS_RESOLUTIONS.include?(resolution)

          "fallback"
        end

        def offer_capture?(reply)
          value = reply_outcome_value(reply)
          return false unless value

          resolution = value.dimensions.resolution
          return true if CAPTURE_RESOLUTIONS.include?(resolution)

          resolution == "clarification" && value.clarification_count >= CAPTURE_CLARIFICATION_COUNT
        end

        def instrument_web_chat(text, outcome:, reply:, exception: nil, context: {})
          value = reply_outcome_value(reply)
          payload = web_chat_payload(text, reply, value, {
                                       outcome:, exception_class: exception&.class&.name,
                                       location_present: context[:location].present?,
                                       conversation_turns: context[:conversation_turns].to_i
                                     })
          ActiveSupport::Notifications.instrument(NOTIFICATION_EVENT, payload)
          record_usage_aggregate(payload, dimensions: value&.dimensions, facet: Dialogue::QuestionFacet.call(text))
          log_turn(payload, value)
          log_diagnostic(reply, payload, value)
        rescue StandardError => e
          # A subscriber/metrics failure must not hide an already committed
          # receipt or send the citizen through a second submission attempt.
          Rails.logger.warn("[WebChatUsageAggregate] instrumentation failed (#{e.class})")
        end

        def web_chat_payload(text, reply, value, turn)
          payload = {
            organization_id: current_organization&.id,
            user_id: nil,
            message_length: text.to_s.length,
            outcome: turn.fetch(:outcome),
            answer_intent: reply_answer_intent(reply),
            topic: value&.topic || "unknown",
            reply_length: reply_text(reply).to_s.length,
            quick_replies_count: reply_quick_replies(reply).length,
            sticker: (reply.respond_to?(:sticker) ? reply.sticker&.to_s : nil),
            location_present: turn.fetch(:location_present),
            conversation_turns: turn.fetch(:conversation_turns),
            exception_class: turn.fetch(:exception_class)
          }
          payload.merge!(value.dimensions.to_h) if value
          payload
        end

        # One structured line per turn for the operator. Every value is an
        # enum token, a count or a class name — never citizen text, reply text,
        # a session or a location. +operation+ (the understanding's
        # start/continue/correct/switch) is not carried by the typed result
        # yet and is logged as unknown until the coordinator exposes it.
        def log_turn(payload, value)
          line = turn_log_fields(payload, value).filter_map { |key, field| "#{key}=#{field}" unless field.nil? }.join(" ")
          Rails.logger.info("#{TURN_LOG_TAG} #{line}")
        end

        def turn_log_fields(payload, value)
          resolution = value&.dimensions&.resolution
          entity_keys = value&.entity_keys.presence
          [
            %w(channel web_chat),
            ["action", log_token(value&.action)],
            ["topic", log_token(payload[:topic])],
            %w(operation unknown),
            ["needs_clarification", (resolution == "clarification").to_s],
            ["resolution", log_token(resolution)],
            ["intent", log_token(payload[:answer_intent])],
            ["outcome", log_token(payload[:outcome])],
            ["ms", elapsed_ms],
            ["pending_slot", log_token(value&.pending_slot)],
            ["clarification_count", value&.clarification_count.to_i],
            ["entity_keys", entity_keys ? entity_keys.join(",") : "none"],
            ["error", log_class_name(payload[:exception_class])]
          ]
        end

        # Diagnostic mode only: one JSON line per turn next to [MilicaTurn]
        # with the route, model call, read count, missing-field reason,
        # transition and capability decision. Bounded tokens and counts —
        # never citizen text (TurnDiagnostics owns the schema).
        def log_diagnostic(reply, payload, value)
          return unless TurnDiagnostics.enabled?

          outcome = reply.respond_to?(:dialogue_outcome) ? reply.dialogue_outcome : nil
          line = TurnDiagnostics.line(outcome:, model_calls: @diag_model_calls.to_i, resolution: value&.dimensions&.resolution,
                                      topic: payload[:topic], action: value&.action, elapsed_ms:)
          Rails.logger.info(line)
        end

        def log_token(value)
          ReplyOutcome.token(value) || "unknown"
        end

        def log_class_name(value)
          name = value.to_s
          return nil if name.empty?

          LOG_CLASS_NAME.match?(name) ? name : "unknown"
        end

        def monotonic_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        def elapsed_ms
          return 0 unless @turn_started_at

          ((monotonic_now - @turn_started_at) * 1000).round
        end

        def record_usage_aggregate(payload, dimensions: nil, facet: nil)
          Decidim::Bih::Concierge::UsageAggregateRecorder.call(
            organization: current_organization,
            channel: "web_chat",
            outcome: payload.fetch(:outcome),
            answer_intent: payload.fetch(:answer_intent),
            topic: payload.fetch(:topic),
            facet:,
            locale: I18n.locale.to_s,
            message_length: payload.fetch(:message_length),
            reply_length: payload.fetch(:reply_length),
            quick_replies_count: payload.fetch(:quick_replies_count),
            sticker_present: payload[:sticker].present?,
            **(dimensions ? { outcome_dimensions: dimensions } : {})
          )
        rescue StandardError => e
          Rails.logger.warn("[WebChatUsageAggregate] #{e.class}: #{Decidim::Bih::LogRedactor.error_message(e)}")
        end

        def instrument_feedback(reply_id:, value:, outcome:, exception: nil)
          ActiveSupport::Notifications.instrument(
            FEEDBACK_EVENT,
            organization_id: current_organization&.id,
            user_id: nil,
            reply_id_present: reply_id.present?,
            value: value,
            outcome: outcome,
            exception_class: exception&.class&.name
          )
        end

        def feedback_session_digest
          raw = web_chat_session_id
          OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base.to_s, raw)
        end

        def web_chat_session_id
          session[:decidim_bih_web_chat_id] ||= SecureRandom.hex(16)
        end

        def conversation_context
          cached = safe_conversation_history(Rails.cache.read(conversation_cache_key))
          return cached if cached.any?

          session_conversation_context
        rescue StandardError => e
          Rails.logger.warn("[WebChatConversation] read failed (#{e.class}: #{Decidim::Bih::LogRedactor.error_message(e)})")
          session_conversation_context
        end

        def remember_conversation_turn(text, reply, location:)
          return if Dialogue::StateStore.sensitive_text?(text) || Dialogue::StateStore.sensitive_text?(reply_text(reply))

          turns = conversation_context
          tone = reply.respond_to?(:tone) ? reply.tone.to_s.presence : nil
          turns << {
            "user" => feedback_transcript_text(text, MAX_CONTEXT_USER_TEXT_LENGTH),
            "bot" => feedback_transcript_text(history_reply_text(reply), MAX_CONTEXT_BOT_TEXT_LENGTH),
            "answer_intent" => reply_answer_intent(reply),
            "tone" => tone,
            "tone_history" => conversation_tone_history(turns, tone),
            "phrase_id" => reply.respond_to?(:phrase_id) ? reply.phrase_id.to_s.presence : nil,
            "location_present" => location.present?,
            "at" => Time.current.to_i
          }.compact
          bounded_turns = turns.last(MAX_CONVERSATION_TURNS)
          session[:decidim_bih_web_chat_context] = bounded_session_turns(bounded_turns)
          Rails.cache.write(conversation_cache_key, bounded_turns, expires_in: CONVERSATION_CONTEXT_TTL)
        rescue StandardError => e
          Rails.logger.warn("[WebChatConversation] write failed (#{e.class}: #{Decidim::Bih::LogRedactor.error_message(e)})")
        end

        def history_reply_text(reply)
          result = reply.dialogue_outcome if reply.respond_to?(:dialogue_outcome)
          if reply_answer_intent(reply) == "goodwill" || ReplyOutcome.from(result)&.factual_history
            # Retrieved civic/private facts do not become next-turn model input.
            # Task slots remain in scoped state; keep only a neutral turn marker.
            return I18n.t("decidim.bih.dialogue.factual_history_summary")
          end

          reply_text(reply)
        end

        def safe_conversation_history(history)
          Dialogue::StateStore.prune_history(history, now: Time.current).map do |turn|
            # Also sanitize personal answers saved before this privacy guard.
            next turn unless turn["answer_intent"] == "goodwill"

            turn.merge("bot" => I18n.t("decidim.bih.dialogue.factual_history_summary"))
          end
        end

        def session_conversation_context
          safe_conversation_history(session[:decidim_bih_web_chat_context]).filter_map do |turn|
            next unless turn.respond_to?(:[])

            {
              "user" => turn["user"].to_s.presence,
              "bot" => turn["bot"].to_s.presence,
              "answer_intent" => turn["answer_intent"].to_s.presence,
              "tone" => bounded_context_token(turn["tone"]),
              "tone_history" => sanitize_tone_history(turn["tone_history"]),
              "phrase_id" => bounded_context_token(turn["phrase_id"]),
              "location_present" => ActiveModel::Type::Boolean.new.cast(turn["location_present"]),
              "at" => turn["at"].to_i.positive? ? turn["at"].to_i : nil
            }.compact
          end.last(MAX_CONVERSATION_TURNS)
        end

        def session_conversation_turn(turn)
          {
            "user" => turn["user"].to_s.first(160).presence,
            "bot" => turn["bot"].to_s.first(240).presence,
            "answer_intent" => turn["answer_intent"].to_s.presence,
            "tone" => bounded_context_token(turn["tone"]),
            "tone_history" => sanitize_tone_history(turn["tone_history"]),
            "phrase_id" => bounded_context_token(turn["phrase_id"]),
            "location_present" => ActiveModel::Type::Boolean.new.cast(turn["location_present"]),
            "at" => turn["at"].to_i.positive? ? turn["at"].to_i : nil
          }.compact
        end

        def bounded_session_turns(turns)
          bounded = turns.last(MAX_CONVERSATION_TURNS).map { |turn| session_conversation_turn(turn) }
          bounded.shift while bounded.any? && JSON.generate(bounded).bytesize > MAX_SESSION_CONTEXT_BYTES
          bounded
        end

        def conversation_cache_key
          "decidim-bih/web-chat/conversation/#{current_organization&.id || "none"}/#{feedback_session_digest}"
        end

        def trusted_dialogue_context
          user = current_organization_user
          capabilities = %w(public_reads report_guidance registration_handoff)
          capabilities += %w(neighborhood_reads own_report_reads) if user
          Dialogue::Contracts::TrustedContext.new(
            organization_id: current_organization.id,
            conversation_key: feedback_session_digest,
            actor_id: user&.id,
            account_state: user ? "registered" : "anonymous",
            capabilities:,
            now: Time.current
          )
        end

        def clear_conversation_reply
          reset_conversation_scope!
          render_json(control_reply("cleared"), outcome: "success", citizen_message: "")
        end

        def ensure_conversation_actor_scope!
          scope = OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base.to_s,
                                          "web-chat-actor:#{current_organization&.id}:#{current_organization_user&.id || "anonymous"}")
          return if session[:decidim_bih_web_chat_actor_scope] == scope

          reset_conversation_scope!
          session[:decidim_bih_web_chat_actor_scope] = scope
          true
        end

        def reset_conversation_scope!
          had_context = session[:decidim_bih_web_chat_id].present?
          previous_context = previous_dialogue_context if had_context
          previous_key = "decidim-bih/web-chat/conversation/#{previous_context.organization_id}/#{previous_context.conversation_key}" if previous_context
          # Rotate before touching fallible cache stores. Even if a delete
          # fails, the next request cannot address the old conversation again.
          session.delete(:decidim_bih_web_chat_context)
          session[:decidim_bih_web_chat_id] = SecureRandom.hex(16)
          session[:decidim_bih_web_chat_state_scope] = { "organization_id" => current_organization.id, "actor_id" => current_organization_user&.id }
          return unless previous_context

          clear_previous_conversation(previous_key, previous_context)
        end

        def previous_dialogue_context
          scope = session[:decidim_bih_web_chat_state_scope]
          return trusted_dialogue_context unless scope.is_a?(Hash)

          # Scope is from the authenticated/encrypted Rails session, never from
          # model output or request parameters. Preserve the OLD actor for deletion.
          Dialogue::Contracts::TrustedContext.new(
            organization_id: scope["organization_id"], actor_id: scope["actor_id"],
            conversation_key: feedback_session_digest, now: Time.current
          )
        end

        def clear_previous_conversation(cache_key, context)
          begin
            brain = concierge
            brain.clear_conversation(context:) if brain.respond_to?(:clear_conversation)
          rescue StandardError => e
            Rails.logger.warn("[WebChatConversation] host clear deferred (#{e.class})")
          end
          Dialogue::StateStore.new.clear(context:)
        rescue StandardError => e
          Rails.logger.warn("[WebChatConversation] state clear deferred (#{e.class})")
        ensure
          begin
            Rails.cache.delete(cache_key)
          rescue StandardError => e
            Rails.logger.warn("[WebChatConversation] cache clear deferred (#{e.class})")
          end
        end

        def credential_guidance_reply(text)
          reply = control_reply("credentials")
          if Dialogue::Coordinator.cancelled?(text)
            # Resolve only a reviewed cancellation command. Never expose the
            # supplied credential to a configurable brain, history or feedback.
            command = Dialogue::Coordinator.locale_for(text) == "sr-Cyrl" ? "одустани" : "odustani"
            cancellation = resolve_reply(command, location: nil, conversation_context: [])
            reply.text = "#{reply_text(cancellation)}\n\n#{reply.text}"
            reply.answer_intent = reply_answer_intent(cancellation)
            result = cancellation.dialogue_outcome if cancellation.respond_to?(:dialogue_outcome)
            reply.define_singleton_method(:dialogue_outcome) { result } if result.is_a?(Dialogue::ProcedureRunner::Result)
          end
          instrument_web_chat("", outcome: "success", reply:, context: { location: nil, conversation_turns: 0 })
          render_json(reply, outcome: "success", citizen_message: "")
        end

        def control_reply(key)
          Responder::Reply.new(text: I18n.t("decidim.bih.dialogue.#{key}"), report: nil, answer_intent: "setup", tone: "core")
        end

        def bounded_context_token(value)
          token = value.to_s.first(80)
          token if token.match?(/\A[a-z0-9_.-]+\z/)
        end

        def conversation_tone_history(turns, tone)
          previous = sanitize_tone_history(turns.last&.fetch("tone_history", nil))
          previous = turns.filter_map { |turn| bounded_tone(turn["tone"]) } if previous.empty?
          (previous + [bounded_tone(tone)]).compact.last(MAX_TONE_HISTORY)
        end

        def sanitize_tone_history(value)
          Array(value).filter_map { |tone| bounded_tone(tone) }.last(MAX_TONE_HISTORY)
        end

        def bounded_tone(value)
          value.to_s if %w(core neighborly playful).include?(value.to_s)
        end

        # The graceful "I can't reach the brain right now" reply. Uses the
        # localized concierge help menu so the widget always shows something
        # useful and on-brand even when the brain is down. It carries the same
        # civic-shortcut chips as the brain's own help reply, so a first-time /
        # offline visitor still gets one-tap jumps into the key flows — the
        # chips don't depend on the brain being reachable.
        def fallback_reply
          Decidim::Bih::Concierge::Responder::Reply.new(
            text: I18n.t("decidim.bih.concierge.web_fallback",
                         default: I18n.t("decidim.bih.concierge.help", locale: I18n.locale, default: nil) ||
                                  I18n.t("decidim.bih.concierge.help", locale: "sr")),
            report: nil,
            quick_replies: fallback_quick_replies,
            answer_intent: "fallback"
          )
        end

        # Best-effort civic-shortcut chips for the controller-built fallback
        # reply. Resolved against the request's organization and UI locale;
        # swallows any failure to [] so the fallback can NEVER break.
        def fallback_quick_replies
          Decidim::Bih::Concierge::CivicShortcuts.new(
            organization: current_organization, locale: I18n.locale.to_s
          ).chips
        rescue StandardError
          []
        end
      end
    end
  end
end
