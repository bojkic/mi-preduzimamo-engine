# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/messaging/message_class"
require_relative "../../../../../app/services/decidim/bih/messaging/composer_plan"

module Decidim
  module Bih
    module Messaging
      # What the shared composer renders in its CONTENT section: one row per
      # channel, with the variant the registry says that channel carries.
      #
      # Everything here is derived from the registry. A page that hard-codes
      # "WhatsApp gets the short one" is a second source of truth that goes
      # stale silently, which is the failure this service exists to prevent.
      class ComposerPlanTest < Minitest::Test
        REPORT_COPY = "report.author_external_copy"
        CASE_MESSAGE = "report.case_message_to_author"

        def test_it_returns_one_row_per_requested_channel
          plan = ComposerPlan.for(message_class: REPORT_COPY, channels: %w(viber whatsapp))
          assert_equal(%w(viber whatsapp), plan[:variants].map { |row| row[:channel] })
        end

        # The registry carries `reference_and_status_only` for WhatsApp against
        # `full_status_text` for Viber. The composer must show that difference,
        # not one blended preview.
        def test_whatsapp_report_copy_is_not_viber_report_copy
          plan = ComposerPlan.for(message_class: REPORT_COPY, channels: %w(viber whatsapp))
          variants = plan[:variants].to_h { |row| [row[:channel], row[:variant]] }
          refute_equal variants["viber"], variants["whatsapp"],
                       "the registry distinguishes these; the composer must not hide it"
        end

        def test_each_row_names_the_group_that_governs_it
          plan = ComposerPlan.for(message_class: CASE_MESSAGE, channels: %w(bell viber))
          groups = plan[:variants].to_h { |row| [row[:channel], row[:group]] }
          assert_equal "bell", groups["bell"]
          assert_equal "external_copy", groups["viber"]
        end

        # A channel the class cannot carry is REPORTED as unsupported rather
        # than rendered with a borrowed variant from another group.
        def test_a_channel_the_class_does_not_support_is_named_not_invented
          plan = ComposerPlan.for(message_class: "city.service_alert_viber", channels: %w(viber postal))
          postal = plan[:variants].find { |row| row[:channel] == "postal" }
          assert_nil postal[:variant]
          assert_equal :unsupported_channel, postal[:reason]
          refute postal[:supported]
        end

        def test_omitting_channels_uses_every_channel_the_class_declares
          plan = ComposerPlan.for(message_class: CASE_MESSAGE)
          assert_equal MessageClass.fetch(CASE_MESSAGE).channels.sort, plan[:variants].map { |r| r[:channel] }.sort
        end

        def test_supplied_content_travels_with_its_channel
          plan = ComposerPlan.for(message_class: REPORT_COPY, channels: %w(viber whatsapp),
                                  contents: { "whatsapp" => "kratko", "viber" => "dugačko" })
          contents = plan[:variants].to_h { |row| [row[:channel], row[:content]] }
          assert_equal "dugačko", contents["viber"]
          assert_equal "kratko", contents["whatsapp"]
        end

        def test_a_channel_with_no_supplied_content_says_nothing_rather_than_borrowing
          plan = ComposerPlan.for(message_class: REPORT_COPY, channels: %w(viber whatsapp),
                                  contents: { "viber" => "dugačko" })
          whatsapp = plan[:variants].find { |row| row[:channel] == "whatsapp" }
          assert_nil whatsapp[:content], "showing Viber's text under WhatsApp would be a false preview"
        end

        # The header the operator reads: which contract this is, and how it is
        # prioritised. Both come off the registry entry.
        def test_the_plan_names_the_class_purpose_and_priority
          plan = ComposerPlan.for(message_class: REPORT_COPY, channels: %w(viber))
          entry = MessageClass.fetch(REPORT_COPY)
          assert_equal entry.key, plan[:message_class]
          assert_equal entry.purpose, plan[:purpose]
          assert_equal entry.priority, plan[:priority]
        end

        def test_an_unknown_message_class_raises_rather_than_rendering_an_empty_composer
          assert_raises(MessageClass::UnknownMessageClass) do
            ComposerPlan.for(message_class: "no.such.class", channels: %w(viber))
          end
        end

        # No page may name a message class; the registry is the only list.
        def test_the_service_hard_codes_no_message_class_key
          source = File.read(File.expand_path("../../../../../app/services/decidim/bih/messaging/composer_plan.rb", __dir__))
          MessageClass.all.each_key do |key|
            refute_includes source, "\"#{key}\"", "#{key} is hard-coded; the registry is the list"
          end
        end
      end
    end
  end
end
