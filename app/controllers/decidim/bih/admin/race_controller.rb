# frozen_string_literal: true
module Decidim
  module Bih
    module Admin
      class RaceController < ApplicationController
        before_action :ensure_global_admin!
        before_action :prevent_caching
        rescue_from Decidim::Bih::Race::Review::Invalid, ArgumentError, ActiveRecord::RecordNotFound, with: :invalid_request

        def show
          @edition = Race::Edition.for(current_organization)
          @review = Race::Review.new(current_organization)
          @rows = @edition&.captured_at ? @review.preview : Race::Standings.new(current_organization).rows
          @revision = @edition&.events&.maximum(:id).to_i
          @items = @edition&.snapshot&.fetch("items", []) || []
          @electorate = @edition&.captured_at ? @review.electorate : []
        end

        def baseline
          review.baseline!(actor: current_user, reason: params[:reason])
          redirect_to race_path
        end

        def capture
          review.capture!(actor: current_user)
          redirect_to race_path
        end

        def decide
          if params[:target] == "electorate"
            review.correct_elector!(actor: current_user, reason: params[:reason], user_id: params[:item_key],
                                    area: params[:area], expected_digest: params[:digest], evidence: params[:evidence])
          else
            raise ArgumentError, "invalid decision" unless %w(include exclude).include?(params[:decision])
            review.decide!(actor: current_user, reason: params[:reason], item_key: params[:item_key],
                           include_item: params[:decision] == "include", area: params[:area], expected_digest: params[:digest])
          end
          redirect_to race_path
        end

        def finalize
          review.finalize!(actor: current_user, reason: params[:reason], expected_digest: params[:digest], expected_revision: params[:revision])
          redirect_to race_path
        end

        def visibility
          raise ArgumentError, "invalid visibility" unless %w(show hide).include?(params[:visibility])
          Race::Visibility.change!(current_organization, visible: params[:visibility] == "show", actor: current_user, reason: params[:reason])
          redirect_to race_path
        end

        def settings
          values = params.require(:settings).permit(:review_closes_at, :vote_starts_at, :vote_ends_at,
                                                     :tie_procedure, :zero_entry_procedure, :project_owner, winners: %i(grad selo)).to_h
          review.settings!(actor: current_user, values:, reason: params[:reason])
          redirect_to race_path
        end

        def membership
          result = review.correct_membership!(actor: current_user, reason: params[:reason], user_id: params[:user_id],
                    area: params[:area], expected_area: params[:expected_area], preview_only: params[:mode] != "apply",
                    expected_preview: params[:preview_digest])
          if params[:mode] == "apply"
            redirect_to race_path
          else
            show
            @membership_preview = result
            render :show
          end
        end

        def evidence
          edition = Race::Edition.find_by!(organization: current_organization, key: Race::Edition::KEY)
          payload = { snapshot: edition.snapshot, digest: edition.snapshot_digest,
                      events: edition.events.order(:id).map { |e| e.attributes.slice("id", "kind", "actor_id", "item_key", "data", "created_at") } }
          send_data JSON.pretty_generate(payload), type: "application/json", disposition: "attachment", filename: "race-2026-private-evidence.json"
        end

        private

        def review = Race::Review.new(current_organization)
        def prevent_caching
          response.cache_control.replace(no_store: true, private: true)
        end
        def invalid_request(error)
          flash.now[:alert] = error.message
          show
          render :show, status: :unprocessable_entity
        end
      end
    end
  end
end
