# frozen_string_literal: true
require "test_helper"
require "rack/mock"
require "rack/request"
require "rack/proxy"
require "decidim/bih/rack_proxy_response_guard"

class RackProxyResponseGuardTest < Minitest::Test
  Guard = Decidim::Bih::RackProxyResponseGuard

  class Backend
    attr_reader :body_reads
    def initialize(headers)
      @headers = headers
      @body_reads = 0
    end
    def code = "200"
    def to_hash = @headers
    def body
      @body_reads += 1
      "abc"
    end
  end

  class Session
    attr_accessor :use_ssl, :read_timeout
    attr_reader :finishes, :requests, :drains
    def initialize(response)
      @response = response
      @started = true
      @finishes = @requests = @drains = 0
    end
    def started? = @started
    def start
      yield self
    ensure
      finish
    end
    def request(*)
      @requests += 1
      @response
    end
    def finish
      @finishes += 1
      @started = false
    end
    def end_request_hacked
      @drains += 1
      raise "Rejected response must not be drained"
    end
  end

  def setup
    assert Guard.install!, "This compatibility regression requires rack-proxy0.8.3"
  end

  def response(headers, streaming:)
    backend = Backend.new(headers)
    session = Session.new(backend)
    proxy = Rack::Proxy.new(backend: "http://backend.example.invalid", streaming:)
    if streaming
      body = Rack::HttpStreamingResponse.allocate
      body.instance_variable_set(:@response, backend)
      body.instance_variable_set(:@session, session)
      result = Rack::HttpStreamingResponse.stub(:new, body) { proxy.call(Rack::MockRequest.env_for("http://community.example.invalid/asset")) }
    else
      result = Net::HTTP.stub(:new, session) { proxy.call(Rack::MockRequest.env_for("http://community.example.invalid/asset")) }
    end
    [result, backend, session]
  end

  def test_ambiguous_framing_is_rejected_in_both_paths_without_downstream_bytes
    [true, false].each do |streaming|
      result, backend, session = response({ "transfer-encoding" => ["chunked"], "content-length" => ["1"] }, streaming:)
      assert_equal [502, {}, []], result
      assert_equal 0, backend.body_reads
      assert_equal 1, session.finishes
      assert_equal 0, session.drains
      refute session.started?
      assert_equal(streaming ? 0 : 1, session.requests)
    end
  end

  def test_header_case_and_repeated_fields_do_not_bypass_rejection
    [true, false].each do |streaming|
      result, = response({ "TrAnSfEr-EnCoDiNg" => ["chunked"], "CONTENT-length" => ["1", "2"] }, streaming:)
      assert_equal [502, {}, []], result
    end
  end

  def test_fixed_length_success_preserves_status_length_and_body_representation
    result, backend, = response({ "content-length" => ["3"], "content-type" => ["text/plain"] }, streaming: false)
    assert_equal "200", result.first
    assert_equal "3", result[1]["content-length"]
    assert_equal ["abc"], result.last
    assert_equal 1, backend.body_reads
    streamed, = response({ "content-length" => ["3"] }, streaming: true)
    assert_equal 200, streamed.first
    assert_equal "3", streamed[1]["content-length"]
    assert_instance_of Rack::HttpStreamingResponse, streamed.last
  end

  def test_valid_chunked_success_drops_transport_header_without_inventing_length
    [true, false].each do |streaming|
      result, = response({ "transfer-encoding" => ["chunked"], "content-type" => ["text/plain"] }, streaming:)
      assert_equal 200, result.first.to_i
      refute result[1].key?("transfer-encoding")
      refute result[1].key?("content-length")
      assert_equal "text/plain", result[1]["content-type"]
    end
  end

  def test_connection_named_response_headers_are_removed_case_insensitively
    [true, false].each do |streaming|
      result, = response({ "Connection" => ["X-Private, keep-alive", "X-Other"], "X-Private" => ["authored-a"],
                           "x-other" => ["authored-b"], "Keep-Alive" => ["timeout=5"], "X-Public" => ["retained"] }, streaming:)
      assert_equal 200, result.first.to_i
      %w(connection x-private x-other keep-alive).each { |key| refute result[1].key?(key) }
      assert_equal "retained", result[1]["x-public"]
    end
  end

  def test_repeated_installation_keeps_exactly_one_guard_per_hook
    2.times { assert Guard.install! }
    assert_equal 1, Rack::Proxy.ancestors.count(Guard::ProxyCall)
    assert_equal 1, Rack::Proxy.singleton_class.ancestors.count(Guard::ResponseHeaders)
    assert_equal 1, Rack::HttpStreamingResponse.ancestors.count(Guard::StreamingHeaders)
  end

  def test_streaming_teardown_failure_still_returns_rejection_without_retry
    backend = Backend.new({ "transfer-encoding" => ["chunked"], "content-length" => ["1"] })
    session = Session.new(backend)
    session.define_singleton_method(:finish) { raise IOError, "authored teardown failure" }
    body = Rack::HttpStreamingResponse.allocate
    body.instance_variable_set(:@response, backend)
    body.instance_variable_set(:@session, session)
    proxy = Rack::Proxy.new(backend: "http://backend.example.invalid", streaming: true)
    result = Rack::HttpStreamingResponse.stub(:new, body) { proxy.call(Rack::MockRequest.env_for("http://community.example.invalid/asset")) }
    assert_equal [502, {}, []], result
    assert_equal 0, backend.body_reads
    assert_equal 0, session.requests
    assert_equal 0, session.drains
  end
end
