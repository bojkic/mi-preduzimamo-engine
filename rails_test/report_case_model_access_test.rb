# frozen_string_literal: true

require "test_helper"
require "tempfile"

module Decidim
  module Bih
    module RailsHarness
      class ReportCaseModelAccessTest < ActiveSupport::TestCase
        MODEL = "gemini-3.8-flash"
        ENDPOINT = "https://aiplatform.googleapis.com"
        SYNTHETIC_KEY = "synthetic-test-credential-not-a-provider-key"

        test "global access receipt binds actual model endpoint and credential without storing the key" do
          with_access_configuration do |file, configuration|
            receipt = receipt_for(configuration)
            file.write(JSON.generate(receipt))
            file.flush
            Config.stub(:gemini, configuration) do
              assert Config.report_case_model_access_verified?(MODEL)
              assert_not Config.report_case_model_access_verified?("gemini-3.5-flash-lite")
            end
            assert_equal false, receipt.dig("request_binding", "project_ownership_verified")
            assert_equal "fixture-project", receipt.dig("request_binding", "configured_project")
            assert_not_includes JSON.generate(receipt), SYNTHETIC_KEY
          end
        end

        test "existing global Express credentials work without invented project labels" do
          with_access_configuration do |file, configuration|
            ENV.delete("GOOGLE_CLOUD_PROJECT")
            ENV.delete("GOOGLE_CLOUD_LOCATION")
            binding = Config.report_case_model_access_binding(**configuration)
            assert_equal "global", binding.fetch("request_location")
            assert_nil binding.fetch("configured_project")
            assert_equal false, binding.fetch("project_ownership_verified")
            file.write(JSON.generate(receipt_for(configuration)))
            file.flush
            Config.stub(:gemini, configuration) { assert Config.report_case_model_access_verified?(MODEL) }
          end
        end

        test "a rotated credential cannot reuse previous access evidence" do
          with_access_configuration do |file, configuration|
            file.write(JSON.generate(receipt_for(configuration)))
            file.flush
            Config.stub(:gemini, configuration.merge(api_key: "another-synthetic-key")) do
              assert_not Config.report_case_model_access_verified?(MODEL)
            end
          end
        end

        test "non-global location and deceptive endpoints fail closed before probing" do
          with_access_configuration do |_file, configuration|
            ENV["GOOGLE_CLOUD_LOCATION"] = "europe-west1"
            assert_nil Config.report_case_model_access_binding(**configuration)
            ENV["GOOGLE_CLOUD_LOCATION"] = "global"
            ["http://aiplatform.googleapis.com", "https://aiplatform.googleapis.com.attacker.invalid",
             "https://aiplatform.googleapis.com/path", "https://aiplatform.googleapis.com?key=fixture",
             "https://fixture@aiplatform.googleapis.com", "https://europe-west1-aiplatform.googleapis.com"].each do |url|
              assert_nil Config.report_case_model_access_binding(**configuration, base_url: url), url
            end
          end
        end

        test "old label-only receipts and invented ownership or request paths are rejected" do
          with_access_configuration do |file, configuration|
            receipt = receipt_for(configuration)
            variants = [receipt.merge("source" => "runtime-probe-v1"),
                        receipt.merge("request_binding" => receipt.fetch("request_binding").merge("project_ownership_verified" => true)),
                        receipt.merge("models" => [{ "model" => MODEL, "answered" => true, "request_path" => "/invented" }])]
            Config.stub(:gemini, configuration) do
              variants.each do |invalid|
                file.rewind
                file.truncate(0)
                file.write(JSON.generate(invalid))
                file.flush
                assert_not Config.report_case_model_access_verified?(MODEL)
              end
            end
          end
        end

        test "probe emits actual global binding and refuses a regional claim without a call" do
          with_access_configuration do |_file, configuration|
            client = Struct.new(:api_key, :base_url).new(SYNTHETIC_KEY, ENDPOINT)
            usage = Struct.new(:models, :reserved_usd_total) do
              def probe(client:, model:)
                raise "Unexpected probe client" unless client.base_url == "https://aiplatform.googleapis.com"

                models << model
                { "ok" => true }
              end
            end.new([], BigDecimal("0.001"))
            Ai::GeminiClient.stub(:new, -> { client }) do
              Ai::CaseUsage.stub(:new, -> { usage }) do
                output, = capture_io { load File.expand_path("../script/report_case_model_probe.rb", __dir__) }
                receipt = JSON.parse(output)
                assert_equal "runtime-probe-v2", receipt.fetch("source")
                assert_equal Config.report_case_model_access_binding(**configuration), receipt.fetch("request_binding")
                assert_equal [MODEL, "gemini-3.5-flash-lite"], usage.models
                assert_not_includes output, SYNTHETIC_KEY
                ENV["GOOGLE_CLOUD_LOCATION"] = "europe-west1"
                capture_io { assert_raises(SystemExit) { load File.expand_path("../script/report_case_model_probe.rb", __dir__) } }
                assert_equal [MODEL, "gemini-3.5-flash-lite"], usage.models
              end
            end
          end
        end

        test "missing or blank community receipt path does not read a server default" do
          with_access_configuration do |_file, configuration|
            Config.stub(:gemini, configuration) do
              [nil, "", "  "].each do |value|
                value.nil? ? ENV.delete("REPORT_CASE_MODEL_ACCESS_RECEIPT") : ENV["REPORT_CASE_MODEL_ACCESS_RECEIPT"] = value
                File.stub(:file?, ->(*) { flunk "No receipt path was supplied; filesystem must not be consulted" }) do
                  assert_not Config.report_case_model_access_verified?(MODEL)
                end
              end
            end
          end
        end

        private

        def receipt_for(configuration)
          {
            "source" => "runtime-probe-v2",
            "request_binding" => Config.report_case_model_access_binding(**configuration),
            "verified_at" => Time.current.utc.iso8601,
            "models" => [{ "model" => MODEL, "answered" => true,
                           "request_path" => "/v1/publishers/google/models/#{MODEL}:generateContent" }]
          }
        end

        def with_access_configuration
          values = { "GOOGLE_CLOUD_PROJECT" => "fixture-project", "GOOGLE_CLOUD_LOCATION" => "global",
                     "REPORT_CASE_MODEL" => MODEL, "REPORT_CASE_CHECK_MODEL" => MODEL,
                     "CASE_EVAL_BASELINE_MODEL" => "gemini-3.5-flash-lite" }
          keys = values.keys + ["REPORT_CASE_MODEL_ACCESS_RECEIPT"]
          previous = keys.to_h { |key| [key, ENV.fetch(key, nil)] }
          Tempfile.create("synthetic-model-access") do |file|
            values.each { |key, value| ENV[key] = value }
            ENV["REPORT_CASE_MODEL_ACCESS_RECEIPT"] = file.path
            yield file, { api_key: SYNTHETIC_KEY, base_url: ENDPOINT }
          end
        ensure
          previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
        end
      end
    end
  end
end
