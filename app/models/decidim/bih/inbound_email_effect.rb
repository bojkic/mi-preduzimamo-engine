# frozen_string_literal: true

module Decidim
  module Bih
    class InboundEmailEffect < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_inbound_email_effects"
      belongs_to :inbound_email, class_name: "Decidim::Bih::InboundEmail"
      belongs_to :report, class_name: "Decidim::Bih::Report", foreign_key: :decidim_bih_report_id
      def self.once!(inbound_email:, report:, effect:)
        transaction(requires_new: true) do
          create!(inbound_email:, report:, effect:)
          yield
        end
      rescue ActiveRecord::RecordNotUnique
        nil
      end
    end
  end
end
