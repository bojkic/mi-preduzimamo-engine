# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/messaging/message_class"

module Decidim
  module Bih
    module Messaging
      # Pure contract tests for the producer registry. No Rails, no database:
      # the registry is a declaration of what exists and how it may be routed,
      # and it has to be readable before any application boots.
      class MessageClassTest < Minitest::Test
        def test_every_entry_declares_the_full_contract
          MessageClass.all.each do |key, entry|
            assert_equal key, entry.key
            assert_includes MessageClass::PURPOSES, entry.purpose, "#{key} purpose"
            assert_includes MessageClass::PRIORITIES, entry.priority, "#{key} priority"
            assert_includes MessageClass::PAYLOAD_CLASSES, entry.payload_class, "#{key} payload class"
            assert_includes MessageClass::ENROLLMENT_STATES, entry.enrollment, "#{key} enrollment"
            assert_includes MessageClass::DEDUPLICATION_OWNERS, entry.deduplication_owner, "#{key} dedup owner"
            assert_includes MessageClass::PREFERENCE_ADAPTERS, entry.preference_adapter, "#{key} adapter"
            refute_empty entry.producer, "#{key} producer"
            refute_empty entry.recipient_kinds, "#{key} recipient kinds"
            assert_empty entry.recipient_kinds - MessageClass::RECIPIENT_KINDS, "#{key} recipient kinds"
          end
        end

        def test_channel_groups_declare_mode_channels_and_ownership
          MessageClass.all.each do |key, entry|
            entry.channel_groups.each do |group|
              refute_empty group.fetch(:name).to_s, "#{key} group name"
              assert_includes MessageClass::GROUP_MODES, group.fetch(:mode), "#{key}/#{group[:name]} mode"
              assert_empty Array(group.fetch(:channels)) - MessageClass::CHANNELS, "#{key}/#{group[:name]} channels"
              refute_empty group.fetch(:content_variant).to_s, "#{key}/#{group[:name]} content variant"
              assert_includes MessageClass::FALLBACK_OWNERS, group.fetch(:fallback_owner), "#{key}/#{group[:name]} fallback owner"
            end
          end
        end

        def test_a_fallback_group_needs_more_than_one_channel_and_a_single_group_exactly_declares_a_choice
          MessageClass.all.each do |key, entry|
            entry.channel_groups.each do |group|
              case group.fetch(:mode)
              when "fallback"
                assert_operator Array(group.fetch(:channels)).length, :>, 1, "#{key}/#{group[:name]} is a chain of one"
              when "parallel"
                assert_operator Array(group.fetch(:channels)).length, :>, 0, "#{key}/#{group[:name]} has no channel"
              end
            end
          end
        end

        def test_unknown_class_is_refused_rather_than_guessed
          assert_raises(MessageClass::UnknownMessageClass) { MessageClass.fetch("not.a.real.class") }
          assert_nil MessageClass.find("not.a.real.class")
          refute MessageClass.known?("not.a.real.class")
        end

        def test_unknown_class_cannot_be_dispatched_by_an_enrolled_sender
          error = assert_raises(MessageClass::UnknownMessageClass) do
            MessageClass.resolve!("not.a.real.class", channel: "viber")
          end

          assert_match(/not\.a\.real\.class/, error.message)
        end

        def test_invalid_class_channel_combination_is_refused
          assert_raises(MessageClass::UnsupportedChannel) do
            MessageClass.resolve!("city.service_alert_viber", channel: "sms")
          end
          assert_raises(MessageClass::UnsupportedChannel) do
            MessageClass.resolve!("report.stale_digest_email", channel: "whatsapp")
          end
          assert MessageClass.supports_channel?("city.service_alert_viber", "viber")
          refute MessageClass.supports_channel?("city.service_alert_viber", "sms")
        end

        def test_resolve_returns_the_group_that_owns_the_channel
          group = MessageClass.resolve!("report.case_message_to_author", channel: "whatsapp")

          assert_equal "external_copy", group.fetch(:name)
          assert_equal "single", group.fetch(:mode)
        end

        def test_external_topic_lookup_accepts_email_but_not_inbox_push_or_sms
          %w(viber whatsapp messenger instagram email).each do |channel|
            assert_equal channel, MessageClass.topic_channel!(channel)
          end

          %w(bell push sms postal web_chat).each do |channel|
            assert_raises(MessageClass::UnsupportedChannel) { MessageClass.topic_channel!(channel) }
          end
        end

        def test_topic_preference_adapters_only_appear_on_external_channel_groups
          topic_adapters = %w(report_updates_topic community_news_topic city_service_alerts_topic neighborhood_info_topic platform_news_topic)
          MessageClass.all.each_value do |entry|
            next unless topic_adapters.include?(entry.preference_adapter)

            entry.channel_groups.select { |group| group.fetch(:preference_adapter) == entry.preference_adapter }.each do |group|
              assert_empty Array(group.fetch(:channels)) - MessageClass::TOPIC_CHANNELS,
                           "#{entry.key}/#{group[:name]} would pass a non-topic channel into the MI key lookup"
            end
          end
        end

        def test_every_group_adapter_is_recognised
          MessageClass.all.each do |key, entry|
            entry.channel_groups.each do |group|
              assert_includes MessageClass::PREFERENCE_ADAPTERS, group.fetch(:preference_adapter),
                              "#{key}/#{group[:name]} adapter"
            end
          end
        end

        def test_enrolment_is_a_declared_subset_and_everything_else_is_legacy
          enrolled = MessageClass.enrolled.keys
          legacy = MessageClass.legacy_unmigrated.keys

          refute_empty enrolled
          refute_empty legacy
          assert_equal MessageClass.all.keys.sort, (enrolled + legacy).sort
          assert_empty enrolled & legacy
          # Phase 1 enrols only what already routes through the MI stored-key
          # matrix; nothing else may claim coverage.
          assert_operator legacy.length, :>, enrolled.length
        end

        def test_enrolled_entries_are_shadow_only_in_this_phase
          MessageClass.enrolled.each_value do |entry|
            assert_equal "shadow", entry.enrollment, "#{entry.key} must not claim authority in phase 1"
          end
        end

        # ---- characterised special cases -------------------------------------

        def test_operator_registration_resend_is_email_plus_sms_only_and_not_the_failover_chain
          entry = MessageClass.fetch("registration.operator_resend")
          channels = entry.channel_groups.flat_map { |group| Array(group.fetch(:channels)) }

          assert_equal %w(email sms), channels.sort
          refute_includes channels, "viber"
          refute_includes channels, "whatsapp"
          entry.channel_groups.each { |group| refute_equal "fallback", group.fetch(:mode) }
        end

        def test_registration_verification_keeps_the_ordered_phone_chain_with_a_final_sms
          group = MessageClass.fetch("authentication.phone_verification").channel_groups.fetch(0)

          assert_equal %w(viber whatsapp sms), group.fetch(:channels)
          assert_equal "fallback", group.fetch(:mode)
          assert_equal "provider", group.fetch(:fallback_owner)
        end

        def test_marketing_campaign_uses_all_suitable_external_channels_without_sms
          entry = MessageClass.fetch("campaign.marketing_phone")
          channels = entry.channel_groups.flat_map { |group| Array(group.fetch(:channels)) }

          assert_equal %w(email instagram messenger viber whatsapp), channels.sort
          refute_includes channels, "sms"
          assert_includes channels, "email"
          assert_equal "platform_news_topic", entry.preference_adapter
          assert_equal %w(P4 P5 P8 P9 P10), entry.message_keys
        end

        def test_transactional_campaign_keys_keep_their_email_fallback_and_never_use_sms
          entry = MessageClass.fetch("campaign.transactional_phone")
          channels = entry.channel_groups.flat_map { |group| Array(group.fetch(:channels)) }

          assert_equal %w(P1 P3 P7), entry.message_keys
          refute_includes channels, "sms"
          assert_includes channels, "email"
        end

        def test_p11_has_no_platform_audience_and_therefore_no_platform_channel
          entry = MessageClass.fetch("campaign.letter_p11")

          assert_empty(entry.channel_groups.flat_map { |group| Array(group.fetch(:channels)) })
          assert_equal "legacy_unmigrated", entry.enrollment
          assert entry.external_boundary?
        end

        def test_report_direct_email_and_account_external_copy_are_different_classes
          direct = MessageClass.fetch("report.reporter_status_email")
          copy = MessageClass.fetch("report.author_external_copy")

          assert_equal(%w(email), direct.channel_groups.flat_map { |group| Array(group.fetch(:channels)) })
          assert_equal "report_contact_address", direct.preference_adapter
          assert_includes direct.recipient_kinds, "anonymous_report_contact"

          assert_equal "report_updates_topic", copy.preference_adapter
          assert_equal %w(account), copy.recipient_kinds
          assert_empty Array(copy.channel_groups.fetch(0).fetch(:channels)) - MessageClass::TOPIC_CHANNELS
        end

        def test_push_fans_out_per_device_rather_than_once_per_recipient
          group = MessageClass.fetch("push.bell_fanout").channel_groups.fetch(0)

          assert_equal "parallel", group.fetch(:mode)
          assert_equal "per_device", group.fetch(:fanout)
          assert_equal "device_subscription", group.fetch(:preference_adapter)
        end

        def test_case_message_viber_text_and_whatsapp_template_are_different_content_variants
          entry = MessageClass.fetch("report.case_message_to_author")
          external = entry.channel_groups.find { |group| group.fetch(:name) == "external_copy" }

          assert_equal "reference_and_status_only", external.fetch(:content_variant_by_channel).fetch("whatsapp")
          assert_equal "full_case_text", external.fetch(:content_variant_by_channel).fetch("viber")
        end

        def test_bell_and_push_are_a_parallel_copy_group_not_a_fallback_chain
          entry = MessageClass.fetch("report.case_message_to_staff")
          entry.channel_groups.each do |group|
            refute_equal "fallback", group.fetch(:mode), "a delivered bell must never terminate another group"
          end
        end

        def test_external_boundaries_are_named_and_are_not_producers
          refute_empty MessageClass::EXTERNAL_BOUNDARIES
          MessageClass::EXTERNAL_BOUNDARIES.each do |boundary|
            refute_empty boundary.fetch(:key).to_s
            refute_empty boundary.fetch(:reason).to_s
            refute MessageClass.known?(boundary.fetch(:key)),
                   "#{boundary[:key]} is a boundary; it must not also be a producer"
          end
        end

        def test_keys_are_unique_stable_and_namespaced
          keys = MessageClass.all.keys

          assert_equal keys.uniq, keys
          keys.each { |key| assert_match(/\A[a-z0-9_]+\.[a-z0-9_]+\z/, key) }
        end
      end
    end
  end
end
