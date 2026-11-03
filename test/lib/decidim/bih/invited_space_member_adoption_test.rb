# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"

class InvitedSpaceMemberAdoptionTest < Minitest::Test
  def test_current_membership_blocks_adoption_even_when_the_legacy_model_is_absent
    # Load the actual command in a child so model doubles cannot leak into
    # another test. This exercises policy, not the separate Rails/DB boundary.
    program = <<~RUBY
      require "active_support"
      require "active_support/core_ext/numeric/time"
      require "active_support/core_ext/object/blank"
      require "active_support/core_ext/string/inflections"
      module Decidim
        class Command; end
        User = Struct.new(:id, :invitation_token, :invitation_accepted_at, :sign_in_count, :roles, :officialized_at) do
          def admin? = false
          def managed? = false
          def blocked? = false
          def deleted? = false
        end
        class Authorization
          def self.exists?(user:) = false
        end
        module ParticipatorySpace
          class Member
            def self.exists?(decidim_user_id:) = decidim_user_id == 1
          end
        end
      end
      require ARGV.fetch(0)
      member = Decidim::User.new(1, "fixture-invitation", nil, 0, [], nil)
      ordinary = Decidim::User.new(2, "fixture-invitation", nil, 0, [], nil)
      abort "Existing member was eligible for adoption" if Decidim::Bih::RegisterWithPhone.adoptable?(member)
      abort "Plain unused invitation was incorrectly refused" unless Decidim::Bih::RegisterWithPhone.adoptable?(ordinary)
      abort "The removed model was reintroduced" if defined?(Decidim::ParticipatorySpacePrivateUser)
    RUBY
    command = File.expand_path("../../../../app/commands/decidim/bih/register_with_phone.rb", __dir__)
    output, status = Open3.capture2e(RbConfig.ruby, "-e", program, command)
    assert status.success?, output
  end
end
