# frozen_string_literal: true

require "test_helper"
require "rake"
require_relative "../../lib/decidim/bih/task_send_modes"

module Decidim
  module Bih
    # What each callable task does, checked against the task's own SOURCE —
    # and the three Rake mechanics that make a guard look present when it is
    # not.
    #
    # Pure: an isolated `Rake::Application`, no Rails, no database.
    class MessagingTaskContractsTest < Minitest::Test
      TASKS_DIR = File.expand_path("../../lib/tasks", __dir__)

      def setup
        @previous_app = Rake.application
        Rake.application = Rake::Application.new
        @env = ENV.to_hash
      end

      def teardown
        Rake.application = @previous_app
        ENV.replace(@env)
      end

      def source_for(task_name)
        File.read(File.join(TASKS_DIR, TaskSendModes.rake_file_for(task_name)))
      end

      def engine_owned
        TASK_SEND_MODES.keys.reject { |name| TaskSendModes.host_owned?(name) }
      end

      # Comments are not code. Mutation-checking found that `abort "Set
      # NOTIFICATION_ID"` commented out still satisfied a plain source match,
      # so every guard assertion below reads the EXECUTABLE lines only.
      def code_for(task_name)
        source_for(task_name).lines.reject { |line| line.strip.start_with?("#") }.join
      end

      def tasks_in(category)
        TASK_SEND_MODES.select { |_, value| value == category }.keys - TASK_SEND_MODES.keys.select { |n| TaskSendModes.host_owned?(n) }
      end

      # ---- the declaration itself ---------------------------------------

      # A host-owned marker is a refusal to check, so it must be rare and it
      # must be true: the engine really has no such rake file.
      def test_a_host_owned_marker_is_only_used_where_the_engine_has_no_such_file
        TASK_SEND_MODES.each_key do |name|
          next unless TaskSendModes.host_owned?(name)

          candidate = File.join(TASKS_DIR, "decidim_bih_#{name.split(":")[1]}.rake")
          refute File.exist?(candidate),
                 "#{name} is marked host-owned but #{candidate} exists; check the source instead"
        end
      end

      def test_every_declared_mode_is_a_known_category
        TASK_SEND_MODES.each do |name, category|
          assert_includes TASK_SEND_MODE_CATEGORIES, category, "#{name} has an unknown category"
        end
      end

      # A declaration about a task that does not exist is worse than none: it
      # reads as coverage.
      def test_every_declared_task_exists_in_the_source_it_claims
        engine_owned.each do |name|
          leaf = name.split(":").last
          assert_match(/task\s+:?#{Regexp.escape(leaf)}\b/, code_for(name),
                       "#{name} is declared but #{TaskSendModes.rake_file_for(name)} defines no such task")
        end
      end

      def test_the_five_categories_are_all_populated
        TASK_SEND_MODE_CATEGORIES.each do |category|
          refute_empty tasks_in(category), "#{category} has no task; a category nobody uses is not a distinction"
        end
      end

      # ---- the rule that keeps reminders running -------------------------

      # Flipping a scheduled sender to dry-run by default looks like a safety
      # improvement and is an outage nobody is paged for.
      def test_no_scheduled_dispatch_task_defaults_to_dry_run
        tasks_in(:scheduled_dispatch).each do |name|
          source = code_for(name)
          leaf = Regexp.escape(name.split(":").last)
          body = source[/task\s+:?#{leaf}\b.*?(?=\n    (?:desc|task|end)\b|\z)/m].to_s
          refute_match(/DRY_RUN|\bAPPLY\b/, body,
                       "#{name} is scheduled; a dry-run or APPLY default would silently stop reminders")
        end
      end

      def test_recovery_tasks_declare_that_they_do_not_send
        assert_equal :recovery, TASK_SEND_MODES.fetch("decidim_bih:account_notifications:reconcile")
        refute TaskSendModes.sends?("decidim_bih:account_notifications:reconcile")
      end

      # The bound on the reconcile task is not a batch size; it is that there
      # is no batch. If a NOTIFICATION_ID stops being required, one run could
      # drain every pending intent's delivery reports.
      def test_the_reconcile_task_still_refuses_to_run_without_one_id
        code = code_for("decidim_bih:account_notifications:reconcile")
        assert_match(/abort.*NOTIFICATION_ID/, code,
                     "commenting the guard out must not count as having it")
        refute_match(/find_each|in_batches|update_all/, code,
                     "a bulk reconcile would consume the reports the per-intent caller needs")
      end

      def test_a_diagnostic_task_never_delivers
        tasks_in(:diagnostic).each do |name|
          code = code_for(name)
          refute_match(/deliver_now|deliver_later/, code,
                       "#{name} is declared read-only; a diagnostic that sends to check is a send")
        end
      end

      # The campaign is the one billed bulk sender, and its default must stay
      # the counting one.
      def test_the_campaign_still_defaults_to_dry_run_and_bounds_its_batch
        code = code_for("decidim_bih:launch:campaign")
        assert_match(/ENV\.fetch\("DRY_RUN", "1"\)/, code, "the campaign must still default to counting, not sending")
        assert_match(/MAX_RECIPIENTS/, code)
      end

      # ---- the three Rake mechanics --------------------------------------

      # The roadmap's correction, executable rather than described.
      def test_a_guard_added_with_enhance_would_run_after_the_action_it_guards
        order = []
        Rake::Task.define_task(:send_something) { order << :sent }
        Rake::Task[:send_something].enhance { order << :guard }
        Rake::Task[:send_something].invoke
        assert_equal [:sent, :guard], order,
                     "this is why every guard in this phase is a pre-action check inside the task body"
      end

      def test_a_pre_action_guard_inside_the_body_runs_first
        order = []
        Rake::Task.define_task(:guarded) do
          order << :guard
          order << :sent
        end
        Rake::Task[:guarded].invoke
        assert_equal [:guard, :sent], order
      end

      def test_a_prerequisite_guard_is_bypassed_by_execute
        order = []
        Rake::Task.define_task(:pre) { order << :guard }
        Rake::Task.define_task(send_only: :pre) { order << :sent }
        Rake::Task[:send_only].execute
        assert_equal [:sent], order,
                     "a prerequisite-only guard does not cover a direct .execute"
      end

      # ---- what must never be scheduled ----------------------------------

      def test_a_manual_bulk_send_is_never_a_scheduled_category
        TASK_NEVER_SCHEDULED_CATEGORIES.each do |category|
          tasks_in(category).each do |name|
            refute_equal :scheduled_dispatch, TASK_SEND_MODES.fetch(name)
          end
        end
        assert_includes TASK_NEVER_SCHEDULED_CATEGORIES, TASK_SEND_MODES.fetch("decidim_bih:launch:campaign")
      end
    end
  end
end
