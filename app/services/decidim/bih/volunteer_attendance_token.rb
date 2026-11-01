# frozen_string_literal: true

require "rqrcode"

module Decidim
  module Bih
    # Signed, expiring operator QR token for confirming one volunteer signup.
    # The token is not persisted; it resolves only to the exact org/opportunity/
    # user/signup tuple embedded in the signed payload.
    class VolunteerAttendanceToken
      TOKEN_PURPOSE = :decidim_bih_volunteer_attendance
      TOKEN_TTL = 7.days

      class << self
        def issue(signup)
          verifier.generate(payload_for(signup), expires_in: TOKEN_TTL)
        end

        def resolve(token, organization:)
          payload = verifier.verified(token.to_s)
          return nil if payload.blank?
          return nil unless payload.fetch("organization_id", nil).to_i == organization.id

          signup = Decidim::Bih::VolunteerSignup
                   .includes(:opportunity, :user)
                   .where(organization:)
                   .find_by(id: payload.fetch("signup_id", nil))
          return nil unless signup
          return nil unless payload_matches_signup?(payload, signup)
          return nil unless signup.going?

          signup
        end

        def qr_svg(url)
          qr = RQRCode::QRCode.new(url.to_s, level: :m)
          qr.as_svg(module_size: 4, standalone: true, use_path: true)
        rescue StandardError => e
          Rails.logger.error("[VolunteerAttendanceToken] QR generation failed: #{e.class}: #{e.message}")
          nil
        end

        private

        def verifier
          Rails.application.message_verifier(TOKEN_PURPOSE)
        end

        def payload_for(signup)
          {
            "signup_id" => signup.id,
            "organization_id" => signup.decidim_organization_id,
            "opportunity_id" => signup.decidim_bih_volunteer_opportunity_id,
            "user_id" => signup.decidim_user_id,
            "issued_at" => Time.current.utc.iso8601
          }
        end

        def payload_matches_signup?(payload, signup)
          payload.fetch("opportunity_id", nil).to_i == signup.decidim_bih_volunteer_opportunity_id &&
            payload.fetch("user_id", nil).to_i == signup.decidim_user_id
        end
      end
    end
  end
end
