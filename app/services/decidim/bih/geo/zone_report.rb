# frozen_string_literal: true

module Decidim
  module Bih
    module Geo
      # Renders the grad/selo split as plain text for the rake task AND for the
      # confirmation the foundation sends before the race rules are published.
      # Kept free of Rails so it can be unit-tested in the fast suite.
      module ZoneReport
        module_function

        def render(results)
          grad, selo = results.partition { |r| r.zona == "grad" }
          borderline = results.select(&:borderline?)

          lines = []
          lines << "PODJELA KOMŠILUKA NA GRADSKE I SEOSKE"
          lines << ""
          lines << format("UKUPNO: %d", results.size)
          lines << format("GRAD:   %d", grad.size)
          lines << format("SELO:   %d", selo.size)
          lines << ""
          lines << "GRADSKI (#{grad.size})"
          lines.concat(grad.map { |r| row(r) })
          lines << ""
          lines << "SEOSKI (#{selo.size})"
          lines.concat(selo.map { |r| row(r) })
          lines << ""
          lines << "GRANIČNI SLUČAJEVI (40–60% površine u gradskoj zoni)"
          lines << if borderline.empty?
                     "  — nema graničnih slučajeva"
                   else
                     borderline.map { |r| row(r) }.join("\n")
                   end
          lines << ""
          lines << "Ova lista ide naručiocu na potvrdu PRIJE objave pravila trke."
          lines.join("\n")
        end

        def row(result)
          format("  %6.1f%%  %-16s %s", result.ratio * 100, result.slug, result.name)
        end
      end
    end
  end
end
