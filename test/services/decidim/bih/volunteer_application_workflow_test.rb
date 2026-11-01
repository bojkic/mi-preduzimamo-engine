# frozen_string_literal: true

require "test_helper"
require "active_support/all"
require "arel"
require_relative "../../../../app/services/decidim/bih/review_volunteer_application"
require_relative "../../../../app/services/decidim/bih/volunteer_seat_allocator"
require_relative "../../../../app/services/decidim/bih/confirm_volunteer_attendance"
require_relative "../../../../app/services/decidim/bih/reconcile_legacy_volunteer_applications"

module Decidim
  module Bih
    class VolunteerApplicationWorkflowTest < Minitest::Test
      NOW = Time.utc(2026, 9, 25, 12)
      Organization = Struct.new(:id) do
        def persisted? = true
      end
      User = Struct.new(:id, :organization, :permissions, keyword_init: true) do
        def decidim_organization_id = organization.id
      end
      EmptyRelation = Struct.new(:none) do
        def exists?(**) = false
      end
      Attendance = Struct.new(:status, :work_date, :opportunity, :user, keyword_init: true)

      class Signup
        attr_accessor :id, :organization, :opportunity, :user, :status, :review_status,
                      :review_source, :reviewed_at, :reviewer, :decision_reason, :queued_at,
                      :first_session_at, :attendance_confirmed_at, :participation_ended_at,
                      :created_at, :updated_at

        def initialize(id:, organization:, opportunity:, user:, status: "pending", review_status: "pending",
                       review_source: "application", first_session_at: nil, attendance_confirmed_at: nil,
                       queued_at: nil, updated_at: NOW)
          @id, @organization, @opportunity, @user = id, organization, opportunity, user
          @status, @review_status, @review_source = status, review_status, review_source
          @first_session_at, @attendance_confirmed_at, @queued_at = first_session_at, attendance_confirmed_at, queued_at
          @created_at = updated_at - 1.hour
          @updated_at = updated_at
        end

        def persisted? = true
        def lock! = self
        def update!(attributes) = attributes.each { |key, value| public_send("#{key}=", value) }
        def decidim_organization_id = organization.id
        def decidim_bih_volunteer_opportunity_id = opportunity.id
        def decidim_user_id = user.id
        def going? = status == "going"
        def waitlisted? = status == "waitlisted"
        def pending? = status == "pending"
        def cancelled? = status == "cancelled"
        def review_approved? = %w(approved automatic).include?(review_status)
        def awaiting_review? = review_status == "pending" && !cancelled?
        def attendance_confirmed? = !attendance_confirmed_at.nil?
        def dated_attendances = EmptyRelation.new
      end

      class Scope
        include Enumerable

        def initialize(rows)
          @rows = rows
        end

        def each(&) = @rows.each(&)
        def count = @rows.count
        def exists?(**filters) = where(**filters).count.positive?
        def distinct = self
        def limit(n) = self.class.new(@rows.first(n))
        def pluck(attribute) = @rows.map { |row| row.public_send(attribute) }

        def where(*args, **filters)
          return self if args.empty? && filters.empty?
          if args.first.is_a?(String)
            # The allocator's SQL only admits waiters whose agreed first session
            # is still in the future, including a rolling programme.
            cutoff = args.last
            start = args.length == 3 ? args[1] : nil
            return self.class.new(@rows.select { |row| (row.first_session_at || start)&.> cutoff })
          end
          filters = args.first if filters.empty?
          self.class.new(@rows.select do |row|
            filters.all? do |key, value|
              actual = row.public_send(key)
              value.is_a?(Array) ? value.include?(actual) : actual == value
            end
          end)
        end

        def not(**filters)
          self.class.new(@rows.reject { |row| filters.all? { |key, value| row.public_send(key) == value } })
        end

        def order(*attributes)
          if attributes.any? { |value| value.to_s.include?("queued_at") }
            self.class.new(@rows.sort_by { |row| [row.queued_at || Time.utc(9999), row.id] })
          else
            self.class.new(@rows.sort_by(&:id))
          end
        end

        def going = where(status: "going")
        def waitlisted = where(status: "waitlisted")
        def approved_waitlist = where(status: "waitlisted", review_status: %w(approved automatic))
      end

      class Opportunity
        attr_accessor :id, :organization, :title, :capacity, :starts_at, :ends_at,
                      :active, :approved, :cancelled, :signups_rows

        def initialize(id:, organization:, capacity: nil, starts_at: NOW + 1.day, ends_at: NOW + 2.days)
          @id, @organization, @capacity, @starts_at, @ends_at = id, organization, capacity, starts_at, ends_at
          @title = "Volunteer programme"
          @active, @approved, @cancelled = true, true, false
          @signups_rows = []
        end

        def decidim_organization_id = organization.id
        def signups = Scope.new(signups_rows)
        def logs = EmptyRelation.new
        def active? = active
        def approved? = approved
        def cancelled? = cancelled
        def full? = !capacity.nil? && signups.going.count >= capacity
        def decision_cutoff_for(signup) = signup.first_session_at || starts_at
      end

      class OpportunityTable
        class << self
          attr_accessor :rows

          def transaction(&block)
            mutex.synchronize(&block)
          end

          def mutex = (@mutex ||= Mutex.new)
          def lock = self
          def find_by(id:) = rows.find { |row| row.id == id }
          def find(id) = find_by(id:)
          def where(**filters) = Scope.new(rows).where(**filters)
        end
      end

      class SignupTable
        class << self
          attr_accessor :rows
          def lock = self
          def find_by(id:) = rows.find { |row| row.id == id }
          def where(**filters) = Scope.new(rows).where(**filters)
        end
      end

      class AttendanceTable
        SOURCES = %w(operator qr).freeze
        STATUSES = %w(confirmed absent).freeze
        class << self
          attr_accessor :rows
          def find_by(opportunity:, user:, work_date:)
            rows.find { |row| row.opportunity == opportunity && row.user == user && row.work_date == work_date }
          end
          def create!(**attributes)
            row = Attendance.new(status: attributes.fetch(:status), work_date: attributes.fetch(:work_date),
                                 opportunity: attributes.fetch(:opportunity), user: attributes.fetch(:user))
            rows << row
            row
          end
        end
      end

      class Authorization
        def self.allowed?(user, permission, organization:, resource: nil)
          user&.organization == organization && user.permissions.include?(permission.to_s)
        end
      end

      class Audit
        class << self
          attr_accessor :events
          def record!(**attributes) = events << attributes
        end
      end

      class Notifications
        class << self
          attr_accessor :events
          def publish(**attributes) = events << attributes
        end
      end

      def setup
        @org = Organization.new(1)
        @other_org = Organization.new(2)
        @reviewer = User.new(id: 10, organization: @org,
                             permissions: %w(volunteering_application_review volunteering_attendance_confirm))
        @opportunity = Opportunity.new(id: 77, organization: @org, capacity: 1)
        OpportunityTable.rows = [@opportunity]
        SignupTable.rows = []
        AttendanceTable.rows = []
        Audit.events = []
        Notifications.events = []
      end

      def test_competing_approvals_allocate_one_last_seat_and_one_approved_waitlist_position
        first = add_signup(1)
        second = add_signup(2)

        with_collaborators do
          results = [first, second].map do |signup|
            Thread.new { ReviewVolunteerApplication.call(signup, reviewer: @reviewer, decision: "approve", at: NOW) }
          end.map(&:value)

          assert_equal [:approved_place, :approved_waitlist], results.map(&:status).sort
          assert_equal 1, @opportunity.signups.going.count
          assert_equal 1, @opportunity.signups.approved_waitlist.count
          assert_equal 2, Audit.events.count { |event| event[:event_type].start_with?("volunteering_application_approved") }
        end
      end

      def test_capacity_promotes_by_original_queue_time_despite_later_edits
        newer = add_signup(1, status: "waitlisted", review_status: "approved", queued_at: NOW - 2.hours)
        older = add_signup(2, status: "waitlisted", review_status: "approved", queued_at: NOW - 3.hours)
        newer.updated_at = NOW - 1.day
        older.updated_at = NOW

        with_collaborators do
          promoted = Time.stub(:current, NOW) { VolunteerSeatAllocator.promote!(@opportunity) }
          assert_equal [older], promoted
          assert older.going?
          assert newer.waitlisted?
          assert_nil older.queued_at
        end
      end

      def test_rolling_first_session_allows_review_after_programme_start_but_closes_after_agreed_session
        @opportunity.starts_at = NOW - 10.days
        @opportunity.ends_at = NOW + 20.days
        future = add_signup(1, first_session_at: NOW + 2.days)
        overdue = add_signup(2, first_session_at: NOW - 1.minute)

        with_collaborators do
          assert_equal :approved_place,
                       ReviewVolunteerApplication.call(future, reviewer: @reviewer, decision: "approve", at: NOW).status
          result = ReviewVolunteerApplication.call(overdue, reviewer: @reviewer, decision: "approve", at: NOW)
          assert_equal :closed, result.status
          assert_equal "closed", overdue.review_status
          assert overdue.cancelled?
          assert_equal NOW, overdue.participation_ended_at
        end
      end

      def test_application_decision_requires_organization_and_review_permission
        signup = add_signup(1)
        outsider = User.new(id: 20, organization: @other_org, permissions: %w(volunteering_application_review))
        unprivileged = User.new(id: 21, organization: @org, permissions: [])

        with_collaborators do
          [outsider, unprivileged].each do |actor|
            assert_equal :invalid, ReviewVolunteerApplication.call(signup, reviewer: actor,
                                                                    decision: "approve", at: NOW).status
          end
          assert signup.pending?
          assert_empty Audit.events
          assert_empty Notifications.events
        end
      end

      def test_attendance_refuses_future_or_cancelled_participation_and_wrong_permission
        signup = add_signup(1, status: "going", review_status: "approved")
        date = NOW.in_time_zone("Europe/Sarajevo").to_date
        with_collaborators do
          assert_equal :invalid, ConfirmVolunteerAttendance.call(signup, confirmer: @reviewer,
                                                                 work_date: date, at: NOW).status
          @opportunity.starts_at = NOW - 1.day
          @opportunity.cancelled = true
          assert_equal :invalid, ConfirmVolunteerAttendance.call(signup, confirmer: @reviewer,
                                                                 work_date: date, at: NOW).status
          @opportunity.cancelled = false
          unauthorized = User.new(id: 11, organization: @other_org, permissions: %w(volunteering_attendance_confirm))
          assert_equal :invalid, ConfirmVolunteerAttendance.call(signup, confirmer: unauthorized,
                                                                 work_date: date, at: NOW).status
          assert_empty AttendanceTable.rows
        end
      end

      def test_dated_attendance_is_idempotent_and_requires_approved_participation
        @opportunity.starts_at = NOW - 1.day
        signup = add_signup(1, status: "going", review_status: "pending", review_source: "legacy_auto")
        date = NOW.in_time_zone("Europe/Sarajevo").to_date
        with_collaborators do
          assert_equal :invalid, ConfirmVolunteerAttendance.call(signup, confirmer: @reviewer,
                                                                 work_date: date, at: NOW).status
          signup.review_status = "approved"
          first = ConfirmVolunteerAttendance.call(signup, confirmer: @reviewer, work_date: date, at: NOW)
          again = ConfirmVolunteerAttendance.call(signup, confirmer: @reviewer, work_date: date, at: NOW)
          assert_equal :confirmed, first.status
          assert_equal :already, again.status
          assert_equal 1, AttendanceTable.rows.size
          assert_equal 1, Audit.events.count { |event| event[:event_type] == "volunteering_dated_attendance_confirmed" }
        end
      end

      def test_scoped_legacy_sweep_preserves_six_seats_and_historical_attendance_without_notifications
        @opportunity.capacity = 6
        six = (1..6).map do |id|
          add_signup(id, status: "going", review_status: "automatic", review_source: "legacy_auto",
                     attendance_confirmed_at: id == 1 ? NOW - 1.day : nil)
        end
        other = Opportunity.new(id: 78, organization: @other_org)
        OpportunityTable.rows << other
        outsider = Signup.new(id: 7, organization: @other_org, opportunity: other,
                             user: User.new(id: 7, organization: @other_org, permissions: []),
                             status: "going", review_status: "automatic", review_source: "legacy_auto")
        other.signups_rows << outsider
        SignupTable.rows << outsider

        with_collaborators do
          preview = ReconcileLegacyVolunteerApplications.preview(organization: @org)
          assert_equal [6, 6, 0, 1], [preview.candidates, preview.going, preview.waitlisted,
                                      preview.historical_attendance]
          assert_equal 6, ReconcileLegacyVolunteerApplications.apply!(organization: @org, actor: @reviewer)
          assert_equal 0, ReconcileLegacyVolunteerApplications.apply!(organization: @org, actor: @reviewer)
          assert_equal 6, @opportunity.signups.going.count
          assert six.all? { |signup| signup.review_status == "pending" && signup.review_source == "legacy_auto" }
          assert_equal NOW - 1.day, six.first.attendance_confirmed_at
          assert_equal "automatic", outsider.review_status
          assert_empty Notifications.events
          assert_equal 6, Audit.events.count { |event| event[:event_type] == "volunteering_legacy_application_marked_for_review" }
        end
      end

      private

      def add_signup(id, status: "pending", review_status: "pending", review_source: "application",
                     first_session_at: nil, attendance_confirmed_at: nil, queued_at: nil)
        user = User.new(id:, organization: @org, permissions: [])
        signup = Signup.new(id:, organization: @org, opportunity: @opportunity, user:, status:, review_status:,
                            review_source:, first_session_at:, attendance_confirmed_at:, queued_at:)
        @opportunity.signups_rows << signup
        SignupTable.rows << signup
        signup
      end

      def with_collaborators(&block)
        swap(:VolunteerOpportunity, OpportunityTable) do
          swap(:VolunteerSignup, SignupTable) do
            swap(:VolunteerAttendance, AttendanceTable) do
              swap(:OperatorAuthorization, Authorization) do
                swap(:OperatorAuditEvent, Audit) do
                  swap(:VolunteerNotifications, Notifications, &block)
                end
              end
            end
          end
        end
      end

      def swap(name, replacement)
        parent = Decidim::Bih
        original = parent.const_get(name, false) if parent.const_defined?(name, false)
        parent.send(:remove_const, name) if parent.const_defined?(name, false)
        parent.const_set(name, replacement)
        yield
      ensure
        parent.send(:remove_const, name) if parent.const_defined?(name, false)
        parent.const_set(name, original) if original
      end
    end
  end
end
