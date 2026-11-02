# frozen_string_literal: true

module Decidim
  module Bih
    module Sms
      # Decidim SMS gateway implementation backed by Infobip.
      #
      # Wired in the host app via `Decidim.sms_gateway_service =
      # "Decidim::Bih::Sms::InfobipGateway"`. Decidim instantiates it with the
      # phone number and verification code and calls #deliver_code.
      #
      # When Infobip is not configured (no credentials), it logs the code and
      # returns true so the verification flow is usable in development without a
      # live SMS account — the same posture as Decidim's ExampleGateway.
      #
      # Delivery strategy is shared with passwordless login and Viber account
      # linking: Viber Business Messages -> WhatsApp AUTH -> SMS. Infobip's Messages
      # API owns delivery-status-aware failover when enabled; otherwise the
      # client preserves Viber -> SMS compatibility. The same single-use token
      # is carried by every eligible channel.
      class InfobipGateway
        attr_reader :mobile_phone_number, :code, :context

        def initialize(mobile_phone_number, code, context = {})
          @mobile_phone_number = mobile_phone_number
          @code = code
          @context = context || {}
        end

        # Returns true when the message was delivered (or logged in dev).
        # Returns false — so Decidim surfaces the error and the citizen can
        # retry — when the provider rejects it, and also when no one-tap link
        # can be minted at all: the message is the link, and a code-only text
        # would leave the citizen with nothing to do with it.
        def deliver_code
          unless client.configured?
            if Rails.env.production?
              Rails.logger.error(
                "[Infobip SMS] client unconfigured; cannot deliver verification code to " \
                "#{Decidim::Bih::LogRedactor.mask_phone(mobile_phone_number)}"
              )
              return false
            end

            # Logs the message the citizen would have received, link and all,
            # so development can follow the flow by tapping it. Minting the
            # token here is deliberate — the logged link has to work.
            Rails.logger.info(
              "[Infobip SMS] (unconfigured) #{message_text} for " \
              "#{Decidim::Bih::LogRedactor.mask_phone(mobile_phone_number)}"
            )
            return true
          end

          url = magic_link_url
          if url.blank?
            # No user (or no organization host) means no user-bound token, and
            # so no one-tap link. A typed code would still verify — Decidim's
            # own /sms/authorizations/edit takes one, and so does the engine's
            # hidden-code page — but a blank link here means the CALLER lost
            # the user, and silently demoting every citizen to typing six
            # digits would hide that. Fail so Decidim shows the retry message
            # and the miss is visible.
            #
            # Two distinct failure modes end up here vs. the rescue below, and
            # the resend.failed copy ("the previous link no longer works") is
            # only true of one of them:
            #   - THIS guard fires before magic_link_url ever calls
            #     LoginToken.issue!, so no token was minted and no previous
            #     token was invalidated — a link already in the citizen's
            #     inbox still works.
            #   - The `rescue Decidim::Bih::Infobip::Error` below is reached
            #     only after magic_link_url succeeded, i.e. issue! already
            #     invalidated the prior token (see LoginToken.issue!'s
            #     update_all(consumed_at:)) before the send itself failed —
            #     there the copy is accurate.
            # A caller landing here (missing context) is exactly the earlier
            # form of this bug: see PhoneVerificationActions#deliver_again
            # (extracted out of phone_verification_controller.rb), which used
            # to build the context via
            # `with_context(user: ...)` — CONTEXT, not a `from_params`
            # attribute — so `form.user` (and therefore context[:user]) was
            # always nil.
            Rails.logger.error(
              "[Infobip SMS] magic link unavailable (missing user/host context); not sending to " \
              "#{Decidim::Bih::LogRedactor.mask_phone(mobile_phone_number)}"
            )
            return false
          end

          send_verified_code(url)
          true
        rescue Decidim::Bih::Infobip::Error => e
          Rails.logger.error(
            "[Infobip SMS] delivery failed for #{Decidim::Bih::LogRedactor.mask_phone(mobile_phone_number)}: " \
            "#{Decidim::Bih::LogRedactor.error_message(e)}"
          )
          false
        end

        private

        # Executes the shared ordered phone-delivery policy for one code.
        def send_verified_code(url)
          client.send_phone_message(
            to: mobile_phone_number,
            text: sms_text(url),
            viber_text: viber_text(url),
            viber_template: viber_template(url),
            # The provider-side validity comes from VERIFY_TTL, so it can never
            # outlive the link it carries. The "24 sata" in the copy is a
            # separate literal in the locale files and has to be kept in step
            # by hand — the gateway test pins the two together.
            expires_at: Decidim::Bih::LoginToken::VERIFY_TTL.from_now,
            channels: context[:channels],
            # WhatsApp AUTH templates carry only the code (never the link), so
            # the code travels as its own field rather than inside the text.
            otp_code: code
          )
        end

        # SMS: the code first (OS autofill reads it there), then the one-tap
        # link. ASCII only so it stays GSM-7, and short enough to be ONE
        # segment at the longest production link — owner decision 2026-09-07
        # (evening), revisiting the earlier two-segment wording: this is the
        # most frequent paid message on the platform, and the foundation's
        # full name is already carried by the sender id. Diacritics would
        # force UCS-2 and quadruple the cost.
        #
        # Rendered in a Latin locale even for a Cyrillic-reading citizen (see
        # #sms_locale): Cyrillic is UCS-2 whatever we do, and the ASCII source
        # this text is written in transliterates into misspelled Cyrillic
        # ("вази", "Немас"). Those generated sr-Cyrl lines are left alone
        # precisely because nothing ever renders them.
        def sms_text(url)
          I18n.with_locale(sms_locale) do
            I18n.t(
              "decidim.bih.sms.verification_link",
              code:,
              url:,
              default: format(
                "MI: %{code} je tvoj kod. Ne dijeli ga. Potvrda jednim dodirom: %{url} (vazi 24 sata)",
                url:, code:
              )
            )
          end
        end

        # Decidim::Bih::Sms.latin_locale_for owns the rule (and why it exists)
        # for every SMS sender on the platform, not just this one.
        def sms_locale
          Decidim::Bih::Sms.latin_locale_for(I18n.locale)
        end

        # Viber implies a smartphone and is not segment-limited, so it keeps
        # the citizen's own locale — Cyrillic included — and carries the link
        # alone. The code never appears in this text (the provisioned Viber
        # template is a separate path; see #viber_template).
        def viber_text(url)
          I18n.t(
            "decidim.bih.sms.viber_verify_link",
            url:,
            default: "MI: potvrdi broj i uđi jednim dodirom: #{url} (važi 24 sata)"
          )
        end

        # The one place the code does reach Viber: Infobip's provisioned
        # templates declare a `pin` placeholder, so the template path has to
        # fill it even when the free-text message deliberately omits it.
        # Dropping it here would make the template render blank, not safer.
        def viber_template(url)
          config = Decidim::Bih::Config.infobip
          template_id = url.present? ? config[:viber_login_template_id] : config[:viber_otp_template_id]
          return if template_id.blank?

          parameters = { pin: code }
          parameters[:token] = url.to_s.split("/").last if url.present?
          {
            template_id:,
            language: config[:viber_template_language],
            parameters:
          }
        end

        # The full SMS as it would go out, minting the token on the way. Used by
        # the unconfigured-in-development log line and by tests that assert on
        # the complete text including the link.
        def message_text
          sms_text(magic_link_url)
        end

        # One-tap verify+login link. Only minted when Decidim handed us the
        # user (see SmsGatewayContextOverride) and the org host is known.
        #
        # The token is minted once per deliver_code call. Both the Viber text
        # and the SMS failover text carry the SAME token — single-use means
        # the first successful activation wins (browser tap or Viber inbound),
        # exactly as before. The token records the phone so ViberVerifyFlow can
        # recover it on consume.
        def magic_link_url
          return @magic_link_url if defined?(@magic_link_url)

          user = context[:user]
          organization = context[:organization]
          @magic_link_url = if user.is_a?(Decidim::User) && organization&.host
                              # Issue the token with the phone EXACTLY as Decidim sanitized it
                              # (mobile_phone_number is the output of MobilePhoneForm#mobile_phone_number,
                              # i.e. gsub(/[^+0-9]/, "")). This value is also what Decidim used to
                              # compute the pending authorization's unique_id:
                              #   unique_id = SHA256("#{mobile_phone_number}-#{secret_key_base}")
                              # Binding the token to the same string lets GrantsSmsAuthorization
                              # recompute the same unique_id on consume and match the stored auth.
                              # DELIVERY normalization (local → E.164) is handled separately by
                              # Decidim::Bih::Infobip::Client#normalize_msisdn at send time.
                              raw = Decidim::Bih::LoginToken.issue!(user:, purpose: "verify", phone: mobile_phone_number)
                              Decidim::Bih.magic_link_url(raw, host: organization.host)
                            end
        end

        def client
          @client ||= Decidim::Bih.phone_auth_delivery_client
        end
      end
    end
  end
end
