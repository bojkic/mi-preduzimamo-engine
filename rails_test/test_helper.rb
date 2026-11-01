# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

# FAIL CLOSED if Redis is not an explicit test endpoint. Test processes once
# fell back to redis://localhost:6379/1 and wrote integration-health keys into
# the production Redis instance. This runs before the generated host boots, so
# no store, Sidekiq client or subscriber can open a connection first. The
# launcher (script/decidim_bih_rails_test) rejects DATABASE_URL the same way.
# The check runs in a child interpreter: requiring the resolver here would
# activate default gems (uri) before the generated host's Bundler setup and
# conflict with its lockfile.
# RUBYOPT and RUBYLIB are cleared so an inherited -r/bundler preload or load
# path cannot change what the child loads. Exit 3 means the guard refused; anything else means the check
# itself failed, which also refuses to boot.
require "rbconfig"
redis_guard = <<~'RUBY'
  begin
    Decidim::Bih::RedisEndpoint.guard_test_environment!(ENV)
  rescue Decidim::Bih::RedisEndpoint::Error => e
    warn "Refusing test Redis configuration: #{e.message}. Set REDIS_URL to a dedicated test endpoint."
    exit 3
  end
RUBY
redis_guard_ok = system({ "RUBYOPT" => nil, "RUBYLIB" => nil }, RbConfig.ruby, "--disable-gems", "-I", File.expand_path("../lib", __dir__),
                        "-rdecidim/bih/redis_endpoint", "-e", redis_guard)
unless redis_guard_ok
  status = Process.last_status&.exitstatus
  abort "Redis guard refused this test environment; the generated host was not booted." if status == 3

  abort "Redis guard check crashed (exit #{status.inspect}); refusing to boot the generated host."
end

app_root = ENV.fetch("DECIDIM_BIH_RAILS_APP") do
  abort "DECIDIM_BIH_RAILS_APP must point at the generated Decidim host"
end

# Latch this process as a test process after the host's Bundler setup (so uri
# and the resolver come from the host's bundle) and before the host loads, so
# no test that stubs Rails.env as "production" can move a client off the
# fail-closed test path.
require File.join(app_root, "config/boot")
require "decidim/bih/redis_endpoint"
Decidim::Bih::RedisEndpoint.mark_test_process!
require File.join(app_root, "config/environment")

# Generated hosts opt into the private fixture service explicitly; production
# never substitutes a default when report_private is missing.
require "active_storage/service/encrypted_private_disk_service"
private_configs = Rails.configuration.active_storage.service_configurations
ActiveStorage::Blob.services # Initialize the configured registry before fixture additions.
private_configs ||= Rails.configuration.active_storage.service_configurations
unless private_configs.keys.map(&:to_s).include?("report_private")
  private_configs = private_configs.merge("report_private" => {
                                            "service" => "EncryptedPrivateDisk", "root" => Rails.root.join("tmp/storage/report-private").to_s
                                          })
  Rails.configuration.active_storage.service_configurations = private_configs
  ActiveStorage::Blob.services = ActiveStorage::Service::Registry.new(private_configs)
end

# The launcher already migrates this run's isolated schema. Rails' automatic
# maintenance compares schema_sha1 and can attempt a database-wide purge even
# when every migration is applied. Check versions without creating metadata
# tables, then keep that destructive maintenance path disabled for this harness.
raise ActiveRecord::PendingMigrationError if ActiveRecord::Base.connection_pool.migration_context.needs_migration?

ActiveRecord.maintain_test_schema = false
require "rails/test_help"
require "minitest/mock"
require "capybara"
require "factory_bot_rails"
require "decidim/dev"
require "decidim/core/test/factories"
require "decidim/budgets/test/factories"
require "devise/test/integration_helpers"
require "securerandom"
require_relative "factories/community_contributions"

# Rendering tests do not compile frontend packs. Load Shakapacker explicitly:
# some generated hosts load it only when their first public layout renders.
# Stub the manifest class so a fresh instance uses the same deterministic paths.
require "shakapacker"

