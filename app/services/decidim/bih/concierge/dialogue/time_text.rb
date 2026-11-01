# frozen_string_literal: true

require "date"
require "time"
require "tzinfo"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Renders a stored time for a citizen: "danas u 04:00", "juče u 19:49",
        # "12.9.2026. u 06:10", "9.9.2026." for a date. Stored values stay ISO
        # 8601; only the rendering changes, always in Europe/Sarajevo.
        module TimeText
          ZONE_NAME = "Europe/Sarajevo"
          DATE_ONLY = /\A\d{4}-\d{2}-\d{2}\z/
          WORDS = {
            "sr" => { today: "danas", yesterday: "juče", at: "u" },
            "sr-Cyrl" => { today: "данас", yesterday: "јуче", at: "у" },
            "bs" => { today: "danas", yesterday: "jučer", at: "u" },
            "hr" => { today: "danas", yesterday: "jučer", at: "u" },
            "en" => { today: "today", yesterday: "yesterday", at: "at" }
          }.freeze

          # == Why a schedule day is interface vocabulary, not source prose
          #
          # A collection day is never quoted from a city source. The published
          # programme spells it in Cyrillic, in either dialect
          # ("Сриједа"/"Среда"), and City::WasteSchedule::DAY_HEADERS rewrites
          # every spelling into one of seven canonical Latin ijekavian tokens
          # before anything downstream sees it. A sr-Cyrl reply then prints
          # that token transliterated back. So the day a citizen reads has
          # already been re-rendered twice by us, in our vocabulary.
          #
          # Rendering the same token in English is that same operation, and it
          # is the only half of the reply that was left in Serbian: the
          # sentence around it, the limitation, the source label and the check
          # time are all English already. It is NOT a translation of a quoted
          # notice — those stay in the source's language, with the note
          # FactRenderer#with_source_language_note puts above them.
          #
          # Keys are the canonical WEEK_ORDER tokens. Anything else passes
          # through untouched: a vocabulary miss must never delete a day from a
          # schedule.
          ENGLISH_WEEKDAYS = {
            "ponedjeljak" => "Monday",
            "utorak" => "Tuesday",
            "srijeda" => "Wednesday",
            "četvrtak" => "Thursday",
            "petak" => "Friday",
            "subota" => "Saturday",
            "nedjelja" => "Sunday"
          }.freeze

          module_function

          # Renders a list of canonical day names for +locale+ as one comma
          # separated string. Every locale but English keeps the canonical
          # Latin spelling, which is what sr, bs and hr all write and what the
          # existing sr-Cyrl transliteration step expects to receive — so this
          # adds English without moving the Cyrillic rendering anywhere.
          def day_names(days, locale: "sr")
            names = Array(days).map(&:to_s)
            names = names.map { |day| ENGLISH_WEEKDAYS.fetch(day.strip.downcase, day) } if locale.to_s == "en"
            names.join(", ")
          end

          # +value+ is a Time, a Date or an ISO 8601 String. Anything that
          # cannot be parsed is returned unchanged (nil stays nil), so area
          # slugs and joined windows pass through untouched.
          def call(value, locale: "sr", now: Time.now.utc)
            return value if value.nil?

            local, date_only = localize(value)
            return value.is_a?(String) ? value : value.to_s unless local

            words = WORDS.fetch(locale.to_s) { WORDS.fetch("sr") }
            today = localize(now).first.to_date
            day = relative_day(local.to_date, today, words) || format_date(local, locale)
            return day if date_only
            return "#{day}, #{local.strftime("%H:%M")}" if locale.to_s == "en" && !day.match?(/\A[a-z]/)

            "#{day} #{words.fetch(:at)} #{local.strftime("%H:%M")}"
          end

          def zone
            TZInfo::Timezone.get(ZONE_NAME)
          end

          # The wall-clock Time in Europe/Sarajevo for any Time.
          def local(time)
            zone.to_local(time.getutc)
          end

          # A Time at exactly local midnight renders as a date: source
          # snapshots are captured per day, not at a meaningful second.
          def localize(value)
            case value
            when Date then [Time.utc(value.year, value.month, value.day), true]
            when Time then localize_time(value)
            when String then localize_string(value)
            end
          end

          def localize_time(value)
            wall = local(value)
            [wall, wall.hour.zero? && wall.min.zero? && wall.sec.zero?]
          end

          def localize_string(value)
            text = value.strip
            return localize(Date.iso8601(text)) if text.match?(DATE_ONLY)

            localize_time(Time.iso8601(text))
          rescue ArgumentError, TypeError
            nil
          end

          def relative_day(date, today, words)
            return words.fetch(:today) if date == today
            return words.fetch(:yesterday) if date == today - 1

            nil
          end

          def format_date(local, locale)
            locale.to_s == "en" ? local.strftime("%-d %b %Y") : local.strftime("%-d.%-m.%Y.")
          end
        end
      end
    end
  end
end
