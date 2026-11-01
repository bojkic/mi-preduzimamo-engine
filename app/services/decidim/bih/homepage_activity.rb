# frozen_string_literal: true

module Decidim
  module Bih
    # Public-only homepage entries. Never reads report free text, contacts,
    # authors, status tokens, or the members-only Komšiluk board.
    class HomepageActivity
      Entry = Struct.new(:kind, :title, :path, :created_at, keyword_init: true)
      SOURCES = [:reports, :volunteering, :organizations, :notices].freeze

      def initialize(organization, limit: 6)
        @organization = organization
        @limit = limit
      end

      def call
        SOURCES.flat_map do |source|
          public_send(source)
        rescue StandardError => e
          Rails.logger.error("[homepage_activity] #{source}: #{e.class}")
          []
        end
      end

      def reports
        Report.publicly_visible.where(organization: @organization).order(created_at: :desc, id: :desc).limit(@limit)
              .select(:id, :reference, :status, :created_at, :duplicate_of_report_id, :review_state, :reviewed_at, :last_citizen_reply_at, :decidim_organization_id)
              .map do |report|
          target = ReportStatusPresenter.main_report(report) if report.duplicate?
          title = if target
                    I18n.t("decidim.bih.reports.duplicate_display.activity", reference: report.reference, main_reference: target.reference)
                  else
                    I18n.t("decidim.bih.homepage_activity.report_title", reference: report.reference, status: ReportStatusPresenter.label(report))
                  end
          Entry.new(kind: :report, created_at: report.created_at, title:,
                    path: Decidim::Bih.public_path("prijave/#{ERB::Util.url_encode(report.reference)}"))
        end
      end

      def volunteering
        VolunteerOpportunity.publicly_visible.where(organization: @organization, cancelled_at: nil)
                            .where("ends_at IS NULL OR ends_at > ?", Time.current)
                            .where("signup_deadline_at IS NULL OR signup_deadline_at > ?", Time.current)
                            .order(Arel.sql("COALESCE(reviewed_at, created_at) DESC, id DESC")).limit(@limit)
                            .pluck(:id, :title, Arel.sql("COALESCE(reviewed_at, created_at)")).map do |id, title, created_at|
          Entry.new(kind: :volunteering, title:, created_at:,
                    path: Decidim::Bih.public_path("volontiranje#volunteer-opportunity-#{id}"))
        end
      end

      def organizations
        PartnerProfile.publicly_visible.where(organization: @organization)
                      .order(Arel.sql("COALESCE(verified_at, created_at) DESC, id DESC")).limit(@limit)
                      .pluck(:slug, :display_name, Arel.sql("COALESCE(verified_at, created_at)")).map do |slug, title, created_at|
          Entry.new(kind: :organization, title:, created_at:, path: organization_path(slug))
        end
      end

      def notices
        PartnerNotice.published.where(organization: @organization).where(published_at: ..Time.current)
                     .joins(:partner_profile).merge(PartnerProfile.publicly_visible.where(organization: @organization))
                     .recent.limit(@limit)
                     .pluck("decidim_bih_partner_profiles.slug", :title, :published_at).map do |slug, title, created_at|
          Entry.new(kind: :notice, title:, created_at:,
                    path: "#{organization_path(slug)}#obavjestenja-organizacije")
        end
      end

      private

      def organization_path(slug)
        Decidim::Bih.public_path("organizacija/#{ERB::Util.url_encode(slug)}")
      end
    end
  end
end
