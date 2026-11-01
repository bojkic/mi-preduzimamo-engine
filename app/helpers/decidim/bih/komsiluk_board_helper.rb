# frozen_string_literal: true

require "uri"

module Decidim
  module Bih
    module KomsilukBoardHelper
      def board_t(key, **)
        t("decidim.bih.boards.#{key}", **)
      end

      # The host adapter checks current tenant/public visibility and material
      # facts. A missing or failed adapter must never expose a linked draft's
      # reviewed wording as if it were still current.
      def board_public_source_state(post)
        details = post.details.to_h
        source = details["source"]
        linked_staff = post.origin == "staff" && details["source_record"].is_a?(Hash)
        linked_city = post.origin == "city_service" && source.is_a?(Hash) &&
                      (source["revalidation_required"] == true || source["event_type"] == "severe_weather")
        return { updating: false, url: nil } unless linked_staff || linked_city

        @board_public_source_states ||= {}
        @board_public_source_states[post.id] ||= begin
          provider = Decidim::Bih.komsiluk_notice_public_source_provider
          state = provider.call(organization: current_organization, post:) if provider.respond_to?(:call)
          state = state.to_h.symbolize_keys if state.respond_to?(:to_h)
          state ||= {}
          url = board_local_source_href(state[:url])
          invalid_url = state[:url].present? && url.nil?
          { updating: state.fetch(:updating, true) == true || invalid_url, url: invalid_url ? nil : url }
        rescue StandardError => error
          Rails.logger.warn("[KomsilukBoard] public source unavailable: #{error.class}")
          { updating: true, url: nil }
        end
      end

      def board_local_source_href(value)
        path = value.to_s
        return if path.empty? || !path.start_with?("/") || path.start_with?("//")
        return if path.include?("\\") || path.match?(/[\x00-\x20\x7f]/)
        return if path.match?(/%(?:2e|2f|5c|0[0-9a-f]|1[0-9a-f]|7f)/i)

        uri = URI.parse(path)
        return if uri.scheme || uri.host || uri.userinfo || !uri.path.start_with?("/") || uri.path.start_with?("//")
        return if uri.path.split("/").intersect?(%w(. ..))

        path
      rescue URI::InvalidURIError
        nil
      end

      def board_datetime(value)
        return if value.blank?

        time = value.respond_to?(:in_time_zone) ? value : Time.iso8601(value.to_s)
        time.in_time_zone("Europe/Sarajevo").strftime("%d.%m.%Y. %H:%M")
      rescue ArgumentError
        nil
      end

      def board_input_date(value)
        return if value.blank?

        value.in_time_zone("Europe/Sarajevo").strftime("%Y-%m-%dT%H:%M")
      end

      def board_form_value(key, fallback = nil)
        return @form_input[key] if @form_input&.has_key?(key)

        fallback
      end

      def board_activity_value(key)
        return @form_input.dig(:activity, key) if @form_input&.dig(:activity)&.has_key?(key)

        value = @post.activity_details[key.to_s]
        return value unless key.to_s == "starts_at" && value.present?

        board_input_date(Time.iso8601(value))
      rescue ArgumentError
        nil
      end

      def board_context_href(value)
        path = value.to_s
        return board_local_source_href(path) if path.start_with?("/")

        KomsilukPost.safe_link(path)
      end

      def board_error_target(attribute)
        key = attribute.to_s
        return "komsiluk-post-errors-title" if key == "base"
        return "board-activity" if key == "details"

        "komsiluk_post_#{key}"
      end
    end
  end
end
