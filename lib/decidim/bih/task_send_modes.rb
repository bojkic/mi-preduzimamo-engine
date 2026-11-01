# frozen_string_literal: true

module Decidim
  module Bih
    # What each callable rake task actually DOES, so an operator, a reviewer
    # and a cron wrapper read the same answer.
    #
    # This is a declaration of CURRENT behaviour. Changing a value here without
    # changing the task is a lie; changing the task is a behaviour change that
    # needs its own review. Nothing in this file changes a default.
    #
    # The five categories must not collapse into one, because the safe default
    # is different for each:
    #
    #   :manual_bulk_send    an operator triggers it; many recipients; billed.
    #                        MAY default to preview/dry-run — the operator is
    #                        present to re-run it.
    #   :scheduled_dispatch  unattended, and citizens or operators depend on
    #                        the message arriving. Must NOT be defaulted to
    #                        dry-run: that stops reminders silently, which
    #                        looks like a safety improvement and is an outage.
    #   :recovery            reads provider state, or re-enqueues work that was
    #                        never attempted. It is not a send, and redefining
    #                        it as one is how a reconciliation becomes a second
    #                        paid message.
    #   :diagnostic          read-only. A "diagnostic" that sends to check is a
    #                        send.
    #   :lifecycle           deletes or expires data, and may also notify.
    #                        Naming it a plain sender would hide the deletion.
    #   :no_delivery         runs unattended and delivers nothing to anybody.
    #                        This one is NOT in the plan's list, and it is here
    #                        because without it the table can only ever cover
    #                        the tasks somebody remembered. With it, the host
    #                        can assert that EVERY scheduled task is classified,
    #                        and "this cron job cannot send" becomes a checked
    #                        claim rather than an assumption.
    #
    # ⚠️ Rake::Task#enhance APPENDS. A guard added with `enhance` runs AFTER the
    # action it was meant to guard, and a prerequisite guard is skipped by
    # `.execute`. Every guard in this area is therefore a pre-action check
    # INSIDE the task body — see `decidim_bih:account_notifications:reconcile`,
    # whose comment says so, and the executable proof in
    # `test/tasks/messaging_task_contracts_test.rb`.
    TASK_SEND_MODES = {
      "decidim_bih:reports:private_storage_convert" => :lifecycle,
      # -- operator-triggered, many recipients, billed ---------------------
      # DRY_RUN=1 by default; DRY_RUN=0 sends. MAX_RECIPIENTS is checked
      # before the first send, and a per-citizen ledger makes a restart safe.
      "decidim_bih:launch:campaign" => :manual_bulk_send,
      # Sends e-mail + SMS immediately, with NO task-level dry run. The bound
      # is the ten-minute per-citizen operator throttle, not a flag.
      "decidim_bih:registration:pending:resend" => :manual_bulk_send,

      # -- unattended, and somebody is waiting for the message -------------
      "decidim_bih:analytics:digest" => :scheduled_dispatch,
      "decidim_bih:reports:stale_digest" => :scheduled_dispatch,
      "decidim_bih:reports:case_reminders" => :scheduled_dispatch,
      "decidim_bih:operator_roles:expiry_warnings" => :scheduled_dispatch,
      "decidim_bih:operations:health_alert" => :scheduled_dispatch,

      # -- reads or re-enqueues; never a new send --------------------------
      # ONE intent, by id. There is no batch to bound, and a bulk variant
      # would consume the delivery reports the per-intent caller needs.
      "decidim_bih:account_notifications:reconcile" => :recovery,
      "decidim_bih:goodwill:reconcile" => :recovery,
      "decidim_bih:goodwill:recover_pending" => :recovery,
      "decidim_bih:reports:mailbox_poll" => :recovery,
      "decidim_bih:reports:mailbox_recover" => :recovery,
      "decidim_bih:reports:mailbox_activate" => :lifecycle,
      "decidim_bih:reports:sistem48_sync" => :recovery,

      # -- read-only ------------------------------------------------------
      "decidim_bih:messaging:report" => :diagnostic,
      "decidim_bih:messaging:diagnostics" => :diagnostic,
      "decidim_bih:messaging:shadow_compare" => :diagnostic,
      "decidim_bih:goodwill:metrics" => :diagnostic,
      "decidim_bih:goodwill:anomalies" => :diagnostic,

      # -- deletes or expires, and may notify ------------------------------
      # Dry-run unless APPLY=1, and the cron wrapper sets APPLY=1. It sends a
      # day-5 notice AND hard-deletes on day 7: calling it a sender would hide
      # the deletion, calling it a sweep would hide the send.
      "decidim_bih:registration:pending:sweep" => :lifecycle,
      "decidim_bih:registration:backfill_welcomed" => :lifecycle,
      "decidim_bih:goodwill:cancel_expired_fulfillments" => :lifecycle,
      "decidim_bih:goodwill:reset_badges" => :lifecycle,
      "decidim_bih:komsiluk:expire_posts" => :lifecycle,
      "decidim_bih:postal:purge_unconfirmed" => :lifecycle,
      "decidim_bih:privacy:retention_sweep" => :lifecycle,
      # Closes undecided applications at their decision cutoff and may notify
      # applicants. The host review-policy switch makes it a no-op until cutover.
      "decidim_bih:volunteering:close_due" => :lifecycle,

      # -- scheduled, and delivers nothing ---------------------------------
      # Recomputing a cached table and rolling up aggregate metrics. Declared
      # so the host's "every scheduled task is classified" check is complete.
      "decidim_bih:race:refresh" => :no_delivery,
      "decidim_bih:race:freeze" => :no_delivery,
      "decidim_bih:concierge:rollup_metrics" => :no_delivery
    }.freeze

    TASK_SEND_MODE_CATEGORIES = [:manual_bulk_send, :scheduled_dispatch, :recovery, :diagnostic, :lifecycle, :no_delivery].freeze

    # Tasks that must never be scheduled: an unattended run would bill the
    # foundation per recipient without anybody present to stop it.
    TASK_NEVER_SCHEDULED_CATEGORIES = [:manual_bulk_send].freeze

    # Which rake FILE declares a task, so a contract test can read the source
    # rather than trust the name. Two namespaces do not follow the
    # `decidim_bih_<namespace>.rake` convention.
    TASK_SEND_MODE_SOURCES = {
      "decidim_bih:launch:campaign" => "decidim_bih_launch_campaign.rake",
      "decidim_bih:messaging:report" => "decidim_bih_messaging_history.rake",
      "decidim_bih:goodwill:reset_badges" => "decidim_bih_goodwill.rake",
      "decidim_bih:goodwill:recover_pending" => "decidim_bih_goodwill_recovery.rake",
      "decidim_bih:reports:private_storage_convert" => "decidim_bih_report_private_storage.rake",
      # ⚠️ Defined in the HOST (`host:lib/tasks/milica_metrics.rake`) despite
      # the `decidim_bih:` namespace, so this engine has no source to check.
      # Marked rather than pointed at a file that does not exist.
      "decidim_bih:concierge:rollup_metrics" => :host_owned
    }.freeze

    module TaskSendModes
      module_function

      def category(task_name) = TASK_SEND_MODES[task_name.to_s]

      def sends?(task_name)
        [:manual_bulk_send, :scheduled_dispatch, :lifecycle].include?(category(task_name))
      end

      def rake_file_for(task_name)
        TASK_SEND_MODE_SOURCES.fetch(task_name.to_s) { "decidim_bih_#{task_name.to_s.split(":")[1]}.rake" }
      end

      # A `decidim_bih:`-namespaced task the HOST defines. The engine cannot
      # check its source, and saying so is better than pointing a contract
      # test at a file that will never exist.
      def host_owned?(task_name) = rake_file_for(task_name) == :host_owned
    end
  end
end
