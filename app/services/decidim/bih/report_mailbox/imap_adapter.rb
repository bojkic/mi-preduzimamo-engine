# frozen_string_literal: true

require "net/imap"
require "timeout"

module Decidim
  module Bih
    module ReportMailbox
      class ImapAdapter
        class AuthenticationFailed < StandardError; end
        def initialize(config: Config.load)
          @config = config or raise Transport::Unavailable
        end
        def open
          Timeout.timeout(30) do
            @imap = Net::IMAP.new(@config.host, port: @config.port, ssl: @config.tls)
            begin
              @config.login(@imap)
            rescue Net::IMAP::NoResponseError
              # NO has many command-specific meanings. Only a rejected LOGIN
              # is an authentication failure; never retain provider response text.
              raise AuthenticationFailed, "Mailbox login rejected", cause: nil
            end
            folder = @imap.list("", "*").find { |entry| entry.attr.any? { |attr| attr.to_s.casecmp?("All") } }&.name
            raise Config::Invalid, "All Mail folder unavailable" unless folder
            @imap.examine(folder)
            { folder:, uidvalidity: @imap.responses.fetch("UIDVALIDITY").last }
          end
        rescue StandardError
          close
          raise
        end
        def headers_after(uid, limit:)
          Timeout.timeout(30) do
            ids = @imap.uid_search(["UID", (uid + 1)..-1]).select { |id| id > uid }.sort.first(limit)
            return [] if ids.empty?
            @imap.uid_fetch(ids, %w(UID RFC822.SIZE X-GM-MSGID X-GM-THRID X-GM-LABELS INTERNALDATE)).map do |item|
              a = item.attr
              { uid: a.fetch("UID"), size: a.fetch("RFC822.SIZE"), gm_msgid: a.fetch("X-GM-MSGID").to_s,
                gm_thrid: a["X-GM-THRID"].to_s, labels: Array(a["X-GM-LABELS"]).map(&:to_s), internal_date: Time.parse(a.fetch("INTERNALDATE")) }
            end.sort_by { |item| item[:uid] }
          end
        end
        def body(uid)
          Timeout.timeout(30) { @imap.uid_fetch(uid, "BODY.PEEK[]").first.attr.fetch("BODY[]") }
        end
        def close
          @imap&.disconnect unless @imap&.disconnected?
        rescue IOError, SystemCallError
          nil
        end
      end
    end
  end
end
