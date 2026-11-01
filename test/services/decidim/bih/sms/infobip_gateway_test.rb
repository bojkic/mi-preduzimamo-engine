# frozen_string_literal: true

require "test_helper"
require "i18n"
require "logger"
require "decidim/bih"

# The gateway stamps the message validity from Decidim::Bih::LoginToken::VERIFY_TTL
# and logs through Rails.logger. Outside a booted Rails app the token model
# inherits from an ActiveRecord base that needs a database, so load the REAL
# constant behind a minimal stand-in base class (the same pattern as
# test/models/decidim/bih/login_token_test.rb) and then take the stand-in back
# out, so no other test file can inherit a too-thin ApplicationRecord.
module Decidim
  unless const_defined?(:ApplicationRecord, false)
    class ApplicationRecord
      def self.table_name=(*); end

      def self.belongs_to(*); end

      def self.validates(*); end
    end
    INFOBIP_GATEWAY_TEST_DEFINED_APPLICATION_RECORD = true
  end
end

require_relative "../../../../../app/models/decidim/bih/login_token"
# The one-segment budget is asserted with the counter that owns the rule.
require_relative "../../../../../app/services/decidim/bih/sms/segment_counter"

module Decidim
  if const_defined?(:INFOBIP_GATEWAY_TEST_DEFINED_APPLICATION_RECORD, false)
    remove_const(:ApplicationRecord)
    remove_const(:INFOBIP_GATEWAY_TEST_DEFINED_APPLICATION_RECORD)
  end
end

require_relative "../../../../../app/services/decidim/bih/log_redactor"
require_relative "../../../../../app/services/decidim/bih/infobip/error"
require_relative "../../../../../app/services/decidim/bih/sms"
require_relative "../../../../../app/services/decidim/bih/sms/infobip_gateway"

