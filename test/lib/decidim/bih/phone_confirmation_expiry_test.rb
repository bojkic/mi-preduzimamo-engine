# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "json"

class PhoneConfirmationExpiryTest < Minitest::Test
  def self.observations
    @observations ||= begin
      # All model/config collaborators live only in the child. Requiring this
      # DB-free test must not define a fake LoginToken in another suite.
      program = <<~RUBY
        require "active_support"
        require "active_support/core_ext/numeric/time"
        require "active_support/core_ext/module/delegation"
        require "wisper"
        require "decidim/command"
        require "json"
        Time.zone = "UTC"
        module Decidim
          def self.verification_code_expiry_minutes = 10
          module Bih
            class LoginToken
              VERIFY_TTL = 24.hours
            end
          end
        end
        upstream = File.join(Gem::Specification.find_by_name("decidim-verifications").full_gem_path,
                             "app/commands/decidim/verifications/confirm_user_authorization.rb")
        require upstream
        require ARGV.fetch(0)
        authorization = Struct.new(:name, :verification_metadata)
        core = Decidim::Verifications::ConfirmUserAuthorization
        bih = Decidim::Bih::PhoneVerification::ConfirmAuthorization
        results = {}
        [["core_20m", core, 20.minutes, "sms"], ["bih_20m", bih, 20.minutes, "sms"],
         ["bih_23h", bih, 23.hours, "sms"], ["bih_expired", bih, 24.hours + 1.second, "sms"],
         ["postal_expired", bih, 20.minutes, "postal_letter"], ["postal_valid", bih, 5.minutes, "postal_letter"]].each do |key, klass, age, name|
          row = authorization.new(name, { "code_sent_at" => age.ago.iso8601 })
          results[key] = klass.new(row, nil).send(:code_expired?)
        end
        results["upstream_methods"] = %i(call confirmation_successful? valid! invalid! locked!).map do |method|
          bih.instance_method(method).owner == core
        end
        puts JSON.generate(results)
      RUBY
      path = File.expand_path("../../../../app/commands/decidim/bih/phone_verification/confirm_authorization.rb", __dir__)
      output, error, status = Open3.capture3(RbConfig.ruby, "-e", program, path)
      raise "Expiry test process failed: #{error}\n#{output}" unless status.success?

      JSON.parse(output)
    end
  end

  def test_bih_verification_retains_the_existing_twenty_four_hour_window
    assert self.class.observations.fetch("core_20m")
    refute self.class.observations.fetch("bih_20m")
    refute self.class.observations.fetch("bih_23h")
  end

  def test_bih_verification_is_refused_after_its_existing_window
    assert self.class.observations.fetch("bih_expired")
  end

  def test_other_workflows_keep_the_upstream_expiry
    assert self.class.observations.fetch("postal_expired")
    refute self.class.observations.fetch("postal_valid")
  end

  def test_locking_validation_and_grant_are_inherited_from_the_actual_upstream_command
    assert_equal [true, true, true, true, true], self.class.observations.fetch("upstream_methods")
  end
end
