# frozen_string_literal: true

require_relative "../text"

module Decidim
  module Bih
    module Concierge
      # "How do I earn points": the top earning actions from the EFFECTIVE
      # schedule (defaults → host initializer → per-organization Setting),
      # rendered as short lines. Points are never repeated as literals here;
      # every number is read from Decidim::Bih::Goodwill::EarningRules, so the
      # answer and the public rules page change together. Read-only; works for
      # anonymous citizens, who cannot see a balance but can see the rules.
      class GoodwillEarningAnswer
        LIMIT = 5
        # Registration is one experience for the citizen but two schedule
        # entries (welcome verification + choosing a komšiluk). Summed, never typed.
        REGISTRATION_ACTIONS = [:verification, :komsiluk_selected].freeze
        RULES_PATH = "zajednistvo?tab=kako"

        # Folded cues for the actions a citizen names by their own word rather
        # than by the schedule's key. A NAMED action is answered directly: the
        # top-five ranking silently dropped `referral` (25, tied with two other
        # 25s that come earlier in the schedule), which is precisely the action
        # most often asked about by name — "koliko bodova za poziv komšiji" was
        # unanswerable for that reason alone.
        ACTION_CUES = {
          referral: /(?:poziv|pozovem|pozvao|pozvala|pozvan|preporuk|referral)/,
          report: /(?:prijav\w*\s+problem|prijava|prijavu|prijave|prijavim|report)/,
          proposal: /(?:prijedlog|predlog|prijedloga|predloga|proposal)/,
          debate: /(?:rasprav|debat)/,
          comment: /(?:komentar|comment)/,
          like: /(?:lajk|svidj|like)/,
          vote: /(?:\bglas\w*|\bvote)/,
          budget_vote: /(?:budzet\w*\s+glas|glas\w*\s+(?:za\s+)?budzet|participativn)/,
          komsiluk_post: /(?:objav\w*\s+(?:na\s+)?tabl|tabla\s+komsiluka|komsiluk\s+objav)/,
          volunteer_hour: /(?:volontersk\w*\s+(?:sat|dan)|volontira|volonter\w*\s+rad|volunteer\s+(?:hour|day))/,
          volunteer_opportunity: /(?:volontersk\w*\s+prilik|prilik\w*\s+za\s+volont)/,
          postal_verified: /(?:pism|postansk|adres\w*\s+verifik|verifikacij\w*\s+adres)/,
          verification: /(?:potvrd\w*\s+telefon|verifikacij\w*\s+telefon|broj\s+telefona|registracij)/,
          komsiluk_selected: /(?:izbor\s+komsiluka|izabere\w*\s+komsiluk|izaberem\s+komsiluk|odabir\s+komsiluka)/
        }.freeze

        # The action this utterance names, or nil. Selection only: the answer
        # still reads the value from the effective schedule.
        def self.requested_action(text)
          folded = Decidim::Bih::Text.fold(text)
          return nil if folded.empty?

          action = ACTION_CUES.find { |_action, cue| cue.match?(folded) }&.first
          if action == :volunteer_hour && Decidim::Bih.volunteer_work_award_unit.to_sym == :day
            :volunteer_day
          else
            action
          end
        end

        def self.referral_values(organization:, locale: "sr", rules: nil, url: nil)
          new(organization:, locale:, rules:, url:).referral_values
        end

        def self.cap_values(organization:, locale: "sr", rules: nil, url: nil)
          new(organization:, locale:, rules:, url:).cap_values
        end

        def self.call(organization:, locale: "sr", rules: nil, url: nil, action: nil)
          new(organization:, locale:, rules:, url:, action:).call
        end

        def initialize(organization:, locale:, rules: nil, url: nil, action: nil)
          @organization = organization
          @locale = locale.to_s
          @rules = rules
          @url = url
          @action = action&.to_sym
        end

        def call
          lines = [t("intro")]
          lines.concat(entries.map { |label, points, cap, period| line(label, points, cap, period) })
          lines << t("note")
          lines << t("footer", url:)
          lines.join("\n")
        end

        # The interpolations the referral answer needs, every one of them read
        # from the code that actually pays it: the effective schedule, the
        # reward job's delay and the referral service's monthly cap. A missing
        # constant (a host without the jobs loaded) falls back to the documented
        # value rather than raising inside a citizen's turn.
        def referral_values
          { points: t("points", count: rules.points_for(:referral)),
            hours: constant(24) { (Decidim::Bih::Goodwill::ReferralRewardJob::REWARD_DELAY / 3600).to_i },
            cap: constant(10) { Decidim::Bih::Goodwill::Referrals::MONTHLY_CAP },
            url: }
        end

        # The effective daily caps, rendered as one localized list. Read from
        # the same rules object an award consults, never typed here.
        def cap_values
          capped = visible_schedule.keys.filter_map do |action|
            cap = rules.cap_for(action)
            t("line", label: action_label(action), points: t(cap_label(action), count: cap)) if cap
          end
          { caps: capped.join("; "), url: }
        end

        private

        def constant(fallback)
          yield
        rescue StandardError
          fallback
        end

        attr_reader :locale

        def rules
          @rules ||= begin
            Decidim::Bih::Goodwill::EarningRules.new(organization: @organization)
          rescue StandardError
            # A settings-store failure must not hide the rules: fall back to
            # defaults + host configuration, exactly as the public page does.
            Decidim::Bih::Goodwill::EarningRules.new
          end
        end

        def url
          @url ||= Decidim::Bih.respond_to?(:public_path) ? Decidim::Bih.public_path(RULES_PATH) : "/#{RULES_PATH}"
        end

        # [label, points, daily_cap] rows: registration first (when it earns
        # anything), then the highest-valued remaining actions; equal points
        # keep the schedule's own order so the list is stable.
        def entries
          return focused_entries if focus

          rows = []
          registration = registration_points
          rows << [t("registration"), registration, nil] if registration.positive?

          ranked = visible_schedule.to_a.each_with_index
                        .reject { |(action, points), _| REGISTRATION_ACTIONS.include?(action.to_sym) || points.to_i <= 0 }
                        .sort_by { |(_, points), index| [-points.to_i, index] }
                        .first(LIMIT - rows.length)
          rows + ranked.map { |(action, points), _| [action_label(action), points.to_i, rules.cap_for(action), rules.cap_period_for(action)] }
        end

        # The named action, when the effective schedule actually pays for it.
        # An action worth nothing here is NOT answered as "0 bodova" — the list
        # is shown instead, exactly as it is for an unnamed question.
        def focus
          return nil if @action.nil?
          if @action == :volunteer_hour && Decidim::Bih.volunteer_work_award_unit.to_sym == :day
            @action = :volunteer_day
          end
          return nil unless rules.points_for(@action).positive?

          @action
        end

        def visible_schedule
          rules.respond_to?(:public_schedule) ? rules.public_schedule : rules.schedule
        end

        # One row for the named action — and, when it is half of registration,
        # the TOTAL first and then both halves. Registration is one experience
        # for the citizen and two schedule entries, and citizens ask about one
        # half at a time ("koliko za potvrdu telefona, a koliko za izbor
        # komšiluka") — but "koliko bodova dobijem za registraciju?" is a
        # question about the whole, and answering it with two tens and no sum
        # left the citizen to add them up. The total is the number the launch
        # invitation is decided on, so it is the one number this answer may
        # never omit and may never type: it is the same row, from the same
        # summed schedule, that the unranked list already leads with, so the
        # two routes cannot state different totals.
        def focused_entries
          return [[action_label(focus), rules.points_for(focus), rules.cap_for(focus), rules.cap_period_for(focus)]] unless REGISTRATION_ACTIONS.include?(focus)

          halves = REGISTRATION_ACTIONS.map { |action| [action_label(action), rules.points_for(action), rules.cap_for(action), rules.cap_period_for(action)] }
          [[t("registration"), registration_points, nil]] + halves
        end

        # Registration's worth, summed from the effective schedule. The ONE
        # place this answer computes it; both the ranked list and the focused
        # answer read it, so neither can drift from the other or from
        # EarningRules.
        def registration_points
          REGISTRATION_ACTIONS.sum { |action| rules.points_for(action) }
        end

        def line(label, points, cap, period = :day)
          values = { label:, points: t("points", count: points) }
          return t("line", **values) if cap.nil?

          t("line_with_cap", **values, cap: t(period == :month ? "monthly_cap" : "daily_cap", count: cap))
        end

        def cap_label(action)
          rules.cap_period_for(action) == :month ? "monthly_cap" : "daily_cap"
        end

        def action_label(action)
          I18n.t("decidim.bih.goodwill.actions.#{action}", locale:, default: action.to_s.tr("_", " "))
        end

        def t(key, **)
          I18n.t("decidim.bih.concierge.goodwill.earning.#{key}", locale:, **)
        end
      end
    end
  end
end
