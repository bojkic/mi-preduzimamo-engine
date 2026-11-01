# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Keep bookmarks and stale forms safe while retaining historical rows.
      # Old count-only confirmations cannot authorize a new phone request.
      class BroadcastsController < ApplicationController
        before_action -> { require_bih_permission!(:broadcast_preview) }

        def new
          redirect_to new_admin_bih_board_notice_path
        end

        def create
          redirect_to new_admin_bih_board_notice_path,
                      alert: t("decidim.bih.admin.board_notices.legacy_redirect")
        end
      end
    end
  end
end
