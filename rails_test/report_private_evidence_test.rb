# frozen_string_literal: true

require "test_helper"
require "timeout"

module Decidim
  module Bih
    module RailsHarness
      class ReportPrivateEvidenceTest < ActiveSupport::TestCase
        self.use_transactional_tests = false

        setup do
          @organization = create_organization
          @reports = []
          @blobs = []
          @threads = []
          @report = make_report
          @source = make_blob
        end

        teardown do
          @threads.each { |thread| thread.kill if thread.alive? }
          @threads.each(&:join)
          items = ReportEvidenceItem.where(report: @reports)
          items.each do |item|
            @blobs << item.blob if item.blob
            @blobs << item.private_file.blob if item.private_file.attached?
            item.private_file.detach
          end
          ReportDispatchEvidence.where(evidence_item: items).delete_all
          ReportEvidenceShare.where(evidence_item: items).delete_all
          ReportDispatch.where(report: @reports).delete_all
          items.delete_all
          @reports.each do |report|
            report.photo.detach
            ReportObligation.where(report:).delete_all
            ReportEvent.where(report:).delete_all
            report.destroy!
          end
          @blobs.compact.uniq(&:id).each(&:purge)
          Decidim::StaticPage.where(organization: @organization, slug: Decidim::StaticPage::DEFAULT_PAGES).delete_all
          @organization.destroy!
        end

        def make_report
          Report.create!(organization: @organization, description: "Synthetic private evidence", address: "Synthetic crossing").tap { |report| @reports << report }
        end

        def make_blob
          ActiveStorage::Blob.create_and_upload!(io: StringIO.new("synthetic identical evidence"), filename: "evidence.pdf", content_type: "application/pdf").tap { |blob| @blobs << blob }
        end

        test "evidence attachment declaration defers optional storage but actual copying never falls back" do
          selector = ReportEvidenceItem.reflect_on_attachment(:private_file).options.fetch(:service_name)
          assert_kind_of Proc, selector
          before = ActiveStorage::Blob.count
          ActiveStorage::Blob.stub(:services, {}) do
            optional_model = Class.new(ApplicationRecord) do
              self.table_name = "decidim_bih_report_evidence_items"
              has_one_attached :private_file, service: selector
            end
            assert_equal selector, optional_model.reflect_on_attachment(:private_file).options.fetch(:service_name)
            assert_raises(ReportPrivateStorage::Unavailable) { selector.call(ReportEvidenceItem.new) }
            assert_raises(ReportPrivateStorage::Unavailable) { ReportPrivateStorage.copy_private!(@source) }
          end
          assert_equal before, ActiveStorage::Blob.count
          assert_equal "synthetic identical evidence", @source.download
        end

        test "public original is copied to owned encrypted evidence without changing public bytes" do
          item = ReportEvidenceItem.register!(report: @report, blob: @source, source: "original")
          refute_equal @source.id, item.blob_id
          assert ReportPrivateStorage.private?(item.blob)
          assert_equal @source.checksum, item.checksum
          assert_equal @source.byte_size, item.byte_size
          assert_equal @source.download, item.blob.download
          assert_equal item.blob_id, item.private_file.blob.id
          refute_includes ActiveStorage::Blob.unattached.pluck(:id), item.blob_id
          refute ReportPrivateStorage.private?(@source)
          assert_equal "synthetic identical evidence", @source.reload.download
        end

        test "ownership repair aligns a mismatched attachment without deleting another owner" do
          item = ReportEvidenceItem.register!(report: @report, blob: @source, source: "original")
          other = ReportEvidenceItem.register!(report: make_report, blob: make_blob, source: "original")
          item.private_file.attach(other.blob)
          refute item.owned_private_blob?

          item.ensure_private!

          assert item.reload.owned_private_blob?
          assert_equal item.blob_id, item.private_file.blob_id
          assert other.reload.owned_private_blob?
          assert_equal "synthetic identical evidence", other.blob.download
        end

        test "overlapping registration blocks on the case lock and uploads one owned private blob" do
          uploaded = []
          entered = Queue.new
          release = Queue.new
          waiter_pid = Queue.new
          copy = ReportPrivateStorage.method(:copy_private!)
          ReportPrivateStorage.stub(:copy_private!, lambda { |blob|
            result = copy.call(blob)
            if result.id != blob.id
              uploaded << result.id
              entered << ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()")
              Timeout.timeout(10) { release.pop }
            end
            result
          }) do
            @threads << Thread.new do
              ActiveRecord::Base.connection_pool.with_connection do
                ReportEvidenceItem.register!(report: Report.find(@report.id), blob: ActiveStorage::Blob.find(@source.id), source: "original").id
              end
            end
            owner = Timeout.timeout(10) { entered.pop }
            @threads << Thread.new do
              ActiveRecord::Base.connection_pool.with_connection do
                waiter_pid << ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()")
                ReportEvidenceItem.register!(report: Report.find(@report.id), blob: ActiveStorage::Blob.find(@source.id), source: "original").id
              end
            end
            waiter = Timeout.timeout(10) { waiter_pid.pop }
            Timeout.timeout(10) do
              loop do
                blockers = ActiveRecord::Base.uncached do
                  ActiveRecord::Base.connection.select_value("SELECT pg_blocking_pids(#{Integer(waiter)})::text")
                end
                break if blockers.delete("{}").split(",").map(&:to_i).include?(owner)

                Thread.pass
              end
            end
            release << true
            ids = Timeout.timeout(10) { @threads.map(&:value) }
            assert_equal 1, ids.uniq.size
          end
          assert_equal 1, uploaded.uniq.size
          assert_equal uploaded, ReportEvidenceItem.live.where(report: @report).pluck(:blob_id)
          assert_equal 1, ReportEvidenceItem.live.where(report: @report).count
        end

        test "outer rollback deletes the newly copied bytes and leaves public source intact" do
          copied = nil
          original_copy = ReportPrivateStorage.method(:copy_private!)
          ReportPrivateStorage.stub(:copy_private!, ->(blob) { copied = original_copy.call(blob) }) do
            ReportEvidenceItem.transaction do
              ReportEvidenceItem.register!(report: @report, blob: @source, source: "original")
              raise ActiveRecord::Rollback
            end
          end
          assert_not copied.service.exist?(copied.key)
          assert_empty ReportEvidenceItem.where(report: @report)
          assert_equal "synthetic identical evidence", @source.download
        end

        test "failed registration cleans up copied storage without touching a shared source" do
          copied = nil
          original_copy = ReportPrivateStorage.method(:copy_private!)
          ReportPrivateStorage.stub(:copy_private!, ->(blob) { copied = original_copy.call(blob) }) do
            ReportEvidenceItem.stub(:create!, ->(**_attributes) { raise ActiveRecord::RecordInvalid }) do
              assert_raises(ActiveRecord::RecordInvalid) { ReportEvidenceItem.register!(report: @report, blob: @source, source: "original") }
            end
          end
          refute copied.service.exist?(copied.key)
          assert_equal "synthetic identical evidence", @source.download
          assert_empty ReportEvidenceItem.where(report: @report)
        end

        test "purged original does not resurrect but new citizen upload of same bytes receives a fresh identity" do
          old = ReportEvidenceItem.register!(report: @report, blob: @source, source: "original")
          old.tombstone!
          assert_nil ReportEvidenceItem.register!(report: @report, blob: @source, source: "original")
          fresh_source = make_blob
          fresh = ReportEvidenceItem.register!(report: @report, blob: fresh_source, source: "citizen_message", source_id: 42)
          refute_equal old.id, fresh.id
          assert_equal old.checksum, fresh.checksum
          assert old.reload.purged?
          assert_nil old.blob_id
          refute old.update(source_id: 999), "tombstone source identity remains immutable"
          old.reload
          refute fresh.purged?
          assert fresh.private_file.attached?
          assert_equal [fresh.id], ReportEvidenceItem.live.where(report: @report).pluck(:id)
        end

        test "database permits a null blob only for an explicit retained tombstone" do
          item = ReportEvidenceItem.register!(report: @report, blob: @source, source: "original")
          error = assert_raises(ActiveRecord::StatementInvalid) do
            ReportEvidenceItem.transaction(requires_new: true) do
              ActiveRecord::Base.connection.execute("UPDATE decidim_bih_report_evidence_items SET blob_id = NULL WHERE id = #{Integer(item.id)}")
            end
          end
          assert_instance_of PG::CheckViolation, error.cause
          assert_equal "report_evidence_live_blob_or_tombstone", error.cause.result.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME)
          assert item.reload.blob_id
          item.tombstone!
          assert_nil item.reload.blob_id
        end

        test "private storage conversion preserves the exact old source tombstone boundary" do
          old = ReportEvidenceItem.register!(report: @report, blob: @source, source: "service_mail", source_id: 73)
          old.tombstone!
          converted_source = ReportPrivateStorage.copy_private!(@source)
          @blobs << converted_source
          refute_equal @source.id, converted_source.id
          assert_equal @source.id, ReportPrivateStorage.stable_source_blob_id(converted_source)
          assert_nil ReportEvidenceItem.register!(report: @report, blob: converted_source, source: "service_mail", source_id: 73)
        end

        test "tombstone preserves dispatch evidence identity and revokes private bearer access" do
          item = ReportEvidenceItem.register!(report: @report, blob: @source, source: "original")
          admin = FactoryBot.create(:user, :confirmed, :admin, organization: @organization)
          dispatch = ReportDispatch.create!(report: @report, approved_by: admin, kind: "initial", state: "accepted", input_digest: "fixture", deduplication_key: SecureRandom.uuid,
                                            message_id: "<private-evidence@fixtures.invalid>",
                                            snapshot: { "to" => ["service@fixtures.invalid"], "body" => "Synthetic evidence", "attachments" => [] })
          join = ReportDispatchEvidence.create!(dispatch:, evidence_item: item)
          share = ReportEvidenceShare.issue!(evidence_item: item, dispatch:, recipient: "service@fixtures.invalid")
          token = share.token
          item.tombstone!
          assert_equal item.id, join.reload.evidence_item_id
          assert_equal @source.checksum, item.reload.checksum
          assert_nil ReportEvidenceShare.resolve(token)
          assert share.reload.revoked_at
          assert_nil item.blob_id
        end

        test "cleanup recovers after detach and blob row destruction before physical delete" do
          item = ReportEvidenceItem.register!(report: @report, blob: @source, source: "original")
          private_blob = item.blob
          item.stub(:enqueue_purge, nil) { item.tombstone! }
          private_blob.service.stub(:delete, lambda { |_key|
            refute ActiveRecord::Base.connection.transaction_open?, "physical deletion must follow committed ownership changes"
            raise IOError, "synthetic delete interruption"
          }) do
            assert_raises(IOError) { ReportEvidencePurgeJob.new.perform(item.id) }
          end
          refute item.reload.private_file.attached?
          refute ActiveStorage::Blob.exists?(private_blob.id)
          assert private_blob.service.exist?(private_blob.key)
          assert item.purge_descriptor_ciphertext.present?
          assert_nil item.purge_completed_at
          ReportEvidencePurgeJob.new.perform(item.id)
          refute private_blob.service.exist?(private_blob.key)
          assert item.reload.purge_completed_at
          assert_nil item.purge_descriptor_ciphertext
          assert_equal "synthetic identical evidence", @source.download
        end

        test "retention dry run preserves bytes and apply purges an expired copy without touching the public source" do
          expired = nil
          travel_to 3.days.ago do
            expired_report = Report.create!(organization: @organization, description: "Expired synthetic evidence", address: "Synthetic crossing", status: "rijeseno")
            @reports << expired_report
            expired = ReportEvidenceItem.register!(report: expired_report, blob: @source, source: "original")
          end
          private_blob = expired.blob
          collector = Privacy::ReportEvidenceRetention.new(organization: @organization, cutoff: 1.day.ago, dry_run: true)
          assert_equal 1, collector.call
          refute expired.reload.purged?
          assert_equal "synthetic identical evidence", private_blob.download
          assert_equal 1, Privacy::ReportEvidenceRetention.new(organization: @organization, cutoff: 1.day.ago, dry_run: false).call
          assert expired.reload.purged?
          ReportEvidencePurgeJob.new.perform(expired.id)
          refute private_blob.service.exist?(private_blob.key)
          assert expired.reload.purge_completed_at
          assert_equal "synthetic identical evidence", @source.reload.download
        end

        test "retention recovers committed tombstone before enqueue and cannot purge a fresh shared owner" do
          old = ReportEvidenceItem.register!(report: @report, blob: @source, source: "original")
          shared = ReportEvidenceItem.register!(report: make_report, blob: old.blob, source: "citizen_message", source_id: 7)
          assert_equal old.blob_id, shared.blob_id
          old.stub(:enqueue_purge, nil) { old.tombstone! }
          assert old.reload.private_file.attached?, "simulated crash left durable attachment intent"
          captured = []
          ReportEvidencePurgeJob.stub(:perform_later, ->(id) { captured << id }) do
            Privacy::ReportEvidenceRetention.new(organization: @organization, cutoff: 1.day.ago, dry_run: false).call
          end
          assert_includes captured, old.id
          ReportEvidencePurgeJob.new.perform(old.id)
          refute old.reload.private_file.attached?
          assert shared.reload.private_file.attached?
          assert_equal "synthetic identical evidence", shared.blob.download
          ReportEvidencePurgeJob.new.perform(old.id)
          ReportEvidencePurgeJob.new.perform(shared.id)
          assert_equal "synthetic identical evidence", shared.reload.blob.download
          assert_equal "synthetic identical evidence", @source.reload.download
        end
      end
    end
  end
end
