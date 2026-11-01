# frozen_string_literal: true

require "decidim/bih/transliterator"

module Decidim
  module Bih
    module Transport
      # Resolves a reviewed stop or an explicit place-to-stop mapping. A folded
      # spelling is only a candidate; collisions always remain ambiguous.
      class StopResolver
        Result = Struct.new(:status, :selected, :candidates, :resolution_kind, :place_id,
                            :assumption_reason, :alternatives, keyword_init: true)

        def initialize(stops:, places: [])
          @stops = Array(stops).map { |stop| stop.transform_keys(&:to_sym) }
          @places = Array(places).map { |place| place.transform_keys(&:to_sym) }
          @exact_stops = index(@stops) { |stop| [stop.fetch(:label), *Array(stop[:aliases])] }
          @exact_places = index(@places) { |place| [place.fetch(:name), *Array(place[:aliases])] }
        end

        def resolve(text, prefer_place: false)
          query = normalized(text)
          return empty if query.empty?

          if prefer_place
            place_matches = @exact_places.fetch(query, [])
            return place_result(place_matches, :reviewed_place) unless place_matches.empty?
          end

          stop_matches = @exact_stops.fetch(query, [])
          return stop_result(stop_matches, :exact_stop) unless stop_matches.empty?

          place_matches = @exact_places.fetch(query, [])
          return place_result(place_matches, :reviewed_place) unless place_matches.empty?

          folded = fold(query)
          if prefer_place
            place_matches = folded_place_matches(folded)
            return place_result(place_matches, :folded_place) unless place_matches.empty?
          end

          stop_matches = @stops.select { |stop| [stop.fetch(:label), *Array(stop[:aliases])].any? { |label| fold(normalized(label)) == folded } }
          return stop_result(stop_matches, :folded_stop) unless stop_matches.empty?

          place_matches = folded_place_matches(folded)
          return place_result(place_matches, :folded_place) unless place_matches.empty?

          empty
        end

        private

        def folded_place_matches(folded)
          @places.select do |place|
            [place.fetch(:name), *Array(place[:aliases])].any? { |label| fold(normalized(label)) == folded }
          end
        end

        def index(items)
          items.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |item, result|
            yield(item).each { |term| result[normalized(term)] << item }
          end
        end

        def stop_result(matches, kind)
          unique = matches.uniq { |stop| stop.fetch(:id) }
          return Result.new(status: :ambiguous, candidates: unique, alternatives: []) unless unique.one?

          Result.new(status: :ok, selected: unique.first, candidates: unique, resolution_kind: kind, alternatives: [])
        end

        def place_result(matches, kind)
          return Result.new(status: :ambiguous, candidates: matches, alternatives: []) unless matches.one?

          place = matches.first
          members = Array(place.fetch(:member_stop_ids))
          defaults = Array(place.fetch(:default_stop_ids))
          return empty if defaults.empty? || (defaults - members).any?

          selected = { id: place.fetch(:id), label: place.fetch(:default_label), stop_ids: defaults,
                       resolution_kind: "assumed_area_stop" }
          alternatives = @stops.select { |stop| members.include?(stop.fetch(:id)) && !defaults.include?(stop.fetch(:id)) }
          Result.new(status: :ok, selected:, candidates: [selected], resolution_kind: kind,
                     place_id: place.fetch(:id), assumption_reason: place.fetch(:assumption_reason),
                     alternatives: alternatives.first(6))
        end

        def empty
          Result.new(status: :unsupported, candidates: [], alternatives: [])
        end

        def normalized(value)
          Decidim::Bih::Transliterator.to_latin(value.to_s).unicode_normalize(:nfc).downcase.gsub(/[^\p{Alnum}]+/u, " ").squeeze(" ").strip
        end

        def fold(value)
          value.tr("čćšžđ", "ccszd").gsub("dj", "d")
        end
      end
    end
  end
end
