# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Registration::PhoneClaims is the ONE bound two callers share:
      # RegisterWithPhone refuses a live claim on a number ("try again in 10
      # minutes") and releases the abandoned ones inside its own transaction,
      # and the pending page does the same when the citizen types a different
      # number. A difference between the two would show up as a number the form
      # accepts and the page rejects, or the reverse.
      #
      # In the harness rather than the unit suite because every question this
      # module answers is a query over real `decidim_authorizations` rows —
      # including the encrypted `verification_metadata` the bound is read from.
      class RegistrationPhoneClaimsTest < ActiveSupport::TestCase
        PHONE = "+38765123456"
        CLAIMS = Decidim::Bih::Registration::PhoneClaims
        TTL = Decidim::Bih::LoginToken::VERIFY_TTL

        setup do
          @organization = create_organization
          @citizen = citizen!
          @somebody_else = citizen!
        end

        def citizen! = FactoryBot.create(:user, :confirmed, organization: @organization)

        # A pending claim is a row with no grant. A GRANTED one carries no
        # verification_metadata at all — Decidim's own model refuses it — which
        # is why `granted` and `code_sent_at` are never combined here.
        def claim!(user, phone: PHONE, code_sent_at: nil, created_at: nil, granted: false)
          metadata = if granted || code_sent_at.nil?
                       {}
                     else
                       { "code_sent_at" => code_sent_at.iso8601 }
                     end
          authorization = Decidim::Authorization.create!(
            user:, name: "sms",
            unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(phone),
            granted_at: granted ? Time.current : nil,
            verification_metadata: metadata
          )
          authorization.update_column(:created_at, created_at) if created_at # rubocop:disable Rails/SkipsModelValidations
          authorization.reload
        end

        def claimed_elsewhere? = CLAIMS.claimed_elsewhere?(PHONE, organization: @organization, except_user: @citizen)

        def release_stale! = CLAIMS.release_stale!(PHONE, organization: @organization, except_user: @citizen)

        test "a claim is live for exactly as long as the code it was staked with" do
          claim = claim!(@somebody_else, code_sent_at: TTL.ago + 5.seconds)

          assert CLAIMS.live?(claim)
          refute CLAIMS.stale?(claim)
          assert claimed_elsewhere?, "somebody who can still answer the code is mid-flow, not gone"

          claim.update!(verification_metadata: { "code_sent_at" => (TTL.ago - 5.seconds).iso8601 })

          refute CLAIMS.live?(claim.reload)
          assert CLAIMS.stale?(claim)
          refute claimed_elsewhere?, "past the code's life it is abandonment, not somebody mid-flow"
        end

        test "a claim with no code_sent_at falls back to when the row was written" do
          # Exactly the shape RegisterWithPhone writes: the row is committed
          # before anything is sent, so there is no code_sent_at yet.
          claim = claim!(@somebody_else, created_at: 1.minute.ago)

          assert CLAIMS.live?(claim)
          assert claimed_elsewhere?

          claim.update_column(:created_at, TTL.ago - 5.seconds) # rubocop:disable Rails/SkipsModelValidations

          refute CLAIMS.live?(claim.reload)
          refute claimed_elsewhere?
        end

        test "a granted row is proof, and proof is never a claim" do
          granted = claim!(@somebody_else, granted: true)
          granted.update_column(:created_at, TTL.ago - 5.seconds) # rubocop:disable Rails/SkipsModelValidations

          refute claimed_elsewhere?, "a proven number is SmsAuthorization.taken?'s business, not this module's"
          assert_equal 0, release_stale!
          assert Decidim::Authorization.exists?(granted.id), "nothing in this module may touch proof"
        end

        test "releasing takes the number off only the abandoned claims of OTHER citizens" do
          abandoned = claim!(@somebody_else, created_at: TTL.ago - 5.seconds)
          live = claim!(citizen!, code_sent_at: Time.current)
          granted = claim!(citizen!, granted: true)
          granted.update_column(:created_at, TTL.ago - 5.seconds) # rubocop:disable Rails/SkipsModelValidations
          mine = claim!(@citizen, created_at: TTL.ago - 5.seconds)

          assert_equal 1, release_stale!, "the count is what the caller logs and reports"

          # The ROW survives: it is somebody's only `sms` authorization, and
          # destroying it takes their whole pending registration with it.
          assert Decidim::Authorization.exists?(abandoned.id), "the row stays; only the claim goes"
          assert_nil abandoned.reload.unique_id, "and it no longer holds the number"
          assert_empty abandoned.verification_metadata.to_h, "nor the dead challenge"
          assert_nil abandoned.granted_at, "releasing never touches proof, in either direction"

          assert_equal Decidim::Bih::SmsAuthorization.unique_id_for(PHONE), live.reload.unique_id,
                       "somebody still mid-flow keeps their claim"
          assert_equal Decidim::Bih::SmsAuthorization.unique_id_for(PHONE), granted.reload.unique_id
          assert_equal Decidim::Bih::SmsAuthorization.unique_id_for(PHONE), mine.reload.unique_id,
                       "the caller's own row is the one about to be rewritten, never released"
        end

        # What the release is FOR: Decidim's own AuthorizationHandler#duplicate
        # refuses to verify a number any other row holds, and a released row no
        # longer holds one.
        test "a released claim stops standing in the next citizen's way" do
          claim!(@somebody_else, created_at: TTL.ago - 5.seconds)

          release_stale!

          refute claimed_elsewhere?
          refute Decidim::Authorization.where(name: "sms", unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(PHONE))
                                       .where.not(decidim_user_id: @citizen.id).exists?,
                 "nothing but the caller's own row still answers for this number"
        end
      end
    end
  end
end
