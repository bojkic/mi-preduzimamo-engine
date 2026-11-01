# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/responder"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # +/x+ (Regexp::EXTENDED) drops every unescaped literal space in the
        # pattern. A multi-word alternative written with a real space is
        # therefore not a phrase that matches loosely — it is a phrase that can
        # never match at all, silently, with no error at any point.
        #
        # This has bitten these matchers repeatedly, always the same way: a
        # one-line regex holding real spaces is widened, wrapped in /x so it can
        # span several lines, and every multi-word alternative in it dies in the
        # same commit that was meant to make it match more. Nothing fails,
        # because a matcher that stops matching only shows up as the model being
        # consulted instead — which looks like normal operation.
        #
        # Measured on 14.09.2026, the dead alternatives were:
        #   * PublicInformation::INFLUENCE_CLAIM — "vise vrijedi", "vise vredi",
        #     "vazi vise", "vrh liste", "na vrh". These deny the claim that
        #     points or donations buy influence, so a vote-integrity question
        #     ("Da li više bodova znači da moj prijedlog ide na vrh?") reached
        #     the model instead of the reviewed denial.
        #   * DeterministicRoutes::EARN — "na koji nacin", "kojim putem",
        #     "mogu da", "dobre volje", "na platformi", "kod vas", "kod tebe",
        #     "kod milice", and the leading "a "/"pa ".
        #   * OWN_STATE_PREFIX / PersonalReadRoutes::PREFIX — "molim te".
        #   * AccountQuestion::REGISTER_ROUTE — "mogu li", "da ".
        #
        # The rule is the one DOCUMENT, BOARD and MZ_CONTACT already followed:
        # in an /x pattern, spell every literal space +[ ]+. This test holds
        # every /x matcher in the concierge to it, so the class cannot return.
        class ExtendedRegexpSpacesTest < Minitest::Test
          # A literal space between two alphanumerics, once character classes
          # (where a space is preserved) and escaped spaces are removed.
          DEAD_SPACE = /[[:alnum:]] [[:alnum:]]/
          CHARACTER_CLASS = /\[[^\]]*\]/
          ESCAPED_SPACE = /\\ /
          ROOT = File.expand_path("../../../../../../app/services/decidim/bih/concierge", __dir__)
          # Requiring the responder alone reaches most of the concierge but not
          # all of it — AccountQuestion, for one, stayed unloaded, so the sweep
          # below silently covered less than it appeared to. A guard that checks
          # an unknown subset is the same failure it exists to catch, so every
          # file is loaded explicitly and the count is asserted.
          SOURCES = Dir.glob("#{ROOT}/**/*.rb").freeze
          # An /x regexp literal in raw source: /…/x or %r{…}x.
          EXTENDED_LITERAL = %r{/[a-wyz]*x[a-wyz]*\s*$|%r[{(\[].*[})\]][a-wyz]*x}

          # The sweep is only as wide as what is loaded, so prove the load. A
          # few concierge files reach ActiveRecord, which this suite has no
          # database for (see the engine's rails_test/); those cannot be loaded
          # here and hold no matcher. Everything else must load, and the count
          # is asserted so a silently shrinking sweep fails instead of passing.
          def test_every_matcher_bearing_source_file_is_loaded_before_the_sweep
            refute_empty SOURCES
            skipped = self.class.load_sources

            assert Dialogue.const_defined?(:AccountQuestion, false),
                   "AccountQuestion did not load; the sweep would silently skip it"
            assert_operator extended_patterns.size, :>=, 20,
                            "only #{extended_patterns.size} /x patterns found — the sweep is not reaching the matchers"
            # A file this suite cannot load (it reaches Rails, which the engine's
            # pure-minitest suite deliberately does not boot — see rails_test/)
            # is still covered, by the weaker but sufficient check that it holds
            # no /x pattern for a literal space to hide in. Matching on the load
            # error's wording instead would pass the day the wording changes.
            carrying = skipped.keys.select { |file| EXTENDED_LITERAL.match?(File.read(file)) }

            assert_empty carrying.map { |file| File.basename(file) },
                         "these files could not be loaded AND declare an /x pattern, so nothing checks them: " \
                         "#{skipped.slice(*carrying).values.join("; ")}"
          end

          # Files that could not be loaded, as { path => error }. A load failure
          # is returned rather than raised so the sweep reports what it covered.
          def self.load_sources
            @load_sources ||= SOURCES.each_with_object({}) do |file, skipped|
              require file
            rescue StandardError, ScriptError => e
              skipped[file] = e
            end
          end

          def test_no_extended_regexp_in_the_concierge_contains_a_literal_space
            self.class.load_sources

            offenders = extended_patterns.filter_map do |name, pattern|
              stripped = pattern.source.gsub(CHARACTER_CLASS, "").gsub(ESCAPED_SPACE, "")
              samples = stripped.scan(DEAD_SPACE).uniq
              next if samples.empty?

              "#{name}: #{samples.size} literal space(s), e.g. #{samples.first.inspect}"
            end

            assert_empty offenders, <<~MESSAGE
              These /x patterns contain a literal space, so every alternative
              spelled with one is unreachable. Spell the space [ ].

              #{offenders.join("\n")}
            MESSAGE
          end

          # The four phrasings that were dead in production on 14.09.2026, kept
          # as behaviour rather than as a property of the source text. The text
          # is folded first because every caller folds — EARN anchors on \z and
          # would not match a trailing question mark otherwise.
          def test_the_phrasings_that_were_dead_match_again
            {
              "Da li više bodova znači da moj prijedlog ide na vrh?" => PublicInformation::INFLUENCE_CLAIM,
              "Da li donacija znači da moje mišljenje važi više?" => PublicInformation::INFLUENCE_CLAIM,
              "Na koji način da zaradim bodove?" => DeterministicRoutes::EARN,
              "Kako da zaradim bodove dobre volje?" => DeterministicRoutes::EARN
            }.each do |text, pattern|
              folded = Decidim::Bih::Text.fold(text)

              assert pattern.match?(folded), "#{text.inspect} (folded: #{folded.inspect}) no longer matches"
            end
          end

          private

          # Every /x Regexp constant reachable under Concierge, named by its
          # full path so a failure says which file to open. Breadth-first over
          # a queue rather than recursion, so the visited set and the result are
          # plain locals instead of accumulator parameters.
          def extended_patterns
            found = {}
            visited = {}.compare_by_identity
            queue = [[Decidim::Bih::Concierge, "Concierge"]]

            while (entry = queue.shift)
              mod, path = entry
              next if visited[mod]

              visited[mod] = true
              mod.constants(false).each do |name|
                value = constant(mod, name)
                next if value.nil?

                full = "#{path}::#{name}"
                if value.is_a?(Regexp)
                  found[full] = value if value.options.anybits?(Regexp::EXTENDED)
                elsif value.is_a?(Module) && value.name.to_s.start_with?("Decidim::Bih")
                  queue << [value, full]
                end
              end
            end
            found
          end

          # A constant that cannot be resolved is not a matcher; the files that
          # raise here are the Rails-dependent ones the sweep covers by text.
          def constant(mod, name)
            mod.const_get(name)
          rescue StandardError, ScriptError
            nil
          end
        end
      end
    end
  end
end
