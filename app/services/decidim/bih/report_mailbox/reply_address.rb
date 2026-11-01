# frozen_string_literal: true

require "securerandom"
require "digest"

module Decidim
  module Bih
    module ReportMailbox
      # Revocable reply capabilities (plan §4.2). The address proves possession of
      # a token we sent to specific correspondents; it never proves identity alone.
      class ReplyAddress
        class Missing < StandardError; end

        ALPHABET = "abcdefghijklmnopqrstuvwxyz234567"
        TOKEN_BYTES = 17
        AUDIENCE_LETTER = { "service" => "s", "citizen" => "c" }.freeze
        PATTERN = /\A(?<local>[^+@\s<>]+)\+(?<letter>[sc])-(?<token>[a-z2-7]{28})@(?<domain>[^>\s]+)\z/

        # The only writer. Call outside any transaction that can roll back
        # (ReportDecision#preview always rolls back).
        def self.ensure!(report:, audience:, correspondents:, question_message: nil)
          return nil if Decidim::Bih.report_reply_mailbox.blank?

          digests = digests_for(correspondents)
          find_active(report, audience, digests, question_message) ||
            create_capability(report, audience, digests, question_message)
        rescue ActiveRecord::RecordNotUnique
          find_active(report, audience, digests, question_message)
        end

        # Read-only; safe inside preview.
        def self.address_for(report:, audience:, correspondents:, question_message: nil)
          mailbox = Decidim::Bih.report_reply_mailbox.presence or return nil
          capability = find_active(report, audience, digests_for(correspondents), question_message) or raise Missing
          local, domain = mailbox.split("@", 2)
          "#{local}+#{AUDIENCE_LETTER.fetch(audience)}-#{capability.token}@#{domain}"
        end

        def self.find_active(report, audience, digests, question_message)
          ReportReplyCapability.active.find_by(report:, audience:, correspondent_digests: digests, question_message:)
        end

        def self.digests_for(correspondents) = correspondents.map { |address| digest_address(address) }.uniq.sort

        def self.resolve(address, organization:)
          mailbox = Decidim::Bih.report_reply_mailbox.presence or return nil
          bare = (address.to_s[/<([^>]+)>/, 1] || address.to_s).strip.downcase
          match = PATTERN.match(bare) or return nil
          local, domain = mailbox.downcase.split("@", 2)
          return nil unless match[:local] == local && match[:domain] == domain

          capability = ReportReplyCapability.active.find_by(token_digest: Digest::SHA256.hexdigest(match[:token]),
                                                            decidim_organization_id: organization.id)
          return nil unless capability && AUDIENCE_LETTER.fetch(capability.audience) == match[:letter]

          capability
        end

        def self.digest_address(address)
          Digest::SHA256.hexdigest(address.to_s.strip.downcase)
        end

        def self.create_capability(report, audience, digests, question_message)
          token = SecureRandom.random_bytes(TOKEN_BYTES).unpack1("B*").scan(/.{1,5}/)
                              .map { |bits| ALPHABET[bits.ljust(5, "0").to_i(2)] }.join
          ReportReplyCapability.transaction(requires_new: true) do
            ReportReplyCapability.create!(organization: report.organization, report:, audience:, question_message:,
                                          correspondent_digests: digests, token:,
                                          token_digest: Digest::SHA256.hexdigest(token))
          end
        end
      end
    end
  end
end