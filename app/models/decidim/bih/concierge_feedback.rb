# frozen_string_literal: true

module Decidim
  module Bih
    # Rating for one web concierge answer, or the citizen's consent to keep an
    # unanswered question.
    #
    # Privacy contract: raw citizen messages and reply text are stored only after
    # the citizen clicks helpful/not helpful, or "keep this question so the bot
    # can learn" (+share_question+) on a turn the bot could not resolve — the
    # same signed token, the same transcript boundary. Rows stay anonymous: no
    # account identity, contact details, IP addresses or user-agent strings.
    # The session value is a digest used only to keep one browser session from
    # voting repeatedly on the same reply token; a later click on the same
    # reply updates the row rather than adding one.
    class ConciergeFeedback < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_concierge_feedbacks"

      VALUES = %w(helpful not_helpful share_question).freeze
      REPLY_ID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"
      belongs_to :user,
                 class_name: "Decidim::User",
                 foreign_key: "decidim_user_id",
                 optional: true

      validates :reply_id, presence: true, format: { with: REPLY_ID_FORMAT }
      validates :session_digest, presence: true, length: { maximum: 128 }
      validates :value, inclusion: { in: VALUES }
      validates :locale, length: { maximum: 16 }, allow_blank: true

      scope :recent, -> { order(created_at: :desc, id: :desc) }
    end
  end
end
