# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      class KomsilukPostPhotosController < ApplicationController
        def show
          post = Komsiluk::ModerationAccess.new(user: current_user, organization: current_organization).posts.find(params[:id])
          require_bih_permission!(:komsiluk_posts_read, resource: post)
          raise ActiveRecord::RecordNotFound unless post.photo.attached?

          response.headers["Cache-Control"] = "private, no-store"
          response.headers["X-Content-Type-Options"] = "nosniff"
          send_data post.photo.download, type: post.photo.content_type, disposition: "inline", filename: "komsiluk-photo"
        end
      end
    end
  end
end
