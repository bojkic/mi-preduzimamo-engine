# frozen_string_literal: true

# Stores the exact prompt and answer only after a citizen clicks helpful/not
# helpful. The row remains anonymous: user, IP and user-agent are not attached.
class AddReviewTranscriptToDecidimBihConciergeFeedbacks < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_concierge_feedbacks, :citizen_message, :text
    add_column :decidim_bih_concierge_feedbacks, :bot_reply_text, :text
  end
end
