# frozen_string_literal: true

module Decidim
  module Bih
    module Launch
      # Reference launch-campaign message catalogue.
      #
      # Delivery uses Viber Business Messages, an explicitly configured WhatsApp
      # template, then email where applicable. These campaign messages never use
      # SMS. Missing message keys are deliberately unsupported.
      #
      # Locale bodies live under decidim.bih.launch.messages.<key>.<channel>.
      # P11 is email-only; email may otherwise reuse the Viber copy.
      module MessageTemplates
        KEYS = %w(p1 p3 p4 p5 p7 p8 p9 p10 p11).freeze
        SCOPE = "decidim.bih.launch.messages"

        # Reference WhatsApp template names and parameter order only.
        # Each installation must obtain approval for its own sender, language
        # and exact provider template before enabling this channel. These names
        # do not transfer approval or prove the recipient received a message.
        # P1/P3/P7 have no WhatsApp mapping. Keep the distinct P4 quantities
        # `fali` (missing points) and `ostalo` (remaining invitations) separate.
        WHATSAPP = {
          "p4" => { name: "mi_p4_fali_bodova_v1", params: %w(ime fali ostalo) },
          "p5" => { name: "mi_p5_nove_pozivnice_v1", params: %w(broj) },
          # P8 v1 asserts event attendance and forwarding that current data
          # cannot establish. Leave WhatsApp unavailable until a reviewed
          # replacement provider template is approved and wired here.
          "p9" => { name: "mi_p9_trka_sedmica_v1", params: %w(datum komsiluk mjesto broj grad_lista selo_lista) },
          "p10" => { name: "mi_p10_pobjednici_v1", params: %w(grad_lista selo_lista datum) }
        }.freeze
        WHATSAPP_LANGUAGE = "sr"

        module_function

        def render(key, channel:, locale: :sr, **vars)
          key = key.to_s
          raise ArgumentError, "Unknown message #{key}" unless KEYS.include?(key)
          raise ArgumentError, "#{key} has no #{channel} variant" unless variant?(key, channel)

          rendered = I18n.t("#{SCOPE}.#{key}.#{channel}", locale:, **vars).strip
          raise ArgumentError, "#{key} has unresolved interpolation" if rendered.match?(/%\{[^}]+\}/)
          rendered
        end

        # Which channels a given message actually has. P11 is a letter to MZ
        # presidents — email only, never SMS. WhatsApp is a template, not a
        # locale variant, so it is answered from WHATSAPP.
        def variant?(key, channel)
          return WHATSAPP.has_key?(key.to_s) if channel.to_s == "whatsapp"

          I18n.exists?("#{SCOPE}.#{key}.#{channel}", :sr)
        end

        # The whatsapp_template: hash Infobip::Client#send_phone_message takes
        # for +key+, or nil when the message has no template. Values are
        # stringified in placeholder order; a missing variable is an error
        # here rather than an empty placeholder at Meta.
        def whatsapp_template(key, **vars)
          entry = WHATSAPP[key.to_s]
          return if entry.blank?

          body = entry[:params].each_with_index.to_h do |param, index|
            value = vars.fetch(param.to_sym) { raise(ArgumentError, "#{key} WhatsApp template needs #{param}") }
            raise ArgumentError, "#{key} WhatsApp template needs #{param}" if value.to_s.strip.empty?
            [(index + 1).to_s, value.to_s]
          end
          { name: entry[:name], language: WHATSAPP_LANGUAGE, body: }
        end
      end
    end
  end
end
