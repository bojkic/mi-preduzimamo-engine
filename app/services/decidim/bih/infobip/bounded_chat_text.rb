# frozen_string_literal: true

module Decidim
  module Bih
    module Infobip
      # Shared by channel presentation and the final queue boundary. Reserve
      # complete links, action lines and qualifications before shortening prose.
      # Never turn a consent instruction or a negative answer into a fragment.
      module BoundedChatText
        TooLong = Class.new(ArgumentError)
        MAX_BYTES = 4096
        ELLIPSIS = " …"
        URL = %r{https?://\S+}
        TRAILING_PUNCTUATION = /[.,;:!?)»”"']+\z/
        QUALIFICATION = /(?<![\p{L}])(
          ne|nije|nisu|nema|nemoj\p{L}*|bez|samo|tek|ako|osim|izuzet\p{L}*|potvrd\p{L}*|saglas\p{L}*|javn\p{L}*|pristan\p{L}*|
          no|not|never|without|only|unless|except|consent|confirm\p{L}*|public|
          не|није|нису|нема|немој\p{L}*|без|само|тек|ако|осим|изузет\p{L}*|потврд\p{L}*|саглас\p{L}*|јавн\p{L}*|пристан\p{L}*
        )(?![\p{L}])/ix
        ACTION = /\A\s*(?:Odgovori:|Одговори:|Reply:)/i

        module_function

        def call(value, max_chars: nil, max_bytes: MAX_BYTES)
          text = value.to_s
          return text if fits?(text, max_chars, max_bytes)

          required = required_parts(text)
          suffix = required.join("\n")
          raise TooLong, "Required chat instructions exceed the delivery limit" unless fits?("#{ELLIPSIS}\n#{suffix}", max_chars, max_bytes)

          # Reserving in both units prevents a second byte cut after rendering.
          reserve = suffix.empty? ? "" : "\n#{suffix}"
          head = prefix(text, max_chars && (max_chars - ELLIPSIS.length - reserve.length),
                        max_bytes - ELLIPSIS.bytesize - reserve.bytesize)
          remaining = required.reject { |part| head.include?(part) }
          head = prefix(text, max_chars && (max_chars - ELLIPSIS.length), max_bytes - ELLIPSIS.bytesize) if remaining.empty?
          "#{head}#{ELLIPSIS}#{remaining.empty? ? "" : "\n#{remaining.join("\n")}"}"
        end

        def fits?(text, max_chars, max_bytes)
          (!max_chars || text.length <= max_chars) && text.bytesize <= max_bytes
        end

        def required_parts(text)
          links = text.scan(URL).map { |url| url.sub(TRAILING_PUNCTUATION, "") }
          # Protect whole sentences, including URLs with periods in their host.
          # Replacing URLs with equal-length spaces makes punctuation splitting
          # independent of the URL spelling, while slices keep the original.
          masked = text.gsub(URL) { |url| " " * url.length }
          segments = []
          masked.scan(/[^.!?\n]+[.!?]?|\n/) do |segment|
            original = text[Regexp.last_match.begin(0), segment.length].strip
            segments << original if original.match?(QUALIFICATION)
          end
          segments.concat(text.lines.map(&:strip).grep(ACTION))
          parts = (segments + links).uniq
          parts.reject { |part| parts.any? { |other| part != other && other.include?(part) } }
        end

        def prefix(text, max_chars, max_bytes)
          head = text.byteslice(0, [max_bytes, 0].max).to_s.scrub("")
          head = head[0, [max_chars, 0].max] if max_chars
          spans = protected_spans(text)
          length = last_boundary(text, head.length, spans, /[.!?\n]/) || last_boundary(text, head.length, spans, /\s/) || head.length
          crossed = spans.find { |span| span.begin < length && length < span.end }
          length = crossed.begin if crossed
          head[0, length].rstrip
        end

        def protected_spans(text)
          required_parts(text).flat_map do |part|
            spans = []
            offset = 0
            while (index = text.index(part, offset))
              spans << (index...(index + part.length))
              offset = index + part.length
            end
            spans
          end
        end

        def last_boundary(text, length, spans, pattern)
          position = length - 1
          while position >= 0 && (index = text.rindex(pattern, position))
            return index + 1 unless spans.any? { |span| span.begin <= index && index + 1 < span.end }

            position = index - 1
          end
          nil
        end
      end
    end
  end
end
