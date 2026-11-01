# frozen_string_literal: true

require "cgi"
require "erb"
require "rqrcode"

module Decidim
  module Bih
    module Goodwill
      # Builds channel-native invite links carrying a referrer's code, so a
      # referral can be attributed SERVER-SIDE when the invited person registers
      # and verifies (off-site likes/shares are unverifiable and are never
      # rewarded). The shared landing URL renders an Open Graph card.
      #
      #   landing  -> https://<host>/registracija?ref=<code>, or the host's short
      #               form https://<host>/p/<code> when Decidim::Bih.invite_short_path
      #               is set (the short route 302s to the same registration form)
      #   whatsapp -> https://api.whatsapp.com/send?text=<msg + landing>
      #   facebook -> https://www.facebook.com/sharer/sharer.php?u=<landing>
      #   viber    -> viber://forward?text=<msg + landing>
      #
      # The referrer code is the user's nickname (stable, unique per org).
      class InviteLinks
        def initialize(referrer, base_url:, message: nil)
          @referrer = referrer
          @base_url = base_url.to_s.chomp("/")
          @message = message || default_message
        end

        def code
          @referrer.nickname
        end

        # The invitee lands on the registration form, not the hub: an anonymous
        # visitor on the "pozovi" tab was only told to sign in to get their own
        # link, and never registered. RegistrationsController#new captures the
        # code into the session; the hub tab still accepts old links.
        def landing_url
          "#{@base_url}#{Decidim::Bih.invite_short_path_for(code) || Decidim::Bih.registration_path_for("?ref=#{CGI.escape(code)}")}"
        end

        # The landing URL as a standalone SVG QR code, for the invite tab and
        # for printing. nil when rendering fails: the tab must still show the
        # link. Memoised — the tab renders it inline AND offers it for
        # download, and one render is enough.
        def qr_svg
          return @qr_svg if defined?(@qr_svg)

          # standalone: true adds an XML prolog, which is invalid inside an
          # HTML document — strip it; the rest is a complete <svg> element that
          # works both inline and saved as a file.
          @qr_svg = RQRCode::QRCode.new(landing_url, level: :m)
                                   .as_svg(module_size: 4, standalone: true, use_path: true, viewbox: true)
                                   .sub(/\A<\?xml[^>]*\?>\s*/, "")
        rescue StandardError => e
          logger&.error("[goodwill] invite QR not rendered: #{e.class}")
          @qr_svg = nil
        end

        def whatsapp_url
          "https://api.whatsapp.com/send?text=#{enc("#{@message} #{landing_url}")}"
        end

        def facebook_url
          "https://www.facebook.com/sharer/sharer.php?u=#{enc(landing_url)}"
        end

        def viber_url
          "viber://forward?text=#{enc("#{@message} #{landing_url}")}"
        end

        def all
          { landing: landing_url, whatsapp: whatsapp_url, facebook: facebook_url, viber: viber_url }
        end

        private

        def logger
          Rails.logger if defined?(Rails) && Rails.respond_to?(:logger)
        end

        def enc(value)
          CGI.escape(value)
        end

        def default_message
          I18n.t("decidim.bih.goodwill.invite.share_message", default: "Pridruži se zajednici Mi pre(d)uzimamo!")
        end
      end
    end
  end
end
