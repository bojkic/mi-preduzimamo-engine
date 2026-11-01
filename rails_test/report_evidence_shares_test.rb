# frozen_string_literal: true
require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class ReportEvidenceSharesTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @admin = FactoryBot.create(:user, :confirmed, :admin, organization: @organization)
          @report = Report.create!(organization: @organization, description: 'Prilog', address: 'Ulica 1')
          @blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('bytes'), filename: 'proof.pdf', content_type: 'application/pdf')
          @item = ReportEvidenceItem.register!(report: @report, blob: @blob, source: 'original')
          @dispatch = ReportDispatch.create!(report: @report, approved_by: @admin, kind: 'initial', state: 'accepted', input_digest: 'fixture', deduplication_key: SecureRandom.uuid, message_id: '<share@example.org>', snapshot: { 'to' => ['service@example.org'], 'body' => 'Fixture', 'attachments' => [] })
        end
        test '136-bit token resolves only the bound file and expires or revokes to no match' do
          share = ReportEvidenceShare.issue!(evidence_item: @item, dispatch: @dispatch, recipient: 'service@example.org')
          assert_match(/\A[a-f0-9]{34}\z/, share.token)
          assert_equal @item.id, ReportEvidenceShare.resolve(share.token).evidence_item_id
          refute_includes share.token, @report.status_token
          share.update!(expires_at: 1.minute.ago)
          assert_nil ReportEvidenceShare.resolve(share.token)
          share.update!(expires_at: 1.day.from_now)
          share.revoke!
          assert_nil ReportEvidenceShare.resolve(share.token)
        end
        test "large evidence links use the public mount exactly once" do
          recipient = "service@example.org"
          ReportServiceSender.create!(organization: @organization, email: recipient, label: "Synthetic approved service")
          request = InboundEmail.create!(organization: @organization, account: "synthetic", folder: "all",
                                         gm_msgid: SecureRandom.uuid, uidvalidity: 1, uid: 1, size_bytes: 32, internal_date: Time.current,
                                         from_digest: Digest::SHA256.hexdigest(recipient), classification: "candidate")
          InboundEmailLink.create!(report: @report, inbound_email: request, matching_method: "capability", assurance: "capability")
          bytes = "%PDF-1.7\n#{"x" * ReportEvidence::MAX_MAIL_BYTES}\n%%EOF"
          blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: "large.pdf", content_type: "application/pdf")
          item = ReportEvidenceItem.register!(report: @report, blob:, source: "original")
          assessment = { "state" => "suitable", "observation_codes" => ["document_present"],
                         "sensitive_presence" => ReportEvidenceItem::SENSITIVE_FLAGS.index_with { "absent" },
                         "matched_request_indexes" => [0] }
          item.update!(assessment: Ai::EvidenceAssessment.normalize_result(assessment, requests: ["document"]))
          arguments = { report: @report, evidence_item_ids: [item.id], recipient:, request_source: request }

          prepared = ReportEvidence.prepare_service_evidence!(**arguments)
          assert_empty prepared[:attachments]
          share = ReportEvidenceShare.find_by!(evidence_item: item, request_source: request)
          uri = URI.parse(prepared[:links].sole.fetch(:url))
          assert_equal "https", uri.scheme
          assert_equal @organization.host, uri.host
          assert_equal Engine.routes.url_helpers.service_evidence_share_path(token: share.token), uri.path
          assert_equal 1, uri.path.scan(Decidim::Bih.public_mount_path).size
          assert_equal item, ReportEvidenceShare.resolve(share.token).evidence_item
          assert_equal prepared, ReportEvidence.service_evidence(**arguments)
          assert_equal 1, ReportEvidenceShare.where(evidence_item: item, request_source: request).count
        end

        test "invalid and tampered tokens expose no evidence" do
          assert_nil ReportEvidenceShare.resolve('x' * 34)
          assert_nil ReportEvidenceShare.resolve(SecureRandom.hex(17))
        end
        test "service shares must bind the exact dispatch recipient and case" do
          share = ReportEvidenceShare.new(token_digest: 'digest', token_ciphertext: 'ciphertext', recipient_digest: 'unknown', expires_at: 30.days.from_now)
          refute share.valid?
          assert share.errors[:dispatch].present?
        end
      end
    end
  end
end
