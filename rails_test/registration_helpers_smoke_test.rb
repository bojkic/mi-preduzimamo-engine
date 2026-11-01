# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Smoke test for the build_komsiluk!/goodwill_balance_for helpers added
      # to DecidimBihRailsTestHelpers for delivery D's /registracija rails_test
      # coverage: proves both helpers actually build usable, correctly-scoped
      # rows rather than just not raising.
      class RegistrationHelpersSmokeTest < ActiveSupport::TestCase
        test "build_komsiluk! builds a komsiluk local area scoped to the organization" do
          organization = create_organization
          citizen = FactoryBot.create(:user, :confirmed, organization:)

          komsiluk = build_komsiluk!(organization, name: "Smoke komšiluk", zona: "selo")

          assert_equal "komsiluk", komsiluk.kind
          assert_equal "selo", komsiluk.zona
          assert_equal organization.id, komsiluk.decidim_organization_id

          Decidim::Bih::CitizenProfile.for_user(citizen, organization:)
                                      .assign_komsiluk!(komsiluk, source: "registration")

          assert_equal 0, goodwill_balance_for(citizen), "an unverified citizen's komsiluk choice earns nothing yet"
        end
      end
    end
  end
end
