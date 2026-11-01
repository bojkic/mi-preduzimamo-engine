# frozen_string_literal: true

require "active_support/core_ext/enumerable"

module Decidim
  module Bih
    module Komsiluk
      # Per-organization policy for automatic Komšiluk board bell fan-out.
      #
      # Missing settings preserve the historical behavior: lost_pet and safety
      # posts notify the author's Komšiluk; activity/general do not. Operators
      # may disable one or all urgent categories or mute selected Komšiluci
      # without changing expiry or moderation semantics.
      #
      # NOT ENROLLED, and the asymmetry below is deliberate. The registry entry
      # `komsiluk.urgent_post` is `legacy_unmigrated`
      # (engine:app/services/decidim/bih/messaging/message_class.rb), so no
      # runtime flag can move this fan-out off its legacy body; only the
      # operator broadcast's external copy (`komsiluk.area_broadcast`) is
      # enrolled. That matters because the two audiences are resolved by the
      # SAME `Komsiluk::MembershipResolver` with opposite arguments:
      #
      #   urgent post  (komsiluk_post_notification_service.rb:86)  honor_opt_out: true
      #   operator broadcast (komsiluk_broadcast.rb:105)           honor_opt_out: false
      #
      # An automatic board fan-out honours the per-user board opt-out; a
      # deliberate org-level broadcast from an operator does not. Unifying them
      # would change who receives an operator broadcast, so it is an intended
      # change with its own manifest row — row T5 in
      # host:docs/superpowers/sdd/2026-09-14-comms/phase-2-intended-changes.md
      # — and not a cleanup. `test/services/decidim/bih/komsiluk_broadcast_test.rb`
      # and `komsiluk_post_notification_service_test.rb` hold both arguments in
      # place.
      class UrgentNotificationPolicy
        NAMESPACE = "komsiluk_urgent_notifications"
        CATEGORIES_KEY = "categories"
        MUTED_KOMSILUK_IDS_KEY = "muted_komsiluk_ids"
        EMPTY_MARKER = "__none__"
        DEFAULT_CATEGORIES = %w(lost_pet safety).freeze
        ALLOWED_CATEGORIES = DEFAULT_CATEGORIES

        def self.categories_for(organization)
          new(organization).categories
        end

        def self.muted_komsiluk_ids_for(organization)
          new(organization).muted_komsiluk_ids
        end

        def self.notify?(post)
          new(post.organization).notify?(post)
        end

        def initialize(organization)
          @organization = organization
        end

        def categories
          stored_settings = settings
          return DEFAULT_CATEGORIES unless stored_settings.has_key?(CATEGORIES_KEY)

          stored = stored_settings[CATEGORIES_KEY]
          values = Array(stored).map(&:to_s)

          values & ALLOWED_CATEGORIES
        end

        def notify_category?(category)
          categories.include?(category.to_s)
        end

        def muted_komsiluk_ids
          Array(settings[MUTED_KOMSILUK_IDS_KEY])
            .map(&:to_s)
            .reject { |value| value.blank? || value == EMPTY_MARKER }
            .uniq
        end

        def notify_komsiluk?(komsiluk_id)
          muted_komsiluk_ids.exclude?(komsiluk_id.to_s)
        end

        def notify?(post)
          notify_category?(post.category) && notify_komsiluk?(post.komsiluk_id)
        end

        def save_categories(raw_categories)
          selected = Array(raw_categories).map(&:to_s) & ALLOWED_CATEGORIES
          stored = selected.presence || [EMPTY_MARKER]
          Decidim::Bih::Setting.put(@organization, NAMESPACE, CATEGORIES_KEY, stored)
        end

        def save_muted_komsiluk_ids(raw_ids, allowed_ids:)
          allowed = Array(allowed_ids).map(&:to_s)
          selected = Array(raw_ids).map(&:to_s).compact_blank & allowed

          Decidim::Bih::Setting.put(
            @organization,
            NAMESPACE,
            MUTED_KOMSILUK_IDS_KEY,
            selected.presence
          )
        end

        private

        def settings
          Decidim::Bih::Setting.namespace_for(@organization, NAMESPACE)
        end
      end
    end
  end
end