module DecidimBihRailsShakapackerManifestStub
  def lookup(name, **_opts)
    "/packs-test/#{name}"
  end

  def lookup!(name, **)
    lookup(name, **)
  end

  def lookup_pack_with_chunks(name, **_opts)
    ["/packs-test/#{name}"]
  end

  def lookup_pack_with_chunks!(name, **)
    lookup_pack_with_chunks(name, **)
  end
end

Shakapacker::Manifest.prepend(DecidimBihRailsShakapackerManifestStub) unless Shakapacker::Manifest < DecidimBihRailsShakapackerManifestStub

if (faker_spec = Gem.loaded_specs["faker"])
  I18n.load_path += Dir[File.join(faker_spec.gem_dir, "lib/locales/en.yml")]
  I18n.load_path += Dir[File.join(faker_spec.gem_dir, "lib/locales/en/*.yml")]
end

BIH_RAILS_TEST_LOCALES = %w(en bs hr sr).freeze

I18n.available_locales = (I18n.available_locales + BIH_RAILS_TEST_LOCALES.map(&:to_sym)).uniq
require "i18n/backend/fallbacks"
I18n::Backend::Simple.include(I18n::Backend::Fallbacks)
I18n.fallbacks = I18n::Locale::Fallbacks.new(:en)
I18n.backend.reload!
Faker::Config.locale = :en if defined?(Faker)

module DecidimBihRailsTestHelpers
  def create_organization(**attrs)
    # Committed concurrency fixtures survive individual transactional tests.
    # Unique translated names avoid collisions with those tenants after Faker's
    # per-example registry resets; caller-supplied names still test validation.
    fixture_key = SecureRandom.hex(8)
    locales = Array(attrs.fetch(:available_locales, BIH_RAILS_TEST_LOCALES))
    FactoryBot.create(
      :organization,
      available_locales: BIH_RAILS_TEST_LOCALES,
      default_locale: "sr",
      host: "rails-test-#{fixture_key}.lvh.me",
      name: locales.index_with { |locale| "Rails organization #{locale} #{fixture_key}" },
      short_name: locales.index_with { |_locale| "Org#{fixture_key}" },
      **attrs
    )
  end

  def create_table_reward!(organization:, key:, cost:, stock:, title: "Rails harness reward")
    Decidim::Bih::Goodwill::Reward.create!(
      organization:,
      key:,
      title: { "en" => title, "sr" => title },
      cost:,
      stock:,
      active: true
    )
  end

  def redeem_path(reward_key)
    Decidim::Bih.public_path("nagrade/redeem/#{reward_key}")
  end

  def redemption_params
    {
      redemption_confirmed: "1",
      redemption_request_key: SecureRandom.uuid
    }
  end

  def admin_reward_fulfillment_path(fulfillment, status)
    "/admin/bih/goodwill/reward-fulfillment/#{fulfillment.id}/#{status}"
  end

  # Build a komsiluk Decidim::Bih::LocalArea row directly -- there is no
  # :local_area FactoryBot factory in this harness. Mirrors the construction
  # in rails_test/onboarding_next_step_test.rb and
  # rails_test/awards_after_verification_test.rb.
  def build_komsiluk!(organization, name: "Test komšiluk", zona: "grad")
    Decidim::Bih::LocalArea.create!(
      decidim_organization_id: organization.id,
      kind: "komsiluk",
      zona:,
      slug: "k-#{SecureRandom.hex(4)}",
      name: { "sr" => name }
    )
  end

  def goodwill_balance_for(user)
    Decidim::Bih::Goodwill::Ledger.new.account_for(user).reload.balance
  end
end

module ActiveSupport
  class TestCase
    include FactoryBot::Syntax::Methods
    include DecidimBihRailsTestHelpers

    self.use_transactional_tests = true

    # Other Decidim factories still use Faker's finite unique registry. Bound
    # that registry to each example; organization names use their own unique
    # fixture key so committed concurrency tenants cannot collide afterward.
    teardown do
      Faker::UniqueGenerator.clear
    end
  end
end
