# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class AssetManifestStubTest < ActiveSupport::TestCase
        test "a new generated-host manifest uses deterministic paths before any render" do
          manifest = ::Shakapacker::Instance.new(root_path: Rails.root).manifest
          assert_equal "/packs-test/media/images/remixicon.symbol.svg", manifest.lookup!("media/images/remixicon.symbol.svg")
          assert_equal ["/packs-test/decidim_core"], manifest.lookup_pack_with_chunks!("decidim_core", type: :stylesheet)
          assert_equal DecidimBihRailsShakapackerManifestStub, manifest.method(:lookup!).owner
        end
      end
    end
  end
end
