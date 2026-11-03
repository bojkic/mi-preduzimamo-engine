# frozen_string_literal: true

require_relative "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # The one surface where a letter is actually produced: the admin presses
      # "print the letter" on a pending postal_letter authorization and the
      # response IS the letter — there is no second render, and the raw token
      # exists only in that response.
      #
      # Regression this locks down: the QR code was rendered with rqrcode's
      # `standalone: false`, which returns bare <path> markup with no <svg>
      # wrapper. Every letter printed for months carried no scannable code at
      # all, and nothing failed — the markup was simply invisible. Asserting on
      # the presence of an <svg> element (not merely "some QR was attempted")
      # is the whole point of this test.
      class PostalPrintableLetterTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        ADDRESS = "Pere Stanića 15/3"
        CODE = "483921"

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                          name: "Marina Đorđević Mitrović")
          # PostageForm#map_model reads "pending_verification_code" (the code the
          # citizen's request generated); PerformAuthorizationStep is what promotes
          # it to "verification_code" and stamps letter_sent_at. Seeding
          # "verification_code" directly would leave the form blank and invalid.
          @authorization = Decidim::Authorization.create!(
            user: @citizen, name: "postal_letter", granted_at: nil,
            verification_metadata: { "address" => ADDRESS, "pending_verification_code" => CODE }
          )
          sign_in @admin
        end

        # The admin engine mounts at /admin/postal_letter, and `resource :postages`
        # makes the segment plural. Ask the helper rather than spelling the path
        # out, so a remount cannot leave this test silently green on a 404.
        # The controller builds its form with from_model, so the POST carries no
        # params at all.
        def print_letter!
          post decidim_admin_postal_letter.pending_authorization_postage_path(@authorization, locale: :sr)
        end

        def test_the_printed_letter_carries_a_real_svg_qr_code
          print_letter!

          assert_response :success
          assert_match(/<svg[\s>]/, response.body, "the letter must carry a full <svg> element")
          assert_includes response.body, "</svg>"
        end

        def test_the_qr_is_not_an_xml_document_fragment
          print_letter!

          # `standalone: true` alone would emit an XML prolog, which is invalid
          # inside an HTML document and breaks parsing in some print engines.
          refute_includes response.body, "<?xml"
        end

        def test_the_letter_carries_the_code_the_address_and_the_recipient
          print_letter!

          assert_includes response.body, CODE
          assert_includes response.body, "Marina Đorđević Mitrović"
          assert_includes response.body, "Pere Stanića 15/3"
        end

        def test_the_letter_explains_the_platform_rather_than_only_verifying
          print_letter!

          scope = "decidim.bih.postal.admin.postages.printable_letter"
          assert_includes response.body, I18n.t("#{scope}.benefits_title", locale: :sr)
          assert_includes response.body, I18n.t("#{scope}.benefits.report.title", locale: :sr)
          assert_includes response.body, I18n.t("#{scope}.encouragement", locale: :sr)
        end

        def test_the_operator_note_about_the_token_is_not_part_of_the_printed_page
          print_letter!

          # It is rendered, but outside .mi-letter-page and hidden in @media
          # print — the citizen must never receive instructions meant for staff.
          assert_includes response.body, "mi-letter-opnote"
          assert_match(/@media print\b[^}]*\{[^@]*\.mi-letter-opnote/m, response.body)
        end

        # The regression that put admin furniture on posted paper: the letter
        # used to render inside "decidim/admin/users", so every print carried
        # the nav, the organisation switcher and the signed-in operator's
        # e-mail address to a citizen's letterbox.
        def test_the_letter_does_not_render_inside_the_admin_layout
          print_letter!

          refute_includes response.body, @admin.email
          refute_match(/<(header|nav)[\s>]/, response.body)
          refute_includes response.body, "main-dropdown-menu-bar"
          refute_includes response.body, "layout-wrapper"
        end

        def test_the_letter_is_a_standalone_document_sized_to_one_a4_sheet
          print_letter!

          assert_match(/@page\s*\{[^}]*size:\s*A4/m, response.body)
          assert_match(/\.mi-letter-page\s*\{[^}]*height:\s*297mm/m, response.body)
        end

        # The address block must sit where the envelope window is, and must be
        # positioned independently of anything above it.
        def test_the_recipient_block_is_placed_for_a_window_envelope
          print_letter!

          assert_match(/class="mi-letter-address"[^>]*style="[^"]*left:\s*115mm/, response.body)
          assert_match(/class="mi-letter-address"[^>]*style="[^"]*top:\s*45mm/, response.body)
        end

        def test_the_window_position_follows_the_configured_geometry
          ::Decidim::Bih::Setting.put(@organization, "postal", "window_side", "left")
          ::Decidim::Bih::Setting.put(@organization, "postal", "window_top_mm", "50")

          print_letter!

          assert_match(/class="mi-letter-address"[^>]*style="[^"]*left:\s*20mm/, response.body)
          assert_match(/class="mi-letter-address"[^>]*style="[^"]*top:\s*50mm/, response.body)
        end

        # The signature ran underneath the privacy note on the printed page: the
        # footer was absolutely positioned, so it was out of flow and the copy
        # simply flowed beneath it. It must be pushed down by the body instead.
        def test_the_footer_is_in_flow_so_it_cannot_overlap_the_signature
          print_letter!

          assert_match(/\.mi-letter-foot\s*\{[^}]*margin-top:\s*auto/m, response.body)
          refute_match(/\.mi-letter-foot\s*\{[^}]*position:\s*absolute/m, response.body)
          assert_match(/\.mi-letter-page\s*\{[^}]*flex-direction:\s*column/m, response.body)
        end

        # An unset letterhead is the DEFAULT, and it is what production printed:
        # no return address and no settlement line. The operator must be told
        # before the print dialog, not after the postbox.
        def test_an_unset_letterhead_warns_the_operator_on_screen_only
          print_letter!

          # Match the ELEMENT, not the bare class name: the stylesheet always
          # carries a .mi-letter-warning rule, so a substring check on the class
          # is true whether or not the banner rendered.
          assert_match(/<p class="mi-letter-warning">/, response.body)
          assert_includes response.body, I18n.t(
            "decidim.bih.postal.admin.postages.printable_letter.letterhead_missing",
            keys: "city_line", locale: :sr
          )
          # …and never on paper.
          assert_match(/@media print\b[^}]*\{[^@]*\.mi-letter-warning/m, response.body)
        end

        def test_a_configured_letterhead_raises_no_warning
          ::Decidim::Bih::Setting.put(@organization, "postal", "sender_line", "Fondacija, Ulica 1")
          ::Decidim::Bih::Setting.put(@organization, "postal", "city_line", "76300 Bijeljina")

          print_letter!

          refute_match(/<p class="mi-letter-warning">/, response.body)
          refute_includes response.body, I18n.t(
            "decidim.bih.postal.admin.postages.printable_letter.letterhead_missing",
            keys: "city_line", locale: :sr
          )
        end

        test "a settlement without an optional return address raises no warning" do
          ::Decidim::Bih::Setting.put(@organization, "postal", "city_line", "76300 Bijeljina")

          print_letter!

          assert_response :success
          refute_match(/<p class="mi-letter-warning">/, response.body)
          refute_match(/<div class="mi-letter-sender">/, response.body)
        end

        # A street-only address must still name a settlement, or the letter
        # cannot be delivered.
        def test_the_configured_city_line_is_appended_when_the_address_has_no_postcode
          ::Decidim::Bih::Setting.put(@organization, "postal", "city_line", "76300 Bijeljina")

          print_letter!

          assert_includes response.body, "76300 Bijeljina"
        end

        def test_the_confirm_url_is_a_working_magic_link_for_this_citizen
          print_letter!

          token = response.body[%r{/v/([A-Za-z0-9_-]+)}, 1]
          refute_nil token, "the letter must print a confirm URL"

          record = Decidim::Bih::LoginToken.where(user: @citizen, purpose: "postal").last
          refute_nil record
          assert_nil record.consumed_at
        end
      end
    end
  end
end
