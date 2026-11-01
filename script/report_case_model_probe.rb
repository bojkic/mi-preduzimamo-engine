# frozen_string_literal: true

# Run only in an authorized, exact-pair production runtime Rails process after
# R3 deployment, with case_agent OFF. Existing protected runtime environment
# provides GEMINI_API_KEY; this client does not resolve ADC or credential files.
# Never import production credentials into mi_work/tests or print their values.
require "json"
require "time"
model = Decidim::Bih::Config.report_case_model
check_model = Decidim::Bih::Config.report_case_check_model
client = Decidim::Bih::Ai::GeminiClient.new
binding = Decidim::Bih::Config.report_case_model_access_binding(api_key: client.api_key, base_url: client.base_url)
abort "Exact HTTPS Vertex Express endpoint, global location and key required" unless binding
# Reuse the existing configured global Express credential. An optional project
# label is metadata only; the receipt makes no billing-project ownership claim.
# Never claim regional processing: this existing client uses global Express mode.
# Access verification is billable. Reserve each fixed, bounded probe from the
# shared conservative daily budget before sending, without retries. The probe
# alone bypasses the receipt it is intended to establish.
baseline_model = ENV.fetch("CASE_EVAL_BASELINE_MODEL", "gemini-3.5-flash-lite")
usage = Decidim::Bih::Ai::CaseUsage.new
models = [model, check_model, baseline_model].uniq.map do |id|
  result = usage.probe(client:, model: id)
  abort "Model did not answer bounded verification" unless result == { "ok" => true }
  { model: id, answered: true, request_path: "/v1/publishers/google/models/#{id}:generateContent" }
end
puts JSON.generate(source: "runtime-probe-v2", request_binding: binding, verified_at: Time.now.utc.iso8601, models:, reserved_usd: usage.reserved_usd_total.to_s("F"),
                   prices_verified: true, cost_measurement: "conservative_reserved_upper_bound")
