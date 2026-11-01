# frozen_string_literal: true

module Decidim
  module Bih
    # One day of one chat metric bucket, rolled up nightly from the 48-hour
    # Redis counters (host `rake decidim_bih:concierge:rollup_metrics[HOST]`).
    #
    # Privacy contract: rows are aggregate integer counts keyed by day, kind,
    # bounded topic, bounded label and fixed latency bucket. The answer_detail
    # cohort adds closed facet/traffic labels and capture-time release metadata. They never store
    # text, user or session identifiers, channel senders, coordinates or
    # provider payloads. A row is only written for a positive count, so a
    # missing row means "not rolled up", never "zero" — readers must render the
    # absence as unknown.
    #
    #   kind    topic                       label                 latency_bucket
    #   answer / answer_detail  Contracts::TOPICS           AnswerOutcome::OUTCOMES  nil
    #   read    Contracts::TOPICS           Contracts::READ_STATUSES bucket
    #   stage   STAGES (understanding, …)   STAGE_STATUSES           bucket
    class ConciergeMetricRollup < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_concierge_metric_rollups"

      KINDS = %w(answer answer_detail read stage).freeze
      FACETS = %w(unknown contact website operator hours fee coverage status location schedule).freeze
      TRAFFIC_KINDS = %w(unclassified synthetic).freeze
      STAGES = %w(understanding rendering).freeze
      STAGE_STATUSES = %w(completed failed).freeze
      # Mirrors DecidimApp::Bijeljina::Milica::ReadMetrics::BUCKETS_MS + "overflow".
      LATENCY_BUCKETS = %w(10 25 50 100 250 500 1000 2500 5000 10000 30000 overflow).freeze
      # Answer outcomes that mean the platform, not the citizen, failed.
      TECHNICAL_FAILURE_LABELS = %w(fallback error provider_unavailable busy).freeze
      RELEASE_SHA_FORMAT = /\A\h{40}\z/

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"

      validates :day, presence: true
      validates :facet, inclusion: { in: FACETS }
      validates :traffic_kind, inclusion: { in: TRAFFIC_KINDS }
      validates :kind, inclusion: { in: KINDS }
      validates :topic, inclusion: { in: ->(row) { row.allowed_topics } }
      validates :label, inclusion: { in: ->(row) { row.allowed_labels } }
      validates :count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
      validates :latency_bucket, inclusion: { in: LATENCY_BUCKETS }, allow_nil: true
      validates :release_sha, format: { with: RELEASE_SHA_FORMAT }, allow_nil: true
      validates :prompt_version, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
      validate :latency_bucket_matches_kind

      scope :for_organization, ->(organization) { where(organization:) }
      scope :on_days, ->(range) { where(day: range) }

      def self.topics_for(kind)
        kind.to_s == "stage" ? STAGES : Decidim::Bih::Concierge::Dialogue::Contracts::TOPICS
      end

      def self.labels_for(kind)
        case kind.to_s
        when "answer", "answer_detail" then Decidim::Bih::Concierge::AnswerOutcome::OUTCOMES
        when "read" then Decidim::Bih::Concierge::Dialogue::Contracts::READ_STATUSES
        when "stage" then STAGE_STATUSES
        else []
        end
      end

      def allowed_topics
        self.class.topics_for(kind)
      end

      def allowed_labels
        self.class.labels_for(kind)
      end

      private

      # Answer rows carry no latency; read and stage rows are histograms and
      # always carry one. Mixing them would let a summed histogram double count.
      def latency_bucket_matches_kind
        if %w(answer answer_detail).include?(kind)
          errors.add(:latency_bucket, :present) unless latency_bucket.nil?
        elsif KINDS.include?(kind)
          errors.add(:latency_bucket, :blank) if latency_bucket.nil?
        end
      end
    end
  end
end
