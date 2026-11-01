# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class GoodwillRescaleTest < ActiveSupport::TestCase
        test "historical rescale refuses both preview and apply before accessing an organization" do
          [true, false].each do |dry_run|
            assert_raises(Decidim::Bih::Goodwill::Rescale::RetiredOperation) do
              Decidim::Bih::Goodwill::Rescale.run!(Object.new, dry_run:)
            end
          end
          assert_raises(Decidim::Bih::Goodwill::Rescale::RetiredOperation) do
            Decidim::Bih::Goodwill::Rescale.apply!(Object.new, Object.new, -10)
          end
        end
      end
    end
  end
end
