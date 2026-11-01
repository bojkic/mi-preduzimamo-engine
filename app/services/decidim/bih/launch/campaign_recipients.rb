# frozen_string_literal: true

module Decidim
  module Bih
    module Launch
      # Who each campaign message is for.
      #
      # The console loop this replaces had no selection rule at all, so the
      # obvious thing to type was "every citizen" — which is how P9 (the weekly
      # standings) became the largest recurring cost in the plan. Each scope
      # here is the smallest audience the message makes sense for.
      #
      # Every phone scope is narrowed to citizens with a stored, verified
      # number: the campaign never uses SMS, but Viber and WhatsApp still need
      # the number to address.
      module CampaignRecipients
        module_function

        def for(organization:, key:)
          base = citizens(organization)
          invitations = auto_issued_invitations(organization)

          case key.to_s
          when "p1", "p3"
            base.where(id: invitations.where(status: "reserved").select(:decidim_user_id))
          when "p7"
            base.where(id: invitations.where(status: "reserved")
                                      .where.not(attendance_confirmed_at: nil)
                                      .select(:decidim_user_id))
          when "p4"
            base.where.not(id: invitations.select(:decidim_user_id))
          when "p5", "p8", "p9", "p10"
            base
          when "p11"
            # The letter to MZ presidents is addressed by hand: it is e-mail
            # only and its recipients are not platform citizens.
            Decidim::User.none
          else
            raise ArgumentError, "no recipient rule for #{key}"
          end
        end

        def citizens(organization)
          Decidim::User
            .where(organization:, deleted_at: nil, blocked: false, managed: false, admin: false)
            .where(id: Decidim::Bih::CitizenPhoneRecord.where(organization:).select(:decidim_user_id))
        end

        def auto_issued_invitations(organization)
          Decidim::Bih::Goodwill::RewardFulfillment.where(
            organization:,
            reward_key: Decidim::Bih::Goodwill::LaunchInvitation::REWARD_KEY,
            auto_issued: true
          )
        end
      end
    end
  end
end
