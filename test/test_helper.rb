# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# This suite is a test environment even without Rails, so the shared Redis
# resolver fails closed here too: a store built without an injected fake
# raises instead of reaching a default endpoint. See lib/decidim/bih/redis_endpoint.rb.
# Set unconditionally: an inherited RAILS_ENV must not make this a non-test run.
ENV["RAILS_ENV"] = "test"

# Latch the process as a test process before any test file loads. Tests stub
# Rails.env (e.g. as "production"); the latch keeps every Redis client on the
# fail-closed test path regardless. When REDIS_URL is given it must be a test
# endpoint; when it is unset, any store built without a fake raises.
require "decidim/bih/redis_endpoint"
Decidim::Bih::RedisEndpoint.mark_test_process!
unless ENV["REDIS_URL"].to_s.strip.empty?
  begin
    Decidim::Bih::RedisEndpoint.guard_test_environment!(ENV)
  rescue Decidim::Bih::RedisEndpoint::Error => e
    abort "Refusing test Redis configuration: #{e.message}. Set REDIS_URL to a dedicated test endpoint or leave it unset."
  end
end

require "minitest/autorun"
# Load mock/stub support explicitly for standalone unit test invocations.
require "minitest/mock"
