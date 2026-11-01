# frozen_string_literal: true

module Decidim
  module Bih
    module Launch
      # How many launch invitations are left.
      #
      # The client settled on 310 invitations in ONE wave opening 6.9.2026, but
      # the schedule stays a LIST of waves in config. Restoring the original
      # three-wave plan must be a configuration change, never a code change —
      # and the "Ovaj talas je popunjen. Novi kreće {datum}." message then works
      # by itself.
      #
      # DEPENDENCY NOTE: the invitation reward itself (issuing, entry code,
      # 72-hour confirmation) is built on the parallel recalibration branch. This
      # class therefore counts issued invitations by querying the fulfillments
      # TABLE directly and never references a class from that branch. Before the
      # reward exists the count is 0 and the counter reads "Preostalo: 310".
      class InvitationWaves
        DEFAULT_WAVES = [{ "starts_on" => "2026-09-06", "quantity" => 310 }].freeze
        DEFAULT_REWARD_KEY = "pozivnica_lansiranje"
        TIME_ZONE = "Europe/Sarajevo"

        def initialize(organization:, now: Time.current, issued_count: nil)
          @organization = organization
          @now = now
          @issued_count = issued_count
          @degraded = false
        end

        def waves
          @waves ||= begin
            configured = Array(Decidim::Bih.launch_invitation_waves.presence || DEFAULT_WAVES)
            normalized = configured.map do |wave|
              {
                starts_on: to_date(wave["starts_on"] || wave[:starts_on]),
                quantity: (wave["quantity"] || wave[:quantity]).to_i
              }
            end
            normalized.sort_by { |wave| wave[:starts_on] }
          end
        end

        def total
          waves.sum { |wave| wave[:quantity] }
        end

        # Invitations from waves that have actually opened by `now`.
        def available_so_far
          opened_waves.sum { |wave| wave[:quantity] }
        end

        def issued
          @issued_count ||= count_issued
        end

        # True only when the issued count could not be read (query failure) —
        # never for the legitimate "no reward exists yet" zero, and never when
        # the caller passed an explicit issued_count:. Not knowing and knowing
        # it is zero are different states; a view should use this to omit the
        # number rather than assert a possibly-wrong one.
        def degraded?
          issued
          @degraded
        end

        def remaining
          [available_so_far - issued, 0].max
        end

        def current_wave
          opened_waves.last
        end

        def next_wave
          waves.find { |wave| wave[:starts_on] > today }
        end

        def state
          return :not_started if opened_waves.empty?
          return :all_issued if issued >= total
          return :wave_exhausted if remaining.zero? && next_wave

          :open
        end

        private

        attr_reader :organization, :now

        def zone
          @zone ||= ActiveSupport::TimeZone[TIME_ZONE]
        end

        def today
          @today ||= now.in_time_zone(zone).to_date
        end

        def opened_waves
          waves.select { |wave| wave[:starts_on] <= today }
        end

        def to_date(value)
          value.respond_to?(:to_date) && !value.is_a?(String) ? value.to_date : Date.parse(value.to_s)
        end

        # `defined?(Rails)` alone is not enough: a unit test that only needs
        # the constant to exist can leave a bare ::Rails module behind, and
        # calling .logger on it would turn a degraded count into a
        # NoMethodError raised from inside the rescue that exists to prevent
        # exactly that.
        def rails_logger? = defined?(Rails) && Rails.respond_to?(:logger)

        # Deliberately a raw table count, not a model from the parallel branch.
        # Any failure (table missing, column renamed) must show 0 issued rather
        # than take the homepage down.
        def count_issued
          return 0 unless organization

          reward_key = Decidim::Bih.launch_invitation_reward_key.presence || DEFAULT_REWARD_KEY
          ActiveRecord::Base.connection.select_value(
            ActiveRecord::Base.sanitize_sql_array(
              [
                "SELECT COUNT(*) FROM decidim_bih_goodwill_reward_fulfillments " \
                "WHERE decidim_organization_id = :org AND reward_key = :key " \
                "AND status NOT IN ('canceled', 'reversed')",
                { org: organization.id, key: reward_key }
              ]
            )
          ).to_i
        rescue StandardError => e
          @degraded = true
          Rails.logger.warn("[launch_invitation_waves] issued count unavailable: #{e.class}") if rails_logger?
          0
        end
      end
    end
  end
end
