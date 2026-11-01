# frozen_string_literal: true

require "test_helper"
require "decidim/bih"

class DecidimModulesTest < Minitest::Test
  def test_required_decidim_modules_are_unique_and_hard_dependencies
    modules = Decidim::Bih.required_decidim_modules
    ids = modules.map { |mod| mod.fetch(:id) }
    gems = modules.map { |mod| mod.fetch(:gem) }

    assert_equal ids.uniq, ids
    assert_equal gems.uniq, gems
    assert_includes gems, "decidim-core"
    assert_includes gems, "decidim-budgets"
    assert_includes gems, "decidim-forms"
    assert_includes gems, "decidim-meetings"
    assert_includes gems, "decidim-proposals"
    assert_includes gems, "decidim-verifications"
    assert(modules.all? { |mod| mod.fetch(:status) == "hard_runtime_dependency" })
    assert(modules.all? { |mod| mod.fetch(:reason).to_s.length > 40 })
  end

  def test_host_contract_manifest_includes_required_decidim_modules
    manifest = Decidim::Bih.host_contract_manifest(mount_path: "/moja-platforma", short_magic_links: false)
    module_gems = manifest.fetch(:required_decidim_modules).map { |mod| mod.fetch(:gem) }

    assert_equal Decidim::Bih.required_decidim_modules.size,
                 manifest.fetch(:required_decidim_modules).size
    assert_includes module_gems, "decidim-budgets"
    assert_includes module_gems, "decidim-verifications"
  end
end
