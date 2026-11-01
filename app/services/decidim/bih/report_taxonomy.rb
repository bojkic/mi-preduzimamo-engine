# frozen_string_literal: true

module Decidim
  module Bih
    # Stable civic report vocabulary shared by intake, staff review and routing.
    module ReportTaxonomy
      CATEGORIES = [
        :rasvjeta,
        :saobracaj,
        :ekologija_otpad,
        :putevi,
        :komunalna_policija,
        :vodovod_kanalizacija,
        :grijanje,
        :ostalo
      ].freeze

      SEVERITIES = [:nizak, :normalan, :visok, :hitan].freeze

      CATEGORY_DEPARTMENT = {
        rasvjeta: "Javna rasvjeta",
        saobracaj: "Saobraćaj i signalizacija",
        ekologija_otpad: "Ekologija i otpad",
        putevi: "Putevi i infrastruktura",
        komunalna_policija: "Komunalna policija",
        vodovod_kanalizacija: "Vodovod i kanalizacija",
        grijanje: "Grijanje",
        ostalo: "Ostalo"
      }.freeze
    end
  end
end
