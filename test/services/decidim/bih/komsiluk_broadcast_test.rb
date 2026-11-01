# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    unless const_defined?(:ChunkedBellJob, false)
      class ChunkedBellJob
        CHUNK_SIZE = 50
      end
      TEST_DEFINED_CHUNKED_BELL_JOB = true
    end
  end
end

require_relative "../../../../app/services/decidim/bih/komsiluk_broadcast"

module Decidim
  module Bih
    remove_const(:ChunkedBellJob) if const_defined?(:TEST_DEFINED_CHUNKED_BELL_JOB, false)
    remove_const(:TEST_DEFINED_CHUNKED_BELL_JOB) if const_defined?(:TEST_DEFINED_CHUNKED_BELL_JOB, false)

    class KomsilukBroadcastTest < Minitest::Test
      Organization = Struct.new(:id, keyword_init: true)
      Admin = Struct.new(:id, keyword_init: true)
      Area = Struct.new(:id, :kind, :translated_name, keyword_init: true)
      BroadcastRecord = Struct.new(:attributes, keyword_init: true) do
        def id = 123
      end

      class BroadcastModel
        MAX_MESSAGE_LENGTH = 20

        class << self
          attr_reader :created_records, :events

          def reset!
            @created_records = []
            @events = []
          end

          def create!(attributes)
            @events << :create
            @created_records << attributes
            BroadcastRecord.new(attributes:)
          end
        end
      end

      class NotificationJob
        class << self
          attr_reader :payloads, :events

          def reset!
            @payloads = []
            @events = []
          end

          def perform_later(**payload)
            @events << :enqueue
            @payloads << payload
          end

          def name
            "Decidim::Bih::BroadcastNotificationJob"
          end
        end
      end

      class Resolver
        class << self
          attr_reader :calls, :recipient_calls

          def reset!(recipient_ids)
            @recipient_ids = recipient_ids
            @calls = []
            @recipient_calls = []
          end

          def for_komsiluk(organization:, komsiluk_id:)
            @calls << [:for_komsiluk, { organization:, komsiluk_id: }]
            new(@recipient_ids)
          end

          def for_mz(organization:, mz_area:)
            @calls << [:for_mz, { organization:, mz_area: }]
            new(@recipient_ids)
          end
        end

        def initialize(recipient_ids)
          @recipient_ids = recipient_ids
        end

        def recipient_ids(**options)
          self.class.recipient_calls << options
          @recipient_ids
        end
      end

      def setup
        @organization = Organization.new(id: 7)
        @admin = Admin.new(id: 99)
        @komsiluk = Area.new(id: 15, kind: "komsiluk", translated_name: "Centar")
        @mz = Area.new(id: 3, kind: "mz", translated_name: "MZ Centar")
        BroadcastModel.reset!
        NotificationJob.reset!
        Resolver.reset!([1, 2, 3])
      end

      def test_preview_returns_aggregate_count_without_audit_record_or_jobs
        result = with_collaborators do
          KomsilukBroadcast.preview(
            organization: @organization,
            area: @komsiluk,
            message: " Pozdrav ",
            channels: ["bell"],
            sent_by: @admin
          )
        end

        assert_equal({ recipients_count: 3 }, result)
        assert_empty BroadcastModel.created_records
        assert_empty NotificationJob.payloads
        assert_equal [[:for_komsiluk, { organization: @organization, komsiluk_id: 15 }]], Resolver.calls
        assert_equal [{ exclude_user_id: nil, honor_opt_out: false }], Resolver.recipient_calls
      end

      def test_mz_area_uses_mz_membership_resolver
        with_collaborators do
          KomsilukBroadcast.preview(
            organization: @organization,
            area: @mz,
            message: "Pozdrav",
            channels: ["bell"],
            sent_by: @admin
          )
        end

        assert_equal [[:for_mz, { organization: @organization, mz_area: @mz }]], Resolver.calls
      end

      def test_call_creates_audit_record_before_enqueueing_jobs
        Resolver.reset!((1..51).to_a)

        result = with_collaborators do
          KomsilukBroadcast.call(
            organization: @organization,
            area: @komsiluk,
            message: "  #{"a" * 40}  ",
            channels: ["bell", :viber, "viber"],
            sent_by: @admin
          )
        end

        assert_instance_of BroadcastRecord, result[:broadcast]
        assert_equal 51, result[:recipients_count]
        assert_equal [:create], BroadcastModel.events
        assert_equal [:enqueue, :enqueue], NotificationJob.events
        assert_equal "a" * BroadcastModel::MAX_MESSAGE_LENGTH, BroadcastModel.created_records.first[:message]
        assert_equal "bell,viber", BroadcastModel.created_records.first[:channels]
      end

      def test_call_enqueues_recipient_chunks_without_private_content
        Resolver.reset!((1..120).to_a)

        with_collaborators do
          KomsilukBroadcast.call(
            organization: @organization,
            area: @komsiluk,
            message: "Akcija",
            channels: %w(bell viber),
            sent_by: @admin
          )
        end

        assert_equal([50, 50, 20], NotificationJob.payloads.map { |payload| payload[:user_ids].size })
        assert_equal(
          {
            organization_id: 7,
            user_ids: (1..50).to_a,
            broadcast_id: 123
          },
          NotificationJob.payloads.first
        )
      end

      def test_unknown_area_creates_zero_recipient_audit_without_jobs
        unknown = Area.new(id: 22, kind: "park", translated_name: "Park")

        result = with_collaborators do
          KomsilukBroadcast.call(
            organization: @organization,
            area: unknown,
            message: "Akcija",
            channels: ["bell"],
            sent_by: @admin
          )
        end

        assert_equal 0, result[:recipients_count]
        assert_equal 0, BroadcastModel.created_records.first[:recipients_count]
        assert_empty NotificationJob.payloads
        assert_empty Resolver.calls
      end

      private

      def with_collaborators(&)
        with_constant(Decidim::Bih, :Broadcast, BroadcastModel) do
          with_constant(Decidim::Bih, :BroadcastNotificationJob, NotificationJob) do
            ensure_komsiluk_module do |komsiluk_module|
              with_constant(komsiluk_module, :MembershipResolver, Resolver, &)
            end
          end
        end
      end

      def ensure_komsiluk_module
        old_defined = Decidim::Bih.const_defined?(:Komsiluk, false)
        old_value = Decidim::Bih.const_get(:Komsiluk, false) if old_defined
        Decidim::Bih.send(:remove_const, :Komsiluk) if old_defined
        komsiluk_module = Module.new
        Decidim::Bih.const_set(:Komsiluk, komsiluk_module)
        yield komsiluk_module
      ensure
        Decidim::Bih.send(:remove_const, :Komsiluk) if Decidim::Bih.const_defined?(:Komsiluk, false)
        Decidim::Bih.const_set(:Komsiluk, old_value) if old_defined
      end

      def with_constant(parent, name, value)
        old_defined = parent.const_defined?(name, false)
        old_value = parent.const_get(name, false) if old_defined
        parent.send(:remove_const, name) if old_defined
        parent.const_set(name, value)
        yield
      ensure
        parent.send(:remove_const, name) if parent.const_defined?(name, false)
        parent.const_set(name, old_value) if old_defined
      end
    end
  end
end
