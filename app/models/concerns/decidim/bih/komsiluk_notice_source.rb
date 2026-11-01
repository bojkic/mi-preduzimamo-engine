# frozen_string_literal: true

module Decidim
  module Bih
    # Optional host adapter. Accumulate changes across all saves in a
    # transaction; a later private-note save must not hide an earlier withdrawal.
    module KomsilukNoticeSource
      extend ActiveSupport::Concern

      included do
        class_attribute :komsiluk_notice_source_refresher, instance_writer: false, default: nil
        after_save :remember_komsiluk_notice_source_changes
        after_commit :refresh_komsiluk_notice_source_projection
        after_rollback :clear_komsiluk_notice_source_changes
      end

      private

      def remember_komsiluk_notice_source_changes
        return unless komsiluk_notice_source_refresher

        @komsiluk_notice_source_changes ||= {}
        saved_changes.slice(*komsiluk_notice_source_refresher.tracked_fields_for(self)).each do |key, values|
          original = @komsiluk_notice_source_changes.fetch(key, values).first
          @komsiluk_notice_source_changes[key] = [original, values.last]
        end
      end

      def refresh_komsiluk_notice_source_projection
        komsiluk_notice_source_refresher&.call(self, changes: @komsiluk_notice_source_changes || {})
      ensure
        clear_komsiluk_notice_source_changes
      end

      def clear_komsiluk_notice_source_changes
        @komsiluk_notice_source_changes = nil
      end
    end
  end
end