module Decidim
  module Bih
    module Sms
      # The verification message is the whole of delivery A's first step: the
      # citizen taps the link and is verified and signed in. These lock the
      # properties that make that work on a real phone —
      #
      #   * the SMS carries the link AND a hidden fallback code, in the
      #     generic engine's printable-ASCII copy, so it stays one GSM-7
      #     segment (160 chars). Diacritics would switch the segment to UCS-2
      #     (70 chars) and the link alone is already ~68;
      #   * Viber implies a smartphone, so its text is link-only and never
      #     leaks the code onto a second channel;
      #   * with no link there is nothing to tap, and a code-only text would
      #     strand the citizen — delivery must fail loudly instead.
      class InfobipGatewayTextTest < Minitest::Test
        LOCALE_FILES = %w(en sr sr-Cyrl).map do |locale|
          File.expand_path("../../../../../config/locales/#{locale}.yml", __dir__)
        end.freeze

        # The longest link production can mint: "https://" + a 25-character
        # host + "/v/" + the 32 characters of SecureRandom.urlsafe_base64(24).
        LONGEST_EXPECTED_LINK = "https://#{"h" * 25}/v/#{"t" * 32}".freeze

        # Records what the ordered phone-delivery policy was asked to send.
        class FakeClient
          attr_reader :calls

          def initialize
            @calls = []
          end

          def configured?
            true
          end

          def send_phone_message(**kwargs)
            @calls << kwargs
            { "ok" => true }
          end
        end

        def setup
          @original_backend = I18n.backend
          @original_enforce_available_locales = I18n.enforce_available_locales
          @original_logger = Rails.logger

          # A fresh Simple backend holding only the two locale files keeps the
          # swap fully reversible; I18n has no way to unload translations.
          # Other files in this suite pin I18n.available_locales to their own
          # short list, so relax the check rather than widen (and thereby
          # leak) theirs — teardown puts both back.
          I18n.enforce_available_locales = false
          I18n.backend = I18n::Backend::Simple.new
          I18n.backend.load_translations(*LOCALE_FILES)

          Rails.logger = Logger.new(IO::NULL)
          @client = FakeClient.new
        end

        def teardown
          I18n.backend = @original_backend
          I18n.enforce_available_locales = @original_enforce_available_locales
          Rails.logger = @original_logger
        end

        def test_sms_carries_link_and_code_without_diacritics_and_viber_only_the_link
          deliver({ fake_url: "https://mi.example/v/abc" })
          call = @client.calls.first

          text = call[:text]
          assert_equal "MI: 123456 je tvoj kod. Ne dijeli ga. Potvrda jednim dodirom: https://mi.example/v/abc (vazi 24 sata)",
                       text
          assert_includes text, "https://mi.example/v/abc"
          assert_includes text, "123456"
          assert_equal "MI: potvrdi broj i uđi jednim dodirom: https://mi.example/v/abc (važi 24 sata) Možeš razgovarati s Milicom ovdje — odgovori na ovu poruku.",
                       call[:viber_text]
          refute_match(/[^ -~]/, text, "SMS must stay printable ASCII so it stays GSM-7")
          refute_includes call[:viber_text], "123456", "Viber implies a smartphone; the code must not travel there"
        end

        # The provider-side validity and the "24 sata" the citizen reads are two
        # separate literals. Pin them to each other so moving VERIFY_TTL cannot
        # leave the copy promising a window that has already closed.
        def test_the_stated_validity_matches_the_link_ttl
          deliver({ fake_url: "https://mi.example/v/abc" })
          call = @client.calls.first
          hours = Decidim::Bih::LoginToken::VERIFY_TTL.in_hours.to_i

          assert_in_delta Decidim::Bih::LoginToken::VERIFY_TTL.from_now, call[:expires_at], 5.seconds
          assert_includes call[:text], "#{hours} sata"
          assert_includes call[:viber_text], "#{hours} sata"
        end

        # A Cyrillic-reading citizen still gets a Latin SMS: the sr-Cyrl copy is
        # a machine transliteration of deliberately diacritic-free Latin, so it
        # reads as misspelled Cyrillic ("вази", "Немас"), and Cyrillic is UCS-2
        # anyway. Viber has no such limit and keeps the citizen's own script.
        def test_a_cyrillic_reader_gets_a_latin_sms_and_a_cyrillic_viber_message
          deliver({ fake_url: "https://mi.example/v/abc" }, locale: :"sr-Cyrl")
          call = @client.calls.first

          refute_match(/[^ -~]/, call[:text], "the SMS must not fall back to Cyrillic")
          text = call[:text]
          assert_equal "MI: 123456 je tvoj kod. Ne dijeli ga. Potvrda jednim dodirom: https://mi.example/v/abc (vazi 24 sata)",
                       text
          assert_includes text, "https://mi.example/v/abc"
          assert_includes text, "123456"
          assert_match(/\p{Cyrillic}/, call[:viber_text], "Viber keeps the citizen's script")
          assert_equal "МИ: потврди број и уђи једним додиром: https://mi.example/v/abc (важи 24 сата) Можеш разговарати с Милицом овдје — одговори на ову поруку.",
                       call[:viber_text]
        end

        # Owner decision 2026-09-07 (evening): the generic engine wording plus
        # the longest production link stays within one GSM-7 segment. A second
        # segment or a diacritic is a regression for this paid message.
        def test_sms_is_one_gsm7_segment_at_the_longest_production_link
          assert_equal 68, LONGEST_EXPECTED_LINK.length, "the link budget this test is built on has moved"

          deliver({ fake_url: LONGEST_EXPECTED_LINK })
          text = @client.calls.first[:text]
          refute_match(/[^ -~]/, text, "diacritics would force UCS-2 and a second segment")
          result = Decidim::Bih::Sms::SegmentCounter.for(text)
          assert_equal :gsm7, result[:encoding]
          assert_equal 1, result[:segments],
                       "#{result[:characters]} GSM-7 units spill into a second segment"
          assert_operator text.length, :<=, 160,
                          "#{text.length} chars spills into a second segment"
        end

        def test_channels_from_context_are_forwarded
          deliver({ fake_url: "https://mi.example/v/abc", channels: [:sms] })

          assert_equal [:sms], @client.calls.first[:channels]
        end

        def test_without_a_link_nothing_is_sent_and_delivery_reports_failure
          refute deliver({ fake_url: nil })
          assert_empty @client.calls
        end

        private

        # The citizen's own locale decides the copy, so pin it for the call
        # rather than for the whole process.
        def deliver(context, locale: :sr)
          I18n.with_locale(locale) { gateway(context).deliver_code }
        end

        def gateway(context)
          gateway = InfobipGateway.new("+38765123456", "123456", context)
          client = @client
          url = context[:fake_url]
          gateway.define_singleton_method(:client) { client }
          gateway.define_singleton_method(:magic_link_url) { url }
          gateway
        end
      end
    end
  end
end
