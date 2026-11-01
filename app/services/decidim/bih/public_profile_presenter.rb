# frozen_string_literal: true

module Decidim
  module Bih
    # Public, privacy-scoped MI profile facts for Decidim profiles.
    # Exposes only public recognition data; never contact data, wallet balance,
    # addresses, report tokens, Viber identifiers, MZ/source metadata or rewards.
    class PublicProfilePresenter
      attr_reader :user, :viewer

      def initialize(user:, viewer: nil)
        @user = user
        @viewer = Decidim::Bih.organization_scoped_user(viewer, user.organization)
      end

      def own_profile?
        viewer == user
      end

      def public_recognition_enabled?
        Decidim::Bih::PublicRecognition.enabled_for?(user)
      end

      def recognition_visible?
        own_profile? || public_recognition_enabled?
      end

      def contribution_score
        goodwill_account&.contribution_score.to_i
      end

      def goodwill_level
        Decidim::Bih::Goodwill::Levels.for(contribution_score)
      end

      def operator?
        Decidim::Bih::OperatorAuthorization.operator?(user, organization: user.organization)
      end

      def verified?
        user.respond_to?(:confirmed?) && user.confirmed? &&
          Decidim::Authorization.where(user:).where.not(granted_at: nil).exists?
      end

      def postal_verified?
        Decidim::Authorization.where(user:, name: "postal_letter").where.not(granted_at: nil).exists?
      end

      def reporter?
        Decidim::Bih::Report.exists?(organization: user.organization, author: user, anonymous: false)
      end

      def volunteer?
        Decidim::Bih::VolunteerLog.approved.exists?(organization: user.organization, user:)
      end

      def komsiluk_name
        citizen_profile&.komsiluk&.translated_name
      end

      def account_url
        Decidim::Bih.public_path("moj-nalog")
      end

      def wallet_url
        Decidim::Bih.public_path("moj-doprinos")
      end

      def leaderboard_url
        Decidim::Bih.public_path("zajednistvo?tab=tabla")
      end

      def summary_items
        [
          {
            key: :level,
            icon: "vip-crown-line",
            label: I18n.t("decidim.bih.public_profile.summary.level"),
            value: recognition_value(goodwill_level.title),
            url: recognition_visible? ? leaderboard_url : nil
          },
          {
            key: :score,
            icon: "award-line",
            label: I18n.t("decidim.bih.public_profile.summary.score"),
            value: recognition_value(contribution_score),
            url: recognition_visible? ? leaderboard_url : nil
          },
          {
            key: :verification,
            icon: "checkbox-circle-line",
            label: I18n.t("decidim.bih.public_profile.summary.verification"),
            value: recognition_value(verification_summary)
          },
          {
            key: :activity,
            icon: "hand-heart-line",
            label: I18n.t("decidim.bih.public_profile.summary.activity"),
            value: recognition_value(activity_summary)
          }
        ]
      end

      def badge_items
        return [] unless recognition_visible?

        [].tap do |items|
          items << badge(:verified, "checkbox-circle-line", "verified") if verified?
          items << badge(:postal_verified, "mail-send-line", "postal_verified") if postal_verified?
          items << badge(:volunteer, "hand-heart-line", "volunteer") if volunteer?
          items << badge(:reporter, "map-pin-line", "reporter") if reporter?
          items << badge(:operator, "shield-user-line", "operator") if operator?
          items << komsiluk_badge if komsiluk_name.present?
          items << level_badge if contribution_score.positive?
        end
      end

      private

      def goodwill_account
        @goodwill_account ||= Decidim::Bih::Goodwill::Account.find_by(
          organization: user.organization,
          owner_type: user.class.base_class.name,
          owner_id: user.id
        )
      end

      def citizen_profile
        @citizen_profile ||= Decidim::Bih::CitizenProfile.includes(:komsiluk).find_by(
          decidim_organization_id: user.organization.id,
          decidim_user_id: user.id
        )
      end

      def recognition_value(value)
        return value if recognition_visible?

        I18n.t("decidim.bih.public_profile.hidden_value")
      end

      def verification_summary
        return I18n.t("decidim.bih.public_profile.summary.postal_verified") if postal_verified?
        return I18n.t("decidim.bih.public_profile.summary.verified") if verified?

        I18n.t("decidim.bih.public_profile.summary.not_verified")
      end

      def activity_summary
        keys = []
        keys << I18n.t("decidim.bih.public_profile.summary.reporter_short") if reporter?
        keys << I18n.t("decidim.bih.public_profile.summary.volunteer_short") if volunteer?
        return keys.join(" / ") if keys.any?

        I18n.t("decidim.bih.public_profile.summary.no_activity")
      end

      def badge(key, icon, i18n_key)
        {
          key:,
          icon:,
          title: I18n.t("decidim.bih.public_profile.badges.#{i18n_key}.title"),
          text: I18n.t("decidim.bih.public_profile.badges.#{i18n_key}.text")
        }
      end

      def komsiluk_badge
        {
          key: :komsiluk,
          icon: "home-heart-line",
          title: I18n.t("decidim.bih.public_profile.badges.komsiluk.title"),
          text: I18n.t("decidim.bih.public_profile.badges.komsiluk.text", name: komsiluk_name)
        }
      end

      def level_badge
        {
          key: :level,
          icon: "vip-crown-line",
          title: I18n.t("decidim.bih.public_profile.badges.level.title"),
          text: I18n.t(
            "decidim.bih.public_profile.badges.level.text",
            level: goodwill_level.title,
            score: contribution_score
          ),
          url: leaderboard_url
        }
      end
    end
  end
end
