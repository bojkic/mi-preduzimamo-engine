# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext"
require "active_support/message_verifier"
require_relative "../../../../app/services/decidim/bih/concierge/answer_intents"
require_relative "../../../../app/services/decidim/bih/concierge/dialogue/procedure_runner"

# Pure controller-boundary probe. Rails owns CSRF/session execution in the host
# integration suite; this loads the real controller methods without a Rails app.
module Decidim
  unless const_defined?(:ApplicationController, false)
    class ApplicationController
      def self.before_action(*); end
    end
  end
  module Bih
    module CurrentOrganizationUser
    end

    module Concierge
      module WebRegistrationResume
      end
    end
  end
end

require_relative "../../../../app/controllers/decidim/bih/concierge/web_chat_controller"

class ConciergeFeedbackAuthorizationTest < Minitest::Test
  class Probe < Decidim::Bih::Concierge::WebChatController
    def current_organization = Struct.new(:id).new(7)

    def feedback_session_digest = "a" * 64

    def feedback_verifier = ActiveSupport::MessageVerifier.new("synthetic-feedback-test-secret")

    def offer_capture?(reply) = reply.fetch(:eligible)

    def reply_text(_) = "Synthetic answer"

    def reply_answer_intent(_) = "service"

    def reply_dialogue_topic(_) = "unknown"

    def reply_quick_replies(_) = []
  end

  def test_actual_token_generation_binds_strict_eligibility_and_keeps_reply_and_tenant_scope
    controller = Probe.new
    [true, false].each do |eligible|
      token = controller.send(:feedback_token, { eligible: }, reply_id: "synthetic-reply", outcome: "fallback", citizen_message: "Synthetic question")
      payload = controller.feedback_verifier.verify(token)
      assert_equal eligible, payload.fetch(:offer_capture)
      assert_equal eligible, controller.send(:authorized_feedback_token?, payload, reply_id: "synthetic-reply", value: "share_question")
      assert controller.send(:authorized_feedback_token?, payload, reply_id: "synthetic-reply", value: "helpful")
      assert controller.send(:authorized_feedback_token?, payload, reply_id: "synthetic-reply", value: "not_helpful")
      assert_equal false, controller.send(:authorized_feedback_token?, payload, reply_id: "different-reply", value: "helpful")
      assert_equal false, controller.send(:authorized_feedback_token?, payload.merge(organization_id: 8), reply_id: "synthetic-reply", value: "helpful")
    end
  end

  def test_missing_or_forged_capture_flag_never_converts_old_rating_tokens_to_capture_permission
    controller = Probe.new
    base = { reply_id: "synthetic-reply", organization_id: 7, session_digest: controller.feedback_session_digest }
    [base, base.merge(offer_capture: nil), base.merge(offer_capture: "true"), base.merge(offer_capture: 1)].each do |payload|
      assert_equal false, controller.send(:authorized_feedback_token?, payload, reply_id: "synthetic-reply", value: "share_question")
      assert controller.send(:authorized_feedback_token?, payload, reply_id: "synthetic-reply", value: "not_helpful")
    end
    assert_equal false, controller.send(:authorized_feedback_token?, base.except(:session_digest), reply_id: "synthetic-reply", value: "helpful")
    assert_equal false, controller.send(:authorized_feedback_token?, base.merge(session_digest: "b" * 64), reply_id: "synthetic-reply", value: "helpful")
    assert_equal false, controller.send(:authorized_feedback_token?, nil, reply_id: "synthetic-reply", value: "helpful")
  end
end
