# frozen_string_literal: true

module Decidim
  module Bih
    module ReportMailbox
      class FakeAdapter
        attr_reader :body_requests
        def initialize(messages: [], folder: "[Gmail]/Sva pošta", uidvalidity: 1)
          @messages, @folder, @uidvalidity, @body_requests = messages, folder, uidvalidity, []
        end
        def open = { folder: @folder, uidvalidity: @uidvalidity }
        def headers_after(uid, limit:) = @messages.select { |m| m.fetch(:uid) > uid }.sort_by { |m| m[:uid] }.first(limit).map { |m| m.except(:body) }
        def body(uid)
          @body_requests << uid
          @messages.find { |m| m[:uid] == uid }.fetch(:body)
        end
        def close = nil
      end
    end
  end
end
