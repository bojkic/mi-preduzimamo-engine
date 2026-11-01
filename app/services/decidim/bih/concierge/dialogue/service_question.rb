# frozen_string_literal: true

require_relative "../../text"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # A narrow route to reviewed publication sources, never a live-status
        # answer or a substitute for missing contact details.
        module ServiceQuestion
          TOPICS = %w(water electricity heating).freeze
          # Reviewed contact cards (Wave 3 package O). A question on one of
          # these topics is answered from the host directory whatever the
          # wording: no area and no day is ever asked, and a time word such as
          # "noćas" never turns a pharmacy question into a live-status read.
          DIRECTORY_TOPICS = %w(health social_welfare agriculture permits education animals).freeze

          module_function

          def directory_lookup?(topic:, entities:)
            return true if DIRECTORY_TOPICS.include?(topic)
            return false unless TOPICS.include?(topic)
            return false if %w(date time_expression).any? { |key| !entities[key].to_s.strip.empty? }

            query = entities["query"]
            return false unless query.is_a?(String) && query.length <= 160

            query = Text.fold(query)
            return false if query.empty?
            return false if query.match?(/\b(?:ne|nije|nisu|nemoj\w*|not|no|don t|without|bez)\b/)

            official_site = query.match?(/\b(?:sluzben\w*|zvanicn\w*|official)\b/) && query.match?(/\b(?:stranic\w*|sajt\w*|web|website|site)\b/)
            publication_source = query.match?(/\b(?:gdje|gde|where)\b/) && query.match?(/\b(?:objav\w*|publish\w*)\b/)
            # "Where are outages published?" asks for the publication source,
            # not whether an outage affects this citizen. Keep mixed clauses,
            # dates, live-status language and contact requests on their old path.
            subject_query = query
            if publication_source && !query.match?(/\b(?:i|a|ali|and|but)\b/)
              subject_query = query.gsub(/\b(?:iskljucenj\w*|prekid\w*|outages?|interruptions?|power cuts?)\b/, "notice")
            end
            return false if event_or_contact_query?(subject_query)

            official_site || publication_source
          end

          def event_or_contact_query?(query)
            return true if query.match?(/\b(?:prekid\w*|iskljuc\w*|nestan\w*|nestal\w*|kvar\w*|obustav\w*|redukc\w*|ima|nema|radi|tece|grije|greje|aktuel\w*|trenut\w*)\b/)
            return true if query.match?(/\b(?:outage\w*|interrupt\w*|cut\w*|status|live|current\w*|working|restor\w*)\b/)
            return true if query.match?(/\d|\b(?:danas|sutra|jucer|juce|veceras|nocas|kada|kad|today|tomorrow|yesterday|tonight|when|now)\b/)

            query.match?(/\b(?:telefon\w*|kontakt\w*|mobitel\w*|broj\w*|phone\w*|contact\w*|number\w*)\b/)
          end
          private_class_method :event_or_contact_query?
        end
      end
    end
  end
end
