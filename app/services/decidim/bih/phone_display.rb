# frozen_string_literal: true

module Decidim
  module Bih
    # The citizen-facing phone mask.
    #
    # Deliberately NOT +LogRedactor.mask_phone+: that one is a log artefact
    # ("[phone:***3456]") shaped for grep, and rendering it on a page a citizen
    # reads is a bug. This one answers one question — "is that my number?" —
    # without putting the number on screen.
    #
    # Shape: a leading "+" keeps its country code; the subscriber digits are
    # grouped in threes from the right; the last group stays readable (that is
    # what the citizen checks), the groups between are hidden entirely, and the
    # first group keeps everything but its final digit, because the operator
    # prefix is the other half of the recognition.
    #
    #   "+3876XXXXXXX" -> "+387 6• ••• XXX"
    #   "06XXXXXXX"    -> "06• ••• XXX"
    #   ""             -> ""
    module PhoneDisplay
      BULLET = "•"
      GROUP_SIZE = 3
      # Every country code this platform can see is three digits (+387 and its
      # neighbours), so a leading "+" takes the next three digits with it.
      COUNTRY_CODE_DIGITS = 3

      module_function

      def mask(phone)
        raw = phone.to_s.strip
        digits = raw.gsub(/\D/, "")
        return "" if digits.empty?

        international = raw.start_with?("+") && digits.length > COUNTRY_CODE_DIGITS
        country = international ? "+#{digits[0, COUNTRY_CODE_DIGITS]}" : nil
        subscriber = international ? digits[COUNTRY_CODE_DIGITS..] : digits

        [country, mask_subscriber(subscriber)].compact.join(" ")
      end

      def mask_subscriber(subscriber)
        # Too short to carry a "prefix … last three" shape, and returning it
        # whole would simply print the number. Keep the final digit only.
        return "#{BULLET * (subscriber.length - 1)}#{subscriber[-1]}" if subscriber.length <= GROUP_SIZE

        groups = group_from_right(subscriber)
        last = groups.length - 1
        masked = groups.each_with_index.map { |group, index| mask_group(group, index, last) }
        masked.join(" ")
      end

      def mask_group(group, index, last)
        return group if index == last
        return "#{group[0..-2]}#{BULLET}" if index.zero?

        BULLET * group.length
      end

      def group_from_right(digits)
        digits.reverse.scan(/.{1,#{GROUP_SIZE}}/).map(&:reverse).reverse
      end
    end
  end
end
