# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Round 25 (W4.4) — admin editor for the Sistem 48 forwarding targets: the
      # central intake mailbox and the per-category routing overrides. These were
      # ENV-only (SISTEM48_CENTRAL_INTAKE, SISTEM48_EMAIL_<CATEGORY>); now an
      # operator overrides them per organization, persisted in
      # Decidim::Bih::Setting.
      #
      # Fallback discipline: a blank field CLEARS its override (row deleted),
      # restoring the ENV/default routing. An empty store forwards exactly as
      # before.
      #
      # Permission model: global-admin gated; writes org-scoped to
      # current_organization.
      class Sistem48SettingsController < Decidim::Bih::Admin::ApplicationController
        CATEGORIES = Decidim::Bih::ReportTaxonomy::CATEGORIES
        ROUTING = Decidim::Bih::Sistem48::DepartmentRouting

        before_action -> { require_bih_permission!(:sistem48_settings_manage) }

        # GET /admin/bih/sistem48-settings
        def edit
          load_settings_form
        end

        # PATCH/PUT /admin/bih/sistem48-settings
        def update
          if settings_change_requested? && approval_rationale.blank?
            load_settings_form
            flash.now[:alert] = t(".approval_rationale_required")
            return render :edit, status: :unprocessable_entity
          end

          persist(ROUTING::CENTRAL_INTAKE_KEY, params.dig(:settings, :central_intake))
          CATEGORIES.each do |category|
            persist(category.to_s, category_params[category.to_s])
          end

          audit_operator_action!(
            "sistem48_settings_updated",
            permission: "sistem48_settings_manage",
            metadata: {
              central_intake_present: params.dig(:settings, :central_intake).to_s.strip.present?,
              category_keys: category_params.keys,
              approval_rationale: approval_rationale.presence
            }.compact
          )
          flash[:notice] = t(".updated")
          redirect_to sistem48_settings_path
        end

        private

        def load_settings_form
          @categories = CATEGORIES
          @overrides = overrides
          @central_default = ROUTING.central_intake_default
          @central_effective = ROUTING.central_intake(current_organization)
          @category_defaults = @categories.index_with { |category| ROUTING.email_for(category) }
          @category_effective = @categories.index_with { |category| ROUTING.email_for(category, current_organization) }
        end

        # Writes a trimmed value, or clears the override on blank. Emails are
        # stored verbatim (no normalization beyond strip) so an operator-entered
        # address is forwarded exactly as typed.
        def persist(key, raw)
          value = raw.to_s.strip
          Decidim::Bih::Setting.put(current_organization, ROUTING::NAMESPACE, key, value.presence)
        end

        def category_params
          params.fetch(:categories, {}).permit(*CATEGORIES.map(&:to_s)).to_h
        end

        def settings_change_requested?
          routing_change_requested?(ROUTING::CENTRAL_INTAKE_KEY, params.dig(:settings, :central_intake), settings_key_present?(:central_intake)) ||
            CATEGORIES.any? do |category|
              routing_change_requested?(category.to_s, category_params[category.to_s], category_params.has_key?(category.to_s))
            end
        end

        def routing_change_requested?(key, raw, present)
          return false unless present

          value = raw.to_s.strip
          value.present? ? overrides.fetch(key, nil) != value : overrides.has_key?(key)
        end

        def settings_key_present?(key)
          params.fetch(:settings, {}).has_key?(key)
        end

        def approval_rationale
          params[:approval_rationale].to_s.strip
        end

        def overrides
          @overrides ||= Decidim::Bih::Setting.namespace_for(current_organization, ROUTING::NAMESPACE)
        end
      end
    end
  end
end
