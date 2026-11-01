# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # The registry of what this platform can actually send.
      #
      # The communication audit counted 159 journey touchpoints; those are
      # moments in a citizen's journey, not senders. Several touchpoints share
      # one producer, many produce no message at all, and a few named surfaces
      # are outside the platform entirely. This registry names the PRODUCERS —
      # the code paths that can put a message in front of somebody — and, for
      # each one, the purpose, who it addresses, which preference contract
      # governs it, how its channels group, and whether it is enrolled in the
      # unified messaging policy yet.
      #
      # Phase 1 enrols only the producers that already route through the MI
      # stored-key matrix, and only in `shadow`: the legacy caller stays
      # authoritative. Everything else is `legacy_unmigrated`, which is an
      # honest statement of coverage rather than a claim that a handful of
      # entries cover the platform.
      #
      # Deliberately plain Ruby (no Rails, no ActiveSupport): the registry is a
      # declaration, it is loaded by pure unit tests, and it must not be able to
      # touch the database or a provider by itself.
      module MessageClass
        class UnknownMessageClass < StandardError; end

        class UnsupportedChannel < StandardError; end

        PURPOSES = %w(
          authentication
          account_lifecycle
          own_report_correspondence
          case_operations
          optional_news
          campaign
          core_event
          core_transactional
          conversation
          reactive_chat
          operator_report
          external_institution
        ).freeze

        CHANNELS = %w(bell push email sms viber whatsapp messenger instagram postal web_chat).freeze

        # External account transports share topic preferences; inbox and device
        # fanout retain separate producer adapters.
        TOPIC_CHANNELS = %w(viber whatsapp messenger instagram email).freeze

        # Repeated literally rather than referenced so this registry stays
        # loadable on its own; `registry_contracts_test.rb` proves the two lists
        # never drift apart.
        RECIPIENT_KINDS = %w(
          account
          pending_authentication
          anonymous_report_contact
          staff
          external_institution
          provider_inbound_identity
          operator_mailbox
        ).freeze

        PRIORITIES = %w(authentication transactional routine bulk).freeze

        PAYLOAD_CLASSES = %w(
          authentication_secret
          case_private
          public_notice
          operational
          marketing
          conversational
          account_lifecycle
        ).freeze

        ENROLLMENT_STATES = %w(legacy_unmigrated shadow).freeze

        GROUP_MODES = %w(fallback parallel single).freeze

        # Who decides that a channel failed and another may be tried. `provider`
        # means Infobip's Messages API owns the chain; `producer` means the
        # calling code does; `none` means nothing falls back.
        FALLBACK_OWNERS = %w(none producer provider).freeze

        DEDUPLICATION_OWNERS = %w(none producer ledger core_event operator_audit provider).freeze

        # Each adapter is a distinct permission contract. They are NOT
        # interchangeable, and a message class names exactly the one that
        # governs it.
        PREFERENCE_ADAPTERS = %w(
          requested_authentication
          report_contact_address
          report_updates_topic
          community_news_topic
          city_service_alerts_topic
          neighborhood_info_topic
          platform_news_topic
          one_time_test_permission
          legacy_urgent_bell
          core_notification_types
          core_email_frequency
          core_newsletter
          core_direct_message
          core_moderation_email
          core_transactional
          device_subscription
          channel_session
          operator_recipient_config
          external_recipient_config
          none
        ).freeze

        Entry = Struct.new(
          :key, :purpose, :producer, :recipient_kinds, :preference_adapter, :channel_groups,
          :priority, :expires_in, :payload_class, :deduplication_owner, :enrollment,
          :message_keys, :external_boundary, :notes,
          keyword_init: true
        ) do
          def external_boundary?
            external_boundary == true
          end

          def channels
            channel_groups.flat_map { |group| Array(group[:channels]) }.uniq
          end

          def group_for(channel)
            channel_groups.find { |group| Array(group[:channels]).include?(channel.to_s) }
          end

          def enrolled?
            enrollment == "shadow"
          end
        end

        # Surfaces that people reasonably call "communication" but which this
        # platform does not send: a page somebody visits, a link a citizen
        # forwards in their own app, a letter a human posts, or a campaign run
        # in another system. Naming them keeps a page view out of the delivery
        # ledger.
        EXTERNAL_BOUNDARIES = [
          { key: "boundary.public_pages", reason: "Published content and Komšiluk boards are visibility, not a recipient list." },
          { key: "boundary.venue_screen", reason: "/ekran and /biceriseno/ekran are a login-free public display with no recipient." },
          { key: "boundary.referral_share", reason: "A share intent opens the citizen's own app; MI never sends that message." },
          { key: "boundary.printed_qr", reason: "A locally generated QR or poster is printed, not delivered by the platform." },
          { key: "boundary.postal_posting", reason: "Printing/marking a letter does not prove physical posting or receipt." },
          { key: "boundary.support_mailbox", reason: "Support mail_to/tel: links are followed outside the app and are not observed." },
          { key: "boundary.odoo_campaigns", reason: "Odoo campaign audiences, unsubscribes and sends are administered outside MI." },
          { key: "boundary.browser_consent", reason: "The data-consent cookie governs scripts in the browser, not delivery." },
          { key: "boundary.page_nudges", reason: "Omnipresent banner, PWA install card and push offer render on a page; they send nothing." },
          { key: "boundary.admin_read_screens", reason: "Integration/analytics screens display stored status; showing it is not sending." }
        ].freeze

        # rubocop:disable Metrics/ParameterLists
        def self.group(name:, channels:, mode:, content_variant:, preference_adapter:,
                       fallback_owner: "none", fanout: "per_recipient", content_variant_by_channel: {},
                       expires_in: nil, deduplication: "producer", notes: nil)
          {
            name:,
            channels: Array(channels).map(&:to_s).freeze,
            mode:,
            content_variant:,
            content_variant_by_channel: content_variant_by_channel.freeze,
            preference_adapter:,
            fallback_owner:,
            fanout:,
            expires_in:,
            deduplication:,
            notes:
          }.freeze
        end
        # rubocop:enable Metrics/ParameterLists

        # A chain the provider owns end to end. A timeout or unknown outcome is
        # not permission to start another chain.
        def self.phone_chain(channels:, preference_adapter:, content_variant: "phone_text", **rest)
          group(name: "phone_chain", channels:, mode: "fallback", content_variant:,
                preference_adapter:, fallback_owner: "provider", **rest)
        end

        def self.bell_group(preference_adapter:, content_variant: "bell_event", **rest)
          group(name: "bell", channels: %w(bell), mode: "parallel", content_variant:, preference_adapter:, **rest)
        end

        def self.push_group(content_variant: "generic_push", **rest)
          group(name: "push", channels: %w(push), mode: "parallel", content_variant:,
                preference_adapter: "device_subscription", fanout: "per_device", **rest)
        end

        def self.email_group(preference_adapter:, name: "email", content_variant: "mail", **rest)
          group(name:, channels: %w(email), mode: "parallel", content_variant:, preference_adapter:, **rest)
        end

        # One permitted external copy: at most one provider-managed phone chain
        # OR one linked social session — never a fan-out to every checked box.
        def self.account_external_copy(preference_adapter:, channels: TOPIC_CHANNELS, content_variant: "external_copy", **rest)
          group(name: "external_copy", channels:, mode: "single", content_variant:,
                preference_adapter:, deduplication: "ledger", **rest)
        end

        def self.define(**attrs)
          Entry.new(
            message_keys: [].freeze,
            external_boundary: false,
            notes: nil,
            **attrs
          ).freeze
        end

        REGISTRY = [
          # ---- authentication and registration ------------------------------
          define(
            key: "authentication.phone_verification",
            purpose: "authentication",
            producer: "engine:app/commands/decidim/bih/register_with_phone.rb; " \
                      "engine:app/controllers/concerns/decidim/bih/phone_verification_actions.rb; " \
                      "engine:app/services/decidim/bih/sms/infobip_gateway.rb",
            recipient_kinds: %w(pending_authentication account),
            preference_adapter: "requested_authentication",
            channel_groups: [phone_chain(channels: %w(viber whatsapp sms), preference_adapter: "requested_authentication",
                                         content_variant: "verify_link_and_code", expires_in: 86_400)],
            priority: "authentication",
            expires_in: 86_400,
            payload_class: "authentication_secret",
            deduplication_owner: "producer",
            enrollment: "legacy_unmigrated",
            notes: "Link + typed code both live 24 h. SMS carries GSM-7 Latin by design. WhatsApp joins only with an AUTH template configured for sr."
          ),
          define(
            key: "authentication.phone_login",
            purpose: "authentication",
            producer: "engine:app/controllers/decidim/bih/phone_sessions_controller.rb; " \
                      "engine:app/jobs/decidim/bih/infobip/send_phone_message_job.rb",
            recipient_kinds: %w(account),
            preference_adapter: "requested_authentication",
            channel_groups: [phone_chain(channels: %w(viber whatsapp sms), preference_adapter: "requested_authentication",
                                         content_variant: "login_link", expires_in: 600)],
            priority: "authentication",
            expires_in: 600,
            payload_class: "authentication_secret",
            deduplication_owner: "producer",
            enrollment: "legacy_unmigrated",
            notes: "The passwordless login link is still 10 minutes; only the verify link was extended to 24 h."
          ),
          define(
            key: "authentication.viber_bot_link",
            purpose: "authentication",
            producer: "engine:app/services/decidim/bih/viber/account_linking.rb; " \
                      "engine:app/services/decidim/bih/viber/queued_phone_message_gateway.rb",
            recipient_kinds: %w(pending_authentication),
            preference_adapter: "requested_authentication",
            channel_groups: [group(name: "sms", channels: %w(sms), mode: "single", content_variant: "link_otp",
                                   preference_adapter: "requested_authentication")],
            priority: "authentication",
            expires_in: 600,
            payload_class: "authentication_secret",
            deduplication_owner: "producer",
            enrollment: "legacy_unmigrated",
            notes: "Dormant. The Bot identity is opaque and is not a phone; do not build further on this path."
          ),
          define(
            key: "registration.resume_email",
            purpose: "account_lifecycle",
            producer: "engine:app/jobs/decidim/bih/resume_registration_email_job.rb; " \
                      "engine:app/mailers/decidim/bih/registration_mailer.rb",
            recipient_kinds: %w(pending_authentication),
            preference_adapter: "core_transactional",
            channel_groups: [email_group(preference_adapter: "core_transactional", content_variant: "resume_registration")],
            priority: "transactional",
            expires_in: 604_800,
            payload_class: "account_lifecycle",
            deduplication_owner: "producer",
            enrollment: "legacy_unmigrated",
            notes: "Scheduled +15 min by the registration command; the resume token lives exactly as long as the stub (7 days)."
          ),
          define(
            key: "registration.final_notice_email",
            purpose: "account_lifecycle",
            producer: "engine:app/services/decidim/bih/registration/pending_lifecycle.rb; " \
                      "engine:app/mailers/decidim/bih/registration_mailer.rb",
            recipient_kinds: %w(pending_authentication),
            preference_adapter: "core_transactional",
            channel_groups: [email_group(preference_adapter: "core_transactional", content_variant: "final_notice")],
            priority: "transactional",
            expires_in: 172_800,
            payload_class: "account_lifecycle",
            deduplication_owner: "producer",
            enrollment: "legacy_unmigrated",
            notes: "Day 5 of the 7-day stub lifetime; day 7 deletion is silent and sends nothing."
          ),
          define(
            key: "registration.operator_resend",
            purpose: "account_lifecycle",
            producer: "engine:app/commands/decidim/bih/registration/resend_verification.rb; " \
                      "engine:app/controllers/decidim/bih/admin/pending_registrations_controller.rb; " \
                      "engine:lib/tasks/decidim_bih_registration.rake",
            recipient_kinds: %w(pending_authentication),
            preference_adapter: "requested_authentication",
            channel_groups: [
              email_group(preference_adapter: "core_transactional", name: "resume_email", content_variant: "resume_registration"),
              group(name: "verification_sms", channels: %w(sms), mode: "single", content_variant: "verify_link_and_code",
                    preference_adapter: "requested_authentication",
                    notes: "delivery_channels: [\"sms\"] — explicitly NOT the citizen failover chain")
            ],
            priority: "authentication",
            expires_in: 86_400,
            payload_class: "authentication_secret",
            deduplication_owner: "operator_audit",
            enrollment: "legacy_unmigrated",
            notes: "One resend per citizen per 600 s, fail-closed. Two parallel copies; neither cancels the other."
          ),
          define(
            key: "account.email_confirmation",
            purpose: "account_lifecycle",
            producer: "engine:app/controllers/decidim/bih/email_confirmations_controller.rb; " \
                      "engine:app/mailers/decidim/bih/email_confirmation_mailer.rb",
            recipient_kinds: %w(account),
            preference_adapter: "core_transactional",
            channel_groups: [email_group(preference_adapter: "core_transactional", content_variant: "email_confirmation")],
            priority: "transactional",
            expires_in: 172_800,
            payload_class: "account_lifecycle",
            deduplication_owner: "producer",
            enrollment: "legacy_unmigrated",
            notes: "Address-bound signed token, 20-minute request cooldown. Proof of address, never a topic permission."
          ),
          define(
            key: "account.channel_test",
            purpose: "optional_news",
            producer: "engine:app/controllers/decidim/bih/account_notification_settings_controller.rb; " \
                      "engine:app/services/decidim/bih/account_notifications.rb",
            recipient_kinds: %w(account),
            preference_adapter: "one_time_test_permission",
            channel_groups: [account_external_copy(preference_adapter: "one_time_test_permission", content_variant: "self_test")],
            priority: "routine",
            expires_in: 300,
            payload_class: "marketing",
            deduplication_owner: "ledger",
            enrollment: "shadow",
            notes: "One-message permission bound to one intent and a provenance snapshot. It bypasses the topic choice ONLY; identity, capability and template rules still apply."
          ),
          define(
            key: "account.push_test",
            purpose: "account_lifecycle",
            producer: "engine:app/controllers/decidim/bih/web_push_tests_controller.rb",
            recipient_kinds: %w(account),
            preference_adapter: "device_subscription",
            channel_groups: [push_group(content_variant: "self_test")],
            priority: "routine",
            expires_in: 3600,
            payload_class: "operational",
            deduplication_owner: "none",
            enrollment: "legacy_unmigrated",
            notes: "Uses the CURRENT browser subscription and reports queued, never received."
          ),

          # ---- goodwill, invitations and awards ------------------------------
          define(
            key: "goodwill.launch_invitation_phone",
            purpose: "account_lifecycle",
            producer: "engine:app/jobs/decidim/bih/goodwill/launch_invitation_delivery_job.rb",
            recipient_kinds: %w(account),
            preference_adapter: "requested_authentication",
            channel_groups: [phone_chain(channels: %w(viber whatsapp sms), preference_adapter: "requested_authentication",
                                         content_variant: "invitation_code_and_link", expires_in: 259_200)],
            priority: "transactional",
            expires_in: 259_200,
            payload_class: "account_lifecycle",
            deduplication_owner: "producer",
            enrollment: "legacy_unmigrated",
            notes: "Stored phone first; named invitation WhatsApp template when configured. No marketing-topic lookup."
          ),
          define(
            key: "goodwill.launch_invitation_email",
            purpose: "account_lifecycle",
            producer: "engine:app/jobs/decidim/bih/goodwill/launch_invitation_delivery_job.rb; " \
                      "engine:app/mailers/decidim/bih/goodwill/launch_invitation_mailer.rb",
            recipient_kinds: %w(account),
            preference_adapter: "core_transactional",
            channel_groups: [email_group(preference_adapter: "core_transactional", content_variant: "invitation_code_and_link")],
            priority: "transactional",
            expires_in: 259_200,
            payload_class: "account_lifecycle",
            deduplication_owner: "producer",
            enrollment: "legacy_unmigrated",
            notes: "Sent only when the phone call did not return sent. Producer owns that decision, not the router."
          ),
          define(
            key: "goodwill.invitation_waiting_for_phone",
            purpose: "core_event",
            producer: "engine:app/events/decidim/bih/goodwill/launch_invitation_waiting_for_phone_event.rb; " \
                      "engine:app/jobs/decidim/bih/goodwill/launch_invitation_delivery_job.rb",
            recipient_kinds: %w(account),
            preference_adapter: "core_notification_types",
            channel_groups: [
              bell_group(preference_adapter: "core_notification_types"),
              push_group,
              email_group(preference_adapter: "core_email_frequency", content_variant: "event_email")
            ],
            priority: "routine",
            expires_in: nil,
            payload_class: "account_lifecycle",
            deduplication_owner: "core_event",
            enrollment: "legacy_unmigrated",
            notes: "The one engine event that is email-capable (SimpleEvent). Raised for :no_phone only, never a transient delivery failure."
          ),
          define(
            key: "goodwill.points_earned",
            purpose: "core_event",
            producer: "engine:app/services/decidim/bih/goodwill/ledger.rb; " \
                      "engine:app/events/decidim/bih/goodwill/points_earned_event.rb",
            recipient_kinds: %w(account),
            preference_adapter: "core_notification_types",
            channel_groups: [bell_group(preference_adapter: "core_notification_types"), push_group],
            priority: "routine",
            expires_in: nil,
            payload_class: "operational",
            deduplication_owner: "core_event",
            enrollment: "legacy_unmigrated",
            notes: "NotificationEvent only — a bell, and push for subscribers. No event e-mail."
          ),
          define(
            key: "goodwill.daily_cap_reached",
            purpose: "core_event",
            producer: "engine:app/services/decidim/bih/goodwill/earning_rules.rb",
            recipient_kinds: %w(account),
            preference_adapter: "core_notification_types",
            channel_groups: [bell_group(preference_adapter: "core_notification_types"), push_group],
            priority: "routine",
            expires_in: nil,
            payload_class: "operational",
            deduplication_owner: "core_event",
            enrollment: "legacy_unmigrated",
            notes: "The action still executes and simply earns nothing; the citizen is told once per action per day."
          ),
          define(
            key: "goodwill.referral_verified",
            purpose: "core_event",
            producer: "engine:app/services/decidim/bih/goodwill/referrals.rb",
            recipient_kinds: %w(account),
            preference_adapter: "core_notification_types",
            channel_groups: [bell_group(preference_adapter: "core_notification_types"), push_group],
            priority: "routine",
            expires_in: nil,
            payload_class: "operational",
            deduplication_owner: "core_event",
            enrollment: "legacy_unmigrated",
            notes: "Carries no name and no points; the reward is paid separately after the 24 h wait."
          ),
          define(
            key: "goodwill.reward_decision",
            purpose: "core_event",
            producer: "engine:app/services/decidim/bih/admin/goodwill_notifier.rb; " \
                      "engine:lib/tasks/decidim_bih_goodwill.rake",
            recipient_kinds: %w(account),
            preference_adapter: "core_notification_types",
            channel_groups: [bell_group(preference_adapter: "core_notification_types"), push_group],
            priority: "routine",
            expires_in: nil,
            payload_class: "operational",
            deduplication_owner: "core_event",
            enrollment: "legacy_unmigrated",
            notes: "reserved / fulfilled / canceled, including the scheduled expiry cancellation with its ledger reversal."
          ),
          define(
            key: "goodwill.match_request_decided",
            purpose: "core_event",
            producer: "engine:app/services/decidim/bih/admin/goodwill_notifier.rb",
            recipient_kinds: %w(account),
            preference_adapter: "core_notification_types",
            channel_groups: [bell_group(preference_adapter: "core_notification_types"), push_group],
            priority: "routine",
            expires_in: nil,
            payload_class: "operational",
            deduplication_owner: "core_event",
            enrollment: "legacy_unmigrated"
          ),

          # ---- launch campaigns ---------------------------------------------
          define(
            key: "campaign.transactional_phone",
            purpose: "campaign",
            producer: "engine:lib/tasks/decidim_bih_launch_campaign.rake; " \
                      "engine:app/services/decidim/bih/launch/campaign_send.rb; " \
                      "engine:app/services/decidim/bih/launch/message_dispatcher.rb",
            recipient_kinds: %w(account),
            preference_adapter: "platform_news_topic",
            channel_groups: [account_external_copy(preference_adapter: "platform_news_topic", channels: TOPIC_CHANNELS,
                                                   content_variant: "campaign_text",
                                                   notes: "One suitable external destination; no SMS")],
            priority: "bulk",
            expires_in: 86_400,
            payload_class: "marketing",
            deduplication_owner: "operator_audit",
            enrollment: "shadow",
            message_keys: %w(P1 P3 P7).freeze,
            notes: "Reserved-invitation and attendance audiences respect platform_news. DRY_RUN=1 by default, MAX_RECIPIENTS ceiling before the first send."
          ),
          define(
            key: "campaign.marketing_phone",
            purpose: "campaign",
            producer: "engine:app/services/decidim/bih/launch/message_dispatcher.rb; " \
                      "engine:app/services/decidim/bih/launch/campaign_recipients.rb",
            recipient_kinds: %w(account),
            preference_adapter: "platform_news_topic",
            channel_groups: [account_external_copy(preference_adapter: "platform_news_topic", channels: TOPIC_CHANNELS,
                                                   content_variant: "campaign_text",
                                                   notes: "Automatic selection among proven eligible external destinations; no SMS")],
            priority: "bulk",
            expires_in: 86_400,
            payload_class: "marketing",
            deduplication_owner: "ledger",
            enrollment: "shadow",
            message_keys: %w(P4 P5 P8 P9 P10).freeze,
            notes: "Canonical platform_news permission through the shared account ledger; one eligible external route."
          ),
          define(
            key: "campaign.letter_p11",
            purpose: "campaign",
            producer: "engine:app/services/decidim/bih/launch/campaign_recipients.rb; " \
                      "engine:app/services/decidim/bih/launch/message_templates.rb",
            recipient_kinds: %w(external_institution),
            preference_adapter: "none",
            channel_groups: [],
            priority: "bulk",
            expires_in: nil,
            payload_class: "operational",
            deduplication_owner: "none",
            enrollment: "legacy_unmigrated",
            message_keys: %w(P11).freeze,
            external_boundary: true,
            notes: "Returns an empty MI audience: a manually addressed letter to local-area presidents. A template existing is not an audience."
          ),

          # ---- reports: intake, status, case ---------------------------------
          define(
            key: "report.reporter_status_email",
            purpose: "own_report_correspondence",
            producer: "engine:app/models/decidim/bih/report.rb; engine:app/mailers/decidim/bih/reporter_mailer.rb",
            recipient_kinds: %w(anonymous_report_contact account),
            preference_adapter: "report_contact_address",
            channel_groups: [email_group(preference_adapter: "report_contact_address", content_variant: "report_status")],
            priority: "transactional",
            expires_in: nil,
            payload_class: "case_private",
            deduplication_owner: "producer",
            enrollment: "legacy_unmigrated",
            notes: "Addressed by the report's own reporter_email. Skips the initial primljeno transition. Not gated by report_updates, newsletter or event frequency."
          ),
          define(
            key: "report.author_external_copy",
            purpose: "own_report_correspondence",
            producer: "engine:app/models/decidim/bih/report.rb; engine:app/services/decidim/bih/account_notifications.rb",
            recipient_kinds: %w(account),
            preference_adapter: "report_updates_topic",
            channel_groups: [account_external_copy(preference_adapter: "report_updates_topic", content_variant: "report_status",
                                                   content_variant_by_channel: {
                                                     "viber" => "full_status_text",
                                                     "whatsapp" => "reference_and_status_only",
                                                     "messenger" => "full_status_text",
                                                     "instagram" => "full_status_text"
                                                   })],
            priority: "routine",
            expires_in: 86_400,
            payload_class: "case_private",
            deduplication_owner: "ledger",
            enrollment: "shadow",
            notes: "Authenticated author only. An anonymous contact address never selects somebody's account. Blockable even when the in-app service notification is not."
          ),
          define(
            key: "report.staff_alert",
            purpose: "case_operations",
            producer: "engine:app/jobs/decidim/bih/report_staff_alert_job.rb",
            recipient_kinds: %w(staff),
            preference_adapter: "none",
            channel_groups: [
              bell_group(preference_adapter: "none", content_variant: "staff_alert",
                         notes: "Notification.create! directly — notification_types is deliberately NOT consulted"),
              push_group(content_variant: "generic_push")
            ],
            priority: "transactional",
            expires_in: nil,
            payload_class: "case_private",
            deduplication_owner: "producer",
            enrollment: "legacy_unmigrated",
            notes: "Admins plus active operators with reports_read; one batch tracked by a staff_alerts_created report event."
          ),
          define(
            key: "report.case_message_to_author",
            purpose: "own_report_correspondence",
            producer: "engine:app/jobs/decidim/bih/report_case_message_job.rb; engine:app/services/decidim/bih/report_case_workflow.rb",
            recipient_kinds: %w(account),
            preference_adapter: "report_updates_topic",
            channel_groups: [
              bell_group(preference_adapter: "none", content_variant: "case_message",
                         notes: "direct bell; the service notification itself is not blockable by a topic choice"),
              push_group(content_variant: "generic_push"),
              account_external_copy(preference_adapter: "report_updates_topic", content_variant: "case_message",
                                    content_variant_by_channel: {
                                      "viber" => "full_case_text",
                                      "whatsapp" => "reference_and_status_only",
                                      "messenger" => "full_case_text",
                                      "instagram" => "full_case_text"
                                    },
                                    notes: "the configured WhatsApp report template carries reference/status placeholders only — no staff body, no private reply link")
            ],
            priority: "transactional",
            expires_in: 86_400,
            payload_class: "case_private",
            deduplication_owner: "ledger",
            enrollment: "shadow",
            notes: "Only the external copy is enrolled. Skipped intents are not automatically retried when a preference later changes."
          ),
          define(
            key: "report.case_message_to_staff",
            purpose: "case_operations",
            producer: "engine:app/jobs/decidim/bih/report_case_message_job.rb",
            recipient_kinds: %w(staff),
            preference_adapter: "none",
            channel_groups: [bell_group(preference_adapter: "none", content_variant: "case_message"), push_group],
            priority: "transactional",
            expires_in: nil,
            payload_class: "case_private",
            deduplication_owner: "producer",
            enrollment: "legacy_unmigrated"
          ),
          define(
            key: "report.case_deadline_reminder",
            purpose: "case_operations",
            producer: "engine:app/jobs/decidim/bih/report_case_reminder_job.rb",
            recipient_kinds: %w(staff),
            preference_adapter: "none",
            channel_groups: [bell_group(preference_adapter: "none", content_variant: "case_reminder"), push_group],
            priority: "routine",
            expires_in: nil,
            payload_class: "case_private",
            deduplication_owner: "producer",
            enrollment: "legacy_unmigrated",
            notes: "One reminder per due timestamp (reminded_due_at). The same sweep also repairs unnotified case messages and missing staff alerts."
          ),
          define(
            key: "report.city_reply",
            purpose: "case_operations",
            producer: "engine:app/services/decidim/bih/report_city_reply.rb; engine:app/services/decidim/bih/report_mailbox/process_message.rb",
            recipient_kinds: %w(staff),
            preference_adapter: "none",
            channel_groups: [bell_group(preference_adapter: "none", content_variant: "service_correspondence")],
            priority: "transactional",
            expires_in: nil,
            payload_class: "case_private",
            deduplication_owner: "producer",
            enrollment: "legacy_unmigrated",
            notes: "Inbound correspondence observed through read-only IMAP. Association and sender assurance are separate facts."
          ),
          define(
            key: "report.sistem48_forward",
            purpose: "external_institution",
            producer: "engine:app/services/decidim/bih/report_dispatching.rb; engine:app/mailers/decidim/bih/report_dispatch_mailer.rb; " \
                      "engine:app/services/decidim/bih/sistem48/forwarder.rb; " \
                      "engine:app/jobs/decidim/bih/report_case_forward_job.rb; " \
                      "engine:app/mailers/decidim/bih/sistem48/report_mailer.rb",
            recipient_kinds: %w(external_institution),
            preference_adapter: "external_recipient_config",
            channel_groups: [email_group(preference_adapter: "external_recipient_config", content_variant: "forwarded_report")],
            priority: "transactional",
            expires_in: nil,
            payload_class: "case_private",
            deduplication_owner: "producer",
            enrollment: "legacy_unmigrated",
            notes: "Automatic forwarding is disabled on this host; an operator confirms a reviewed preview whose digest must still match."
          ),
          define(
            key: "report.stale_digest_email",
            purpose: "operator_report",
            producer: "engine:lib/tasks/decidim_bih_reports.rake; engine:app/mailers/decidim/bih/reports/stale_digest_mailer.rb",
            recipient_kinds: %w(operator_mailbox),
            preference_adapter: "operator_recipient_config",
            channel_groups: [email_group(preference_adapter: "operator_recipient_config", content_variant: "operator_digest")],
            priority: "routine",
            expires_in: nil,
            payload_class: "operational",
            deduplication_owner: "none",
            enrollment: "legacy_unmigrated",
            notes: "Skips an empty attention queue or a missing recipient. Repeated manual invocation can send again."
          ),

          # ---- neighbourhood, broadcast and city alerts -----------------------
          define(
            key: "komsiluk.urgent_post",
            purpose: "optional_news",
            producer: "engine:app/services/decidim/bih/komsiluk_post_notification_service.rb; " \
                      "engine:app/jobs/decidim/bih/komsiluk_post_notification_job.rb; " \
                      "engine:app/services/decidim/bih/komsiluk/urgent_notification_policy.rb",
            recipient_kinds: %w(account),
            preference_adapter: "legacy_urgent_bell",
            channel_groups: [bell_group(preference_adapter: "legacy_urgent_bell", content_variant: "urgent_post"), push_group],
            priority: "routine",
            expires_in: nil,
            payload_class: "public_notice",
            deduplication_owner: "core_event",
            enrollment: "legacy_unmigrated",
            notes: "Opt-OUT reader: missing key falls back to the legacy komsiluk_board value and then to true. Same area, author excluded; default categories lost_pet/safety."
          ),
          define(
            key: "komsiluk.area_broadcast",
            purpose: "optional_news",
            producer: "engine:app/services/decidim/bih/komsiluk_broadcast.rb; " \
                      "engine:app/jobs/decidim/bih/broadcast_notification_job.rb; " \
                      "engine:app/controllers/decidim/bih/admin/broadcasts_controller.rb",
            recipient_kinds: %w(account),
            preference_adapter: "neighborhood_info_topic",
            channel_groups: [
              bell_group(preference_adapter: "core_notification_types", content_variant: "broadcast",
                         notes: "always delivered; the local urgent-board opt-out is deliberately NOT applied here"),
              push_group,
              account_external_copy(preference_adapter: "neighborhood_info_topic", content_variant: "broadcast",
                                    notes: "no SMS; the Viber leg additionally needs provider health ok and a current viber_launch approval")
            ],
            priority: "routine",
            expires_in: 86_400,
            payload_class: "public_notice",
            deduplication_owner: "ledger",
            enrollment: "shadow",
            notes: "Only the external copy is enrolled. The preview digest compares an audience COUNT, not a frozen recipient list."
          ),
          define(
            key: "city.service_alert_viber",
            purpose: "optional_news",
            producer: "host:app/jobs/decidim_app/bijeljina/city_service_alert_notification_job.rb; " \
                      "host:app/services/decidim_app/bijeljina/city_service_event_publisher.rb",
            recipient_kinds: %w(account),
            preference_adapter: "city_service_alerts_topic",
            channel_groups: [account_external_copy(preference_adapter: "city_service_alerts_topic", channels: TOPIC_CHANNELS,
                                                   content_variant: "city_alert")],
            priority: "routine",
            expires_in: 86_400,
            payload_class: "public_notice",
            deduplication_owner: "ledger",
            enrollment: "shadow",
            notes: "One provider-managed Viber/WhatsApp phone chain. Requires prior board publication, explicit confirmation, approved WhatsApp template and area/publisher gates; geography is not a preference."
          ),

          # ---- operator communication -----------------------------------------
          define(
            key: "operator.direct_message",
            purpose: "operator_report",
            producer: "engine:app/services/decidim/bih/operator_messenger.rb; " \
                      "engine:app/controllers/decidim/bih/admin/operator_messages_controller.rb",
            recipient_kinds: %w(account),
            preference_adapter: "community_news_topic",
            channel_groups: [
              bell_group(preference_adapter: "core_notification_types", content_variant: "operator_message"),
              push_group,
              account_external_copy(preference_adapter: "community_news_topic", content_variant: "operator_message",
                                    notes: "topic is report_updates when the message is case-bound, community_news otherwise")
            ],
            priority: "transactional",
            expires_in: 86_400,
            payload_class: "case_private",
            deduplication_owner: "ledger",
            enrollment: "shadow",
            notes: "External copy needs a preview and a signed token expiring after 10 minutes. Only the external copy is enrolled."
          ),
          define(
            key: "operator.role_expiry_warning",
            purpose: "operator_report",
            producer: "engine:app/services/decidim/bih/operator_role_expiry_notifier.rb; " \
                      "engine:app/mailers/decidim/bih/operator_role_expiry_mailer.rb",
            recipient_kinds: %w(staff),
            preference_adapter: "none",
            channel_groups: [
              bell_group(preference_adapter: "core_notification_types", content_variant: "role_expiry"),
              email_group(preference_adapter: "none", content_variant: "role_expiry",
                          notes: "direct mailer — no event-frequency check")
            ],
            priority: "routine",
            expires_in: nil,
            payload_class: "operational",
            deduplication_owner: "operator_audit",
            enrollment: "legacy_unmigrated",
            notes: "Separately deduplicated 30-day and 7-day thresholds."
          ),
          define(
            key: "ops.analytics_digest",
            purpose: "operator_report",
            producer: "engine:lib/tasks/decidim_bih_analytics.rake; " \
                      "engine:app/mailers/decidim/bih/admin/analytics_digest_mailer.rb",
            recipient_kinds: %w(operator_mailbox),
            preference_adapter: "operator_recipient_config",
            channel_groups: [email_group(preference_adapter: "operator_recipient_config", content_variant: "operator_digest")],
            priority: "routine",
            expires_in: nil,
            payload_class: "operational",
            deduplication_owner: "none",
            enrollment: "legacy_unmigrated",
            notes: "Per-organization analytics.operator_email, or a global address only when explicitly enabled. No recipient configured = skip."
          ),
          define(
            key: "ops.engine_health_alert",
            purpose: "operator_report",
            producer: "engine:lib/tasks/decidim_bih_operations.rake; " \
                      "engine:app/mailers/decidim/bih/admin/ops_health_alert_mailer.rb",
            recipient_kinds: %w(operator_mailbox),
            preference_adapter: "operator_recipient_config",
            channel_groups: [email_group(preference_adapter: "operator_recipient_config", content_variant: "health_alert")],
            priority: "routine",
            expires_in: nil,
            payload_class: "operational",
            deduplication_owner: "producer",
            enrollment: "legacy_unmigrated",
            notes: "Caps input at 50 rows; an identical row-set digest is cached 6 hours after a send. Distinct from the Rails-free host notifier."
          ),
          define(
            key: "ops.host_standalone_alert",
            purpose: "operator_report",
            producer: "host:script/lib/mi_ops_notify.rb; host:script/lib/mi_health_notifications.rb; host:bin/ops-health-alert.sh",
            recipient_kinds: %w(operator_mailbox),
            preference_adapter: "operator_recipient_config",
            channel_groups: [email_group(preference_adapter: "operator_recipient_config", content_variant: "health_alert")],
            priority: "routine",
            expires_in: nil,
            payload_class: "operational",
            deduplication_owner: "producer",
            enrollment: "legacy_unmigrated",
            notes: "Runs WITHOUT Rails so it still works during an outage. It must keep that property; do not consolidate it into a Rails-only sender."
          ),

          # ---- community programmes -------------------------------------------
          define(
            key: "volunteer.decision",
            purpose: "core_event",
            producer: "engine:app/services/decidim/bih/volunteer_notifications.rb; " \
                      "engine:app/controllers/decidim/bih/volunteer_controller.rb",
            recipient_kinds: %w(account),
            preference_adapter: "core_notification_types",
            channel_groups: [bell_group(preference_adapter: "core_notification_types"), push_group],
            priority: "routine",
            expires_in: nil,
            payload_class: "operational",
            deduplication_owner: "core_event",
            enrollment: "legacy_unmigrated",
            notes: "Opportunity approval/rejection, hour-log verification/rejection, attendance confirmation and waitlist promotion."
          ),
          define(
            key: "partner.membership_invitation",
            purpose: "core_event",
            producer: "engine:app/services/decidim/bih/partner_membership_notifications.rb",
            recipient_kinds: %w(account),
            preference_adapter: "core_notification_types",
            channel_groups: [bell_group(preference_adapter: "core_notification_types"), push_group],
            priority: "routine",
            expires_in: nil,
            payload_class: "operational",
            deduplication_owner: "core_event",
            enrollment: "legacy_unmigrated"
          ),
          define(
            key: "community.contribution_decision",
            purpose: "core_event",
            producer: "engine:app/services/decidim/bih/community_contribution_notifications.rb; " \
                      "engine:app/services/decidim/bih/approve_partner_project_submission.rb; " \
                      "engine:app/services/decidim/bih/create_contribution_offer.rb; " \
                      "engine:app/services/decidim/bih/manage_contribution_offer.rb",
            recipient_kinds: %w(account),
            preference_adapter: "core_notification_types",
            channel_groups: [bell_group(preference_adapter: "core_notification_types"), push_group],
            priority: "routine",
            expires_in: nil,
            payload_class: "operational",
            deduplication_owner: "core_event",
            enrollment: "legacy_unmigrated",
            notes: "Need review/approval/rejection, project submission decisions and the offer lifecycle."
          ),

          # ---- Decidim core ----------------------------------------------------
          define(
            key: "core.welcome",
            purpose: "core_event",
            producer: "engine:app/overrides/decidim/authorization_referral_override.rb; " \
                      "core:app/events/decidim/welcome_notification_event.rb",
            recipient_kinds: %w(account),
            preference_adapter: "core_notification_types",
            channel_groups: [
              bell_group(preference_adapter: "core_notification_types", content_variant: "welcome"),
              push_group,
              email_group(preference_adapter: "core_email_frequency", content_variant: "welcome",
                          notes: "force_email bypasses FREQUENCY only; notification-type and organization gates still apply")
            ],
            priority: "transactional",
            expires_in: nil,
            payload_class: "account_lifecycle",
            deduplication_owner: "core_event",
            enrollment: "legacy_unmigrated",
            notes: "Published at the first qualifying phone authorization on this phone-first host, not at e-mail confirmation."
          ),
          define(
            key: "core.event_bell",
            purpose: "core_event",
            producer: "core:app/services/decidim/events_manager.rb; core:app/services/decidim/notification_generator.rb",
            recipient_kinds: %w(account staff),
            preference_adapter: "core_notification_types",
            channel_groups: [bell_group(preference_adapter: "core_notification_types")],
            priority: "routine",
            expires_in: nil,
            payload_class: "operational",
            deduplication_owner: "core_event",
            enrollment: "legacy_unmigrated",
            notes: "All installed module event families. force_send bypasses the publication check only, never the recipient's notification_types."
          ),
          define(
            key: "core.event_email",
            purpose: "core_event",
            producer: "core:app/services/decidim/email_notification_generator.rb; core:app/mailers/decidim/notification_mailer.rb",
            recipient_kinds: %w(account staff),
            preference_adapter: "core_email_frequency",
            channel_groups: [email_group(preference_adapter: "core_email_frequency", content_variant: "event_email")],
            priority: "routine",
            expires_in: nil,
            payload_class: "operational",
            deduplication_owner: "core_event",
            enrollment: "legacy_unmigrated",
            notes: "Only email-capable events; real_time frequency unless force_email."
          ),
          define(
            key: "core.digest_email",
            purpose: "core_event",
            producer: "core:lib/tasks/decidim_mailers_tasks.rake; core:app/mailers/decidim/notifications_digest_mailer.rb",
            recipient_kinds: %w(account staff),
            preference_adapter: "core_email_frequency",
            channel_groups: [email_group(preference_adapter: "core_email_frequency", content_variant: "digest")],
            priority: "bulk",
            expires_in: nil,
            payload_class: "operational",
            deduplication_owner: "core_event",
            enrollment: "legacy_unmigrated",
            notes: "No installed cron entry at the audit; manual invocation remains possible. Stored daily/weekly values are not proof anybody chose them."
          ),
          define(
            key: "core.newsletter_email",
            purpose: "optional_news",
            producer: "decidim-admin:app/commands/decidim/admin/deliver_newsletter.rb; " \
                      "decidim-admin:app/queries/decidim/admin/newsletter_recipients.rb; " \
                      "core:app/mailers/decidim/newsletter_mailer.rb",
            recipient_kinds: %w(account),
            preference_adapter: "core_newsletter",
            channel_groups: [email_group(preference_adapter: "core_newsletter", content_variant: "newsletter")],
            priority: "bulk",
            expires_in: nil,
            payload_class: "marketing",
            deduplication_owner: "producer",
            enrollment: "legacy_unmigrated",
            notes: "A null newsletter timestamp is currently INELIGIBLE, not inherited allowance. Core's confirmed scope is not this host's e-mail proof."
          ),
          define(
            key: "core.conversation_email",
            purpose: "conversation",
            producer: "core:app/commands/decidim/messaging/start_conversation.rb; " \
                      "core:app/mailers/decidim/messaging/conversation_mailer.rb",
            recipient_kinds: %w(account),
            preference_adapter: "core_direct_message",
            channel_groups: [email_group(preference_adapter: "core_direct_message", content_variant: "conversation")],
            priority: "transactional",
            expires_in: nil,
            payload_class: "conversational",
            deduplication_owner: "producer",
            enrollment: "legacy_unmigrated",
            notes: "Reply mail additionally requires the first unread message; that restriction is NOT a push policy."
          ),
          define(
            key: "core.conversation_push",
            purpose: "conversation",
            producer: "core:app/commands/decidim/messaging/reply_to_conversation.rb; engine:app/services/decidim/bih/web_push.rb",
            recipient_kinds: %w(account),
            preference_adapter: "device_subscription",
            channel_groups: [push_group(content_variant: "conversation")],
            priority: "transactional",
            expires_in: 3600,
            payload_class: "conversational",
            deduplication_owner: "none",
            enrollment: "legacy_unmigrated",
            notes: "Called independently of the e-mail gating block, so the first-unread rule does not suppress it."
          ),
          define(
            key: "core.devise_transactional",
            purpose: "core_transactional",
            producer: "core:app/mailers/decidim/decidim_devise_mailer.rb; " \
                      "engine:app/overrides/decidim/passwords_email_confirmed_guard_override.rb",
            recipient_kinds: %w(account),
            preference_adapter: "core_transactional",
            channel_groups: [email_group(preference_adapter: "core_transactional", content_variant: "devise")],
            priority: "authentication",
            expires_in: nil,
            payload_class: "authentication_secret",
            deduplication_owner: "none",
            enrollment: "legacy_unmigrated",
            notes: "Confirmation, password reset, unlock, e-mail change and administrative invitations. Reset is refused for an unproven address while phone-first is on."
          ),
          define(
            key: "core.account_lifecycle",
            purpose: "core_transactional",
            producer: "core:app/mailers/decidim/block_user_mailer.rb; core:app/mailers/decidim/delete_user_mailer.rb; " \
                      "core:app/mailers/decidim/user_update_mailer.rb; core:app/mailers/decidim/participants_account_mailer.rb",
            recipient_kinds: %w(account),
            preference_adapter: "core_transactional",
            channel_groups: [email_group(preference_adapter: "core_transactional", content_variant: "account_lifecycle")],
            priority: "transactional",
            expires_in: nil,
            payload_class: "account_lifecycle",
            deduplication_owner: "none",
            enrollment: "legacy_unmigrated",
            notes: "Blocked/deleted/updated plus the inactivity warning and removal workflow, which is a lifecycle action and not ordinary digest mail."
          ),
          define(
            key: "core.moderation_email",
            purpose: "core_transactional",
            producer: "core:app/mailers/decidim/reported_mailer.rb; core:app/mailers/decidim/user_report_mailer.rb",
            recipient_kinds: %w(staff),
            preference_adapter: "core_moderation_email",
            channel_groups: [email_group(preference_adapter: "core_moderation_email", content_variant: "moderation")],
            priority: "transactional",
            expires_in: nil,
            payload_class: "operational",
            deduplication_owner: "none",
            enrollment: "legacy_unmigrated"
          ),
          define(
            key: "core.export_email",
            purpose: "core_transactional",
            producer: "core:app/mailers/decidim/export_mailer.rb; core:app/jobs/decidim/download_your_data_export_job.rb",
            recipient_kinds: %w(account staff),
            preference_adapter: "core_transactional",
            channel_groups: [email_group(preference_adapter: "core_transactional", content_variant: "export")],
            priority: "transactional",
            expires_in: nil,
            payload_class: "operational",
            deduplication_owner: "none",
            enrollment: "legacy_unmigrated"
          ),
          define(
            key: "push.bell_fanout",
            purpose: "core_event",
            producer: "core:app/jobs/decidim/notification_generator_for_recipient_job.rb; " \
                      "engine:app/overrides/decidim/web_push_override.rb; " \
                      "engine:app/jobs/decidim/bih/web_push_delivery_job.rb",
            recipient_kinds: %w(account staff),
            preference_adapter: "device_subscription",
            channel_groups: [push_group],
            priority: "routine",
            expires_in: 3600,
            payload_class: "operational",
            deduplication_owner: "none",
            enrollment: "legacy_unmigrated",
            notes: "One job per subscribed browser. A failed endpoint must not resend the others; expired subscriptions are removed, temporary failures retry up to five times."
          ),

          # ---- reactive chat and channel administration -------------------------
          define(
            key: "chat.web_reply",
            purpose: "reactive_chat",
            producer: "host:app/services/decidim_app/bijeljina/web_concierge.rb; " \
                      "engine:app/controllers/decidim/bih/concierge/web_chat_controller.rb",
            recipient_kinds: %w(provider_inbound_identity account),
            preference_adapter: "channel_session",
            channel_groups: [group(name: "web_reply", channels: %w(web_chat), mode: "single",
                                   content_variant: "assistant_reply", preference_adapter: "channel_session")],
            priority: "transactional",
            expires_in: 1800,
            payload_class: "conversational",
            deduplication_owner: "none",
            enrollment: "legacy_unmigrated",
            notes: "A reply to a request the visitor made. Not a subscription and not a marketing audience."
          ),
          define(
            key: "chat.external_reply",
            purpose: "reactive_chat",
            producer: "host:app/jobs/decidim_app/infobip/process_inbound_delivery_job.rb; " \
                      "host:app/services/decidim_app/bijeljina/external_chat_concierge.rb; " \
                      "engine:app/jobs/decidim/bih/infobip/send_chat_text_job.rb",
            recipient_kinds: %w(provider_inbound_identity),
            preference_adapter: "channel_session",
            channel_groups: [group(name: "same_channel_reply", channels: %w(viber whatsapp messenger instagram),
                                   mode: "single", content_variant: "assistant_reply",
                                   preference_adapter: "channel_session",
                                   notes: "always the SAME channel the message arrived on; never a fallback to another channel")],
            priority: "transactional",
            expires_in: 82_800,
            payload_class: "conversational",
            deduplication_owner: "provider",
            enrollment: "legacy_unmigrated",
            notes: "Deadline is trusted inbound occurred_at + 23 h, clamped by the reply deadline. A blank voice/sticker/reaction event gets no paid generic reply."
          ),
          define(
            key: "channel.connection_challenge",
            purpose: "account_lifecycle",
            producer: "engine:app/services/decidim/bih/channel_connections.rb",
            recipient_kinds: %w(provider_inbound_identity),
            preference_adapter: "channel_session",
            channel_groups: [group(name: "same_channel_reply", channels: %w(whatsapp messenger instagram), mode: "single",
                                   content_variant: "connection_challenge", preference_adapter: "channel_session")],
            priority: "transactional",
            expires_in: 600,
            payload_class: "authentication_secret",
            deduplication_owner: "producer",
            enrollment: "legacy_unmigrated",
            notes: "Two-way POVEZI challenge, 10-minute expiry, five failed confirmations. Linking sets no topic key."
          ),
          define(
            key: "channel.opt_out_reply",
            purpose: "reactive_chat",
            producer: "host:app/services/decidim_app/bijeljina/channel_notification_opt_out.rb; " \
                      "engine:app/services/decidim/bih/notification_preferences.rb",
            recipient_kinds: %w(provider_inbound_identity),
            preference_adapter: "channel_session",
            channel_groups: [group(name: "same_channel_reply", channels: %w(viber whatsapp messenger instagram), mode: "single",
                                   content_variant: "opt_out_acknowledgement", preference_adapter: "channel_session")],
            priority: "transactional",
            expires_in: 82_800,
            payload_class: "conversational",
            deduplication_owner: "none",
            enrollment: "legacy_unmigrated",
            notes: "STOP/ODJAVA writes provider_opt_out for all three topics on THAT channel. It is transport suppression evidence, " \
                   "not a citizen topic choice, and it never disconnects a channel or disables authentication."
          ),
          define(
            key: "postal.verification_letter",
            purpose: "account_lifecycle",
            producer: "engine:app/overrides/decidim/postal_postages_controller_override.rb; " \
                      "engine:app/services/decidim/bih/postal/postal_token_service.rb",
            recipient_kinds: %w(account),
            preference_adapter: "none",
            channel_groups: [group(name: "postal", channels: %w(postal), mode: "single", content_variant: "postal_letter",
                                   preference_adapter: "none")],
            priority: "routine",
            expires_in: 2_592_000,
            payload_class: "authentication_secret",
            deduplication_owner: "producer",
            enrollment: "legacy_unmigrated",
            notes: "Printing or marking a letter is not proof of posting or receipt; MI observes no postal delivery outcome."
          )
        ].freeze

        # NOT ActiveSupport's index_by: this file is loaded by the pure
        # minitest suite, which boots no Rails and has no core extensions.
        # rubocop:disable Rails/IndexBy
        ALL = REGISTRY.to_h { |entry| [entry.key, entry] }.freeze
        # rubocop:enable Rails/IndexBy

        def self.all
          ALL
        end

        def self.known?(key)
          ALL.has_key?(key.to_s)
        end

        def self.find(key)
          ALL[key.to_s]
        end

        def self.fetch(key)
          ALL.fetch(key.to_s) { raise UnknownMessageClass, "unknown message class: #{key}" }
        end

        def self.enrolled
          ALL.select { |_key, entry| entry.enrolled? }
        end

        def self.legacy_unmigrated
          ALL.reject { |_key, entry| entry.enrolled? }
        end

        # Which class owns a producer's own message key (the campaign's P1..P11).
        # The keys are NOT contiguous — P2 and P6 were deleted with the 72-hour
        # sweep they served — and they do not all live in one class, so a caller
        # must look the owner up rather than derive it from the number.
        def self.for_message_key(message_key)
          return nil if message_key.nil?

          wanted = message_key.to_s.upcase
          ALL.each_value.find { |entry| entry.message_keys.include?(wanted) }
        end

        def self.supports_channel?(key, channel)
          entry = find(key)
          return false unless entry

          !entry.group_for(channel).nil?
        end

        # The single safe-before-send entry point: an unknown class or an
        # unsupported class/channel combination raises here, before anything can
        # claim a token, bill a segment or write a ledger row.
        def self.resolve!(key, channel:)
          entry = fetch(key)
          entry.group_for(channel) ||
            raise(UnsupportedChannel, "message class #{entry.key} does not support channel #{channel}")
        end

        def self.topic_channel!(channel)
          channel = channel.to_s
          return channel if TOPIC_CHANNELS.include?(channel)

          raise UnsupportedChannel, "#{channel} is not one of the four MI topic channels; it has its own contract"
        end
      end
    end
  end
end
