# frozen_string_literal: true

namespace :decidim_bih do
  desc "Prepare inactive parking guidance for local recipient review"
  task prepare_parking_guidance: :environment do
    organization = Decidim::Organization.find(ENV.fetch("ORGANIZATION_ID"))
    guide = Decidim::Bih::ReportRoutingGuide.find_or_initialize_by(organization:, key: "parking")
    abort "Existing guidance preserved" if guide.persisted?
    categories = Decidim::Bih::ReportTaxonomy::CATEGORIES.map(&:to_s).grep(/parking|saobrac/)
    guidance = "Prijave blokiranog prolaza i nepropisnog parkiranja traže provjeru organa nadležnog za postupanje. " \
               "Zahtjevi za oznake, znakove i procjenu infrastrukture traže pregled upravljanja saobraćajem. " \
               "Ne zaključuj da je parkiranje dozvoljeno zato što znak nije vidljiv. " \
               "Ne tvrdi da je policija zaprimila prijavu bez potvrđenog upućivanja. Lokalni kontakti se odobravaju u postavkama prije aktivacije."
    guide.update!(title: "Parkiranje: postupanje i infrastruktura", categories:, active: false,
                  body_sr: guidance, approved_recipient_keys: [])
  end
end
