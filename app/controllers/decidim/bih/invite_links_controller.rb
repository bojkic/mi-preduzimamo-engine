# frozen_string_literal: true

module Decidim
  module Bih
    # The short invite link: /p/<nadimak> (host root route, see
    # Decidim::Bih.invite_short_path) and <mount>/p/<nadimak>. It only
    # redirects to the registration form with ?ref=<nadimak>; the form's
    # controller captures the code, exactly as for the long link. A code that
    # is not nickname-shaped is dropped, and the citizen still lands on the
    # form. 302, never 301: a cached redirect would outlive a rollback.
    class InviteLinksController < Decidim::ApplicationController
      CODE = /\A[\w-]{1,60}\z/

      skip_before_action :store_current_location, raise: false

      def short
        code = params[:code].to_s
        suffix = CODE.match?(code) ? "?ref=#{CGI.escape(code)}" : nil
        redirect_to Decidim::Bih.registration_path_for(suffix), status: :found
      end
    end
  end
end
