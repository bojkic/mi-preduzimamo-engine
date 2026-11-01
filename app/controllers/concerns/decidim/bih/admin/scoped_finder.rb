# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Shared "find an org-scoped record or redirect" helper for the Bih admin
      # controllers (citizens, reports, rewards, local areas, komšiluk posts).
      #
      # Every one of those controllers had copy-pasted the same shape:
      #   org-scoped `find_by(<col> => params[...])`
      #     → on a miss: set a flash[:alert] + redirect to the index + halt.
      #
      # The duplication hid a latent bug: some `edit`/`show` actions assigned the
      # finder result WITHOUT a `return unless @x` guard, so on a not-found the
      # action set a redirect AND then fell through to implicitly render its
      # template → a double-render (500 / AbstractController::DoubleRenderError)
      # instead of the intended clean redirect. Routing every finder call through
      # this concern, with the mandatory `return unless (@x = find_scoped!(...))`
      # idiom, makes that impossible to get wrong.
      #
      # Behaviour (identical to the old per-controller helpers):
      #   * found  → returns the record.
      #   * miss   → sets flash[:alert] = t(flash_key), redirects to `redirect_to`,
      #              and returns nil (so the caller halts).
      #
      # The scope must already be org-constrained by the caller (e.g.
      # `Model.where(organization: current_organization)`), so a cross-org id
      # resolves to nil → redirect, never a leak and never a 500.
      module ScopedFinder
        extend ActiveSupport::Concern

        private

        # @param scope [ActiveRecord::Relation] an already org-scoped relation.
        # @param redirect_to [String, #call] the index path to bounce to on a miss.
        # @param flash_key [String] an ABSOLUTE i18n key for the alert (callers
        #   pass their existing absolute key so user-facing strings don't change).
        # @param find_by [Hash] the lookup conditions, e.g. `id: params[:id]` or
        #   `reference: params[:reference]`.
        # @return [ActiveRecord::Base, nil] the record, or nil after redirecting.
        def find_scoped!(scope, redirect_to:, flash_key:, **find_by)
          record = scope.find_by(**find_by)
          return record if record

          flash[:alert] = t(flash_key)
          redirect_to(redirect_to.respond_to?(:call) ? redirect_to.call : redirect_to)
          nil
        end
      end
    end
  end
end
