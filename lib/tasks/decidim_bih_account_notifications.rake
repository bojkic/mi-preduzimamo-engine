# frozen_string_literal: true

namespace :decidim_bih do
  namespace :account_notifications do
    # ⚠️ ONE intent, by id, on purpose — and the check is INSIDE the task body,
    # not appended with Rake::Task#enhance. `enhance` APPENDS, so a guard added
    # that way would run AFTER the thing it guards.
    #
    # The Messages API hands each delivery report over ONCE. A "reconcile
    # everything" variant of this task would consume the reports belonging to
    # every pending intent and leave `AccountNotifications.reconcile!` — which
    # asks for reports BY MESSAGE ID — with nothing to find, permanently. The
    # bound is therefore not a batch size; it is that there is no batch.
    desc "Reconcile one intent from Infobip (consumes only its delivery reports; never sends, never drains the queue)"
    task reconcile: :environment do
      abort "Set NOTIFICATION_ID and ORGANIZATION_ID" unless ENV["NOTIFICATION_ID"].present? && ENV["ORGANIZATION_ID"].present?
      notification = Decidim::Bih::AccountNotification.find_by!(id: ENV.fetch("NOTIFICATION_ID", nil), decidim_organization_id: ENV.fetch("ORGANIZATION_ID", nil))
      Decidim::Bih::AccountNotifications.reconcile!(notification)
      puts "notification=#{notification.id} status=#{notification.status}"
    end
  end
end
