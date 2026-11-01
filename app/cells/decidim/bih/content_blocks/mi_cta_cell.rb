# frozen_string_literal: true

module Decidim
  module Bih
    module ContentBlocks
      # Homepage closing CTA content block from the MI PRE(D)UZIMAMO! design
      # kit: centered heart mark, the "Grad se ne mijenja sam. / Mijenjamo ga
      # MI." display headline, sub copy, join/projects pills and the brand
      # hashtag. Data-light — copy comes from i18n
      # (decidim.bih.content_blocks.mi_cta.*), styling from the host theme
      # (public/mi/mi-theme.css: .mi-cta).
      class MiCtaCell < Decidim::ViewModel
        include Decidim::SanitizeHelper

        delegate :current_organization, to: :controller

        # Signed-out visitors are invited to register; signed-in citizens are
        # pointed at their goodwill wallet instead.
        def primary_cta_key
          current_organization_user ? "cta_contribution" : "cta_join"
        end

        def primary_cta_href
          current_organization_user ? Decidim::Bih.public_path("moj-doprinos") : Decidim::Bih.registration_path
        end

        def secondary_cta_href
          Decidim::Bih.public_path("projekti")
        end

        def t_scope(key)
          t(key, scope: "decidim.bih.content_blocks.mi_cta")
        end

        def heart_mark_path
          "/mi/heart-mark.webp"
        end

        private

        def current_organization_user
          Decidim::Bih.organization_scoped_user(current_user, current_organization)
        end
      end
    end
  end
end
