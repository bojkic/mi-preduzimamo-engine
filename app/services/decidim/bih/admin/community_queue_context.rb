# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Carries only bounded pagination state between the three independent
      # community review queues. No user supplied return URL reaches a redirect.
      class CommunityQueueContext
        PAGE_KEYS = %w(projects_page needs_page offers_page).freeze
        MAX_PAGE = 10_000

        def initialize(params)
          @pages = PAGE_KEYS.to_h do |key|
            raw = params[key] || params[key.to_sym]
            page = raw.to_s.match?(/\A[1-9]\d*\z/) ? raw.to_i : 1
            [key, page.clamp(1, MAX_PAGE)]
          end
        end

        def page(key)
          @pages.fetch(key.to_s)
        end

        def clamp_to_count(key, count:, per:)
          key = key.to_s
          @pages.fetch(key)
          last_page = [(count.to_i + per - 1) / per, 1].max
          @pages[key] = [@pages[key], last_page].min
        end

        def to_h
          @pages.reject { |_key, page| page == 1 }
        end
      end
    end
  end
end
