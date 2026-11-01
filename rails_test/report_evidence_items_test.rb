# frozen_string_literal: true
require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class ReportEvidenceItemsTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @report = Report.create!(organization: @organization, description: 'Kontejner kod ulaza', address: 'Ulica 1')
          @blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('fixture bytes'), filename: 'fixture.jpg', content_type: 'image/jpeg')
        end
        test "the same bytes have one evidence identity in a case" do
          first = ReportEvidenceItem.register!(report: @report, blob: @blob, source: 'original')
          second = ReportEvidenceItem.register!(report: @report, blob: @blob, source: 'citizen_message', source_id: 7)
          assert_equal first.id, second.id
        end
        test "positive assessment and no sensitive flag required for automatic handoff" do
          item = ReportEvidenceItem.register!(report: @report, blob: @blob, source: 'original')
          refute item.automatic_handoff?
          result = { 'state' => 'suitable', 'observation_codes' => ['container_damage'],
            'sensitive_presence' => ReportEvidenceItem::SENSITIVE_FLAGS.index_with { 'absent' }, 'matched_request_indexes' => [] }
          item.update!(assessment: Ai::EvidenceAssessment.normalize_result(result, requests: []))
          assert item.automatic_handoff?
          item.update!(sensitive_flags: ['plate_visible'])
          refute item.automatic_handoff?
        end
        class AssessmentMeter
          attr_reader :calls
          def initialize(result)
            @result = result
            @calls = []
          end
          def call(**arguments)
            @calls << arguments
            @result.deep_dup
          end
        end
        def assess_payload(payload, requests: ['fotografiju'])
          Setting.put(@organization, 'report_review', 'attachment_assessment', true)
          item = ReportEvidenceItem.register!(report: @report, blob: @blob, source: 'original')
          meter = AssessmentMeter.new(payload)
          result = Ai::EvidenceAssessment.new(client: Object.new, usage: meter).call(item, requests:)
          [item.reload, result, meter]
        end
        def safe_payload
          { 'state' => 'suitable', 'observation_codes' => ['container_damage'],
            'sensitive_presence' => ReportEvidenceItem::SENSITIVE_FLAGS.index_with { 'absent' }, 'matched_request_indexes' => [0] }
        end
        test 'coded nonidentifying assessment renders on server and preserves automatic evidence matching' do
          item, result, meter = assess_payload(safe_payload)
          assert_equal ['fotografiju'], result['request_matches']
          assert_equal ['Vidljivo je oštećenje kontejnera.'], result['observations']
          assert item.automatic_handoff?
          assert_equal 'attachment', meter.calls.first[:purpose]
          assert_equal 1024, meter.calls.first[:generation_limits][:max_output_tokens]
        end
        test 'arbitrary names plate identities and face description strings are rejected' do
          ['Petar Petrović', 'A12-E-345', 'Vidljivo je lice osobe.'].each do |identity|
            payload = safe_payload.merge('observation_codes' => [identity])
            item, result = assess_payload(payload)
            assert_equal 'uncertain', result['state']
            refute item.automatic_handoff?
            refute_includes item.assessment_for_context.to_json, identity
          end
          item, result = assess_payload(safe_payload.merge('observations' => ['Petar Petrović']))
          assert_equal 'invalid_assessment', result['reason']
          refute item.automatic_handoff?
        end
        test 'requested plate visibility is assessed without transcribing its identity and remains staff only' do
          payload = safe_payload.merge('observation_codes' => ['vehicle_present', 'plate_visible'],
            'sensitive_presence' => ReportEvidenceItem::SENSITIVE_FLAGS.index_with { |flag| flag == 'plate_visible' ? 'visible' : 'absent' })
          item, result = assess_payload(payload, requests: ['fotografiju vozila sa vidljivom tablicom'])
          assert_equal 'suitable', result['state']
          assert_equal ['fotografiju vozila sa vidljivom tablicom'], result['request_matches']
          assert_equal ['plate_visible'], item.sensitive_flags
          refute item.automatic_handoff?
          refute_includes result.to_json, 'A12-E-345'
        end
        test 'contradictory and uncertain sensitive presence cannot enter automatic handoff' do
          payload = safe_payload.merge('observation_codes' => ['face_visible'])
          item, result = assess_payload(payload)
          assert_equal 'contradictory_sensitive_presence', result['reason']
          assert_equal ['face_visible'], item.sensitive_flags
          refute item.automatic_handoff?
          payload = safe_payload.deep_dup
          payload['sensitive_presence']['document_personal_data'] = 'uncertain'
          item, result = assess_payload(payload)
          assert_equal 'uncertain', result['state']
          assert_includes item.sensitive_flags, 'document_personal_data'
          refute item.automatic_handoff?
        end
        test 'old free text assessments neither authorize handoff nor leak into new model context' do
          item = ReportEvidenceItem.register!(report: @report, blob: @blob, source: 'original')
          item.update!(assessment: { 'state' => 'suitable', 'observations' => ['Petar Petrović'] })
          refute item.automatic_handoff?
          refute_includes item.assessment_for_context.to_json, 'Petar Petrović'
        end
        test "unsupported evidence becomes uncertain without a model call" do
          item = ReportEvidenceItem.register!(report: @report, blob: @blob, source: 'original')
          item.update!(content_type: 'text/html')
          result = Ai::EvidenceAssessment.new.call(item)
          assert_equal 'uncertain', result['state']
        end
      end
    end
  end
end
