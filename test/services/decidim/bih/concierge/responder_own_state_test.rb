# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string"
require_relative "../../../../../app/services/decidim/bih/concierge/responder"

module Decidim
  module Bih
    module Concierge
      # The own-state handler (invitation + chosen komšiluk) without Rails: the
      # record lookups and i18n are stubbed, so these tests pin the STATE
      # MAPPING, the sign-in hand-off and the actor-scope refusal. The
      # DB-backed behaviour is covered by the host's web chat integration tests.
      class ResponderOwnStateTest < Minitest::Test
        Message = Struct.new(:text, :user, :trusted_context, keyword_init: true) do
          def image_url = nil

          def latitude = nil

          def longitude = nil
        end
        Scope = Struct.new(:actor_id, :organization_id, keyword_init: true)
        User = Struct.new(:id, :decidim_organization_id, :name, :nickname, keyword_init: true)
        # Stands in for Decidim::Bih::AccountSummary: the two granted-
        # authorization reads the verification answer consults, and nothing else.
        Summary = Struct.new(:sms, :postal, keyword_init: true) do
          def sms_verified? = sms

          def postal_verified? = postal
        end
        Invitation = Struct.new(:status, :entry_code, :attendance_confirmed_at, keyword_init: true)
        Reward = Struct.new(:cost, :expired, keyword_init: true) do
          def expired? = !!expired
        end
        Account = Struct.new(:contribution_score, keyword_init: true)
        Area = Struct.new(:name, :kind, :decidim_organization_id, :primary_mz, keyword_init: true)
        Profile = Struct.new(:komsiluk, :mz, keyword_init: true)
        Organization = Struct.new(:id)

        class HostFreeResponder < Responder
          attr_accessor :invitation, :reward, :account, :verified, :profile, :summary, :email_proven, :referral_counts
          attr_reader :log

          def initialize
            @organization = Organization.new(7)
            @goodwill_user_resolver = ->(message) { message.user }
            @verified = true
            @email_proven = false
            @log = []
          end

          private

          # The four reads the new own-state answers perform, stubbed at the
          # same seam the invitation and komsiluk reads already are.
          def account_summary_for(_user) = summary

          def email_proven?(_user) = email_proven

          def referral_counts_for(_user) = referral_counts

          def referral_wait_hours = 24

          def account_url = "/nalog"

          def invite_url = "/hub?tab=pozovi"

          def t(key, **options)
            "[#{key}#{options.map { |name, value| " #{name}=#{value}" }.join}]"
          end

          def dialogue_t(key, **options)
            "[dialogue.#{key}#{options.map { |name, value| " #{name}=#{value}" }.join}]"
          end

          def launch_invitation_for(_user) = invitation

          def launch_invitation_reward = reward

          def goodwill_account_for(_user) = account

          def sms_authorized?(_user) = verified

          def citizen_profile_for(_user) = profile

          def area_display_name(area) = area.name

          def sign_in_url = "/users/sign_in"

          def community_hub_url = "/hub"

          def rules_url = "/hub?tab=kako"

          def verification_url = "/verify"

          def komsiluk_url = "/komsiluk"

          def komsiluk_board_url = "/board"

          def log_failure(code, _error = nil)
            log << code
          end
        end

        def setup
          @responder = HostFreeResponder.new
          @user = User.new(id: 1, decidim_organization_id: 7)
        end

        def test_anonymous_invitation_question_offers_sign_in_and_the_launch_facts_without_data
          @responder.invitation = Invitation.new(status: "reserved", entry_code: "MI-AAAAA-22222")
          reply = @responder.respond(Message.new(text: "Imam li pozivnicu?", user: nil))

          assert_equal "goodwill", reply.answer_intent
          assert_includes reply.text, "[account_state.invitation.sign_in]"
          assert_includes reply.text, "[dialogue.handoff_sign_in url=/users/sign_in]"
          assert_includes reply.text, "[launch.answer url=/hub]"
          refute_includes reply.text, "MI-AAAAA-22222"
        end

        def test_anonymous_komsiluk_question_offers_sign_in_only
          reply = @responder.respond(Message.new(text: "koji je moj komšiluk", user: nil))

          assert_equal "goodwill", reply.answer_intent
          assert_equal "[account_state.komsiluk.sign_in]\n[dialogue.handoff_sign_in url=/users/sign_in]", reply.text
        end

        def test_a_conversation_scoped_to_another_actor_is_refused_without_data
          @responder.invitation = Invitation.new(status: "reserved", entry_code: "MI-AAAAA-22222")
          scope = Scope.new(actor_id: 2, organization_id: 7)
          reply = @responder.respond(Message.new(text: "imam li pozivnicu", user: @user, trusted_context: scope))

          refute_includes reply.text, "MI-AAAAA-22222"
          assert_includes reply.text, "[dialogue.handoff_sign_in url=/users/sign_in]"
          assert_includes @responder.log, "own_state_actor_scope_mismatch"
        end

        def test_a_conversation_scoped_to_another_organization_is_refused_without_data
          @responder.profile = Profile.new(komsiluk: area("Dvorovi"), mz: nil)
          scope = Scope.new(actor_id: 1, organization_id: 8)
          reply = @responder.respond(Message.new(text: "moj komšiluk", user: @user, trusted_context: scope))

          refute_includes reply.text, "Dvorovi"
          assert_includes reply.text, "[dialogue.handoff_sign_in url=/users/sign_in]"
        end

        def test_a_user_from_another_organization_gets_no_data
          foreign = User.new(id: 1, decidim_organization_id: 9)
          @responder.invitation = Invitation.new(status: "reserved", entry_code: "MI-AAAAA-22222")
          reply = @responder.respond(Message.new(text: "imam li pozivnicu", user: foreign))

          refute_includes reply.text, "MI-AAAAA-22222"
          assert_includes reply.text, "[dialogue.handoff_sign_in url=/users/sign_in]"
        end

        def test_reserved_invitation_answers_with_the_door_number
          @responder.invitation = Invitation.new(status: "reserved", entry_code: "MI-AAAAA-22222")
          reply = ask("Jesam li pozvan na 17.9?")

          assert_equal "[account_state.invitation.reserved code=MI-AAAAA-22222 hub_url=/hub]", reply.text
          assert_equal "goodwill", reply.answer_intent
        end

        def test_confirmed_fulfilled_and_canceled_states_each_have_their_own_answer
          @responder.invitation = Invitation.new(status: "reserved", entry_code: "MI-AAAAA-22222", attendance_confirmed_at: Time.now.utc)
          assert_equal "[account_state.invitation.confirmed code=MI-AAAAA-22222 hub_url=/hub]", ask("moja pozivnica").text

          @responder.invitation = Invitation.new(status: "fulfilled", entry_code: "MI-AAAAA-22222")
          assert_equal "[account_state.invitation.fulfilled hub_url=/hub]", ask("moja pozivnica").text

          %w(canceled reversed).each do |status|
            @responder.invitation = Invitation.new(status:, entry_code: "MI-AAAAA-22222")
            assert_equal "[account_state.invitation.canceled hub_url=/hub]", ask("moja pozivnica").text, status
          end
        end

        def test_an_invitation_without_a_code_points_at_the_rewards_tab
          @responder.invitation = Invitation.new(status: "reserved", entry_code: nil)
          assert_equal "[account_state.invitation.reserved_without_code hub_url=/hub]", ask("imam li pozivnicu").text

          @responder.invitation = Invitation.new(status: "requested", entry_code: "", attendance_confirmed_at: Time.now.utc)
          assert_equal "[account_state.invitation.confirmed_without_code hub_url=/hub]", ask("imam li pozivnicu").text
        end

        def test_no_invitation_explains_the_catalogue_threshold_and_the_gap_from_the_ledger
          @responder.reward = Reward.new(cost: 20)
          @responder.account = Account.new(contribution_score: 12)
          reply = ask("da li sam dobio pozivnicu")

          assert_equal(
            "[account_state.invitation.not_yet threshold=[goodwill.earning.points count=20] " \
            "score=[goodwill.earning.points count=12] missing=[goodwill.earning.points count=8] rules_url=/hub?tab=kako]",
            reply.text
          )
        end

        def test_no_invitation_and_no_account_counts_as_zero_and_offers_verification_when_unverified
          @responder.reward = Reward.new(cost: 20)
          @responder.account = nil
          @responder.verified = false
          reply = ask("imam li pozivnicu")

          assert_includes reply.text, "score=[goodwill.earning.points count=0] missing=[goodwill.earning.points count=20]"
          assert_includes reply.text, "[dialogue.handoff_verify url=/verify]"
        end

        def test_threshold_reached_without_an_issued_invitation_is_said_plainly
          @responder.reward = Reward.new(cost: 20)
          @responder.account = Account.new(contribution_score: 25)
          reply = ask("imam li pozivnicu")

          assert_equal(
            "[account_state.invitation.reached threshold=[goodwill.earning.points count=20] score=[goodwill.earning.points count=25] hub_url=/hub]",
            reply.text
          )
        end

        def test_expired_reward_never_promises_a_new_invitation
          @responder.reward = Reward.new(cost: 20, expired: true)
          @responder.account = Account.new(contribution_score: 50)
          assert_equal "[account_state.invitation.unavailable hub_url=/hub]", ask("imam li pozivnicu").text
        end

        def test_missing_catalogue_reward_is_reported_as_unavailable_never_with_a_typed_threshold
          @responder.reward = nil
          @responder.account = Account.new(contribution_score: 3)

          assert_equal "[account_state.invitation.unavailable hub_url=/hub]", ask("kad je lansiranje").text
        end

        def test_chosen_komsiluk_is_named_with_its_mz_and_the_change_link
          mz = area("MZ Dvorovi", kind: "mz")
          @responder.profile = Profile.new(komsiluk: area("Dvorovi"), mz:)
          reply = ask("u kom sam komšiluku")

          assert_equal "[account_state.komsiluk.assigned komsiluk=Dvorovi board_url=/board url=/komsiluk mz=MZ Dvorovi]", reply.text
          assert_equal "goodwill", reply.answer_intent
        end

        def test_chosen_komsiluk_falls_back_to_the_primary_mz_and_then_to_no_mz
          primary = area("MZ Janja", kind: "mz")
          @responder.profile = Profile.new(komsiluk: area("Janja", primary_mz: primary), mz: nil)
          assert_equal "[account_state.komsiluk.assigned komsiluk=Janja board_url=/board url=/komsiluk mz=MZ Janja]", ask("moj komšiluk").text

          @responder.profile = Profile.new(komsiluk: area("Janja"), mz: nil)
          assert_equal "[account_state.komsiluk.assigned_without_mz komsiluk=Janja board_url=/board url=/komsiluk]", ask("moj komšiluk").text
        end

        def test_no_chosen_komsiluk_reuses_the_choose_area_hand_off
          [nil, Profile.new(komsiluk: nil, mz: nil), Profile.new(komsiluk: area("Janja", kind: "mz"), mz: nil),
           Profile.new(komsiluk: area("Tudja", org: 9), mz: nil)].each do |profile|
            @responder.profile = profile
            reply = ask("gdje sam prijavljen")

            assert_equal "[account_state.komsiluk.none]\n[dialogue.handoff_choose_area url=/komsiluk]", reply.text, profile.inspect
          end
        end

        def test_own_state_never_intercepts_balance_or_earning_questions
          reply = @responder.send(:own_state_reply, Message.new(text: "moji bodovi", user: @user))
          assert_nil reply
          assert_nil @responder.send(:own_state_reply, Message.new(text: "kako da zaradim bodove", user: @user))
        end

        # --- R8: four questions, one 90-character reply --------------------
        #
        # Measured signed in on 14.09.2026 against the live site: "Da li sam
        # verifikovan?", "Kako se zovem?" and "Gdje je moj link za pozivanje
        # komšija?" all returned the IDENTICAL 90-character registration menu,
        # and "Koliko sam ljudi pozvao?" returned "Prema trenutnom stanju tvog
        # naloga, ovaj korak je već završen" — the same sentence as "Da li mi
        # je broj telefona potvrđen?". Each of these asks something different
        # and each now answers it.

        def test_the_four_account_questions_no_longer_share_one_reply
          @responder.summary = Summary.new(sms: true, postal: false)
          @responder.referral_counts = [3, 2]
          user = User.new(id: 1, decidim_organization_id: 7, name: "Savo Savić", nickname: "savo")
          replies = ["Da li sam verifikovan?", "Koliko sam ljudi pozvao?", "Kako se zovem?",
                     "Gdje je moj link za pozivanje komšija?"].map { |text| ask(text, user:).text }

          assert_equal replies.uniq.length, replies.length, "four different questions must not share one reply"
          assert(replies.none? { |text| text.include?("account_help_clarify") }, "none of them is the account menu")
        end

        def test_verification_answers_the_phone_the_letter_and_the_email_separately
          @responder.summary = Summary.new(sms: true, postal: false)
          @responder.email_proven = true
          reply = ask("Da li sam verifikovan?")

          assert_includes reply.text, "[account_state.verification.verified account_url=/nalog]"
          assert_includes reply.text, "[account_state.verification.postal_open url=/verify]"
          assert_includes reply.text, "[account_state.verification.email_done]"
          refute_includes reply.text, "not_verified"
        end

        def test_an_unverified_phone_says_so_and_hands_off_to_the_official_page
          @responder.summary = Summary.new(sms: false, postal: false)
          reply = ask("Da li mi je broj telefona potvrđen?")

          assert_includes reply.text, "[account_state.verification.not_verified account_url=/nalog]"
          assert_includes reply.text, "[dialogue.handoff_verify url=/verify]"
          assert_includes reply.text, "[account_state.verification.email_open]"
        end

        # An unreadable summary answers NOTHING here rather than a guessed
        # "no": telling a verified citizen they are not verified is worse than
        # sending them to the page.
        def test_an_unreadable_verification_summary_answers_nothing_rather_than_guessing
          @responder.summary = nil

          assert_nil @responder.send(:own_state_reply, Message.new(text: "Da li sam verifikovan?", user: @user))
        end

        def test_the_referral_count_is_a_count_and_names_nobody
          @responder.referral_counts = [3, 2]
          reply = ask("Koliko sam ljudi pozvao?")

          assert_includes reply.text, "[account_state.referrals.count count=3 rewarded=2 url=/hub?tab=pozovi]"
          assert_includes reply.text, "[account_state.referrals.pending count=1 hours=24]"
        end

        def test_a_zero_referral_count_is_a_real_zero_with_the_invite_page
          @responder.referral_counts = [0, 0]
          reply = ask("Koliko sam komšija pozvao?")

          assert_includes reply.text, "[account_state.referrals.none url=/hub?tab=pozovi]"
          refute_includes reply.text, "pending"
        end

        def test_a_fully_rewarded_referral_count_carries_no_pending_line
          @responder.referral_counts = [2, 2]

          refute_includes ask("Koliko sam ljudi pozvao?").text, "pending"
        end

        def test_an_unreadable_referral_ledger_answers_nothing_rather_than_a_zero
          @responder.referral_counts = nil

          assert_nil @responder.send(:own_state_reply, Message.new(text: "Koliko sam ljudi pozvao?", user: @user))
        end

        def test_identity_answers_with_the_citizens_own_name_and_nickname
          user = User.new(id: 1, decidim_organization_id: 7, name: "Savo Savić", nickname: "savo")
          reply = ask("Kako se zovem?", user:)

          assert_includes reply.text, "[account_state.identity.known name=Savo Savić nickname=savo url=/nalog]"
        end

        # THE production utterance, which the reviewed privacy card also claims.
        # The card ran first as a pre-model stage and answered a VERIFIED,
        # SIGNED-IN citizen with "ovaj razgovor te ne prepoznaje sam od sebe"
        # one turn after Milica had named him (14.09.2026). The card now steps
        # aside for a resolved actor; this is what answers instead — the
        # existing authorized own-state read, which still resolves the user,
        # the organization and the trusted scope before it says a name, and
        # still refuses an anonymous chat.
        def test_the_recognition_question_is_answered_by_the_authorized_own_state_read
          user = User.new(id: 1, decidim_organization_id: 7, name: "Savo Savić", nickname: "savo")

          assert_includes ask("Znaš li ko sam ja?", user:).text,
                          "[account_state.identity.known name=Savo Savić nickname=savo url=/nalog]"

          anonymous = @responder.respond(Message.new(text: "Znaš li ko sam ja?", user: nil))

          assert_includes anonymous.text, "[account_state.identity.sign_in]"
          refute_includes anonymous.text, "Savo"
        end

        def test_identity_falls_back_to_whichever_half_the_account_carries
          only_name = User.new(id: 1, decidim_organization_id: 7, name: "Savo Savić")
          only_nick = User.new(id: 1, decidim_organization_id: 7, nickname: "savo")
          blank = User.new(id: 1, decidim_organization_id: 7)

          assert_includes ask("Ko sam ja?", user: only_name).text, "[account_state.identity.name_only name=Savo Savić url=/nalog]"
          assert_includes ask("Ko sam ja?", user: only_nick).text, "[account_state.identity.nickname_only nickname=savo url=/nalog]"
          assert_includes ask("Ko sam ja?", user: blank).text, "[account_state.identity.unknown url=/nalog]"
        end

        # The invite page is PUBLIC, so this is the one own-state category an
        # anonymous chat is answered rather than handed off — and it is
        # answered without resolving a user or reading anything.
        def test_the_invite_link_is_answered_anonymously_and_reads_nothing
          @responder.referral_counts = nil
          @responder.summary = nil
          anonymous = @responder.respond(Message.new(text: "Gdje je moj link za pozivanje komšija?", user: nil))

          assert_includes anonymous.text, "[account_state.invite_link.answer url=/hub?tab=pozovi]"
          refute_includes anonymous.text, "[dialogue.handoff_sign_in"
          assert_equal anonymous.text, ask("Gdje je moj link za pozivanje komšija?").text,
                       "the public answer is the same signed in"
        end

        # Every category that DOES read gets the sign-in hand-off when no user
        # can be resolved, and no number of any kind.
        def test_the_reading_categories_hand_an_anonymous_chat_to_sign_in
          @responder.summary = Summary.new(sms: true, postal: true)
          @responder.referral_counts = [3, 2]
          { "Da li sam verifikovan?" => "verification", "Koliko sam ljudi pozvao?" => "referrals",
            "Kako se zovem?" => "identity" }.each do |text, category|
            reply = @responder.respond(Message.new(text:, user: nil))

            assert_includes reply.text, "[account_state.#{category}.sign_in]", text
            assert_includes reply.text, "[dialogue.handoff_sign_in url=/users/sign_in]", text
            refute_match(/\b3\b|Savo/, reply.text, "an anonymous chat is given no account data")
          end
        end

        # An actor-scope mismatch is the account-switch case: the resolver
        # names one citizen and the conversation's trusted scope another.
        def test_a_scope_mismatch_gets_the_hand_off_and_no_account_data
          @responder.summary = Summary.new(sms: true, postal: true)
          reply = @responder.respond(Message.new(text: "Da li sam verifikovan?", user: @user,
                                                 trusted_context: Scope.new(actor_id: 99, organization_id: 7)))

          assert_includes reply.text, "[account_state.verification.sign_in]"
          assert_includes @responder.log, "own_state_actor_scope_mismatch"
        end

        private

        def ask(text, user: @user)
          @responder.respond(Message.new(text:, user:, trusted_context: Scope.new(actor_id: user.id, organization_id: 7)))
        end

        def area(name, kind: "komsiluk", org: 7, primary_mz: nil)
          Area.new(name:, kind:, decidim_organization_id: org, primary_mz:)
        end
      end
    end
  end
end
