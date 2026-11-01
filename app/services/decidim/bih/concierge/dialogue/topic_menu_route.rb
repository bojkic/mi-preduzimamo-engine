# frozen_string_literal: true

require_relative "topic_menu"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Pins the menu's own service wording to the lane the menu offered.
        #
        # The action is +help+ rather than a read: "a city service" is a family,
        # not a question, and the honest next step is the one the runner already
        # owns — "Koju uslugu ili problem imaš na umu?". Procedures::CityService
        # turns a help/unknown turn into exactly that, through the top-level
        # menu ladder, which never offers the same menu twice.
        module TopicMenuRoute
          module_function

          def route(query, text)
            return unless TopicMenu.service_choice?(query)

            { action: "help", topic: "unknown", entities: { "query" => text } }
          end
        end

        DeterministicRoutes.register("topic_menu_choice") do |query, text|
          TopicMenuRoute.route(query, text)
        end
      end
    end
  end
end
