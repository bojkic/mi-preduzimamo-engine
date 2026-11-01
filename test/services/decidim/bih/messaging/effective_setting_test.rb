# frozen_string_literal: true

require "test_helper"
require "i18n"
require "yaml"
require_relative "../../../../../app/services/decidim/bih/messaging/effective_setting"

module Decidim
  module Bih
    module Messaging
      # Pure: no Rails, no ActiveRecord. EffectiveSetting must stay usable
      # without ActiveSupport loaded, because it is the one object the page
      # cannot render an honest row without.
      class EffectiveSettingTest < Minitest::Test
        LOCALES_DIR = File.expand_path("../../../../../config/locales", __dir__)

        def self.sr_copy
          @sr_copy ||= YAML.load_file(File.join(LOCALES_DIR, "sr.yml"))
                           .dig("sr", "decidim", "bih", "communication_settings") || {}
        end

        def setup
          I18n.backend = I18n::Backend::Simple.new
          I18n.available_locales = [:sr, :en]
          I18n.backend.store_translations(
            :sr, { decidim: { bih: { communication_settings: self.class.sr_copy } } }
          )
        end

        def build(**) = EffectiveSetting.new(row: { id: :report_updates_viber }, **)

        def test_a_matching_pair_does_not_differ_and_shows_no_reason
          setting = build(requested: true, effective: true, origin: "account", reason_key: nil)
          refute setting.differs?
          assert_nil setting.reason_key
          assert_nil setting.citizen_reason(:sr)
        end

        def test_an_organization_default_is_shown_as_such_not_as_a_personal_choice
          setting = build(requested: true, effective: true, origin: "organization_default", reason_key: nil)
          assert_equal "organization_default", setting.origin
          refute setting.personal_choice?
        end

        def test_a_provider_stop_beats_a_requested_yes_and_says_why
          setting = build(requested: true, effective: false, origin: "provider_opt_out", reason_key: "provider_stop")
          assert setting.differs?
          assert_equal "provider_stop", setting.reason_key
        end

        def test_a_missing_phone_makes_a_requested_yes_ineffective
          assert build(requested: true, effective: false, origin: "account", reason_key: "no_verified_phone").differs?
        end

        def test_unknown_origin_stays_unknown_and_is_never_rendered_as_a_refusal
          setting = build(requested: nil, effective: false, origin: "unknown", reason_key: "never_chosen")
          assert_equal "unknown", setting.origin
          refute_equal false, setting.requested, "absent is not a stored no"
          refute setting.differs?, "an absent choice cannot disagree with anything"
          assert setting.never_chosen?
        end

        def test_a_backend_enum_is_never_the_citizen_string
          setting = build(requested: false, effective: false, origin: "provider_opt_out", reason_key: "provider_stop")
          reason = setting.citizen_reason(:sr).to_s
          refute_empty reason, "the sr copy for provider_stop is missing from config/locales/sr.yml"
          refute_includes reason, "provider_opt_out"
          refute_includes reason, "followed-only"
          refute_includes reason, "provider_stop"
        end

        def test_every_origin_and_reason_key_has_serbian_copy
          EffectiveSetting::ORIGINS.each do |origin|
            assert self.class.sr_copy.dig("origin", origin).to_s != "",
                   "no sr copy for communication_settings.origin.#{origin}"
          end
          EffectiveSetting::REASON_KEYS.each do |reason|
            assert self.class.sr_copy.dig("reasons", reason).to_s != "",
                   "no sr copy for communication_settings.reasons.#{reason}"
          end
        end

        def test_the_origin_labels_never_leak_the_backend_enum_itself
          EffectiveSetting::ORIGINS.each do |origin|
            refute_includes self.class.sr_copy.dig("origin", origin).to_s, origin
          end
        end

        def test_an_unknown_origin_is_refused_rather_than_rendered
          assert_raises(ArgumentError) do
            build(requested: true, effective: true, origin: "followed-only", reason_key: nil)
          end
        end

        def test_an_unknown_reason_key_falls_back_to_the_generic_string
          setting = build(requested: true, effective: false, origin: "account", reason_key: "no_such_reason")
          assert_equal self.class.sr_copy.dig("reasons", "generic"), setting.citizen_reason(:sr)
        end

        def topic_channel(**)
          EffectiveSetting.for_topic_channel(row: { id: :report_updates_viber }, **)
        end

        def test_a_stored_yes_on_a_working_channel_is_a_personal_choice_with_no_reason
          setting = topic_channel(requested: true, permitted: true, channel_reason: nil, provenance_source: "account")
          assert setting.effective
          assert setting.personal_choice?
          assert_nil setting.reason_key
        end

        def test_a_stored_yes_on_an_unusable_channel_keeps_the_yes_and_names_the_obstacle
          setting = topic_channel(requested: true, permitted: true, channel_reason: "no_verified_phone",
                                  provenance_source: "account")
          assert_equal true, setting.requested
          refute setting.effective
          assert setting.differs?
          assert_equal "no_verified_phone", setting.reason_key
        end

        def test_an_absent_key_is_unknown_and_never_chosen_not_refused
          setting = topic_channel(requested: nil, permitted: false, channel_reason: nil, provenance_source: "absent")
          assert_equal "unknown", setting.origin
          assert_equal "never_chosen", setting.reason_key
          refute setting.differs?
          refute setting.checked?
        end

        def test_an_organization_default_yes_is_not_relabelled_as_a_personal_choice
          setting = topic_channel(requested: true, permitted: true, channel_reason: nil,
                                  provenance_source: "organization_default")
          assert_equal "organization_default", setting.origin
          refute setting.personal_choice?
          assert_nil setting.reason_key
        end

        def test_a_provider_stop_explains_the_stored_no
          setting = topic_channel(requested: false, permitted: false, channel_reason: nil,
                                  provenance_source: "provider_opt_out")
          assert_equal "provider_stop", setting.reason_key
          refute setting.differs?, "a stored no that is honoured is not a disagreement"
        end

        def test_a_stored_no_with_no_provider_stop_needs_no_excuse
          setting = topic_channel(requested: false, permitted: false, channel_reason: nil,
                                  provenance_source: "account")
          assert_nil setting.reason_key
        end

        def test_an_imported_value_is_shown_as_carried_over_not_as_a_choice
          setting = topic_channel(requested: true, permitted: true, channel_reason: nil, provenance_source: "legacy_import")
          assert_equal "legacy", setting.origin
          refute setting.personal_choice?
        end

        def test_a_stored_value_with_no_recorded_provenance_is_unrecorded_not_account
          setting = topic_channel(requested: true, permitted: true, channel_reason: nil, provenance_source: "unknown")
          assert_equal "unrecorded", setting.origin
          refute setting.personal_choice?, "a stored value nobody recorded is not evidence of a choice"
          assert_nil setting.reason_key
        end

        def test_an_unmapped_provenance_value_is_unrecorded_when_a_value_exists
          setting = topic_channel(requested: false, permitted: false, channel_reason: nil, provenance_source: "martian")
          assert_equal "unrecorded", setting.origin
        end

        def test_an_unmapped_provenance_value_is_unknown_when_nothing_is_stored
          setting = topic_channel(requested: nil, permitted: false, channel_reason: nil, provenance_source: "martian")
          assert_equal "unknown", setting.origin
        end

        def test_origin_label_is_a_key_lookup_not_the_enum
          setting = build(requested: true, effective: true, origin: "organization_default", reason_key: nil)
          assert_equal self.class.sr_copy.dig("origin", "organization_default"), setting.citizen_origin(:sr)
        end
      end
    end
  end
end
