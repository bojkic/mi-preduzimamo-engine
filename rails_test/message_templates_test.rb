# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # The launch campaign's message catalogue (P1-P11) asserts on real
      # I18n.t lookups against the engine's loaded locale files, so it belongs
      # in the Rails suite: the fast suite boots no Rails and loads no engine
      # locales, and there these assertions would pass while testing nothing.
      #
      # Realistic worst-case substitutions — a real magic link is ~52
      # characters, and the SMS budget has to survive it.
      class MessageTemplatesTest < ActiveSupport::TestCase
        SAMPLE = {
          ime: "Milica",
          kod: "MI-XXXXX-XXXXX",
          link: "https://mi.fondacijabijeljina.com/v/#{"t" * 32}",
          broj: "150",
          datum: "11.9.",
          komsiluk: "Brčanska malta",
          mjesto: "3.",
          fali: "5",
          ostalo: "120"
        }.freeze

        # decidim.bih.sms.* keys that are actually sent AS AN SMS. Every one of
        # them has to be GSM-7: Cyrillic or a single diacritic switches the
        # encoding to UCS-2, which cuts the segment from 160 characters to 70
        # and doubles (or triples) the price of a message whose link alone is
        # ~68 characters. The Viber-only keys are deliberately absent — Viber
        # implies a smartphone, is not segment-limited, and keeps the
        # citizen's own letters.
        SMS_TEXT_KEYS = %w(verification_link login_link_and_code).freeze
        VIBER_ONLY_KEYS = %w(viber_verify_link login_link).freeze
        SMS_LOCALES = %w(en sr bs hr).freeze

        # The longest link production can mint: "https://" + a 25-character
        # host + "/v/" + the 32 characters of SecureRandom.urlsafe_base64(24).
        LONGEST_LINK = "https://#{"h" * 25}/v/#{"t" * 32}".freeze

        # Owner decision 2026-09-07: the race campaign is minimal and must not use
        # SMS at all. SMS is the only channel billed per segment, and P1/P2 were
        # two segments each with realistic values — the sample this file used to
        # pass with had a 52-character link and a 7-character code, so it proved
        # one segment for texts that shipped as two.
        test "no campaign message has an SMS variant" do
          Decidim::Bih::Launch::MessageTemplates::KEYS.each do |key|
            refute Decidim::Bih::Launch::MessageTemplates.variant?(key, :sms),
                   "#{key} must not carry an SMS text: the campaign never uses SMS"
          end
        end

        # P2 (72-hour expiry reminder) and P6 (waiting list) existed only to serve
        # the sweep that voided unconfirmed invitations. The sweep is gone — 310
        # invitations for 350 seats is not over-subscribed — so they are too.
        test "p2 and p6 are gone with the sweep they served" do
          refute_includes Decidim::Bih::Launch::MessageTemplates::KEYS, "p2"
          refute_includes Decidim::Bih::Launch::MessageTemplates::KEYS, "p6"
          assert_raises(ArgumentError) { Decidim::Bih::Launch::MessageTemplates.render("p2", channel: :viber, **SAMPLE) }
        end

        # `fali` (points still missing) and `ostalo` (invitations left) are
        # different quantities. One variable used to fill both, so every P4 told
        # the citizen the two numbers were equal.
        test "p4 renders the missing points and the invitations left as two different numbers" do
          text = Decidim::Bih::Launch::MessageTemplates.render("p4", channel: :viber, **SAMPLE)

          assert_includes text, "još 5 bodova"
          assert_includes text, "još 120 pozivnica"

          template = Decidim::Bih::Launch::MessageTemplates.whatsapp_template("p4", ime: "Milica", fali: "5", ostalo: "120")

          assert_equal({ "1" => "Milica", "2" => "5", "3" => "120" }, template[:body])
          assert_raises(ArgumentError) { Decidim::Bih::Launch::MessageTemplates.whatsapp_template("p4", ime: "Milica", fali: "5") }
        end

        # Owner decision 2026-09-07: the value shown at the door is a "broj
        # rezervacije" everywhere — the pages, the e-mail and the invitation
        # message already said so while the campaign copy still said "kod za ulaz".
        test "invitation messages call the value a reservation number" do
          %w(p1 p3 p7).each do |key|
            text = Decidim::Bih::Launch::MessageTemplates.render(key, channel: :viber, **SAMPLE)

            assert_match(/[Bb]roj rezervacije/, text, key)
            refute_match(/[Kk]od za ulaz/, text, key)
          end
        end

        # The launch catalogue above is not the only SMS this platform sends:
        # the verification link and the passwordless login link go out through
        # the gateway and the phone-login controller, in whichever of the four
        # languages the citizen is reading.
        test "every sms locale key that is sent as an SMS fits one GSM-7 segment" do
          SMS_LOCALES.each do |locale|
            SMS_TEXT_KEYS.each do |key|
              text = I18n.t("decidim.bih.sms.#{key}", url: LONGEST_LINK, code: "123456", locale:)
              result = Decidim::Bih::Sms::SegmentCounter.for(text)

              assert_equal :gsm7, result[:encoding],
                           "#{locale}/#{key}: an SMS in UCS-2 costs double and this copy is Latin anyway"
              assert_equal 1, result[:segments],
                           "#{locale}/#{key}: #{result[:characters]} characters spills into a second segment"
            end
          end
        end

        # The list above must not silently miss a newly added key: everything
        # under decidim.bih.sms.* is either guarded as SMS text or declared
        # Viber-only.
        test "every decidim.bih.sms key is classified as SMS text or Viber only" do
          keys = I18n.t("decidim.bih.sms", locale: :sr).keys.map(&:to_s)

          assert_equal (SMS_TEXT_KEYS + VIBER_ONLY_KEYS).sort, keys.sort,
                       "a new decidim.bih.sms.* key must be added to SMS_TEXT_KEYS or VIBER_ONLY_KEYS"
        end

        test "Viber templates keep full diacritics" do
          text = Decidim::Bih::Launch::MessageTemplates.render("p1", channel: :viber, **SAMPLE)

          assert_match(/[čćžšđ]/, text, "Viber is free and readable — it keeps our letters")
        end

        test "placeholders are substituted" do
          text = Decidim::Bih::Launch::MessageTemplates.render("p1", channel: :viber, **SAMPLE)

          assert_match SAMPLE[:kod], text
          refute_match(/%\{|\{kod\}/, text, "no placeholder may survive rendering")
        end

        # P5 announces a new wave. Under the client's single-wave decision it is
        # built but never scheduled — it must still render, so restoring waves is
        # a configuration change.
        test "p5 still renders even though it is not scheduled" do
          assert_match SAMPLE[:link], Decidim::Bih::Launch::MessageTemplates.render("p5", channel: :viber, **SAMPLE)
        end

        test "p11 is email only" do
          assert_raises(ArgumentError) { Decidim::Bih::Launch::MessageTemplates.render("p11", channel: :viber, **SAMPLE) }
          assert_match(/mjesne zajednice/i, Decidim::Bih::Launch::MessageTemplates.render("p11", channel: :email, **SAMPLE))
        end
      end
    end
  end
end
