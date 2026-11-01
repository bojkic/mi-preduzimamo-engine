# frozen_string_literal: true

require "securerandom"

module Decidim
  module Bih
    module Komsiluk
      # One create boundary for web and supported protected channels. Callers
      # prove phone verification/membership; daily limits serialize per author.
      class PostCreator
        DAILY_LIMIT = 5
        Result = Struct.new(:status, :post, keyword_init: true)

        def initialize(organization:, author:, komsiluk:)
          @organization = organization
          @author = author
          @komsiluk = komsiluk
        end

        def call(category:, title:, body:, details: {}, expires_at: nil, photo: nil, publication_key: nil)
          post = KomsilukPost.new(organization: @organization, author: @author, komsiluk: @komsiluk,
                                  category:, title:, body:, details:, expires_at:, origin: "citizen",
                                  published_at: Time.current, publication_key: publication_key.presence || SecureRandom.uuid)
          result = nil
          @author.with_lock do
            existing = KomsilukPost.find_by(organization: @organization, author: @author, publication_key:) if publication_key.present?
            if existing
              result = Result.new(status: :created, post: existing)
            elsif over_daily_limit?
              result = Result.new(status: :rate_limited, post:)
            else
              post.photo.attach(photo) if photo
              if post.save
                NoticePublishing.publish!(post:)
                award_points(post)
                result = Result.new(status: :created, post:)
              else
                result = Result.new(status: :invalid, post:)
              end
            end
          end
          result
        end

        private

        def over_daily_limit?
          KomsilukPost.where(decidim_organization_id: @organization.id, decidim_user_id: @author.id)
                      .where(created_at: Time.current.beginning_of_day..).count >= DAILY_LIMIT
        end

        def award_points(post)
          Decidim::Bih::Goodwill::AwardDispatch.komsiluk_post_created(post, author: @author)
        rescue StandardError => e
          Rails.logger.error("[Komsiluk::PostCreator] points award failed: #{Decidim::Bih::LogRedactor.error_message(e)}")
        end
      end
    end
  end
end
