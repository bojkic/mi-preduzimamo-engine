# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Isporučuje pozivnicu TELEFONOM: Viber Business Messages -> WhatsApp
      # (template) -> SMS kroz Infobip::Client#send_phone_message, isti
      # redoslijed kao ostatak platforme. E-mail je REZERVA, ne duplikat —
      # ide samo kad telefonski lanac NIJE poslao (odluka 2026-09-07): na
      # telefon-prvo platformi adresa nije potvrđena, a ova poruka nosi broj
      # rezervacije koji se pokazuje na ulazu i link koji potvrđuje dolazak.
      #
      # Kad NEMA sačuvanog broja, pozivnica se NE gubi u tišini: e-mail je već
      # otišao, a in-app obavještenje + e-mail traže potvrdu broja. Kad broj
      # POSTOJI ali isporuka nije uspjela (Infobip nije konfigurisan, ili je
      # send_phone_message pukao), to je samo log upozorenje — verifikovan
      # građanin se NIKAD ne smije pozvati da "potvrdi broj" koji je već
      # potvrdio; ta razlika je namjerna (vidi #deliver_phone/#perform).
      #
      # NIKAD ne loguje ulazni kod ni broj telefona.
      #
      # NOT A CAMPAIGN MESSAGE. This is a reward fulfilment, and the difference
      # is not cosmetic: it uses SMS (the campaign never does — owner decision
      # 2026-09-07, `Launch::MessageDispatcher` has no SMS leg at all) and its
      # e-mail is an unconditional fallback whenever the phone chain did not
      # send (the marketing campaign has no e-mail fallback whatsoever). The
      # registry keeps them apart as `goodwill.launch_invitation_phone` /
      # `goodwill.launch_invitation_email`, both `account_lifecycle` and both
      # `legacy_unmigrated`, so no campaign enrollment flag can reach this job.
      # Merging it into a campaign class would put SMS inside a no-SMS
      # contract; see rails_test/messaging_router_campaign_test.rb.
      class LaunchInvitationDeliveryJob < ActiveJob::Base
        self.log_arguments = false

        queue_as :mailers

        discard_on ActiveJob::DeserializationError

        def perform(fulfillment_id)
          fulfillment = RewardFulfillment.find_by(id: fulfillment_id)
          return if fulfillment.blank?
          return if fulfillment.entry_code.blank?

          # Phone first: the verified number is the identity and the campaign
          # promises "pozivnica ti stiže porukom". E-mail is additional and,
          # since phone-first registration, unproven.
          #
          # The waiting-for-phone nudge fires ONLY for :no_phone. A verified
          # citizen whose number simply could not be reached this one time
          # (Infobip unconfigured, or send_phone_message raised) must never be
          # told to "confirm your number" — they already did; that would be
          # actively wrong, not just unhelpful. Those two reasons are
          # log-only (see #deliver_phone).
          # One confirm-attendance link for every channel of this delivery. The
          # raw token lives only in this process: the e-mail is delivered NOW
          # rather than enqueued, so the link never sits in Redis as a job
          # argument (same reasoning as the phone number below).
          confirm_url = Decidim::Bih::Goodwill::LaunchInvitation.confirm_link_url(fulfillment)

          reason = deliver_phone(fulfillment, confirm_url)
          # E-mail is the FALLBACK, not a duplicate. On a phone-first host the
          # address is never proven, and this mail carries the reservation number
          # shown at the door plus a 72-hour bearer confirm link — a mistyped
          # address hands both to a stranger. It goes out only when the phone
          # chain did not send (review 2026-09-07, lane 6 H4).
          deliver_email(fulfillment, confirm_url) unless reason == :sent
          notify_waiting_for_phone(fulfillment) if reason == :no_phone
        end

        private

        def deliver_email(fulfillment, confirm_url)
          return if fulfillment.user.email.blank?

          LaunchInvitationMailer.invitation(fulfillment, confirm_url:).deliver_now
        rescue StandardError => e
          Rails.logger.error(
            "[launch_invitation] e-mail isporuka pala za fulfillment " \
            "#{fulfillment.id}: #{Decidim::Bih::LogRedactor.error_message(e)}"
          )
        end

        # Broj se sada trajno čuva (odluka naručioca 2026-08-31), pa ovo zaista
        # šalje poruku kad broj postoji.
        #
        # Namjerno šalje SINHRONO kroz Infobip::Client umjesto da zakaže
        # Infobip::SendSmsJob(to: phone, ...): taj job bi ozbiljno broj
        # (ActiveJob argument) serijalizovao u Redis/Sidekiq za trajanje reda,
        # a SendSmsJob-ov retry_on ga PONOVO serijalizuje na svaki retry — kod
        # trajnog pada broj bi ostao vidljiv u dead setu, van ove tabele i van
        # dohvata retencionog sweep-a. Ovdje se broj čita svježe iz baze u
        # lokalnu varijablu i nikad ne postaje argument zakazanog posla, pa ga
        # ništa ne perzistira van decidim_bih_citizen_phones. Cijena: gubi se
        # Infobip::SendSmsJob-ov automatski retry sa exponential backoff-om za
        # ovaj kanal — prihvatljivo jer je e-mail (poslan bezuslovno iznad)
        # primarni, pouzdan kanal za ulazni kod; telefon je bonus.
        #
        # Returns a reason symbol, not a boolean, because #perform must tell
        # "no number at all" apart from "had a number, could not reach it
        # this time" — only the former means the waiting-for-phone nudge:
        #   :sent           — send_phone_message was called and did not raise
        #   :no_phone       — CitizenPhone.for returned nothing to send to
        #   :not_configured — a number exists but Infobip has no credentials
        #   :failed         — a number exists but send_phone_message raised
        def deliver_phone(fulfillment, confirm_url)
          phone = Decidim::Bih::CitizenPhone.for(fulfillment.user)
          return :no_phone if phone.blank?

          client = Decidim::Bih::Infobip::Client.new
          unless client.configured?
            warn_phone_delivery_failed(fulfillment, "not configured")
            return :not_configured
          end

          locale = fulfillment.organization.default_locale.presence || "sr"
          client.send_phone_message(
            to: phone,
            text: invitation_text(fulfillment, gsm7_locale(locale), confirm_url),
            viber_text: invitation_text(fulfillment, locale, confirm_url),
            whatsapp_template: whatsapp_invitation_template(fulfillment, confirm_url),
            expires_at: 24.hours.from_now,
            # An invitation lives 24 hours: it may wait hours on the free
            # channel rather than falling through to a paid SMS because the
            # handset was offline for a minute.
            channel_validity_seconds: Decidim::Bih::Infobip::Client::CAMPAIGN_CHANNEL_VALIDITY.to_i
          )
          :sent
        rescue StandardError => e
          warn_phone_delivery_failed(fulfillment, Decidim::Bih::LogRedactor.error_message(e))
          :failed
        end

        # Shared WARN (not ERROR — a verified citizen simply not reached this
        # once is an expected, recoverable outcome, not a bug) for both
        # non-:sent, non-:no_phone reasons. Fulfillment id only, never phone
        # or entry code.
        def warn_phone_delivery_failed(fulfillment, reason)
          Rails.logger.warn(
            "[decidim-bih] launch invitation phone delivery failed for fulfillment #{fulfillment.id}: #{reason}"
          )
        end

        def invitation_text(fulfillment, locale, confirm_url)
          I18n.with_locale(locale) do
            I18n.t(
              "decidim.bih.goodwill.launch_invitation_mailer.invitation.sms",
              code: fulfillment.entry_code,
              url: confirm_url
            )
          end
        end

        # WhatsApp joins the Viber -> SMS chain only through a Meta-approved
        # template (INFOBIP_WHATSAPP_INVITATION_TEMPLATE_NAME): {{1}} is the
        # reservation number or the first name (see Config), and the
        # dynamic-URL button gets the confirm token as its suffix — the same
        # token the SMS and Viber links carry. Nil until the host names an
        # approved template, and then the chain is exactly as before.
        def whatsapp_invitation_template(fulfillment, confirm_url)
          config = Decidim::Bih::Config.infobip
          name = config[:whatsapp_invitation_template_name]
          return if name.blank? || config[:whatsapp_sender].blank?

          value = if config[:whatsapp_invitation_template_placeholder] == "first_name"
                    fulfillment.user.name.to_s.split.first.presence || fulfillment.user.nickname
                  else
                    fulfillment.entry_code
                  end
          {
            name:,
            language: config[:whatsapp_template_language],
            body: { "1" => value },
            button_suffix: confirm_url.to_s.split("/").last
          }
        end

        # The SMS leg renders under the Latin sibling of the citizen's locale
        # — Decidim::Bih::Sms.latin_locale_for owns that rule and the reasons
        # for it. The Viber leg is not segment-limited and keeps the citizen's
        # own locale, diacritics included.
        def gsm7_locale(locale)
          Decidim::Bih::Sms.latin_locale_for(locale)
        end

        # ONLY za :no_phone (vidi #perform) — bez sačuvanog broja pozivnica se
        # NIKAD ne gubi u tišini: e-mail je već poslan bezuslovno iznad, a ovo
        # dodaje in-app obavještenje + e-mail koji građanina vode na potvrdu
        # broja. Prolazni kvar isporuke (broj postoji, slanje nije uspjelo)
        # NIKAD ne stiže ovamo — verifikovan građanin ne smije čuti "potvrdi
        # broj" za broj koji je već potvrdio.
        def notify_waiting_for_phone(fulfillment)
          Rails.logger.warn(
            "[launch_invitation] poruka telefonom nije poslana za fulfillment #{fulfillment.id}; " \
            "pozivnica čeka potvrdu broja"
          )
          Decidim::EventsManager.publish(
            event: "decidim.events.bih.launch_invitation_waiting_for_phone",
            event_class: Decidim::Bih::Goodwill::LaunchInvitationWaitingForPhoneEvent,
            resource: fulfillment.user,
            affected_users: [fulfillment.user]
          )
        rescue StandardError => e
          Rails.logger.error(
            "[launch_invitation] obavještenje 'čeka broj' palo: #{Decidim::Bih::LogRedactor.error_message(e)}"
          )
        end
      end
    end
  end
end
