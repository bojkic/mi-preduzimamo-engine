# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Admin-only, PII-minimized operator action history.
      class OperatorAuditEventsController < Decidim::Bih::Admin::ApplicationController
        before_action -> { require_bih_permission!(:operator_audit_read) }

        PER_PAGE = 50

        def index
          @event_type = params[:event_type].to_s.strip.presence
          @actor_id = params[:actor_id].to_s.strip.presence
          @role = params[:role].to_s.strip.presence
          @resource_type = params[:resource_type].to_s.strip.presence
          @from_date = parsed_date(:from_date)
          @to_date = parsed_date(:to_date)
          @events = Decidim::Bih::OperatorAuditEvent
                    .where(organization: current_organization)
                    .includes(:user)
          @events = @events.where(event_type: @event_type) if @event_type
          @events = @events.where(decidim_user_id: @actor_id) if @actor_id
          @events = @events.where(role: @role) if @role
          @events = @events.where(resource_type: @resource_type) if @resource_type
          @events = @events.where(occurred_at: @from_date.beginning_of_day..) if @from_date
          @events = @events.where(occurred_at: ..@to_date.end_of_day) if @to_date
          @events = @events.recent.page(params[:page]).per(PER_PAGE)

          options_scope = Decidim::Bih::OperatorAuditEvent.where(organization: current_organization)
          @event_types = options_scope
                         .distinct
                         .order(:event_type)
                         .pluck(:event_type)
          @roles = options_scope.where.not(role: [nil, ""]).distinct.order(:role).pluck(:role)
          @resource_types = options_scope.where.not(resource_type: [nil, ""]).distinct.order(:resource_type).pluck(:resource_type)
          @actors = Decidim::User.where(organization: current_organization, id: options_scope.where.not(decidim_user_id: nil).select(:decidim_user_id))
                                 .order(:name, :nickname)
        end

        private

        def parsed_date(key)
          value = params[key].to_s
          return if value.blank?

          Date.iso8601(value)
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
