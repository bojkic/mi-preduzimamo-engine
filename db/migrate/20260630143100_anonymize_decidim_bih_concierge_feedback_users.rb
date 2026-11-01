# frozen_string_literal: true

# Feedback review rows should not be tied back to a Decidim account. Keep the
# nullable column for compatibility, but clear historical values.
class AnonymizeDecidimBihConciergeFeedbackUsers < ActiveRecord::Migration[7.2]
  def up
    update "UPDATE decidim_bih_concierge_feedbacks SET decidim_user_id = NULL WHERE decidim_user_id IS NOT NULL"
  end

  def down
    # Intentionally irreversible: old account links were removed for privacy.
  end
end
