# frozen_string_literal: true

require "test_helper"
require "decidim/bih"
require_relative "../../../../app/controllers/concerns/decidim/bih/mi_bot_data"

class MiBotDataTest < Minitest::Test
  CONFIG_ACCESSORS = [
    :campaign_hashtag,
    :mi_bot_showcase_assistant_name,
    :mi_bot_showcase_sticker_text,
    :mi_bot_demo_city_accusative,
    :mi_bot_demo_street,
    :mi_bot_demo_address,
    :mi_bot_demo_destination,
    :mi_bot_demo_proposal_title,
    :mi_bot_demo_budget_amount,
    :mi_bot_demo_budget_items,
    :mi_bot_demo_donation_title
  ].freeze

  Subject = Class.new do
    include Decidim::Bih::MiBotData
  end

  def setup
    @original_values = CONFIG_ACCESSORS.index_with do |accessor|
      Decidim::Bih.public_send(accessor)
    end
  end

  def teardown
    @original_values.each do |accessor, value|
      Decidim::Bih.public_send("#{accessor}=", value)
    end
  end

  def test_showcase_defaults_are_not_bijeljina_specific
    data = serialized_showcase

    refute_includes data, "Bijelj"
    refute_includes data, "jervolimbijeljinu"
    refute_includes data, "Srpske vojske"
    refute_includes data, "Račanska"
    refute_includes data, "MI! bot"
    refute_includes data, "MI PREUZIMAMO"
    assert_includes data, "asistent platforme"
    refute_includes subject.mi_bot_channels, "sms"
    refute_includes subject.mi_bot_conversations, "sms"
    assert_equal "VOLIM GRAD", sticker_text("volim")
    assert_equal "PREUZIMAMO", sticker_text("preuzimamo")
  end

  def test_showcase_data_uses_host_overrides
    Decidim::Bih.campaign_hashtag = "#jervolimbijeljinu"
    Decidim::Bih.mi_bot_showcase_assistant_name = "MI! bot"
    Decidim::Bih.mi_bot_showcase_sticker_text = "MI PREUZIMAMO"
    Decidim::Bih.mi_bot_demo_city_accusative = "Bijeljinu"
    Decidim::Bih.mi_bot_demo_street = "Srpske vojske"
    Decidim::Bih.mi_bot_demo_address = "Račanska"
    Decidim::Bih.mi_bot_demo_destination = "obale Drine"
    Decidim::Bih.mi_bot_demo_proposal_title = "Biciklistička staza do Drine"
    Decidim::Bih.mi_bot_demo_budget_items = [["Novi vrtić u Ledincima", "240.000"]]
    Decidim::Bih.mi_bot_demo_donation_title = "Uredimo obalu Drine"

    data = serialized_showcase

    assert_includes data, "Bijeljinu"
    assert_includes data, "Srpske vojske"
    assert_includes data, "Biciklistička staza do Drine"
    assert_includes data, "#jervolimbijeljinu"
    assert_includes data, "MI! bot"
    assert_equal "MI PREUZIMAMO", sticker_text("preuzimamo")
    refute_includes data, "1300"
  end

  private

  def subject
    @subject ||= Subject.new
  end

  def serialized_showcase
    [
      subject.mi_bot_channels,
      subject.mi_bot_conversations,
      subject.mi_bot_stickers,
      subject.mi_bot_templates
    ].inspect
  end

  def sticker_text(id)
    subject.mi_bot_stickers.find { |sticker| sticker.fetch(:id) == id }.fetch(:text)
  end
end
