# frozen_string_literal: true

# Workaround for CVE-2026-32700 (GHSA-57hq-95w6-v4fc), the Devise confirmable
# "change email" race fixed in Devise 5.0.3. Decidim 0.31 pins Devise ~> 4.7
# and 4.9.4 has no backport, so the fix is applied here.
#
# The race: two concurrent email changes on the same account each load the
# row, and ActiveRecord writes only the columns that changed in memory. If one
# request sets unconfirmed_email to the value it already loaded, that column is
# left out of its UPDATE while its new confirmation_token is written — so the
# row can end up pairing the OTHER request's address with the token that was
# mailed to the attacker's address, and confirming it hands over an address
# the attacker does not own. Marking unconfirmed_email dirty first forces it
# into every UPDATE that regenerates the token, exactly as Devise 5.0.3 does
# with devise_unconfirmed_email_will_change! (a Devise 5 ORM wrapper; on 4.9
# the ActiveRecord dirty method is the same call).
#
# super is safe here: this is a model method with no alias chain, and the
# prepend is guarded against a second application on code reload.
#
# Remove once Decidim allows Devise >= 5.0.3 (Decidim 0.32).
module Decidim
  module Bih
    module UserEmailChangeRaceOverride
      protected

      def postpone_email_change_until_confirmation_and_regenerate_confirmation_token
        unconfirmed_email_will_change!
        super
      end
    end
  end
end

Decidim::User.prepend(Decidim::Bih::UserEmailChangeRaceOverride) unless Decidim::User < Decidim::Bih::UserEmailChangeRaceOverride
