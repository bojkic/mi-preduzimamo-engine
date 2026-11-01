# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class ReportEvidenceAssessmentJobTest < ActiveSupport::TestCase
        test "legacy observations are recoded once while current uncertain assessments do not retry billable calls" do
          report = Struct.new(:id).new(42)
          item_type = Struct.new(:assessment)
          legacy = item_type.new({ "state" => "suitable", "observations" => ["unreviewed identifier"] })
          current = item_type.new({ "format" => Ai::EvidenceAssessment::FORMAT, "state" => "uncertain" })
          calls = []
          assessor = Object.new
          assessor.define_singleton_method(:call) do |item|
            calls << item
            item.assessment = { "format" => Ai::EvidenceAssessment::FORMAT, "state" => "uncertain" }
          end
          reviews = []
          Report.stub(:find_by, report) do
            ReportWorkQueue.stub(:closed?, false) do
              ReportEvidenceItem.stub(:sync!, [legacy, current]) do
                Ai::EvidenceAssessment.stub(:new, -> { assessor }) do
                  ReportReviewAssistant.stub(:enqueue, ->(value) { reviews << value }) do
                    2.times { ReportEvidenceAssessmentJob.new.perform(report.id) }
                  end
                end
              end
            end
          end
          assert_equal [legacy], calls
          assert_equal [report, report], reviews
          assert_equal Ai::EvidenceAssessment::FORMAT, legacy.assessment["format"]
        end
      end
    end
  end
end
