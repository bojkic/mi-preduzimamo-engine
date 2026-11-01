# frozen_string_literal: true

namespace :decidim_bih do
  namespace :reports do
    desc "Inspect or explicitly convert selected private attachment IDs; no sends, dry-run by default"
    task private_storage_convert: :environment do
      organization = Decidim::Organization.find(Integer(ENV.fetch("ORGANIZATION_ID")))
      actor = Decidim::User.find(Integer(ENV.fetch("ACTOR_ID")))
      ids = ENV.fetch("ATTACHMENT_IDS").split(",")
      result = Decidim::Bih::ReportPrivateStorageConversion.call(organization:, actor:, attachment_ids: ids,
                                                                 apply: ENV["APPLY"] == "1", confirmation: ENV.fetch("CONFIRM", nil))
      puts JSON.generate(result)
    end
  end
end
