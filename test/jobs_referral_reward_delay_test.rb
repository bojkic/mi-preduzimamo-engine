# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/numeric/time"

# The referral reward waits exactly one day after the invitee verifies (owner
# decision 2026-09-12, down from 48 hours). The constant is the single source:
# the authorization hook schedules with it and the notification quotes it.
class ReferralRewardDelayTest < Minitest::Test
  def test_reward_delay_is_twenty_four_hours
    source = File.read(File.expand_path("../app/jobs/decidim/bih/goodwill/referral_reward_job.rb", __dir__))
    assert_match(/REWARD_DELAY = 24\.hours/, source)
  end

  def test_the_hook_schedules_with_the_constant_and_not_a_literal
    hook = File.read(File.expand_path("../app/overrides/decidim/authorization_referral_override.rb", __dir__))
    assert_match(/ReferralRewardJob\.set\(wait: Decidim::Bih::Goodwill::ReferralRewardJob::REWARD_DELAY\)/, hook)
    refute_match(/wait: 48\.hours/, hook)
  end
end
