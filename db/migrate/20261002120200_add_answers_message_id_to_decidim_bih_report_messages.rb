# frozen_string_literal: true

class AddAnswersMessageIdToDecidimBihReportMessages < ActiveRecord::Migration[7.2]
  def change
    add_reference :decidim_bih_report_messages, :answers_message, foreign_key: { to_table: :decidim_bih_report_messages }
  end
end
