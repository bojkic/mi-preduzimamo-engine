# frozen_string_literal: true

# Workaround for CVE-2026-40295 (GHSA-jp94-3292-c3xv), the open redirect in
# Devise::FailureApp fixed in Devise 5.0.4. Decidim 0.31 pins Devise ~> 4.7 and
# 4.9.4 has no backport. Decidim's Warden failure app is RandomStalling
# (decidim-core config/initializers/devise.rb), which inherits the vulnerable
# redirect_url: when a session times out on a non-GET request, Devise redirects
# to the raw Referer header, which can name any host.
#
# This follows Devise 5.0.4's redirect_url, which reduces the Referer to path,
# query and fragment, and goes one step further: the GET branch's
# attempted_path (the request path, which Devise 5.0.4 still passes through
# raw) runs through the same normaliser, because a request for
# `//evil.example/x` would otherwise produce `Location: //evil.example/x`.
#
# It does not reuse Devise 4.9.4's StoreLocation#extract_path_from_location:
# that version lacks 5.x's nil-path check (an opaque Referer such as
# `javascript:x` would raise and 500), and neither version requires a leading
# slash — Rails turns a string redirect into `protocol + host + string`, so a
# Referer of `.evil.example` would land on `<our host>.evil.example`. On both
# branches only an absolute same-host path survives (leading slashes collapse
# to one, any host is dropped); anything else falls back to the sign-in page.
#
# The method is rebuilt in full rather than calling super with an adjusted
# request: no recursion path, and nothing else in the chain redefines it.
#
# Remove once Decidim allows Devise >= 5.0.4 (Decidim 0.32).
module Decidim
  module Bih
    module DeviseTimeoutRedirectOverride
      protected

      def redirect_url
        return scope_url unless warden_message == :timeout

        flash[:timedout] = true if is_flashing_format?
        same_host_path(request.get? ? attempted_path : request.referer) || scope_url
      end

      private

      def same_host_path(location)
        uri = URI.parse(location.to_s)
        path = uri.path.to_s.sub(%r{\A/+}, "/")
        return unless path.start_with?("/")

        [[path, uri.query].compact.join("?"), uri.fragment].compact.join("#")
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end

RandomStalling.prepend(Decidim::Bih::DeviseTimeoutRedirectOverride) unless RandomStalling < Decidim::Bih::DeviseTimeoutRedirectOverride
