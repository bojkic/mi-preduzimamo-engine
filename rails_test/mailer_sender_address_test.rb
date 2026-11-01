# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Three mailers used to read ENV["NOTIFICATION_EMAIL"], which no host
      # sets, so they sent from notifications@example.org — a domain whose SPF
      # record is "-all". The launch invitation carries the reservation number,
      # so that one silently never reached an inbox (review 2026-09-07, lane 5
      # H1). Every engine mailer must resolve the same sender chain.
      class MailerSenderAddressTest < ActiveSupport::TestCase
        setup do
          @previous_from = Decidim::Bih.reporter_mailer_from
          @previous_env = ENV.fetch("REPORTER_MAILER_FROM", nil)
          ENV.delete("REPORTER_MAILER_FROM")
          Decidim::Bih.reporter_mailer_from = "obavjestenja@test.example"
        end

        teardown do
          Decidim::Bih.reporter_mailer_from = @previous_from
          if @previous_env.nil?
            ENV.delete("REPORTER_MAILER_FROM")
          else
            ENV["REPORTER_MAILER_FROM"] = @previous_env
          end
        end

        test "the shared sender address is the host's reporter address" do
          assert_equal "obavjestenja@test.example", Decidim::Bih::SenderAddress.call
        end

        test "REPORTER_MAILER_FROM wins over the config accessor" do
          ENV["REPORTER_MAILER_FROM"] = "env@test.example"

          assert_equal "env@test.example", Decidim::Bih::SenderAddress.call
        end

        test "the ops health alert never builds a mail from example.org" do
          organization = create_organization
          mail = Decidim::Bih::Admin::OpsHealthAlertMailer.alert(
            organization:, recipient: "ops@test.example", rows: [%w(queue ok)]
          )

          assert_equal ["obavjestenja@test.example"], mail.from
        end

        # Every engine mailer, not just the three that were wrong: the sender
        # domain has to be one the foundation can actually send for.
        test "no engine mailer declares an example.org sender in its source" do
          mailers = Dir[Decidim::Bih::Engine.root.join("app/mailers/**/*.rb")].reject do |path|
            path.end_with?("sender_address.rb")
          end
          offenders = mailers.select { |path| File.read(path).include?('ENV.fetch("NOTIFICATION_EMAIL"') }

          assert_empty offenders, "these mailers still read NOTIFICATION_EMAIL: #{offenders.inspect}"
        end
      end
    end
  end
end
