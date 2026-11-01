# frozen_string_literal: true

module Decidim
  module Bih
    class UpdateCommunicationSettings < Decidim::Command
      def initialize(form, user)
        @form = form
        @user = user
      end

      def call
        return broadcast(:invalid) unless @form.valid?

        ActiveRecord::Base.transaction do
          @user.with_lock do
            @form.submitted_rows.each do |topic|
              TopicPreferences.set!(@user, topic:, enabled: @form.public_send(topic), source: "account")
            end
          end
        end
        broadcast(:ok, @user)
      rescue ActiveRecord::ActiveRecordError
        broadcast(:invalid)
      end
    end
  end
end
