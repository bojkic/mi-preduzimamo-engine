# frozen_string_literal: true

require "digest"
require "stringio"

module Decidim
  module Bih
    module ReportMailbox
      class Ingest
        MAX_BYTES = 25.megabytes
        BATCH_SIZE = 100
        def initialize(organization:, adapter: ImapAdapter.new)
          @organization, @adapter = organization, adapter
        end
        def call
          counts = { stored: 0, oversized: 0, skipped_existing: 0 }
          account = Decidim::Bih.report_reply_mailbox.to_s.strip.downcase
          raise Config::Invalid, "Mailbox identity missing" if account.empty?
          @lock_key = Digest::SHA256.hexdigest("report-mailbox:#{account.downcase}")[0, 15].to_i(16)
          @connection = ActiveRecord::Base.connection
          @connection.execute("SELECT pg_advisory_lock(#{@lock_key})")
          @cursor = MailboxCursor.find_or_create_by!(organization: @organization, account:) { |c| c.folder = "All" }
          opened = @adapter.open
          # A cursor row lock serializes readers of the same account without
          # allowing one cursor advance to skip another process's uncommitted rows.
          @cursor.with_lock do
            @cursor.update!(uidvalidity: opened[:uidvalidity], folder: opened[:folder], last_uid: 0) if @cursor.uidvalidity != opened[:uidvalidity]
            @cursor.update!(last_polled_at: Time.current)
            @adapter.headers_after(@cursor.last_uid, limit: BATCH_SIZE).each do |metadata|
              begin
                email = InboundEmail.transaction(requires_new: true) { store(metadata, opened, counts) }
              rescue ActiveRecord::RecordNotUnique
                counts[:skipped_existing] += 1
                email = nil
              end
              @cursor.update!(last_uid: metadata.fetch(:uid))
              ActiveRecord.after_all_transactions_commit { ReportMailboxProcessJob.perform_later(email.id) } if email&.state == "stored"
            end
            @cursor.update!(last_success_at: Time.current, last_error_class: nil, consecutive_failures: 0)
          end
          counts
        rescue StandardError => error
          @cursor&.reload&.with_lock { @cursor.update!(last_polled_at: Time.current, last_error_class: error.class.name, consecutive_failures: @cursor.consecutive_failures + 1) }
          raise
        ensure
          @adapter.close
          @connection&.execute("SELECT pg_advisory_unlock(#{@lock_key})") if @lock_key
        end
        def import_history!(raw:)
          target = Target.resolve!
          raise Config::Invalid, "Mailbox organization mismatch" unless target.organization == @organization
          raise Config::Invalid, "Invalid history file size" unless raw.is_a?(String) && raw.bytesize.positive? && raw.bytesize <= MAX_BYTES
          digest = Digest::SHA256.hexdigest(raw)
          identity = "manual-history:#{digest}"
          metadata = { uid: digest.first(15).to_i(16) + 1, gm_msgid: identity, size: raw.bytesize, internal_date: Time.current }
          email = InboundEmail.transaction(requires_new: true) do
            store(metadata, { folder: "manual-history", uidvalidity: 1 }, { stored: 0, oversized: 0, skipped_existing: 0 },
              account: target.account, raw:, force_history: true)
          end
          email ||= InboundEmail.find_by!(organization: @organization, account: target.account, gm_msgid: identity)
          ProcessMessage.new(email).call if email.state == "stored"
          email.reload
        rescue ActiveRecord::RecordNotUnique
          InboundEmail.find_by!(organization: @organization, account: target.account, gm_msgid: identity)
        end

        private
        def store(metadata, opened, counts, account: @cursor.account, raw: nil, force_history: false)
          existing = InboundEmail.find_by(organization: @organization, account:, gm_msgid: metadata.fetch(:gm_msgid).to_s)
          if existing
            counts[:skipped_existing] += 1
            return nil
          end
          history = force_history || @cursor.activation_at.nil? || metadata.fetch(:internal_date) < @cursor.activation_at
          attrs = { organization: @organization, account:, folder: opened[:folder], uidvalidity: opened[:uidvalidity],
                    uid: metadata.fetch(:uid), gm_msgid: metadata.fetch(:gm_msgid).to_s, gm_thrid: metadata[:gm_thrid],
                    labels: metadata.fetch(:labels, []), internal_date: metadata.fetch(:internal_date), size_bytes: metadata.fetch(:size),
                    history_only: history, history_reason: force_history ? "manual_import" : (history ? "pre_activation" : nil) }
          if metadata.fetch(:size) > MAX_BYTES
            counts[:oversized] += 1
            return InboundEmail.create!(**attrs, state: "review", review_reason: "oversized")
          end
          raw ||= @adapter.body(metadata.fetch(:uid))
          begin
            mail = Mail.read_from_string(raw)
            raise ArgumentError, "Missing mail envelope" if Array(mail.from).empty?
            sender = mail.from.first.to_s.downcase
            digest = Digest::SHA256.hexdigest(raw)
            if !attrs[:history_only] && InboundEmail.where(organization: @organization, account:, history_only: true, content_digest: digest).exists?
              attrs.merge!(history_only: true, history_reason: "known_history_content")
            end
            conflict = mail.message_id.present? && InboundEmail.where(organization: @organization, message_id: mail.message_id).where.not(content_digest: digest).exists?
            email = InboundEmail.create!(**attrs, raw:, subject: mail.subject.to_s, body_text: ReplyText.new_part(mail),
              message_id: mail.message_id, in_reply_to: Array(mail.in_reply_to).first, references: Array(mail.references),
              from_digest: ReplyAddress.digest_address(sender), from_domain: sender.split("@", 2).last,
              authentication: GoogleAuthentication.parse(mail), content_digest: digest, message_id_conflict: conflict,
              file_numbers: FileNumbers.scan(ReplyText.new_part(mail)))
            mail.attachments.each_with_index do |attachment, index|
              bytes = attachment.body.decoded
              next if bytes.bytesize > CitizenReply::MAX_FILE_BYTES
              type = Marcel::MimeType.for(StringIO.new(bytes))
              next unless CitizenReply::CONTENT_TYPES.include?(type) && type == attachment.mime_type
              extension = type == "application/pdf" ? ".pdf" : Media::ImageNormalizer::EXTENSION_FOR.fetch(type)
              email.attachments.attach(io: StringIO.new(bytes), filename: "mail-#{index}#{extension}", content_type: type)
            end
            counts[:stored] += 1
            email
          rescue Mail::Field::ParseError, ArgumentError, EncodingError
            InboundEmail.create!(**attrs, state: "review", review_reason: "malformed")
          end
        end
      end
    end
  end
end
