# frozen_string_literal: true

require "test_helper"
require "date"
require_relative "../../../../../app/services/decidim/bih/goodwill/idempotency_key"
require_relative "../../../../../app/services/decidim/bih/goodwill/volunteer_daily_awards"

module Decidim
  module Bih
    module Goodwill
      class VolunteerDailyAwardsTest < Minitest::Test
        Person = Struct.new(:id, keyword_init: true) do
          def group? = false
        end
        Claim = Struct.new(:id, :user, :organization, :work_date, :hours, keyword_init: true)
        Award = Struct.new(:organization, :user, :work_date, :active, :version, :transaction_id,
                           keyword_init: true) do
          def active? = active

          def update!(attributes)
            attributes.each { |key, value| self[key] = value }
          end
        end
        Transaction = Struct.new(:id, keyword_init: true)

        class AwardStore
          class << self
            attr_accessor :rows

            def reset! = self.rows = []

            def where(**attributes)
              matches = rows.select { |row| attributes.all? { |key, value| row[key] == value } }
              matches
            end

            def create!(**attributes)
              Award.new(**attributes).tap { |row| rows << row }
            end
          end
        end

        class Ledger
          attr_reader :postings

          def initialize
            @postings = []
          end

          def award(owner, amount, **payload)
            @postings << payload.merge(owner:, amount:)
            Transaction.new(id: @postings.size)
          end
        end

        class Rules
          def points_for(action)
            raise "unexpected action #{action}" unless action == :volunteer_day

            100
          end
        end

        def setup
          AwardStore.reset!
          @ledger = Ledger.new
          @rules = Rules.new
          @user = Person.new(id: 11)
          @organization = Object.new
        end

        def test_two_distinct_claims_on_same_date_pay_one_base_award
          date = Date.new(2026, 10, 25)
          first = claim(1, date, 1)
          second = claim(2, date, 2)

          result = award(first)
          assert_instance_of Transaction, result
          assert_nil award(second)
          assert_equal 1, @ledger.postings.size
          assert_equal 100, @ledger.postings.first.fetch(:amount)
          assert_equal "volunteer_day:11:2026-10-25", @ledger.postings.first.fetch(:idempotency_key)
          assert_equal "volunteer_day", @ledger.postings.first.fetch(:reason)
        end

        def test_new_local_date_pays_again_and_corrected_date_uses_new_version
          date = Date.new(2026, 10, 25)
          award(claim(1, date, 1))
          award(claim(2, date.next_day, 1))
          assert_equal 2, @ledger.postings.size

          AwardStore.rows.first.update!(active: false)
          award(claim(3, date, 1))
          assert_equal "volunteer_day:11:2026-10-25:v2", @ledger.postings.last.fetch(:idempotency_key)
          assert_equal 3, @ledger.postings.size
        end

        private

        def claim(id, date, hours)
          Claim.new(id:, user: @user, organization: @organization, work_date: date, hours:)
        end

        def award(log)
          VolunteerDailyAwards.award_for(log, ledger: @ledger, earning_rules: @rules, award_model: AwardStore)
        end
      end
    end
  end
end
