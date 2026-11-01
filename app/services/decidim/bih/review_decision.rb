# frozen_string_literal: true

module Decidim
  module Bih
    # Shared decision pipeline for the four volunteer-review services
    # (approve/reject an opportunity, verify/reject a log). They all follow the
    # same skeleton:
    #
    #   1. run an ordered list of GUARDS over the input; the first guard whose
    #      condition holds short-circuits with its status symbol (e.g. :missing,
    #      :already, :invalid);
    #   2. lock the review row, rerun the guards, and PERFORM the state
    #      transition (and any point award) inside one DB transaction;
    #   3. NOTIFY the affected user;
    #   4. return :ok.
    #
    # Subclasses keep their own public `self.call(...)` signature (so callers and
    # the existing return contracts are untouched) and configure the pipeline by
    # overriding #guards, #perform, #notify, #review_record and
    # #transaction_model.
    class ReviewDecision
      # Run the configured guards in order. Returns the first matching guard's
      # status symbol, or nil when every guard passes.
      #
      # Each guard is a [status_symbol, condition_proc] pair. The proc is
      # evaluated with no arguments in the service instance's context.
      def call
        guard_status = run_guards
        return guard_status if guard_status

        transition_status = run_transition
        return transition_status unless transition_status == :ok

        notify

        :ok
      end

      private

      # Ordered list of [status_symbol, -> { condition }] guard pairs. The first
      # pair whose condition is truthy short-circuits #call with its symbol.
      # Subclasses override this; the order is significant and preserved exactly.
      def guards
        []
      end

      def run_guards
        guards.each do |status, condition|
          return status if condition.call
        end
        nil
      end

      # Apply the state transition (and any point award). Review decisions
      # provide a transaction model and record so concurrent reviewers serialize
      # on the same row and the locked guard recheck precedes every mutation.
      def run_transition
        model = transaction_model
        unless model
          perform
          return :ok
        end

        result = :ok
        model.transaction do
          record = review_record
          record.lock! if record.respond_to?(:lock!)
          lock_related_records

          result = run_guards || :ok
          perform if result == :ok
        end
        result
      end

      # The ActiveRecord class whose .transaction wraps #perform, or nil to run
      # #perform without an explicit transaction. Defaults to nil.
      def transaction_model
        nil
      end

      # The state-machine row reloaded under a database lock before guards are
      # evaluated a second time. Subclasses with transactional decisions should
      # override this alongside #transaction_model.
      def review_record
        nil
      end

      # Hook for rows whose current state affects publication eligibility. The
      # primary review row is always locked first, giving every caller one lock
      # order and avoiding approve/reject deadlocks.
      def lock_related_records; end

      # Mutate the record into its new state (and award points where applicable).
      def perform
        raise NotImplementedError
      end

      # Publish the user-facing notification for this decision.
      def notify
        raise NotImplementedError
      end
    end
  end
end
