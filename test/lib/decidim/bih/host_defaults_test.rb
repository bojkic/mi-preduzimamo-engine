# frozen_string_literal: true

require "test_helper"
require "decidim/bih"

class HostDefaultsTest < Minitest::Test
  def setup
    @original_infobip_sms_sender = ENV.fetch("INFOBIP_SMS_SENDER", nil)
    @original_infobip_chat_channels = ENV.fetch("INFOBIP_CHAT_CHANNELS", nil)
    @original_infobip_instagram_sender = ENV.fetch("INFOBIP_INSTAGRAM_SENDER", nil)
    ENV.delete("INFOBIP_SMS_SENDER")
    ENV.delete("INFOBIP_CHAT_CHANNELS")
    ENV.delete("INFOBIP_INSTAGRAM_SENDER")
    Decidim::Bih::Config.reset!
  end

  def teardown
    if @original_infobip_sms_sender.nil?
      ENV.delete("INFOBIP_SMS_SENDER")
    else
      ENV["INFOBIP_SMS_SENDER"] = @original_infobip_sms_sender
    end
    restore_env("INFOBIP_CHAT_CHANNELS", @original_infobip_chat_channels)
    restore_env("INFOBIP_INSTAGRAM_SENDER", @original_infobip_instagram_sender)
    Decidim::Bih::Config.reset!
  end

  def test_reusable_engine_defaults_do_not_name_a_specific_host
    assert_nil Decidim::Bih.infobip_sms_sender
    assert_nil Decidim::Bih::Config.infobip[:sms_sender]
    assert_empty Decidim::Bih::Config.infobip[:chat_channels]
    assert_nil Decidim::Bih::Config.infobip[:instagram_sender]
    assert_empty Decidim::Bih.external_chat_onboarding_links
    assert_nil Decidim::Bih.sistem48_central_intake
    assert_nil Decidim::Bih.sistem48_archive_url
    assert_equal "notifications@example.org", Decidim::Bih.reporter_mailer_from
    assert_equal "reports@example.org", Decidim::Bih.sistem48_mailer_from
    assert_equal "Decidim BIH platforme", Decidim::Bih.sistem48_forwarded_via_name
    assert_nil Decidim::Bih.flagship_process_slug
    assert_nil Decidim::Bih.mi_hub_decision_path
    assert_nil Decidim::Bih.campaign_hashtag
    assert_nil Decidim::Bih.mi_bot_sms_shortcode
    assert_nil Decidim::Bih.geocoder_base_url
    assert_equal "/search", Decidim::Bih.geocoder_search_path
    assert_empty Decidim::Bih.geocoder_extra_headers
    assert_equal "svoj grad", Decidim::Bih.mi_bot_demo_city_accusative
    assert_equal "Glavna ulica", Decidim::Bih.mi_bot_demo_street
  end

  private

  def restore_env(key, value)
    value.nil? ? ENV.delete(key) : ENV[key] = value
  end
end
