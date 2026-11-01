# frozen_string_literal: true

module Decidim
  module Bih
    # Author correction of a returned whole proposal. Every term is previewed
    # and resubmitted together; existing decision/audit rows remain intact.
    class ReviseVolunteerProposal
      Result = Struct.new(:status, :terms, :errors, :warnings, keyword_init: true)
      TIME_ZONE = "Europe/Sarajevo"
      SHARED_FIELDS = %w(title description location meeting_point requirements category).freeze
      TERM_FIELDS = %w(starts_at ends_at signup_deadline_at capacity).freeze

      def self.group_for(opportunity, author:)
        return VolunteerOpportunity.none unless opportunity && author && opportunity.decidim_author_id == author.id

        scope = VolunteerOpportunity.where(organization: opportunity.organization, author:,
                                           review_status: "needs_revision")
        if opportunity.respond_to?(:proposal_identity) && opportunity.proposal_identity.present?
          scope.where(proposal_identity: opportunity.proposal_identity).order(:series_position, :id)
        elsif opportunity.series_key.present?
          scope.where(series_key: opportunity.series_key).order(:series_position, :id)
        else
          scope.where(id: opportunity.id)
        end
      end

      def self.call(opportunity:, author:, shared:, terms:, submit: false)
        group = group_for(opportunity, author:).to_a
        return Result.new(status: :missing, terms: [], errors: []) if group.empty?
        return Result.new(status: :invalid, terms: group, errors: ["not_returned"]) unless group.all? { |term| term.review_status == "needs_revision" }

        candidates = build_candidates(group, shared, terms)
        errors = candidates.flat_map do |term|
          term.valid? ? [] : term.errors.full_messages.map { |message| "#{term.series_position || term.id}: #{message}" }
        end
        warnings = schedule_warnings(candidates)
        return Result.new(status: errors.empty? ? :preview : :invalid, terms: candidates, errors:, warnings:) unless submit && errors.empty?

        VolunteerOpportunity.transaction do
          locked = group.sort_by(&:id).map { |term| VolunteerOpportunity.lock.find(term.id) }
          raise ActiveRecord::RecordInvalid, locked.first unless locked.all? { |term| term.review_status == "needs_revision" }

          build_candidates(locked, shared, terms).each do |candidate|
            original = locked.find { |term| term.id == candidate.id }
            original.assign_attributes(candidate.attributes.slice(*(SHARED_FIELDS + TERM_FIELDS)))
            original.update!(review_status: "pending", rejection_reason: nil, reviewed_at: nil, reviewer: nil)
            OperatorAuditEvent.record!(organization: original.organization, actor: author,
                                       event_type: "volunteering_proposal_resubmitted", resource: original,
                                       metadata: { proposal_identity: original.respond_to?(:proposal_identity) ? original.proposal_identity : nil,
                                                   series_position: original.series_position })
          end
        end
        Result.new(status: :submitted, terms: candidates, errors: [], warnings:)
      rescue ActiveRecord::RecordInvalid => error
        Result.new(status: :invalid, terms: candidates || group, errors: error.record.errors.full_messages)
      end

      def self.build_candidates(group, shared, terms)
        shared_values = shared.to_h.stringify_keys.slice(*SHARED_FIELDS)
        group.map do |term|
          copy = term.dup
          copy.id = term.id
          copy.assign_attributes(shared_values)
          values = terms.to_h.fetch(term.id.to_s, {}).to_h.stringify_keys.slice(*TERM_FIELDS)
          %w(starts_at ends_at signup_deadline_at).each do |field|
            values[field] = parse_local(values[field]) if values.key?(field)
          end
          copy.assign_attributes(values)
          copy.review_status = "pending"
          copy.rejection_reason = nil
          copy
        end
      end
      private_class_method :build_candidates

      def self.parse_local(value)
        return nil if value.blank?

        ActiveSupport::TimeZone[TIME_ZONE].parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end
      private_class_method :parse_local

      def self.schedule_warnings(terms)
        ordered = terms.sort_by { |term| term.starts_at || Time.zone.at(0) }
        ordered.each_cons(2).filter_map do |left, right|
          next unless left.ends_at && right.starts_at && left.ends_at > right.starts_at

          "overlap: #{left.series_position || left.id} and #{right.series_position || right.id}"
        end
      end
      private_class_method :schedule_warnings
    end
  end
end
