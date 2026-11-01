# frozen_string_literal: true
module Decidim
  module Bih
    module Launch
      class CampaignVariables
        def initialize(organization:, key:, now: Time.current)
          @organization, @key, @now = organization, key.to_s, now
          @config = Race::Config.new(organization:)
          @standings = Race::Standings.new(organization)
          @edition = Race::Edition.for(organization)
        end

        def validate_state!
          if %w(p8 p9).include?(@key)
            raise ArgumentError, "race acquisition campaign is closed" unless @config.open?(@now)
            raise ArgumentError, "race scores are hidden" unless Race::Visibility.visible?(@organization)
          end
          if @key == "p10"
            raise ArgumentError, "approved final snapshot required" unless @edition&.finalized_at && @edition.final_digest.present? && @standings.final?
            raise ArgumentError, "project vote dates required" if @edition.settings["vote_starts_at"].blank? || @edition.settings["vote_ends_at"].blank?
            raise ArgumentError, "both winners required for this template" unless %w(grad selo).all? { |zone| @standings.leader(zone) }
          end
        end

        def call(user)
          validate_state!
          member = @edition&.memberships&.find_by(decidim_user_id: user.id)
          area = member&.komsiluk || Decidim::Bih::CitizenProfile.find_by(organization: @organization, decidim_user_id: user.id)&.komsiluk
          row = area && @standings.for_komsiluk(area.id)
          raise ArgumentError, "recipient lacks a scored neighborhood" if %w(p8 p9).include?(@key) && !row
          result = { ime: user.name, link: "https://#{@organization.host}/trka", komsiluk: area&.translated_name,
                     mjesto: row && "#{row.rank_in_zone}.", datum: @now.in_time_zone("Europe/Sarajevo").strftime("%d.%m.%Y."),
                     broj: [((@config.window_to - @now) / 1.day).ceil,0].max }
          %w(grad selo).each do |zone|
            result["#{zone}_lista".to_sym] = if @key == "p10"
                                             @standings.leader(zone)&.display_name
                                           else
                                             @standings.rows(zone:).first(3).map { |r| "#{r.rank_in_zone}. #{r.display_name} (#{r.score})" }.join(", ")
                                           end
          end
          result[:datum] = Time.iso8601(@edition.settings.fetch("vote_starts_at")).in_time_zone("Europe/Sarajevo").strftime("%d.%m.%Y. u %H:%M") if @key == "p10"
          result[:broj] = Decidim::Bih::Report.where(organization: @organization).count if @key == "p8"
          result
        end
      end
    end
  end
end
