# frozen_string_literal: true

module Decidim
  module Bih
    # Static, presentational data for the MI bot showcase page — a Ruby port of
    # the design kit's `bot-data.jsx` (CHANNELS, CONVERSATIONS, STICKERS,
    # ICON_SET) plus the message-card templates from `bot-assets.jsx`.
    #
    # The conversation bubble text is illustrative Serbian (ijekavica, informal
    # "ti") demonstrating the bot's voice — it is intentionally NOT routed through
    # i18n and stays literal in Serbian across every locale. Section headings and
    # intro copy (rendered by the view) are translated; this data is not.
    module MiBotData
      extend ActiveSupport::Concern

      # ---- Per-channel chrome themes (colours + status copy) ----
      def mi_bot_channels
        {
          "viber" => {
            id: "viber", name: "Viber", brand: "#7360F2",
            header_bg: "#7360F2", header_ink: "#fff", chat_bg: "#f4f1fb",
            out_bubble: "#7360F2", out_ink: "#fff", in_bubble: "#fff", in_ink: "#2b2b3a",
            status: "na vezi", status_ink: "rgba(255,255,255,0.85)", icon: "phone",
            input_placeholder: "Poruka", send_bg: "#7360F2", light: false
          },
          "whatsapp" => {
            id: "whatsapp", name: "WhatsApp", brand: "#25D366",
            header_bg: "#075E54", header_ink: "#fff", chat_bg: "#e5ddd5",
            out_bubble: "#d9fdd3", out_ink: "#111b21", in_bubble: "#fff", in_ink: "#111b21",
            status: "na mreži", status_ink: "rgba(255,255,255,0.85)", icon: "video",
            input_placeholder: "Upiši poruku", send_bg: "#128C7E", light: false
          },
          "messenger" => {
            id: "messenger", name: "Messenger", brand: "#0084FF",
            header_bg: "#ffffff", header_ink: "#1c1e21", chat_bg: "#ffffff",
            out_bubble: "#0084FF", out_ink: "#fff", in_bubble: "#f0f0f0", in_ink: "#1c1e21",
            status: "Aktivan/na", status_ink: "#65676b", icon: "phone",
            input_placeholder: "Aa", send_bg: "#0084FF", light: true
          }
        }
      end

      # ---- Conversations: ordered steps per channel ----
      # Each step is one of:
      #   { who: "bot"|"me", t: "..." }            -> message bubble
      #   { quick: ["..", ".."] }                  -> quick-reply chips
      #   { card: { kind:, ... } }                 -> rich card bubble
      #   { sticker: "id" }                        -> sticker stamp
      #   { note: "time" }                         -> centred time/label divider
      def mi_bot_conversations
        {
          "viber" => {
            flow: "Prijava problema",
            steps: [
              { note: "danas 09:14" },
              { who: "bot", t: "Zdravo, komšija! 👋 Ja sam #{mi_bot_showcase_assistant_name} — tvoja prečica do grada. Šta radimo danas?" },
              { quick: ["📍 Prijavi problem", "💡 Predloži ideju", "💰 Budžet", "❤️ Doniraj"] },
              { who: "me", t: "📍 Prijavi problem" },
              { who: "bot", t: "Važi! Pošalji mi lokaciju ili samo napiši gdje je problem." },
              { who: "me", t: "Velika rupa na putu kod Doma zdravlja, ulica #{mi_bot_demo_street}" },
              { who: "bot", t: "Primljeno 👍 Koji je tip problema?" },
              { quick: ["🚧 Kolovoz", "💡 Rasvjeta", "🗑️ Smeće", "💧 Voda"] },
              { who: "me", t: "🚧 Kolovoz" },
              { card: { kind: "prijava", id: "#2481", title: "Oštećen kolovoz", addr: "#{mi_bot_demo_street} bb", status: "Prijavljeno" } },
              { who: "bot", t: "Prijava je poslata komunalnoj službi. Javljam ti čim ekipa krene 🛠️" },
              { sticker: "prijavljeno" }
            ]
          },
          "whatsapp" => {
            flow: "Predloži i podrži",
            steps: [
              { note: "danas 18:42" },
              { who: "bot", t: "Ćao! Imaš ideju za #{mi_bot_demo_city_accusative}? Reci mi je u jednoj rečenici 🙂" },
              { who: "me", t: "Biciklistička staza od centra do #{mi_bot_demo_destination}" },
              { who: "bot", t: "Odlično 🚲 Dodajem je u modul „Predlažemo”. Treba 500 podrški da ode pred Skupštinu grada." },
              { card: { kind: "prijedlog", title: mi_bot_demo_proposal_title, support: 487, goal: 500 } },
              { who: "me", t: "👍 Podržavam!" },
              { who: "bot", t: "Ti si 488. podrška! 💪 Podijeli komšijama da brže stignemo do cilja." },
              { sticker: "preuzimamo" }
            ]
          },
          "messenger" => {
            flow: "Glasanje o budžetu",
            steps: [
              { note: "danas 12:03" },
              { who: "bot", t: "Ove godine MI odlučujemo o #{mi_bot_demo_budget_amount} gradskog budžeta 💪 Hoćeš da rasporediš svoj dio?" },
              { quick: ["Da, glasam", "Vidi projekte"] },
              { who: "me", t: "Da, glasam" },
              { card: { kind: "budzet", items: mi_bot_demo_budget_items } },
              { who: "bot", t: "Izabrao si 2 projekta — ostalo ti je 180.000 KM. Da pošaljem tvoj glas?" },
              { quick: ["✅ Pošalji glas"] },
              { who: "me", t: "✅ Pošalji glas" },
              { sticker: "glas" },
              { who: "bot", t: "Glas je zabilježen! Rezultate objavljujemo 1. jula. Hvala što odlučuješ 🙌" }
            ]
          }
        }
      end

      # ---- Sticker pack (branded PNG stamps reused from /mi/stickers) ----
      # `tone` drives the stamp frame colour; `id` maps to /mi/stickers/<id>.png.
      def mi_bot_stickers
        [
          { id: "prijavljeno", text: "PRIJAVLJENO", sub: "ekipa stiže", tone: "coral", shape: "badge" },
          { id: "podrzano", text: "PODRŽANO!", sub: "+1 glas", tone: "park", shape: "badge" },
          { id: "glas", text: "GLAS ZABILJEŽEN", sub: nil, tone: "sava", shape: "circle" },
          { id: "hvala", text: "HVALA, KOMŠIJA!", sub: nil, tone: "coral", shape: "circle" },
          { id: "preuzimamo", text: mi_bot_showcase_sticker_text, sub: nil, tone: "navy", shape: "badge" },
          { id: "rijeseno", text: "RIJEŠENO", sub: "svaka čast", tone: "park", shape: "badge" },
          { id: "stize", text: "STIŽE EKIPA", sub: "u toku", tone: "sun", shape: "badge" },
          { id: "volim", text: mi_bot_campaign_sticker_text, sub: nil, tone: "navy", shape: "circle" },
          { id: "bravo", text: "BRAVO!", sub: "tvoj glas se čuje", tone: "coral", shape: "badge" }
        ]
      end

      # ---- Icon set (modules + statuses) ----
      # `icon` is an inline-SVG key resolved by MiBotIconsHelper; `tone` maps to a
      # soft-bg / ink CSS class pair.
      def mi_bot_icon_set
        [
          {
            group_key: "modules",
            items: [
              { icon: "megaphone", label: "Predlažemo", tone: "sava" },
              { icon: "wallet", label: "Budžet", tone: "park" },
              { icon: "map-pin", label: "Prijavi", tone: "coral" },
              { icon: "sprout", label: "Projekti", tone: "sun" },
              { icon: "heart", label: "Doniraj", tone: "coral" },
              { icon: "vote", label: "Glasaj", tone: "sava" }
            ]
          },
          {
            group_key: "statuses",
            items: [
              { icon: "message-circle", label: "Na vezi", tone: "park" },
              { icon: "check-check", label: "Riješeno", tone: "park" },
              { icon: "clock", label: "U toku", tone: "sun" },
              { icon: "bell", label: "Obavještenje", tone: "coral" },
              { icon: "camera", label: "Dodaj foto", tone: "sava" },
              { icon: "landmark", label: "Skupština", tone: "navy" }
            ]
          }
        ]
      end

      def mi_bot_showcase_assistant_name
        Decidim::Bih.mi_bot_showcase_assistant_name.to_s.presence || "asistent platforme"
      end

      def mi_bot_showcase_sticker_text
        Decidim::Bih.mi_bot_showcase_sticker_text.to_s.presence || "PREUZIMAMO"
      end

      # ---- Message-card templates (the "Šabloni poruka" sheet) ----
      # `label_key` resolves under decidim.bih.mi_bot.templates.*; `card`/`kind`
      # reuse the same renderers as the in-conversation cards.
      def mi_bot_templates
        [
          { label_key: "prijedlog", accent: "var(--mi-sava-500)",
            card: { kind: "prijedlog", title: mi_bot_demo_proposal_title, support: 487, goal: 500 } },
          { label_key: "prijava", accent: "var(--mi-coral-600)",
            card: { kind: "prijava", title: "Oštećen kolovoz", addr: "#{mi_bot_demo_street} bb", status: "Prijavljeno", id: "#2481" } },
          { label_key: "budzet", accent: "var(--mi-park-500)",
            card: { kind: "budzet", items: mi_bot_demo_budget_items } },
          { label_key: "donacija", accent: "var(--mi-coral-600)",
            card: { kind: "donacija", title: mi_bot_demo_donation_title, raised: "6.240", goal: "10.000", pct: 62 } },
          { label_key: "akcije", accent: nil,
            card: { kind: "akcije", options: ["📍 Prijavi problem", "💡 Predloži ideju", "💰 Budžet grada", "❤️ Doniraj", "📊 Moje prijave"] } },
          { label_key: "obavjestenje", accent: "var(--mi-sun-500)",
            card: { kind: "obavjestenje", title: "Tvoja prijava je riješena! ✅",
                    body: "Rupa u ulici #{mi_bot_demo_street} je sanirana. Hvala što si prijavio — grad je bolji zbog tebe." } }
        ]
      end

      private

      def mi_bot_campaign_sticker_text
        hashtag = mi_bot_campaign_hashtag
        hashtag.empty? ? "VOLIM GRAD" : hashtag
      end

      def mi_bot_hashtag_suffix
        hashtag = mi_bot_campaign_hashtag
        hashtag.empty? ? "" : " #{hashtag}"
      end

      def mi_bot_campaign_hashtag
        Decidim::Bih.campaign_hashtag.to_s.strip
      end

      def mi_bot_demo_city_accusative
        Decidim::Bih.mi_bot_demo_city_accusative.to_s.strip
      end

      def mi_bot_demo_street
        Decidim::Bih.mi_bot_demo_street.to_s.strip
      end

      def mi_bot_demo_address
        Decidim::Bih.mi_bot_demo_address.to_s.strip
      end

      def mi_bot_demo_destination
        Decidim::Bih.mi_bot_demo_destination.to_s.strip
      end

      def mi_bot_demo_proposal_title
        Decidim::Bih.mi_bot_demo_proposal_title.to_s.strip
      end

      def mi_bot_demo_budget_amount
        Decidim::Bih.mi_bot_demo_budget_amount.to_s.strip
      end

      def mi_bot_demo_budget_items
        Array(Decidim::Bih.mi_bot_demo_budget_items)
      end

      def mi_bot_demo_donation_title
        Decidim::Bih.mi_bot_demo_donation_title.to_s.strip
      end
    end
  end
end
