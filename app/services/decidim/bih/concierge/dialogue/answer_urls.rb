# frozen_string_literal: true

require "uri"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Match destinations, not substrings of a serialized evidence envelope.
        # Root-relative aliases come only from explicit public navigation routes;
        # an external source URL's path is not a route on the current tenant.
        class AnswerUrls
          LINKS = %r{(?<![[:alnum:]_/])(?:https?://[^\s<>"'`]+|//[^\s<>"'`]+|/[[:alpha:]_%][^\s<>"'`]*)}i

          def initialize(evidence)
            @destinations = destinations(evidence).uniq
          end

          def validate!(text)
            return if (links(text) - @destinations).empty?

            raise Contracts::Invalid, "Unsupported answer URL"
          end

          private

          def destinations(value)
            case value
            when Hash
              value.flat_map { |key, item| destinations(item) + (key == "public_routes" ? local_routes(item) : []) }
            when Array then value.flat_map { |item| destinations(item) }
            when String then value.match?(%r{\Ahttps?://[^\s<>"\'`]+\z}i) ? [value] : links(value)
            else []
            end
          end

          def local_routes(value)
            return [] unless value.is_a?(Hash)

            value.values.filter_map do |url|
              uri = URI.parse(url) if url.is_a?(String)
              next unless uri.is_a?(URI::HTTP) && uri.host

              [uri.request_uri, uri.fragment].compact.join("#")
            rescue URI::InvalidURIError
              nil
            end
          end

          def links(text)
            text.scan(LINKS).map do |link|
              next link if @destinations&.include?(link)

              link = link.sub(/[.,;!?]+\z/, "")
              link = link.chop while link.end_with?(")") && link.count(")") > link.count("(")
              link
            end
          end
        end
      end
    end
  end
end
