# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Round 25 (W4.2) — admin editor for the Goodwill EARNING SCHEDULE
      # (per-action point values), per-action DAILY CAPS, and the SEASON start
      # date. These previously lived only in the host initializer; now an
      # operator edits them per organization, persisted in Decidim::Bih::Setting.
      #
      # Fallback discipline: leaving a field blank CLEARS its DB override (the
      # row is deleted), restoring the DEFAULTS → config value. An empty store is
      # byte-identical to the pre-table behavior — this touches the points
      # economy, so the form never writes a value it was not given.
      #
      # Permission model: global-admin gated (ApplicationController#
      # ensure_global_admin!); all writes org-scoped to current_organization.
      class GoodwillSettingsController < Decidim::Bih::Admin::ApplicationController
        # Actions exposed for point-value and cap editing — the union of the
        # default schedule and cap keys, kept in a stable display order.
        SCHEDULE_ACTIONS = Decidim::Bih::Goodwill::EarningRules::DEFAULT_SCHEDULE.keys.freeze
        CAP_ACTIONS = Decidim::Bih::Goodwill::EarningRules::DEFAULT_DAILY_CAPS.keys.freeze

        before_action -> { require_bih_permission!(:goodwill_settings_manage) }

        # GET /admin/bih/goodwill-settings
        def edit
          load_settings_form
        end

        # PATCH /admin/bih/goodwill-settings
        def update
          sections = %w(schedule caps monthly_caps settings).each_with_object({}) do |key, values|
            next unless params.key?(key)

            raw = params[key]
            values[key] = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
          end
          Decidim::Bih::Goodwill::SettingsUpdate.new(
            organization: current_organization, sections:, rationale: approval_rationale
          ).call! do |metadata|
            audit_operator_action!("goodwill_settings_updated", permission: "goodwill_settings_manage", metadata:)
          end
          flash[:notice] = t(".updated")
          redirect_to goodwill_settings_path
        rescue Decidim::Bih::Goodwill::SettingsUpdate::Invalid => e
          load_settings_form
          flash.now[:alert] = t(".#{e.message}")
          render :edit, status: :unprocessable_entity
        end

        private

        def load_settings_form
          rules_klass = Decidim::Bih::Goodwill::EarningRules
          @rules = rules_klass.new(organization: current_organization)
          @schedule_actions = SCHEDULE_ACTIONS
          @cap_actions = CAP_ACTIONS
          @season_started_at = rules_klass.season_started_at(current_organization)
          # Stored OVERRIDES only (string-keyed), so the form shows the override as
          # the field value and the effective default as a placeholder. A blank
          # field therefore means "no override" and clears the row on save —
          # never baking a default into the DB on a no-op save.
          @schedule_overrides = Decidim::Bih::Setting.namespace_for(current_organization, rules_klass::SCHEDULE_NAMESPACE)
          @cap_overrides = Decidim::Bih::Setting.namespace_for(current_organization, rules_klass::CAPS_NAMESPACE)
          @season_override = Decidim::Bih::Setting.namespace_for(current_organization, rules_klass::SEASON_NAMESPACE)[rules_klass::SEASON_KEY]
          @schedule_defaults = rules_klass::DEFAULT_SCHEDULE.merge(Decidim::Bih.goodwill_earning_schedule.to_h.symbolize_keys)
          @cap_defaults = rules_klass::DEFAULT_DAILY_CAPS.merge(Decidim::Bih.goodwill_daily_caps.to_h.symbolize_keys)
          @monthly_cap_actions = rules_klass::DEFAULT_MONTHLY_CAPS.keys
          @monthly_cap_defaults = rules_klass::DEFAULT_MONTHLY_CAPS
          @monthly_cap_overrides = Decidim::Bih::Setting.namespace_for(current_organization, rules_klass::MONTHLY_CAPS_NAMESPACE)
          @season_default = Decidim::Bih.goodwill_season_started_at
        end

        def approval_rationale
          params[:approval_rationale].to_s.strip
        end
      end
    end
  end
end
