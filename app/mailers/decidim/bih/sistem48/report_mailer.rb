# frozen_string_literal: true

module Decidim
  module Bih
    module Sistem48
      # Builds the plain-text e-mail that forwards a "Bice riseno" citizen
      # report into the city's Sistem 48 intake. The body is FixMyStreet-style:
      # an enriched, human-readable summary that a clerk can act on directly,
      # including a clickable OpenStreetMap link for the exact location.
      #
      # The body is composed inline (no view template) so the engine stays
      # self-contained and the format is trivially testable.
      # Subclasses ActionMailer::Base directly (rather than an ApplicationMailer)
      # to keep this forwarding mailer self-contained within the engine.
      class ReportMailer < ActionMailer::Base
        # Default sender; overridable so each institution can use its own
        # verified envelope address.
        DEFAULT_FROM = "reports@example.org"

        # report is a Hash with symbol keys: reference, category, department,
        # severity, description, address, lat, lng, photo_url, reporter_contact.
        def report_email(report = nil, evidence: nil, **attributes)
          report = (report || {}).to_h.symbolize_keys.merge(attributes)
          category = report[:category]
          organization = resolve_organization(report[:organization_id])

          if evidence.nil?
            source = Report.find_by(organization:, reference: report[:reference]) if organization && report[:reference].present?
            evidence = source ? ReportEvidence.attachments(source) : []
          end
          ReportEvidence.attach(self, evidence)
          report[:photo_url] = nil if evidence.any?
          mail(
            to: report[:recipient].presence || DepartmentRouting.email_for(category, organization),
            from: sender_address,
            subject: subject_for(report),
            body: body_for(report, organization)
          )
        end

        private

        def sender_address
          ENV.fetch("SISTEM48_FROM", nil).presence ||
            Decidim::Bih.sistem48_mailer_from.presence ||
            DEFAULT_FROM
        end

        # Resolves the org for per-organization routing overrides. Nil id (older
        # payloads / standalone) yields nil, so routing falls back to ENV/default.
        def resolve_organization(organization_id)
          return nil if organization_id.blank?

          Decidim::Organization.find_by(id: organization_id)
        end

        # AI-computed severity (nizak / normalan / visok / hitan); accepts a
        # Symbol or String. Only :hitan triggers the urgency treatment.
        def hitan?(report)
          report[:severity].to_s == "hitan"
        end

        def subject_for(report)
          base = "Prijava problema [#{report[:reference]}] — #{report[:category]}"
          hitan?(report) ? "[HITNO] #{base}" : base
        end

        # Plain "Hitnost: <severity>" for normal reports (byte-identical to the
        # historical line); a prominent uppercase ⚠ banner only for :hitan, so a
        # Sistem 48 clerk triages it first.
        def severity_line(report)
          return "Hitnost: #{report[:severity]}" unless hitan?(report)

          "⚠ HITNOST: #{report[:severity].to_s.upcase} ⚠"
        end

        def body_for(report, organization = nil)
          lat = report[:lat]
          lng = report[:lng]
          contact = report[:reporter_contact].presence || "anonimno"

          lines = [
            "Nova prijava komunalnog problema (proslijeđeno putem #{Decidim::Bih.sistem48_forwarded_via_name}).",
            "",
            "Referentni broj: #{report[:reference]}",
            "Kategorija: #{report[:category]}",
            "Nadležni organ: #{report[:department]}",
            severity_line(report),
            "",
            "Opis građanina:",
            report[:description].to_s,
            "",
            "Lokacija: #{report[:address]}",
            *coordinate_lines(lat, lng),
            *mz_context_lines(lat, lng, organization),
            "",
            "Kontakt prijavioca: #{contact}"
          ]

          if report[:photo_url].present?
            lines << ""
            lines << "Napomena: uz prijavu je priložena fotografija (#{report[:photo_url]})."
          end

          "#{lines.join("\n")}\n"
        end

        def coordinate_lines(lat, lng)
          return [] if lat.blank? || lng.blank?

          ["Koordinate: #{lat},#{lng}", "Mapa: #{osm_link(lat, lng)}"]
        end

        # W6.3 — ADDITIVE local-area context. When the report's coordinates fall
        # inside a known Mjesna zajednica, we append the MZ name and (if on file)
        # its president + phone so the Sistem 48 clerk knows the responsible local
        # body. This is purely informational: it never changes the routing target
        # (the city's central intake stays authoritative) and MZ presidents have
        # no e-mail on file to route to. With no geo data, no organization, a
        # point outside every MZ, or any lookup error, this returns [] and the
        # forward is byte-identical to the pre-W6.3 behavior.
        def mz_context_lines(lat, lng, organization)
          return [] if organization.nil? || lat.blank? || lng.blank?

          mz_slug = Decidim::Bih::Geo::PointRouting.resolve(
            lat:, lon: lng, organization:
          )[:mz_slug]
          return [] if mz_slug.blank?

          # The forwarded email is Serbian (Latin); resolve the MZ name in :sr so
          # it stays language-consistent regardless of the caller's I18n.locale
          # (a report can be forwarded from a request/job in any active locale).
          contact = I18n.with_locale(:sr) do
            Decidim::Bih::Geo::PointRouting.mz_contact(slug: mz_slug, organization:)
          end
          return [] if contact.nil?

          lines = ["", "Mjesna zajednica: #{contact[:name]}"]
          lines << "Predsjednik MZ: #{contact[:predsjednik]}" if contact[:predsjednik].present?
          lines << "Telefon MZ: #{contact[:telefon]}" if contact[:telefon].present?
          lines
        rescue StandardError => e
          Rails.logger.error("[Sistem48::ReportMailer] MZ context lookup failed: #{e.class}: #{e.message}")
          []
        end

        # OpenStreetMap deep link with a marker at the reported coordinates.
        def osm_link(lat, lng)
          "https://www.openstreetmap.org/?mlat=#{lat}&mlon=#{lng}#map=18/#{lat}/#{lng}"
        end
      end
    end
  end
end
