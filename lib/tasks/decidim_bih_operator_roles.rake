# frozen_string_literal: true

namespace :decidim_bih do
  namespace :operator_roles do
    desc "Send deduplicated 30- and 7-day operator-role expiry warnings"
    task expiry_warnings: :environment do
      puts "operator_role_expiry_warnings=#{Decidim::Bih::OperatorRoleExpiryNotifier.call}"
    end
  end
end
