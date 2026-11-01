# frozen_string_literal: true

require "test_helper"
require "timeout"

module Decidim
  module Bih
    module RailsHarness
      class ReportMailboxProcessingConcurrencyTest < ActiveSupport::TestCase
        self.use_transactional_tests = false

        setup do
          @organization = create_organization
          @report = Report.create!(organization: @organization, description: "Concurrent mailbox fixture", status: "primljeno")
          raw = "From: city@city.example\r\nTo: prijave@example.org\r\nSubject: #{@report.reference}\r\n\r\nReply"
          @email = InboundEmail.create!(organization: @organization, account: "prijave@example.org", folder: "All",
            uidvalidity: 1, uid: 1, gm_msgid: SecureRandom.uuid, internal_date: Time.current,
            size_bytes: raw.bytesize, raw:, body_text: "Reply", subject: @report.reference)
          @threads = []
        end

        teardown do
          @threads.each { |thread| thread.kill if thread.alive? }
          @threads.each(&:join)
          InboundEmailEffect.where(inbound_email: @email).delete_all
          @email.destroy!
          ReportObligation.where(report: @report).delete_all if defined?(ReportObligation)
          ReportEvent.where(report: @report).delete_all
          # Intake may have cached the now-deleted obligation collection.
          @report.reload.destroy!
          @organization.static_pages.delete_all
          @organization.destroy!
        end

        def worker(&block)
          result = Queue.new
          @threads << Thread.new do
            ActiveRecord::Base.connection_pool.with_connection { result << block.call }
          rescue StandardError => error
            result << error
          end
          result
        end

        def receive(queue)
          Timeout.timeout(10) { queue.pop }
        end

        def assert_blocked(waiter, owner)
          Timeout.timeout(10) do
            loop do
              # Lock state changes independently of committed table writes. Rails
              # must not reuse the first empty result while the worker blocks.
              blockers = ActiveRecord::Base.uncached do
                ActiveRecord::Base.connection.select_value("SELECT pg_blocking_pids(#{Integer(waiter)})::text")
              end
              break if blockers.delete("{}").split(",").map(&:to_i).include?(owner)
              Thread.pass
            end
          end
        end

        test "history conversion waits for processing effects and cannot be overwritten" do
          entered = Queue.new
          release = Queue.new
          classifier = lambda do |*_args, **_options|
            entered << ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()")
            receive(release)
            { classification: "outbound_copy", no_auto_response: false }
          end
          ReportMailbox::Classifier.stub(:call, classifier) do
            processing = worker { ReportMailbox::ProcessMessage.new(InboundEmail.find(@email.id)).call }
            owner = receive(entered)
            admin_pid = Queue.new
            history = worker do
              admin_pid << ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()")
              mail = InboundEmail.find(@email.id)
              mail.with_lock do
                assert_equal "processed", mail.state
                assert_equal 1, mail.links.count
                mail.update!(history_only: true, history_reason: "forwarded_import", state: "history")
              end
              true
            end
            assert_blocked(receive(admin_pid), owner)
            release << true
            assert_equal true, receive(processing)
            assert_equal true, receive(history)
          end
          assert_equal "history", @email.reload.state
          assert @email.history_only
          assert_equal 1, @email.links.count
        ensure
          release << true if release
        end

        test "processing lock permits a report locked effect foreign key without deadlock" do
          entered = Queue.new
          release = Queue.new
          classifier = lambda do |*_args, **_options|
            entered << true
            receive(release)
            { classification: "outbound_copy", no_auto_response: false }
          end
          ReportMailbox::Classifier.stub(:call, classifier) do
            processing = worker { ReportMailbox::ProcessMessage.new(InboundEmail.find(@email.id)).call }
            receive(entered)
            approval = worker do
              report = Report.find(@report.id)
              report.with_lock do
                InboundEmailEffect.once!(inbound_email: InboundEmail.find(@email.id), report:, effect: "approval_fixture") do
                  report.record_event!("city_email_history_linked", source: "background", metadata: { inbound_email_id: @email.id })
                end
              end
              true
            end
            # This must finish while the processor still owns its row lock.
            # FOR UPDATE would block the FK KEY SHARE and fail this barrier.
            assert_equal true, receive(approval)
            release << true
            assert_equal true, receive(processing)
          end
          assert_equal 1, InboundEmailEffect.where(inbound_email: @email, effect: "approval_fixture").count
        ensure
          release << true if release
        end

        test "history committed before the durable claim prevents any classifier or effect" do
          held = Queue.new
          release = Queue.new
          admin = worker do
            mail = InboundEmail.find(@email.id)
            mail.with_lock do
              held << ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()")
              receive(release)
              mail.update!(history_only: true, history_reason: "forwarded_import", state: "history")
            end
            true
          end
          owner = receive(held)
          process_pid = Queue.new
          ReportMailbox::Classifier.stub(:call, ->(*) { raise "classifier must not run" }) do
            processing = worker do
              process_pid << ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()")
              ReportMailbox::ProcessMessage.new(InboundEmail.find(@email.id)).call
            end
            assert_blocked(receive(process_pid), owner)
            release << true
            assert_equal true, receive(admin)
            assert_equal false, receive(processing)
          end
          assert_equal "history", @email.reload.state
          assert_equal 0, @email.processing_attempts
          assert_empty @email.links
        ensure
          release << true if release
        end

        test "a processing exception rolls back links events and effect guards but retains the claim attempt" do
          @email.update!(history_only: true, history_reason: "pre_activation")
          processor = ReportMailbox::ProcessMessage.new(@email)
          processor.define_singleton_method(:finish) { |_state| raise "after effects" }
          before = @report.events.count
          assert_raises(RuntimeError) { processor.call }
          assert_equal "stored", @email.reload.state
          assert_nil @email.locked_at
          assert_equal 1, @email.processing_attempts
          assert_empty @email.links
          assert_equal 0, InboundEmailEffect.where(inbound_email: @email).count
          assert_equal before, @report.events.count
        end

        test "stale failure recovery cannot replace history ignored or a newer processing claim" do
          %w(history ignored processing).each do |state|
            @email.update_columns(state: "stored", history_only: false, locked_at: nil)
            failed = Queue.new
            release = Queue.new
            processor = ReportMailbox::ProcessMessage.new(InboundEmail.find(@email.id))
            processor.define_singleton_method(:recover_claim) do |error|
              failed << true
              Timeout.timeout(10) { release.pop }
              super(error)
            end
            ReportMailbox::Classifier.stub(:call, ->(*_args, **_options) { raise "classifier failure" }) do
              processing = worker { processor.call }
              receive(failed) # Processing transaction has already rolled back.
              replacement_time = Time.current
              @email.reload.update!(state:, history_only: state == "history",
                history_reason: state == "history" ? "forwarded_import" : nil,
                locked_at: state == "processing" ? replacement_time : nil,
                processing_attempts: @email.processing_attempts + 1, review_reason: "staff decision")
              expected = @email.attributes.slice("state", "locked_at", "processing_attempts", "review_reason", "history_only")
              release << true
              assert_instance_of RuntimeError, receive(processing)
              assert_equal expected, @email.reload.attributes.slice(*expected.keys)
            end
          ensure
            release << true if release
          end
        end
      end
    end
  end
end
