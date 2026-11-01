# frozen_string_literal: true

# The concierge feedback row also records the citizen's consent to keep an
# unanswered question ("share_question"). The value vocabulary is enforced
# twice — by the model's inclusion validation and by this check constraint —
# so the constraint has to learn the third value too. Instant on a table of
# this size (a few hundred rows); no data changes.
class AllowShareQuestionInConciergeFeedbackValue < ActiveRecord::Migration[7.2]
  OLD_VALUES = "value IN ('helpful', 'not_helpful')"
  NEW_VALUES = "value IN ('helpful', 'not_helpful', 'share_question')"
  NAME = "chk_bih_concierge_feedback_value"

  def up
    remove_check_constraint :decidim_bih_concierge_feedbacks, name: NAME
    add_check_constraint :decidim_bih_concierge_feedbacks, NEW_VALUES, name: NAME
  end

  def down
    execute "DELETE FROM decidim_bih_concierge_feedbacks WHERE value = 'share_question'"
    remove_check_constraint :decidim_bih_concierge_feedbacks, name: NAME
    add_check_constraint :decidim_bih_concierge_feedbacks, OLD_VALUES, name: NAME
  end
end
