# frozen_string_literal: true

module Decidim
  module Bih
    class EvidenceSharesController < Decidim::ApplicationController
      def show
        share = ReportEvidenceShare.resolve(params[:token])
        return head :not_found unless share
        share.with_lock do
          return head :not_found unless share.revoked_at.nil? && share.expires_at > Time.current &&
            !share.evidence_item.purged? && share.evidence_item.owned_private_blob?
          share.update!(last_accessed_at: Time.current, access_count: share.access_count + 1)
          response.headers['Cache-Control'] = 'private, no-store'
          response.headers['Referrer-Policy'] = 'no-referrer'
          response.headers['X-Content-Type-Options'] = 'nosniff'
          blob = share.evidence_item.blob
          send_data blob.download, filename: blob.filename.to_s, type: 'application/octet-stream', disposition: 'attachment'
        end
      end
    end
  end
end
