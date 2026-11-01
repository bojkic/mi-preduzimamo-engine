# frozen_string_literal: true

require "digest"

module Decidim
  module Bih
    module Messaging
      # Compare what the platform decides today with what the candidate policy
      # would decide, from the SAME frozen inputs.
      #
      # Equal totals prove nothing: two policies can permit the same number of
      # people and not the same people. So this compares actual sets — per
      # sample, per channel — and classifies every difference in BOTH
      # directions. A new denial can be correct (a suppression finally being
      # honoured); a new allowance can be a bug (a missing key quietly becoming
      # permission). Neither is assumed to be fine.
      #
      # Compatibility mode must produce zero unexplained differences either way.
      # Target mode must match every difference to a named intended change with
      # an audience ceiling; anything else stops the rollout.
      #
      # The artifact this produces is aggregate: counts, reason categories and
      # versions. Identifiers stay in the in-memory comparison and are never
      # written into it.
      class ShadowCompare
        # Every deliberate difference the target policy is allowed to produce in
        # this phase, with the direction it may move and the ceiling it may not
        # exceed. A difference that is not on this list is unexplained.
        INTENDED_CHANGES = [
          {
            id: "d3-organization-default-inherit",
            direction: "added",
            reason: nil,
            preference_origin: "organization_default",
            description: "D3: a missing topic choice inherits the organization's activated default.",
            audience_ceiling: :organization_default_eligible
          },
          {
            id: "target-durable-stop-precedence",
            direction: "removed",
            reason: :transport_suppressed,
            preference_origin: nil,
            description: "A durable provider STOP or bounce outranks a stored topic choice.",
            audience_ceiling: :suppressed_destinations
          }
        ].freeze

        Difference = Struct.new(:direction, :message_class, :channel, :reason_codes, :preference_origin,
                                :intended_change_id, keyword_init: true) do
          def explained?
            !intended_change_id.nil?
          end

          def to_h
            {
              direction:, message_class:, channel:,
              reason_codes: Array(reason_codes).map(&:to_s),
              preference_origin:, intended_change_id:
            }
          end
        end

        Report = Struct.new(:mode, :evaluated, :unchanged, :added, :removed, :differences,
                            :reason_counts, :contract_differences, :coverage, :policy_version,
                            :eligibility_version, :cutoff, :organization_id, keyword_init: true) do
          def equivalent?
            added.zero? && removed.zero? && contract_differences.zero?
          end

          def unexplained
            differences.reject(&:explained?)
          end

          def explained?
            unexplained.empty?
          end

          # Calendar duration proves neither coverage nor equivalence. This does:
          # how many evaluations each class/channel contract actually received.
          # A contract nobody exercised has not been compared, however long the
          # observation window was left open.
          def uncovered(minimum: 1)
            coverage.select { |_contract, count| count < minimum }.keys
          end

          def sufficient_coverage?(minimum: 1)
            uncovered(minimum:).empty?
          end

          # Aggregate only: counts, reason categories, versions. No recipient,
          # no address, no identifier.
          def to_h
            {
              mode:, evaluated:, unchanged:, added:, removed:,
              contract_differences:,
              equivalent: equivalent?,
              explained: explained?,
              reason_counts: reason_counts.transform_keys(&:to_s),
              coverage: coverage.transform_keys { |contract| contract.join("|") },
              sufficient_coverage: sufficient_coverage?,
              differences: differences.group_by { |d| [d.direction, d.message_class, d.channel, d.intended_change_id] }
                                      .map do |(direction, message_class, channel, intended), rows|
                                        { direction:, message_class:, channel:, intended_change_id: intended,
                                          count: rows.length,
                                          reason_codes: rows.flat_map { |r| Array(r.reason_codes).map(&:to_s) }.uniq.sort }
                                      end,
              policy_version:, eligibility_version:,
              cutoff: cutoff&.iso8601, organization_id:
            }
          end
        end

        # Build a bounded, deterministic sample set from stored facts.
        #
        # Deliberately NOT a Cartesian product of every citizen against every
        # channel: each sample pairs an enrolled class with the channels that
        # class actually uses, and carries only context we can actually observe.
        # Where a fact is unknown it is left unset rather than asserted, so the
        # policy classifies it as a non-send instead of inventing reachability.
        def self.build_samples(organization:, limit: 200)
          entries = MessageClass.enrolled.values.reject(&:external_boundary?)
          Decidim::User.where(decidim_organization_id: organization.id, admin: false, deleted_at: nil)
                       .order(:id).limit(limit).flat_map do |user|
            recipient = RecipientContext.account(organization_id: organization.id, account_id: user.id)
            context = { destination_digest: phone_digest(user:, organization:) }.compact
            entries.map do |entry|
              { message_class: entry.key, recipient:,
                channels: entry.channels & TOPIC_SAMPLE_CHANNELS, context: }
            end
          end
        end

        # Only the four external channels are sampled here: bell and push have
        # their own device/notification contracts and are compared through their
        # own producers, not through this topic-oriented sweep.
        TOPIC_SAMPLE_CHANNELS = MessageClass::TOPIC_CHANNELS

        def self.phone_digest(user:, organization:)
          phone = VerifiedPhone.delivery_phone_for(user:, organization:)
          return nil if phone.blank?

          Digest::SHA256.hexdigest(phone.to_s)
        rescue StandardError
          nil
        end

        # `samples` is a list of frozen evaluation inputs:
        #   { message_class:, recipient:, context:, channels: (optional) }
        # They come from real or sanitised events and from deterministic
        # fixtures, including the rare paths and the scheduled windows — not
        # from a Cartesian product of every citizen against every channel
        # regardless of whether that combination can occur.
        def initialize(organization:, samples:, mode: Modes::COMPATIBILITY, baseline_mode: Modes::LEGACY, cutoff: nil)
          @organization = organization
          @samples = samples
          @mode = mode.to_s
          @baseline_mode = baseline_mode.to_s
          @cutoff = cutoff || Time.current
        end

        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def run
          evaluated = 0
          unchanged = 0
          contract_differences = 0
          differences = []
          reason_counts = Hash.new(0)
          coverage = Hash.new(0)

          samples.each do |sample|
            entry = MessageClass.fetch(sample.fetch(:message_class))
            channels = Array(sample[:channels]).map(&:to_s)
            channels = entry.channels if channels.empty?

            channels.each do |channel|
              evaluated += 1
              coverage[[entry.key, channel]] += 1
              baseline = decide(sample, channel, baseline_mode)
              candidate = decide(sample, channel, mode)

              baseline.reason_codes.each { |code| reason_counts[:"baseline.#{code}"] += 1 }
              candidate.reason_codes.each { |code| reason_counts[:"candidate.#{code}"] += 1 }

              if baseline.permitted? == candidate.permitted?
                unchanged += 1
                # Equal permission is not equal delivery: a different group,
                # content variant or expiry is a real difference.
                contract_differences += 1 unless same_contract?(baseline, candidate)
                next
              end

              direction = candidate.permitted? ? "added" : "removed"
              differences << Difference.new(
                direction:, message_class: entry.key, channel:,
                reason_codes: (candidate.permitted? ? baseline : candidate).reason_codes,
                preference_origin: candidate.preference_origin,
                intended_change_id: intended_change_for(direction:, decision: candidate)
              )
            end
          end

          Report.new(
            mode:, evaluated:, unchanged:,
            added: differences.count { |d| d.direction == "added" },
            removed: differences.count { |d| d.direction == "removed" },
            differences:, reason_counts:, contract_differences:, coverage:,
            policy_version: Policy::POLICY_VERSION, eligibility_version: Policy::ELIGIBILITY_VERSION,
            cutoff:, organization_id: organization&.id
          )
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        private

        attr_reader :organization, :samples, :mode, :baseline_mode, :cutoff

        def decide(sample, channel, evaluation_mode)
          Policy.decide(
            organization:, message_class: sample.fetch(:message_class),
            recipient: sample.fetch(:recipient), channel:,
            context: sample.fetch(:context, {}), mode: evaluation_mode
          )
        end

        def same_contract?(baseline, candidate)
          baseline.channel_group == candidate.channel_group &&
            baseline.expires_at.to_i == candidate.expires_at.to_i
        end

        # Compatibility mode has no intended changes at all: every difference is
        # unexplained by definition, which is exactly the gate the plan wants.
        def intended_change_for(direction:, decision:)
          return nil unless mode == Modes::TARGET

          match = INTENDED_CHANGES.find do |change|
            next false unless change[:direction] == direction
            next false if change[:reason] && decision.reason_codes.exclude?(change[:reason])
            next false if change[:preference_origin] && change[:preference_origin] != decision.preference_origin

            true
          end
          match&.fetch(:id)
        end
      end
    end
  end
end
