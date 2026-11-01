# frozen_string_literal: true
require_relative "test_helper"
require "rack/mock"
require "shakapacker/dev_server_proxy"

class RackProxyResponseGuardRailsTest < ActiveSupport::TestCase
  test "engine initializer installs the version scoped response guard" do
    guard = Decidim::Bih::RackProxyResponseGuard
    assert_equal "0.8.3", Gem.loaded_specs.fetch("rack-proxy").version.to_s
    assert_equal 1, Rack::Proxy.ancestors.count(guard::ProxyCall)
    assert_equal 1, Rack::Proxy.singleton_class.ancestors.count(guard::ResponseHeaders)
    assert_equal 1, Rack::HttpStreamingResponse.ancestors.count(guard::StreamingHeaders)
  end

  test "Shakapacker pass through retains downstream app status and body" do
    app = ->(_env) { [204, { "x-authored" => "retained" }, []] }
    instance = Struct.new(:config, :dev_server).new(nil, nil)
    proxy = Shakapacker::DevServerProxy.new(app, shakapacker: instance)
    proxy.define_singleton_method(:public_output_uri_path) { "authored-assets" }
    assert_equal [204, { "x-authored" => "retained" }, []], proxy.call(Rack::MockRequest.env_for("/non-asset"))
  end
end
