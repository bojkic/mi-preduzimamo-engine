# frozen_string_literal: true

require "test_helper"
module Decidim
  module Bih
    module RailsHarness
      class ReportMailboxAdapterContractTest < ActiveSupport::TestCase
        test "localized all-mail names and bounded metadata without write methods" do
          ["[Gmail]/Sva pošta", "[Gmail]/All Mail"].each do |folder|
            adapter = ReportMailbox::FakeAdapter.new(folder:, messages: [{ uid: 1 }, { uid: 2 }])
            assert_equal folder, adapter.open[:folder]
            assert_equal [{ uid: 2 }], adapter.headers_after(1, limit: 1)
            %i(store append copy move expunge delete add_label).each { |method| refute_respond_to adapter, method }
          end
        end
        def rejected_imap_response
          Net::IMAP::NoResponseError.new(Struct.new(:data).new(Struct.new(:text).new("fixture rejected")))
        end

        test "LOGIN denial has safe authentication class while LIST denial remains a command failure" do
          [:login, :list].each do |phase|
            fake = Minitest::Mock.new
            fake.expect(:disconnected?, false)
            fake.expect(:disconnect, nil)
            rejection = rejected_imap_response
            fake.expect(:list, nil) { |_reference, _pattern| raise rejection } if phase == :list
            config = Struct.new(:host, :port, :tls, :rejection) do
              def login(_imap)
                raise rejection if rejection
              end
            end.new("fixture", 993, true, phase == :login ? rejection : nil)
            Net::IMAP.stub(:new, fake) do
              error_class = phase == :login ? ReportMailbox::ImapAdapter::AuthenticationFailed : Net::IMAP::NoResponseError
              error = assert_raises(error_class) { ReportMailbox::ImapAdapter.new(config:).open }
              assert_equal "Mailbox login rejected", error.message if phase == :login
              assert_nil error.cause if phase == :login
            end
            fake.verify
          end
        end

        test "IMAP discovers All attribute and uses examine and peek" do
          fake = Minitest::Mock.new
          entry = Struct.new(:name, :attr).new("[Gmail]/Sva pošta", [:All])
          fake.expect(:list, [entry], ["", "*"])
          fake.expect(:examine, nil, [entry.name])
          fake.expect(:responses, { "UIDVALIDITY" => [9] })
          fake.expect(:uid_fetch, [Struct.new(:attr).new({ "BODY[]" => "raw" })], [1, "BODY.PEEK[]"])
          fake.expect(:disconnected?, false)
          fake.expect(:disconnect, nil)
          config = Struct.new(:host, :port, :tls) { def login(_imap) = nil }.new("fixture", 993, true)
          Net::IMAP.stub(:new, fake) do
            adapter = ReportMailbox::ImapAdapter.new(config:)
            assert_equal({ folder: entry.name, uidvalidity: 9 }, adapter.open)
            assert_equal "raw", adapter.body(1)
            adapter.close
          end
          fake.verify
        end
      end
    end
  end
end
