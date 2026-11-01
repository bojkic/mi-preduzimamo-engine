# frozen_string_literal: true

require 'securerandom'
require 'digest'
module Decidim
  module Bih
    class ReportEvidenceShare < Decidim::ApplicationRecord
      self.table_name = 'decidim_bih_report_evidence_shares'
      self.filter_attributes += [:token_ciphertext, :token_digest]
      belongs_to :evidence_item, class_name: 'Decidim::Bih::ReportEvidenceItem'
      belongs_to :dispatch, class_name: 'Decidim::Bih::ReportDispatch'
      belongs_to :request_source, polymorphic: true, optional: true
      validates :token_digest, :token_ciphertext, :recipient_digest, :expires_at, presence: true
      validate :dispatch_recipient
      def self.issue!(evidence_item:, dispatch:, recipient:, request_source: nil)
        raise ArgumentError, "Purged evidence" if evidence_item.purged?
        token = SecureRandom.hex(17)
        create!(evidence_item:, dispatch:, request_source:, recipient_digest: Digest::SHA256.hexdigest(recipient.to_s.downcase.strip),
                token_digest: Digest::SHA256.hexdigest(token), expires_at: 30.days.from_now,
                token_ciphertext: Infobip::EncryptedJobEnvelope.seal({ 'token' => token }, purpose: 'report-evidence-share', salt: 'bih-evidence-share-v1'))
      end
      def token
        Infobip::EncryptedJobEnvelope.open(token_ciphertext, purpose: 'report-evidence-share', salt: 'bih-evidence-share-v1').fetch('token')
      end
      def self.resolve(token)
        return unless token.to_s.match?(/\A[a-f0-9]{34}\z/)
        find_by(token_digest: Digest::SHA256.hexdigest(token), revoked_at: nil)&.then do |share|
          share if share.expires_at > Time.current && !share.evidence_item.purged? && share.evidence_item.owned_private_blob?
        end
      end
      def revoke! = update!(revoked_at: Time.current)
      private
      def dispatch_recipient
        return errors.add(:dispatch, :invalid) unless dispatch && evidence_item && dispatch.report_id == evidence_item.report_id
        allowed = Array(dispatch.snapshot['to']).map { |address| Digest::SHA256.hexdigest(address.downcase.strip) }
        errors.add(:recipient_digest, :invalid) unless allowed.include?(recipient_digest)
      end
    end
  end
end
