# frozen_string_literal: true

require "time"
module Decidim
  module Bih
    module Race
      # Pure scoring over captured facts. Adjudication never joins mutable sources.
      class Calculator
        attr_reader :evidence
        def initialize(snapshot, decisions: {})
          @snapshot = snapshot.deep_stringify_keys
          @decisions = decisions.stringify_keys
          @evidence = []
        end

        def timestamp(value)
          return nil if value.blank?
          text = value.to_s
          text += "Z" unless text.match?(/(?:Z|[+-]\d{2}:?\d{2})\z/i)
          Time.iso8601(text)
        end

        def rows
          counts = Hash.new { |h,k| h[k] = Hash.new(0) }
          times = Hash.new { |h,k| h[k] = [] }
          admitted = Hash.new(0)
          area_ids = @snapshot.fetch("areas").map { |a| a.fetch("id") }
          items = @snapshot.fetch("items").sort_by { |i| [timestamp(i["at"]) || Time.utc(9999), i["source_id"].to_i, i["key"]] }
          @evidence = items.map do |item|
            decision = @decisions[item.fetch("key")] || {}
            eligible = decision.key?("include") ? decision["include"] : item["eligible"]
            area = decision.fetch("area", item["area"])
            kind = item.fetch("kind")
            cap = kind == "registered" ? 1 : @snapshot.fetch("caps").fetch(kind)
            counter = [item["user_id"],kind]
            # Default duplicate exclusion also protects older captured facts.
            # An audited inclusion can correct a mistaken classification.
            duplicate = kind == "report" && item.dig("facts", "duplicate_of").present? && !decision.key?("include")
            reason = if duplicate then "duplicate"
                     elsif !eligible then "ineligible"
                     elsif !area_ids.include?(area) then "unknown_area"
                     elsif admitted[counter] >= cap then "cap"
                     else "counted"
                     end
            if reason == "counted"
              admitted[counter] += 1
              counts[area][kind] += 1
              times[area] << timestamp(item.fetch("at"))
            end
            { "key" => item["key"], "reason" => reason, "area" => area, "decision" => decision }
          end
          @snapshot.fetch("areas").map do |area|
            tally = counts[area["id"]]
            { komsiluk_id: area["id"], slug: area["slug"], zona: area["zona"],
              registered: tally["registered"], reports: tally["report"], proposals: tally["proposal"],
              score: @snapshot.fetch("weights").sum { |kind, weight| tally[kind] * weight }, reached_at: times[area["id"]].max }
          end.sort_by { |r| [-r[:score], r[:reached_at] || Time.utc(9999), r[:slug]] }
        end
      end
    end
  end
end
