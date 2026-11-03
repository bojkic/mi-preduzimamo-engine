# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Launch mode (isporuka B, Task 2): the homepage hero must be able to
      # swap its three design-kit buttons for a host-supplied list, every
      # "register" link must follow Decidim::Bih.registration_path instead of
      # a hardcoded /users/sign_up, thin activity counters must be hideable,
      # and the omni band must offer a button that opens the chat.
      class MiHeroLaunchCtasTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        HERO_SCOPE = "decidim.bih.content_blocks.mi_hero"
        CTA_SCOPE = "#{HERO_SCOPE}.launch_ctas".freeze

        setup do
          @previous_cache = Rails.cache
          Rails.cache = ActiveSupport::Cache::MemoryStore.new
          @previous_hero_settings = {
            mi_hero_ctas: Decidim::Bih.mi_hero_ctas,
            mi_hero_stat_min: Decidim::Bih.mi_hero_stat_min,
            registration_path: Decidim::Bih.registration_path
          }
          Decidim::Bih.mi_hero_ctas = nil
          Decidim::Bih.mi_hero_stat_min = 0
          Decidim::Bih.registration_path = "/users/sign_up"
          @organization = create_organization
          host! @organization.host
          FactoryBot.create(:content_block, organization: @organization, scope_name: :homepage,
                                            manifest_name: :mi_hero, published_at: Time.current)
          FactoryBot.create(:content_block, organization: @organization, scope_name: :homepage,
                                            manifest_name: :mi_hub, published_at: Time.current)
        end

        teardown do
          if instance_variable_defined?(:@previous_hero_settings)
            @previous_hero_settings.each { |key, value| Decidim::Bih.public_send("#{key}=", value) }
          end
          if instance_variable_defined?(:@previous_cache)
            Rails.cache.clear
            Rails.cache = @previous_cache
          end
        end

        def launch_ctas
          [
            { label_key: "#{CTA_SCOPE}.register", href: :registration, style: "primary" },
            { label_key: "#{CTA_SCOPE}.report", href: "/biceriseno/prijave/new", style: "ghost" },
            { label_key: "#{CTA_SCOPE}.ask", href: "/biceriseno/mi-bot", style: "ghost", chat: true }
          ]
        end

        def cta_label(key)
          I18n.t("#{CTA_SCOPE}.#{key}", locale: :sr)
        end

        def assert_launch_ctas_rendered
          assert_response :success
          assert_select ".mi-hero__ctas a.mi-btn", count: 3
          assert_select ".mi-hero__ctas a.mi-btn.mi-btn--primary[href='/registracija-test']",
                        text: cta_label("register")
          assert_select ".mi-hero__ctas a.mi-btn[href='/biceriseno/prijave/new']", text: cta_label("report")
          assert_select ".mi-hero__ctas a.mi-btn[data-mi-bot-open][href='/biceriseno/mi-bot']",
                        text: cta_label("ask")
          # The design-kit defaults must be gone, not merely pushed down.
          assert_select ".mi-hero__ctas a", text: I18n.t("#{HERO_SCOPE}.cta_secondary", locale: :sr), count: 0
          assert_select ".mi-hero__ctas a[href='/processes']", count: 0
        end

        test "configured hero ctas replace the defaults and the register link follows registration_path" do
          Decidim::Bih.registration_path = "/registracija-test"
          Decidim::Bih.mi_hero_ctas = launch_ctas

          get "/sr/"

          assert_launch_ctas_rendered
          # registration_path also owns the side register panel, not just the CTA row.
          assert_select ".mi-hero-register a[href='/registracija-test']"
          # Scoped to the hero: Decidim core's own header still owns a
          # /users/sign_up link that this configuration does not touch.
          assert_select "#mi-hero a[href='/users/sign_up']", count: 0
        end

        # The host sets both of these to Procs (launch mode decides the button
        # list and the floor at request time, not at boot). A Proc is never
        # blank and has no #to_i, so both must be resolved BEFORE the blank
        # check in #hero_ctas and before the comparison in #stat_visible?.
        test "hero ctas and the stat minimum may be supplied as procs" do
          3.times { FactoryBot.create(:user, :confirmed, organization: @organization) }
          Decidim::Bih.registration_path = "/registracija-test"
          ctas = launch_ctas
          Decidim::Bih.mi_hero_ctas = -> { ctas }
          Decidim::Bih.mi_hero_stat_min = -> { 20 }

          get "/sr/"

          assert_launch_ctas_rendered
          assert_select ".mi-hero-stats__item .mi-hero-stats__label",
                        text: I18n.t("#{HERO_SCOPE}.stats.citizens", count: 3, locale: :sr), count: 0
          assert_select ".mi-hero-stats__item--hi .mi-hero-stats__label",
                        text: I18n.t("#{HERO_SCOPE}.stats.campaign", locale: :sr)
        end

        test "positional config callbacks receive the current organization once" do
          3.times { FactoryBot.create(:user, :confirmed, organization: @organization) }
          Decidim::Bih.registration_path = "/registracija-test"
          cta_organizations = []
          stat_organizations = []
          ctas = launch_ctas
          Decidim::Bih.mi_hero_ctas = lambda do |organization|
            cta_organizations << organization
            ctas
          end
          Decidim::Bih.mi_hero_stat_min = lambda do |organization|
            stat_organizations << organization
            20
          end

          get "/sr/"

          assert_launch_ctas_rendered
          assert_equal [@organization], cta_organizations
          assert_equal [@organization], stat_organizations
          assert_select ".mi-hero-stats__item .mi-hero-stats__label",
                        text: I18n.t("#{HERO_SCOPE}.stats.citizens", count: 3, locale: :sr), count: 0
        end

        test "callable object and keyword-only method configs retain compatible invocation" do
          3.times { FactoryBot.create(:user, :confirmed, organization: @organization) }
          Decidim::Bih.registration_path = "/registracija-test"
          cta_organizations = []
          ctas = launch_ctas
          cta_source = Object.new
          cta_source.define_singleton_method(:call) do |organization|
            cta_organizations << organization
            ctas
          end
          stat_calls = []
          stat_source = Object.new
          stat_source.define_singleton_method(:configured_minimum) do |preview: false|
            stat_calls << preview
            20
          end
          Decidim::Bih.mi_hero_ctas = cta_source
          Decidim::Bih.mi_hero_stat_min = stat_source.method(:configured_minimum)

          get "/sr/"

          assert_launch_ctas_rendered
          assert_equal [@organization], cta_organizations
          assert_equal [false], stat_calls
          assert_select ".mi-hero-stats__item .mi-hero-stats__label",
                        text: I18n.t("#{HERO_SCOPE}.stats.citizens", count: 3, locale: :sr), count: 0
        end

        # A :registration button swaps its DESTINATION for a signed-in citizen,
        # so it has to swap its LABEL too — otherwise launch mode tells someone
        # who already has an account to "Registruj se" and sends them to
        # /moj-doprinos.
        test "a signed-in citizen gets the signed-in label and the account link on a registration cta" do
          sign_in FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Bih.registration_path = "/registracija-test"
          Decidim::Bih.mi_hero_ctas = [
            { label_key: "#{CTA_SCOPE}.register",
              signed_in_label_key: "#{HERO_SCOPE}.register.signed_in_cta",
              href: :registration, style: "primary" },
            { label_key: "#{CTA_SCOPE}.report", href: "/biceriseno/prijave/new", style: "ghost" }
          ]
          account_path = Decidim::Bih.public_path("moj-doprinos")

          get "/sr/"

          assert_response :success
          assert_select ".mi-hero__ctas a.mi-btn--primary[href='#{account_path}']",
                        text: I18n.t("#{HERO_SCOPE}.register.signed_in_cta", locale: :sr)
          assert_select ".mi-hero__ctas a", text: cta_label("register"), count: 0
          assert_select ".mi-hero__ctas a[href='/registracija-test']", count: 0
        end

        # Without signed_in_label_key the single label_key is used in both
        # states — the pre-existing contract must not silently change.
        test "a cta with no signed_in_label_key keeps its only label when signed in" do
          sign_in FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Bih.mi_hero_ctas = [
            { label_key: "#{CTA_SCOPE}.report", href: "/biceriseno/prijave/new", style: "ghost" }
          ]

          get "/sr/"

          assert_response :success
          assert_select ".mi-hero__ctas a.mi-btn", count: 1
          assert_select ".mi-hero__ctas a[href='/biceriseno/prijave/new']", text: cta_label("report")
        end

        # The floor applies to activity counters only. UNFILTERED_STAT_KEYS
        # (campaign, reports_total, reports_sent, launch_invitations) is the
        # list of tiles that must survive it — the report counters are the
        # campaign's headline figures and show from the very first report.
        test "activity stat tiles below the configured minimum are hidden, the campaign tile is not" do
          3.times { FactoryBot.create(:user, :confirmed, organization: @organization) }
          2.times { create_report! }

          citizens_label = I18n.t("#{HERO_SCOPE}.stats.citizens", count: 3, locale: :sr)
          reports_total_label = I18n.t("#{HERO_SCOPE}.stats.reports_total", count: 2, locale: :sr)
          campaign_label = I18n.t("#{HERO_SCOPE}.stats.campaign", locale: :sr)

          get "/sr/"

          assert_response :success
          assert_select ".mi-hero-stats__item .mi-hero-stats__value", text: "3"
          assert_select ".mi-hero-stats__item .mi-hero-stats__label", text: citizens_label
          assert_select ".mi-hero-stats__item .mi-hero-stats__label", text: reports_total_label

          Decidim::Bih.mi_hero_stat_min = 20
          Rails.cache.clear

          get "/sr/"

          assert_response :success
          assert_select ".mi-hero-stats__item .mi-hero-stats__label", text: citizens_label, count: 0
          assert_select ".mi-hero-stats__item .mi-hero-stats__label", text: reports_total_label
          assert_select ".mi-hero-stats__item--hi .mi-hero-stats__label", text: campaign_label
        end

        test "the omni band has a button that opens the chat" do
          get "/sr/"

          assert_response :success
          assert_select ".mi-omni-band a[data-mi-bot-open]",
                        text: I18n.t("decidim.bih.content_blocks.mi_hub.omni.ask", locale: :sr)
        end

        private

        def create_report!
          Decidim::Bih::Report.create!(
            organization: @organization,
            reference: SecureRandom.hex(6),
            description: "Rasvjeta ne radi u ulici pored škole.",
            category: "putevi",
            severity: "normalan",
            status: "rijeseno"
          )
        end
      end
    end
  end
end
