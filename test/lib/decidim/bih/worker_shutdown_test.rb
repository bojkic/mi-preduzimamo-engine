# frozen_string_literal: true

require "test_helper"
require "decidim/bih/worker_shutdown"

module Decidim
  module Bih
    class WorkerShutdownTest < Minitest::Test
      # Stands in for Sidekiq::Config#on.
      class FakeSidekiqConfig
        attr_reader :events

        def initialize = @events = Hash.new { |hash, key| hash[key] = [] }

        def on(event, &block) = @events[event] << block
      end

      def teardown = WorkerShutdown.reset!

      def test_install_registers_a_quiet_hook_that_raises_the_flag
        config = FakeSidekiqConfig.new
        WorkerShutdown.install!(config)

        assert_equal [:quiet], config.events.keys
        refute_predicate WorkerShutdown, :requested?
        config.events[:quiet].each(&:call)
        assert_predicate WorkerShutdown, :requested?
      end

      def test_engine_installs_the_hook_on_the_sidekiq_server
        engine = File.read(File.expand_path("../../../../lib/decidim/bih/engine.rb", __dir__))

        assert_includes engine, %(require "decidim/bih/worker_shutdown")
        assert_match(/::Sidekiq\.configure_server \{ \|config\| Decidim::Bih::WorkerShutdown\.install!\(config\) \}/, engine)
      end
    end
  end
end
