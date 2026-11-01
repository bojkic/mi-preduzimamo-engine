# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Brojeve sa ove stranice citiramo u kampanji. Ako se stranica i kod
      # raziđu, kampanja laže — zato ovaj test poredi doslovno.
      class KakoTabMatchesCodeTest < ActionDispatch::IntegrationTest
        setup do
          @organization = create_organization
          host! @organization.host
        end

        # Mount path derived, ne hardkodovan — test harness montira engine na
        # /moja-platforma, produkcija na /biceriseno.
        def kako_path
          "#{Decidim::Bih.public_path("zajednistvo")}?tab=kako"
        end

        test "every earning value on the page matches the code" do
          get kako_path

          assert_response :success
          rules = Decidim::Bih::Goodwill::EarningRules.new(organization: @organization)

          rules.public_schedule.each do |action, points|
            next unless points.to_i.positive?

            label = I18n.t("decidim.bih.goodwill.actions.#{action}", locale: :sr)
            assert_includes response.body, label, "nedostaje oznaka za #{action}"
            assert_includes response.body, "+#{points}", "nedostaje vrijednost za #{action}"
          end
        end

        test "the daily limits are stated on the page and match the code" do
          get kako_path
          rules = Decidim::Bih::Goodwill::EarningRules.new(organization: @organization)

          [:like, :vote, :comment].each do |action|
            cap = rules.cap_for(action)
            label = I18n.t("decidim.bih.goodwill.actions.#{action}", locale: :sr)
            # Provjeravamo stvarnu iskazanu rečenicu, ne goli broj — mnoge
            # vrijednosti bodova na stranici su male cifre koje bi se slučajno
            # poklopile sa cap.to_s i test bi prošao i bez implementacije.
            limit_text = I18n.t("decidim.bih.kako.show.daily_limit", count: cap, locale: :sr)

            assert_includes response.body, label
            assert_includes response.body, limit_text, "nedostaje dnevna granica za #{action}"
          end
        end

        test "every action that has a daily cap states it on the page" do
          get kako_path
          rules = Decidim::Bih::Goodwill::EarningRules.new(organization: @organization)

          # Ne samo tri iz specifikacije — sve zadržane zaštite od farmanja
          # bodova (report, proposal, debate, komsiluk_post, budget_vote) takođe
          # moraju biti vidljive, jer i njih citiramo prema kodu.
          Decidim::Bih::Goodwill::EarningRules::DEFAULT_DAILY_CAPS.each_key do |action|
            cap = rules.cap_for(action)
            assert cap.present?, "#{action} bi trebalo imati dnevnu granicu u kodu"

            limit_text = I18n.t("decidim.bih.kako.show.daily_limit", count: cap, locale: :sr)
            assert_includes response.body, limit_text, "nedostaje dnevna granica za #{action}"
          end
        end

        test "the page states that points never affect voting" do
          get kako_path

          assert_includes response.body,
                          I18n.t("decidim.bih.kako.show.no_vote_policy", locale: :sr)
        end
      end
    end
  end
end
