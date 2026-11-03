# frozen_string_literal: true

module Decidim
  module Bih
    # Read-only private summary for a signed-in citizen's account setup page.
    # It intentionally exposes only aggregate/status data; postal addresses,
    # phone numbers and typed Komšiluk addresses stay out of the UI.
    class AccountSummary
      SetupStep = Struct.new(:key, :title_key, :text_key, :state, :icon, :href_key, keyword_init: true) do
        def done?
          state.to_sym == :done
        end

        def pending?
          state.to_sym == :pending
        end
      end
      ActivityItem = Struct.new(:title, :meta, :status, :href, :cancel_path, :certificate_path, keyword_init: true)

      attr_reader :organization, :user

      def initialize(organization:, user:)
        @organization = organization
        @user = user
      end

      def account
        @account ||= Decidim::Bih::Goodwill::Account.find_by(
          organization:,
          owner_type: user.class.base_class.name,
          owner_id: user.id
        )
      end

      def contribution
        account&.contribution_score.to_i
      end

      def balance
        account&.balance.to_i
      end

      def level
        @level ||= Decidim::Bih::Goodwill::Levels.for(contribution)
      end

      def community_summary
        [
          I18n.t("decidim.bih.account.show.stats.community_summary.balance", count: balance),
          I18n.t("decidim.bih.account.show.stats.community_summary.level", level: level.title)
        ].join(" · ")
      end

      def level_progress_percent
        level.progress_percent
      end

      def points_to_next_level
        level.points_to_next
      end

      def weekly_streak
        @weekly_streak ||= Decidim::Bih::Goodwill::Streaks.weekly_for(account)
      end

      def season_score
        @season_score ||= Decidim::Bih::Goodwill::Streaks.season_score(account, since: season_started_at)
      end

      def season_started?
        season_started_at.present?
      end

      def citizen_profile
        @citizen_profile ||= Decidim::Bih::CitizenProfile.find_by(
          decidim_organization_id: organization.id,
          decidim_user_id: user.id
        )
      end

      def komsiluk_assigned?
        citizen_profile&.assigned? || false
      end

      def komsiluk_name
        return unless komsiluk_assigned?

        citizen_profile.komsiluk&.translated_name
      end

      def email_confirmed?
        EmailConfirmation.confirmed?(user)
      end

      def sms_verified?
        granted_authorization?("sms")
      end

      def postal_verified?
        granted_authorization?("postal_letter")
      end

      # True when the citizen's "sms" authorization is granted AND the phone
      # number that earned it is still on file. A grant can outlive its
      # number (Decidim::Bih::PhoneVerification::Complete's phone write is
      # best-effort and can fail independently of the grant — see its
      # comment), which is exactly the gap #phone_step's :reverify state
      # exists to surface. Kept as its own overridable predicate (like
      # #sms_verified? / #postal_verified?) so callers needing a real
      # Decidim::User never touch this in tests that stub a bare user object.
      def phone_number_saved?
        Decidim::Bih::VerifiedPhone.consistent?(user:, organization: user.organization)
      end

      def postal_pending?
        authorization("postal_letter")&.granted_at.nil? && authorization("postal_letter").present?
      end

      def postal_status
        auth = authorization("postal_letter")
        return :confirmed if auth&.granted_at.present?
        return :not_requested if auth.blank?
        return :expired if auth.created_at < 6.months.ago
        return :sent if auth.verification_metadata["verification_code"].present?

        :requested
      end

      def postal_status_date
        auth = authorization("postal_letter")
        return auth&.granted_at&.to_date if postal_status == :confirmed

        sent_at = auth&.verification_metadata&.[]("letter_sent_at")
        return Time.zone.parse(sent_at).to_date if sent_at.present?

        auth&.created_at&.to_date
      rescue ArgumentError, TypeError
        auth&.updated_at&.to_date
      end

      def postal_request_path
        Decidim::Verifications::Adapter.from_element("postal_letter").root_path
      end

      def postal_confirm_path
        Decidim::Verifications::Adapter.from_element("postal_letter").resume_authorization_path
      end

      def any_verification?
        authorizations.where.not(granted_at: nil).exists?
      end

      def account_verification_complete?
        sms_verified? || postal_verified?
      end

      def report_count
        @report_count ||= Decidim::Bih::Report.where(organization:, author: user).count
      end

      def open_report_count
        @open_report_count ||=
          Decidim::Bih::Report
          .where(organization:, author: user)
          .where.not(status: Decidim::Bih::Report::TERMINAL_STATUSES)
          .count
      end

      def active_volunteer_signup_count
        @active_volunteer_signup_count ||=
          Decidim::Bih::VolunteerSignup.active_rsvp.where(organization:, user:).count
      end

      def pending_volunteer_log_count
        @pending_volunteer_log_count ||= Decidim::Bih::VolunteerLog.pending.where(organization:, user:).count
      end

      def available_volunteer_opportunity_count
        @available_volunteer_opportunity_count ||=
          Decidim::Bih::VolunteerOpportunity
          .active
          .upcoming
          .where(organization:)
          .where.not(id: active_volunteer_opportunity_ids)
          .count
      end

      def followed_thread_count
        @followed_thread_count ||= Decidim::Follow.user_collection(user).count
      end

      def authored_reply_count
        @authored_reply_count ||=
          comments_scope
          .where("depth > 0")
          .select { |comment| comment.organization == organization }
          .count
      end

      def approved_volunteer_hours
        @approved_volunteer_hours ||= Decidim::Bih::VolunteerLog.approved.where(organization:, user:).sum(:hours).to_i
      end

      def viber_linked?
        @viber_linked ||= Decidim::Bih::Viber::Linkage.exists?(organization:, user:)
      end

      def partner_memberships
        @partner_memberships ||= Decidim::Bih::PartnerMembership
                                 .for_user(user, organization:)
                                 .joins(:partner_profile)
                                 .includes(:partner_profile)
                                 .order("decidim_bih_partner_profiles.display_name")
                                 .to_a
      end

      def partner_membership_count
        partner_memberships.length
      end

      def verified_partner_memberships
        partner_memberships.select { |membership| membership.partner_profile&.verified? }
      end

      def latest_report_items(limit: 3)
        @latest_report_items ||= Decidim::Bih::Report
                                 .where(organization:, author: user)
                                 .order(created_at: :desc, id: :desc)
                                 .limit(limit)
                                 .map do |report|
          ActivityItem.new(
            title: report.reference,
            meta: Decidim::Bih::ReportStatusPresenter.label(report),
            status: Decidim::Bih::ReportStatusPresenter.public_status(report),
            href: report.tokenized_status_path
          )
        end
      end

      def recent_reward_items(limit: 3)
        @recent_reward_items ||= Decidim::Bih::Goodwill::RewardFulfillment
                                 .where(organization:, user:)
                                 .recent
                                 .limit(limit)
                                 .map do |fulfillment|
          ActivityItem.new(
            title: reward_name(fulfillment.reward_key),
            meta: fulfillment.created_at&.to_date&.to_s,
            status: fulfillment.status,
            href: Decidim::Bih.public_path("zajednistvo?tab=nagrade"),
            certificate_path: fulfillment.certificate_available? ? Decidim::Bih.public_path("nagrade/zahtjevi/#{fulfillment.id}/zahvalnica") : nil,
            cancel_path: fulfillment.citizen_cancelable? ? Decidim::Bih.public_path("nagrade/zahtjevi/#{fulfillment.id}/otkazi") : nil
          )
        end
      end

      def active_volunteer_items(limit: 3)
        @active_volunteer_items ||= Decidim::Bih::VolunteerSignup
                                    .active_rsvp
                                    .where(organization:, user:)
                                    .includes(:opportunity)
                                    .order(created_at: :desc, id: :desc)
                                    .limit(limit)
                                    .map do |signup|
          ActivityItem.new(
            title: signup.opportunity&.title.to_s,
            meta: volunteer_time(signup.opportunity),
            status: signup.status,
            href: Decidim::Bih.public_path("volontiranje")
          )
        end
      end

      def setup_steps
        [
          email_step,
          komsiluk_step,
          phone_step,
          postal_step,
          notifications_step,
          first_action_step,
          invite_step
        ].compact
      end

      def completed_required_steps
        required_steps.count(&:done?)
      end

      def required_steps_count
        required_steps.length
      end

      def completion_percent
        return 0 if required_steps_count.zero?

        ((completed_required_steps.to_f / required_steps_count) * 100).round
      end

      def public_profile_ready?
        user.nickname.present?
      end

      def public_recognition_enabled?
        Decidim::Bih::PublicRecognition.enabled_for?(user)
      end

      private

      def season_started_at
        @season_started_at ||= Decidim::Bih::Goodwill::EarningRules.season_started_at(organization)
      end

      def active_volunteer_opportunity_ids
        Decidim::Bih::VolunteerSignup.active_rsvp
                                     .where(organization:, user:)
                                     .select(:decidim_bih_volunteer_opportunity_id)
      end

      def authorizations
        @authorizations ||= Decidim::Authorization.where(user:)
      end

      def authorization(name)
        @authorization_by_name ||= {}
        @authorization_by_name[name] ||= authorizations.where(name:).order(created_at: :desc).first
      end

      def granted_authorization?(name)
        authorization(name)&.granted_at.present?
      end

      def required_steps
        steps = setup_steps.reject { |step| [:notifications, :phone, :postal, :invite].include?(step.key) }
        steps << SetupStep.new(
          key: :verification,
          state: account_verification_complete? ? :done : :todo
        )
        steps
      end

      def reward_name(reward_key)
        Decidim::Bih::Goodwill::RewardsCatalog.find(reward_key, organization)&.name || reward_key.to_s
      rescue StandardError
        reward_key.to_s
      end

      def comments_scope
        return Decidim::Comments::Comment.none unless defined?(Decidim::Comments::Comment)
        return Decidim::Comments::Comment.none unless Decidim::Comments::Comment.table_exists?

        Decidim::Comments::Comment
          .not_hidden
          .not_deleted
          .where(decidim_author_type: "Decidim::UserBaseEntity", decidim_author_id: user.id)
      end

      def volunteer_time(opportunity)
        return if opportunity.blank? || opportunity.starts_at.blank?

        I18n.l(opportunity.starts_at.to_date, format: :decidim_short)
      rescue I18n::MissingTranslationData
        opportunity.starts_at.to_date.to_s
      end

      def email_step
        return if user.respond_to?(:phone_only_registration?) && user.phone_only_registration? && user.email.blank?

        SetupStep.new(
          key: :email,
          title_key: "email.title",
          text_key: email_confirmed? ? "email.done" : "email.todo",
          state: email_confirmed? ? :done : :todo,
          icon: "mail-send-line",
          href_key: :account
        )
      end

      def komsiluk_step
        SetupStep.new(
          key: :komsiluk,
          title_key: "komsiluk.title",
          text_key: komsiluk_assigned? ? "komsiluk.done" : "komsiluk.todo",
          state: komsiluk_assigned? ? :done : :todo,
          icon: "map-pin-line",
          href_key: :komsiluk
        )
      end

      def phone_step
        state = if sms_verified? && !phone_number_saved?
                  :reverify
                elsif sms_verified?
                  :done
                elsif postal_verified?
                  :optional
                else
                  :todo
                end
        SetupStep.new(
          key: :phone,
          title_key: "phone.title",
          text_key: "phone.#{state}",
          state:,
          icon: "shield-check-line",
          href_key: state == :reverify ? :phone_verification : :authorizations
        )
      end

      def postal_step
        state = case postal_status
                when :confirmed
                  :done
                when :requested, :sent
                  :pending
                when :not_requested
                  sms_verified? ? :optional : :todo
                else
                  :todo
                end
        SetupStep.new(
          key: :postal,
          title_key: "postal.title",
          text_key: "postal.#{state}",
          state:,
          icon: "mail-send-line",
          href_key: :postal
        )
      end

      def notifications_step
        SetupStep.new(
          key: :notifications,
          title_key: "notifications.title",
          text_key: "notifications.todo",
          state: :optional,
          icon: "megaphone-line",
          href_key: :notifications
        )
      end

      # Always :optional, never :done. Inviting is not a box that gets ticked —
      # a citizen who invited one neighbour can invite another tomorrow, and the
      # campaign wants the ask standing open. It is excluded from
      # #required_steps for the same reason: marking it required would drop
      # every finished account below 100% the day it shipped.
      def invite_step
        SetupStep.new(
          key: :invite,
          title_key: "invite.title",
          text_key: "invite.todo",
          state: :optional,
          icon: "user-add-line",
          href_key: :invite
        )
      end

      def first_action_step
        active = report_count.positive? || active_volunteer_signup_count.positive? || approved_volunteer_hours.positive?
        SetupStep.new(
          key: :first_action,
          title_key: "first_action.title",
          text_key: active ? "first_action.done" : "first_action.todo",
          state: active ? :done : :todo,
          icon: "checkbox-circle-line",
          href_key: :new_report
        )
      end
    end
  end
end
