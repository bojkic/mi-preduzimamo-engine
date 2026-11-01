# frozen_string_literal: true

module Decidim
  module Bih
    # Public volunteering surface: citizens browse opportunities, register
    # availability, propose opportunities, and log hours. Admin review gates
    # opportunity publishing and logged-hour verification are consolidated under
    # the admin Goodwill dashboard, not the public page.
    #
    # GET    /biceriseno/volontiranje                       -> opportunities + my hours
    # POST   /biceriseno/volontiranje/dostupnost            -> register/update availability
    # POST   /biceriseno/volontiranje/prilika               -> propose opportunity
    # POST   /biceriseno/volontiranje/sati                  -> log hours (signed-in)
    # POST   /biceriseno/volontiranje/prijavi-se/:id        -> RSVP / sign up (signed-in)
    # DELETE /biceriseno/volontiranje/prijavi-se/:id        -> cancel RSVP (signed-in)
    class VolunteerController < Decidim::ApplicationController
      include Decidim::Bih::CurrentOrganizationUser

      MAX_RECURRING_SHIFTS = 8
      CONTRIBUTION_HISTORY_LIMIT = 100
      VOLUNTEER_TABS = %w(prilike dostupnost predlozi moje).freeze

      def index
        if current_organization_user.blank? && params[:sign_in] == "1" && volunteer_tab != "prilike"
          destination = "#{Decidim::Bih.public_path('volontiranje')}?tab=#{volunteer_tab}"
          CitizenReturnPath.store(session, organization: current_organization, path: destination)
          return redirect_to decidim.new_user_session_path(redirect_url: destination)
        end

        load_index_data
      end

      def load_index_data
        @tab = volunteer_tab
        user = current_organization_user
        load_form_context(user)
        load_opportunities(user)
        load_private_context(user)
      end

      def load_form_context(user)
        @availability = if user
                          VolunteerAvailability.find_or_initialize_by(
                            organization: current_organization, user: user
                          )
                        end
        @taxonomy = Decidim::Bih::VolunteeringTaxonomy
        @category_options = @taxonomy.option_pairs(:categories)
        @interest_options = @taxonomy.option_pairs(:interests)
        @skill_options = @taxonomy.option_pairs(:skills)
        @capability_options = @taxonomy.option_pairs(:capabilities)
        @weekday_options = @taxonomy.option_pairs(:weekdays)
        @month_options = @taxonomy.option_pairs(:months)
        @time_slot_options = @taxonomy.option_pairs(:time_slots)
        @opportunity_kind_options = category_options(
          Decidim::Bih::VolunteerOpportunity::OPPORTUNITY_KINDS,
          "decidim.bih.volunteer.opportunity_kinds"
        )
        @org_bonus_recognition_options = category_options(
          Decidim::Bih::VolunteerOpportunity::ORG_BONUS_RECOGNITIONS,
          "decidim.bih.volunteer.org_bonus_recognitions"
        )
        @mz_options = local_area_options("mz")
        @komsiluk_options = local_area_options("komsiluk")
        @partner_profile_options = partner_profile_options(user)
        @offering_partner_profile_options = partner_profiles_for(
          user,
          roles: Decidim::Bih::PartnerMembership::VOLUNTEER_ROLES
        ).sort_by(&:display_name).map { |profile| [profile.display_name, profile.id] }
        @approved_project_options = approved_project_options(user)
      end

      def load_opportunities(user)
        @opportunities =
          VolunteerOpportunity.publicly_visible
                              .where(organization: current_organization)
                              .includes(:komsiluk, :partner_profile)
                              .order(created_at: :desc)
                              .to_a
        @opportunity_match_scores = if @availability&.persisted?
                                      Decidim::Bih::VolunteeringMatcher.scores_by_opportunity(
                                        @opportunities,
                                        @availability
                                      )
                                    else
                                      {}
                                    end
        @opportunities = recommended_first(@opportunities, @opportunity_match_scores)
        # Active RSVPs of the current user, keyed by opportunity id, so the
        # listing can render the right Sign-up / Waitlist / Cancel control per
        # row without an N+1 query.
        @my_signups = if user
                        VolunteerSignup.where(organization: current_organization, user: user)
                                       .index_by(&:decidim_bih_volunteer_opportunity_id)
                      else
                        {}
                      end
        @my_closed_opportunity_signups = if user
                                           VolunteerSignup.where(organization: current_organization, user: user)
                                                          .includes(:opportunity)
                                                          .where.not(decidim_bih_volunteer_opportunity_id: @opportunities.map(&:id))
                                                          .order(updated_at: :desc)
                                                          .limit(CONTRIBUTION_HISTORY_LIMIT)
                                         else
                                           []
                                         end
        # Preloaded GOING signup counts keyed by opportunity id, so the listing
        # renders "N/M spots" + full? without a per-row COUNT query (N+1).
        @signup_counts = VolunteerSignup.going
                                        .where(opportunity: @opportunities)
                                        .group(:decidim_bih_volunteer_opportunity_id)
                                        .count
        @waitlist_counts = VolunteerSignup.waitlisted
                                          .where(opportunity: @opportunities)
                                          .group(:decidim_bih_volunteer_opportunity_id)
                                          .count
        load_contribution_context(user)
      end

      def load_contribution_context(user)
        @contribution_needs = Decidim::Bih::ContributionNeed
                              .approved_open
                              .where(organization: current_organization)
                              .joins(:partner_profile)
                              .merge(Decidim::Bih::PartnerProfile.publicly_visible)
                              .includes(:partner_profile, :project, :offers)
                              .order(needed_by: :asc, created_at: :desc)
                              .limit(CONTRIBUTION_HISTORY_LIMIT)
        offering_profile_ids = accepted_partner_profiles_for(
          user,
          roles: Decidim::Bih::PartnerMembership::VOLUNTEER_ROLES
        ).map(&:id)
        @my_contribution_offers = if user
                                    scope = Decidim::Bih::ContributionOffer.where(organization: current_organization)
                                    scope = scope
                                            .where(contributor: user, partner_profile_id: nil)
                                            .or(scope.where(partner_profile_id: offering_profile_ids))
                                    scope
                                      .includes(contribution_need: [:partner_profile, :project])
                                      .order(created_at: :desc)
                                      .limit(CONTRIBUTION_HISTORY_LIMIT)
                                  else
                                    Decidim::Bih::ContributionOffer.none
                                  end
        @my_contribution_offers_by_need_id = @my_contribution_offers.each_with_object({}) do |offer, offers|
          next unless Decidim::Bih::ContributionOffer::ACTIVE_STATUSES.include?(offer.status)

          offers[offer.contribution_need_id] ||= offer
        end
      end

      def load_private_context(user)
        @my_opportunities = if user
                              VolunteerOpportunity.where(organization: current_organization, author: user)
                                                  .includes(:komsiluk)
                                                  .order(created_at: :desc)
                            else
                              VolunteerOpportunity.none
                            end
        @my_logs = if user
                     VolunteerLog.where(organization: current_organization, user: user)
                                 .includes(:opportunity).order(created_at: :desc)
                   else
                     VolunteerLog.none
                   end
        managed_profile_ids = accepted_partner_profiles_for(
          user,
          roles: Decidim::Bih::PartnerMembership::VOLUNTEER_ROLES
        ).map(&:id)
        @managed_contribution_needs = if managed_profile_ids.any?
                                        Decidim::Bih::ContributionNeed
                                          .where(organization: current_organization, partner_profile_id: managed_profile_ids)
                                          .includes(:partner_profile, :project, offers: [:contributor, :partner_profile])
                                          .order(created_at: :desc)
                                          .limit(CONTRIBUTION_HISTORY_LIMIT)
                                      else
                                        Decidim::Bih::ContributionNeed.none
                                      end
      end

      private :load_index_data, :load_form_context, :load_opportunities, :load_contribution_context, :load_private_context

      def create_opportunity
        user = current_organization_user
        unless user
          flash[:alert] = t("decidim.bih.volunteer.flash.login_required")
          return redirect_to(action: :index)
        end
        if partner_profile_options(user).empty?
          flash[:alert] = t("decidim.bih.volunteer.flash.organization_required")
          return redirect_to(action: :index, tab: "predlozi", anchor: "predlozi")
        end
        if params[:budget_project_id].present? && selected_opportunity_project(user).nil?
          flash[:alert] = t("decidim.bih.volunteer.flash.invalid")
          return redirect_to(action: :index, tab: "predlozi", anchor: "predlozi")
        end

        preview_data = verified_proposal_preview(user)
        unless preview_data && params[:schedule_preview_confirmed] == "1"
          flash.now[:alert] = t("decidim.bih.volunteer.flash.schedule_preview_required")
          return preview_opportunity
        end

        create_opportunity_series!(user, submission_key: preview_data.fetch("submission_key"))
        flash[:notice] = t("decidim.bih.volunteer.flash.opportunity_submitted")
        redirect_to(action: :index, tab: "moje", anchor: "moje-prilike")
      rescue ActiveRecord::RecordInvalid => e
        # Re-render the index with the submitted values preserved (Decidim form
        # convention) instead of redirecting and losing the citizen's input.
        # The rescued record carries the rejected attributes + errors so the
        # opportunity form can repopulate every field.
        @submitted_opportunity = e.record if e.record.is_a?(VolunteerOpportunity)
        unless @submitted_opportunity
          @submitted_opportunity = VolunteerOpportunity.new(opportunity_attributes(user))
          @submitted_opportunity.validate
        end
        load_index_data
        @tab = "predlozi"
        flash.now[:alert] = submission_error_message(@submitted_opportunity)
        render(:index)
      end

      def preview_opportunity
        user = current_organization_user
        unless user
          flash[:alert] = t("decidim.bih.volunteer.flash.login_required")
          return redirect_to(action: :index)
        end
        if partner_profile_options(user).empty?
          flash[:alert] = t("decidim.bih.volunteer.flash.organization_required")
          return redirect_to(action: :index, tab: "predlozi", anchor: "predlozi")
        end
        if params[:budget_project_id].present? && selected_opportunity_project(user).nil?
          flash[:alert] = t("decidim.bih.volunteer.flash.invalid")
          return redirect_to(action: :index, tab: "predlozi", anchor: "predlozi")
        end

        @proposal_payload = proposal_submission_params
        @proposal_preview = VolunteerProposalPreview.build(
          starts_at: params[:starts_at], ends_at: params[:ends_at],
          signup_deadline_at: params[:signup_deadline_at],
          recurrence_count: params[:recurrence_count], maximum: MAX_RECURRING_SHIFTS
        )
        attributes = opportunity_attributes(user)
        invalid = @proposal_preview.terms.filter_map do |term|
          candidate = VolunteerOpportunity.new(attributes.merge(
            starts_at: term.starts_at, ends_at: term.ends_at,
            signup_deadline_at: term.signup_deadline_at
          ))
          candidate unless candidate.valid?
        end
        if invalid.any?
          @submitted_opportunity = invalid.first
          load_index_data
          @tab = "predlozi"
          flash.now[:alert] = submission_error_message(@submitted_opportunity)
          return render(:index, status: :unprocessable_entity)
        end

        @preview_token = proposal_preview_verifier.generate(
          { digest: VolunteerProposalPreview.digest(@proposal_payload),
            author_id: user.id, organization_id: current_organization.id,
            submission_key: SecureRandom.uuid },
          expires_in: 20.minutes
        )
        render :preview_opportunity
      end

      def edit_opportunity_preview
        user = current_organization_user
        unless user
          flash[:alert] = t("decidim.bih.volunteer.flash.login_required")
          return redirect_to(action: :index)
        end

        @submitted_opportunity = VolunteerOpportunity.new(opportunity_attributes(user))
        load_index_data
        @tab = "predlozi"
        render :index
      end

      def edit_opportunity_revision
        return revision_not_found unless load_revision_opportunity

        @revision_terms = ReviseVolunteerProposal.group_for(@revision_opportunity,
                                                              author: current_organization_user).to_a
        render :edit_opportunity_revision
      end

      def preview_opportunity_revision
        return revision_not_found unless load_revision_opportunity

        @revision_shared = revision_shared_params
        @revision_term_params = revision_term_params
        @revision_result = ReviseVolunteerProposal.call(opportunity: @revision_opportunity,
                                                         author: current_organization_user,
                                                         shared: @revision_shared, terms: @revision_term_params)
        @revision_terms = @revision_result.terms
        render(@revision_result.status == :preview ? :preview_opportunity_revision : :edit_opportunity_revision)
      end

      def resubmit_opportunity_revision
        return revision_not_found unless load_revision_opportunity
        return revision_not_found unless params[:preview_confirmed] == "1"

        @revision_shared = revision_shared_params
        @revision_term_params = revision_term_params
        @revision_result = ReviseVolunteerProposal.call(opportunity: @revision_opportunity,
                                                         author: current_organization_user,
                                                         shared: @revision_shared, terms: @revision_term_params,
                                                         submit: true)
        if @revision_result.status == :submitted
          redirect_to volunteer_path(tab: "moje", anchor: "moje-prilike"),
                      notice: t("decidim.bih.volunteer.flash.opportunity_resubmitted")
        else
          @revision_terms = @revision_result.terms
          render :edit_opportunity_revision, status: :unprocessable_entity
        end
      end

      def create_contribution_need
        user = current_organization_user
        return contribution_redirect(:login_required) unless user

        profile = selected_partner_profile_for(user, params[:need_partner_profile_id])
        return contribution_redirect(:organization_required, tab: "predlozi") unless profile

        project = selected_budget_project(profile, params[:project_id])
        return contribution_redirect(:invalid, tab: "predlozi") if params[:project_id].present? && project.nil?

        need = Decidim::Bih::ContributionNeed.new(
          organization: current_organization,
          partner_profile: profile,
          author: user,
          project:,
          need_type: params[:need_type],
          title: params[:need_title],
          description: params[:need_description],
          quantity: params[:quantity],
          unit: params[:unit],
          needed_by: params[:needed_by].presence,
          location: params[:need_location],
          review_status: "pending",
          fulfillment_status: "open"
        )
        need.save!
        flash[:notice] = t("decidim.bih.volunteer.contributions.flash.need_submitted")
        redirect_to volunteer_path(tab: "moje", anchor: "moje-potrebe")
      rescue ActiveRecord::RecordInvalid => e
        flash[:alert] = e.record.errors.full_messages.first || t("decidim.bih.volunteer.contributions.flash.invalid")
        redirect_to volunteer_path(tab: "predlozi", anchor: "predlozi-potrebu")
      end

      def create_contribution_offer
        user = current_organization_user
        return contribution_redirect(:login_required) unless user

        need = Decidim::Bih::ContributionNeed
               .approved_open
               .where(organization: current_organization)
               .joins(:partner_profile)
               .merge(Decidim::Bih::PartnerProfile.publicly_visible)
               .find_by(id: params[:need_id])
        return contribution_redirect(:not_found) unless need

        offering_profile = selected_partner_profile_for(
          user,
          params[:offering_partner_profile_id],
          roles: Decidim::Bih::PartnerMembership::VOLUNTEER_ROLES
        )
        return contribution_redirect(:offer_forbidden) if params[:offering_partner_profile_id].present? && offering_profile.nil?

        result, = Decidim::Bih::CreateContributionOffer.call(
          need:,
          contributor: user,
          quantity: params[:offer_quantity],
          partner_profile: offering_profile
        )
        flash[result == :ok ? :notice : :alert] = t("decidim.bih.volunteer.contributions.flash.offer_#{result}")
        redirect_to volunteer_path(tab: "moje", anchor: "moje-ponude")
      end

      def cancel_contribution_need
        user = current_organization_user
        return contribution_redirect(:login_required, tab: "moje") unless user

        need = Decidim::Bih::ContributionNeed.where(organization: current_organization).find_by(id: params[:id])
        result = Decidim::Bih::CancelContributionNeed.call(need:, actor: user)
        flash[[:ok, :already].include?(result) ? :notice : :alert] =
          t("decidim.bih.volunteer.contributions.flash.cancel_#{result}")
        redirect_to volunteer_path(tab: "moje", anchor: "moje-potrebe")
      end

      def accept_contribution_offer
        manage_contribution_offer("accept")
      end

      def reject_contribution_offer
        manage_contribution_offer("decline")
      end

      def deliver_contribution_offer
        manage_contribution_offer("mark_delivered")
      end

      def withdraw_contribution_offer
        manage_contribution_offer("withdraw")
      end

      def confirm_contribution_offer
        manage_contribution_offer("confirm")
      end

      def register_availability
        user = current_organization_user
        unless user
          flash[:alert] = t("decidim.bih.volunteer.flash.login_required")
          return redirect_to(action: :index)
        end

        status, = RegisterVolunteerAvailability.call(
          user: user,
          organization: current_organization,
          availability: params[:availability],
          interests: params[:interests],
          area_scope: params[:area_scope],
          local_area: selected_availability_area,
          day_keys: params[:day_keys],
          month_keys: params[:month_keys],
          time_slot_keys: params[:time_slot_keys],
          interest_keys: params[:interest_keys],
          skill_keys: params[:skill_keys],
          capability_keys: params[:capability_keys]
        )
        # Broj bodova se cita iz vazece skale, nikad se ne upisuje u tekst —
        # inace poruka odluta cim se skala promijeni (bila je "50" dok je
        # stvarna vrijednost postala 10).
        flash[:notice] = t(
          "decidim.bih.volunteer.flash.availability_#{status}",
          count: Decidim::Bih::Goodwill::EarningRules.new(
            organization: current_organization
          ).points_for(:volunteer_availability)
        )
        redirect_to(action: :index, tab: "dostupnost", anchor: "dostupnost")
      rescue ActiveRecord::RecordInvalid => e
        # Re-render the index with the submitted availability/interests preserved.
        # The index view reads @availability for the form values, so seed it with
        # the rejected record (or a fresh one carrying the submitted text).
        @submitted_availability = availability_record_from_error(e, user)
        load_index_data
        @tab = "dostupnost"
        @availability = @submitted_availability
        flash.now[:alert] = submission_error_message(@submitted_availability)
        render(:index)
      end

      def log_hours
        user = current_organization_user
        unless user
          flash[:alert] = t("decidim.bih.volunteer.flash.login_required")
          return redirect_to(action: :index)
        end

        saved = false
        # Claims for completed work remain possible after an opportunity has
        # closed; the interval and approved place are checked under locks.
        VolunteerOpportunity.transaction do
          locked = VolunteerOpportunity.lock.find_by(id: params[:opportunity_id], organization: current_organization)
          unless locked
            flash[:alert] = t("decidim.bih.volunteer.flash.invalid")
            raise ActiveRecord::Rollback
          end
          signup = locked.signups.lock.find_by(user: user)
          work_date, worked_from_at, worked_until_at = parsed_work_interval
          if !eligible_work_signup?(signup, locked, user, work_date, worked_until_at)
            flash[:alert] = t("decidim.bih.volunteer.flash.not_attending")
            raise ActiveRecord::Rollback
          end

          user.lock!
          duration = if worked_from_at && worked_until_at
                       ((worked_until_at - worked_from_at) / 3600).round(2)
                     end

          log = VolunteerLog.new(
            organization: current_organization, opportunity: locked, user: user,
            hours: duration, status: "pending",
            work_date: work_date, worked_from_at: worked_from_at, worked_until_at: worked_until_at
          )
          saved = log.save
          raise ActiveRecord::Rollback unless saved
        end

        if saved
          flash[:notice] = t("decidim.bih.volunteer.flash.logged")
          return redirect_to(action: :index, tab: "moje", anchor: "moji-sati")
        elsif flash[:alert].blank?
          flash[:alert] = t("decidim.bih.volunteer.flash.invalid")
        end
        redirect_to(action: :index, tab: "moje")
      end

      def parsed_work_interval
        date = Date.iso8601(params[:work_date].to_s)
        from = params[:worked_from_time].to_s
        until_time = params[:worked_until_time].to_s
        return [date, nil, nil] unless from.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/) &&
                                            until_time.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)

        zone = Time.find_zone!("Europe/Sarajevo")
        started = zone.parse("#{date.iso8601} #{from}")
        ending_date = until_time == "00:00" && from != "00:00" ? date.next_day : date
        finished = zone.parse("#{ending_date.iso8601} #{until_time}")
        return [date, nil, nil] unless started&.strftime("%H:%M") == from &&
                                            finished&.strftime("%H:%M") == until_time

        [date, started, finished]
      rescue Date::Error, ArgumentError
        [nil, nil, nil]
      end

      def eligible_work_signup?(signup, opportunity, user, work_date, worked_until_at)
        return false unless signup&.review_approved?
        return true if signup.going?
        return false unless signup.cancelled? && signup.participation_ended_at && worked_until_at &&
                            worked_until_at < signup.participation_ended_at && work_date

        VolunteerAttendance.confirmed.exists?(organization: current_organization,
                                              opportunity:, user:, work_date:)
      end

      def signup
        user = current_organization_user
        unless user
          flash[:alert] = t("decidim.bih.volunteer.flash.login_required")
          return redirect_to(action: :index)
        end

        outcome = nil
        promoted_signups = []
        # Lock both the opportunity and its current host profile so capacity and
        # partner eligibility stay atomic with create/reactivate.
        VolunteerOpportunity.transaction do
          locked = lock_public_opportunity(params[:opportunity_id])
          outcome = if locked
                      promoted_signups = Decidim::Bih::VolunteerSeatAllocator.promote!(locked)
                      locked.signup_open? ? register_signup(locked, user) : :deadline_closed
                    else
                      :not_found
                    end
        end

        promoted_signups.each do |promoted|
          VolunteerNotifications.publish(user: promoted.user, kind: "signup", status: "promoted",
                                         title: promoted.opportunity.title)
        end

        flash_type = [:deadline_closed, :not_found].include?(outcome) ? :alert : :notice
        flash[flash_type] = t("decidim.bih.volunteer.flash.#{signup_flash_key(outcome)}")
        redirect_to(action: :index, tab: "prilike")
      rescue ActiveRecord::RecordInvalid
        flash[:alert] = t("decidim.bih.volunteer.flash.invalid")
        redirect_to(action: :index, tab: "prilike")
      end

      def cancel_signup
        user = current_organization_user
        unless user
          flash[:alert] = t("decidim.bih.volunteer.flash.login_required")
          return redirect_to(action: :index)
        end

        opportunity = VolunteerOpportunity.active.find_by(id: params[:opportunity_id], organization: current_organization)
        outcome = :not_found
        promoted_signup = nil

        if opportunity
          VolunteerOpportunity.transaction do
            locked = VolunteerOpportunity.lock.find(opportunity.id)
            signup = VolunteerSignup.lock.find_by(organization: current_organization, opportunity: locked, user: user)

            if signup && (signup.attendance_confirmed? || signup.dated_attendances.exists? ||
                          locked.logs.exists?(decidim_user_id: user.id))
              outcome = :attendance_locked
            elsif signup&.active_rsvp?
              was_going = signup.going?
              signup.update!(status: "cancelled", queued_at: nil, participation_ended_at: Time.current)
              Decidim::Bih::OperatorAuditEvent.record!(
                organization: current_organization, actor: user, event_type: "volunteering_application_withdrawn",
                resource: signup, metadata: { opportunity_id: locked.id, review_status: signup.review_status }
              )
              promoted_signup = Decidim::Bih::VolunteerSeatAllocator.promote!(locked).first if was_going
              outcome = :cancelled
            end
          end
        end

        if promoted_signup
          VolunteerNotifications.publish(
            user: promoted_signup.user,
            kind: "signup",
            status: "promoted",
            title: opportunity.title
          )
        end

        flash[:notice] = t("decidim.bih.volunteer.flash.signup_#{outcome}")
        redirect_to(action: :index, tab: "prilike")
      rescue ActiveRecord::RecordInvalid
        flash[:alert] = t("decidim.bih.volunteer.flash.invalid")
        redirect_to(action: :index, tab: "prilike")
      end

      private

      PROPOSAL_SCALAR_FIELDS = %i(
        title description location meeting_point opportunity_kind category opportunity_area_scope
        opportunity_mz_local_area_id opportunity_komsiluk_local_area_id komsiluk_id
        partner_profile_id budget_project_id capacity starts_at ends_at signup_deadline_at
        recurrence_count requirements org_bonus_points_per_hour org_bonus_budget_cap
        org_bonus_max_participants org_bonus_recognition
      ).freeze
      PROPOSAL_ARRAY_FIELDS = %i(
        opportunity_day_keys opportunity_month_keys opportunity_time_slot_keys
        opportunity_skill_keys opportunity_capability_keys
      ).freeze

      def proposal_submission_params
        params.permit(*PROPOSAL_SCALAR_FIELDS, PROPOSAL_ARRAY_FIELDS.index_with { [] }).to_h
      end

      def proposal_preview_verifier
        Rails.application.message_verifier(:volunteer_proposal_preview)
      end

      def verified_proposal_preview(user)
        data = proposal_preview_verifier.verified(params[:preview_token].to_s)
        return nil unless data.is_a?(Hash)
        data = data.stringify_keys
        return nil unless data["author_id"] == user.id && data["organization_id"] == current_organization.id
        return nil if data["submission_key"].blank? || data["digest"].to_s.length != 64

        digest = VolunteerProposalPreview.digest(proposal_submission_params)
        return nil unless ActiveSupport::SecurityUtils.secure_compare(data["digest"].to_s, digest)

        data
      end

      def load_revision_opportunity
        user = current_organization_user
        return false unless user

        @revision_opportunity = VolunteerOpportunity.where(organization: current_organization, author: user,
                                                            review_status: "needs_revision").find_by(id: params[:id])
        @revision_opportunity.present?
      end

      def revision_not_found
        redirect_to volunteer_path(tab: "moje", anchor: "moje-prilike"),
                    alert: t("decidim.bih.volunteer.flash.invalid")
      end

      def revision_shared_params
        params.fetch(:shared, ActionController::Parameters.new)
              .permit(*ReviseVolunteerProposal::SHARED_FIELDS).to_h
      end

      def revision_term_params
        params[:terms]&.to_unsafe_h || {}
      end

      def volunteer_tab
        tab = params[:tab].to_s
        return tab if VOLUNTEER_TABS.include?(tab)

        VOLUNTEER_TABS.first
      end

      # Builds the VolunteerAvailability instance whose values seed the re-rendered
      # form after a validation error. Prefer the rescued record (it already holds
      # the rejected attributes + errors); fall back to a fresh record carrying the
      # submitted text so input is never lost.
      def availability_record_from_error(error, user)
        record = error.record if error.record.is_a?(VolunteerAvailability)
        record ||= VolunteerAvailability.find_or_initialize_by(
          organization: current_organization, user: user
        )
        record.assign_attributes(
          availability: params[:availability].to_s.strip,
          interests: params[:interests].to_s.strip,
          area_scope: params[:area_scope].to_s.presence || "city",
          local_area: selected_availability_area,
          day_keys: params[:day_keys],
          month_keys: params[:month_keys],
          time_slot_keys: params[:time_slot_keys],
          interest_keys: params[:interest_keys],
          skill_keys: params[:skill_keys],
          capability_keys: params[:capability_keys]
        )
        record
      end

      # Surfaces the first model validation message when present so the citizen
      # learns *why* the submission was rejected, falling back to the generic copy.
      def submission_error_message(record)
        message = record.errors.full_messages.first if record.respond_to?(:errors)
        message.presence || t("decidim.bih.volunteer.flash.invalid")
      end

      def create_opportunity_series!(user, submission_key:)
        attributes = opportunity_attributes(user)
        schedule = Decidim::Bih::VolunteerSchedule.new(
          starts_at: attributes.delete(:starts_at),
          ends_at: attributes.delete(:ends_at),
          signup_deadline_at: attributes.delete(:signup_deadline_at),
          recurrence_count: params[:recurrence_count],
          maximum: MAX_RECURRING_SHIFTS
        )

        VolunteerOpportunity.transaction do
          # Serializes a repeated confirmed POST for this organization. The
          # proposal identity is persisted on every term by the award schema.
          current_organization.lock!
          existing = VolunteerOpportunity.where(organization: current_organization, author: user,
                                                 proposal_identity: submission_key).exists?
          return if existing

          attributes[:proposal_identity] = submission_key
          schedule.instances.each do |schedule_attributes|
            VolunteerOpportunity.create!(attributes.merge(schedule_attributes))
          end
        end
      end

      def opportunity_attributes(user)
        partner_profile = selected_partner_profile(user)

        {
          organization: current_organization,
          author: user,
          title: params[:title].to_s.strip,
          description: params[:description].to_s.strip,
          location: selected_opportunity_location_text,
          komsiluk: selected_opportunity_komsiluk,
          meeting_point: params[:meeting_point].to_s.strip.presence,
          opportunity_kind: selected_opportunity_kind,
          category: selected_category,
          day_keys: params[:opportunity_day_keys],
          month_keys: params[:opportunity_month_keys],
          time_slot_keys: params[:opportunity_time_slot_keys],
          starts_at: params[:starts_at].presence,
          ends_at: params[:ends_at].presence,
          signup_deadline_at: params[:signup_deadline_at].presence,
          requirements: params[:requirements].to_s.strip.presence,
          skill_keys: params[:opportunity_skill_keys],
          capability_keys: params[:opportunity_capability_keys],
          capacity: params[:capacity].presence,
          org_bonus_points_per_hour: params[:org_bonus_points_per_hour].presence || 0,
          org_bonus_budget_cap: params[:org_bonus_budget_cap].presence,
          org_bonus_max_participants: params[:org_bonus_max_participants].presence,
          org_bonus_recognition: selected_org_bonus_recognition,
          partner_profile:,
          partner_name: partner_profile&.display_name,
          budget_project: selected_opportunity_project(user),
          active: false,
          review_status: "pending"
        }
      end

      def register_signup(opportunity, user)
        signup = VolunteerSignup.find_or_initialize_by(
          organization: current_organization, opportunity: opportunity, user: user
        )

        return :already if signup.persisted? && (signup.going? || signup.pending?)
        return :already_waitlisted if signup.persisted? && signup.waitlisted?

        first_session = selected_first_session(opportunity)
        return :deadline_closed if opportunity.starts_at && opportunity.starts_at <= Time.current && !first_session

        signup.first_session_at = first_session
        signup.queued_at = nil
        signup.participation_ended_at = nil
        signup.reviewed_at = nil
        signup.reviewer = nil
        signup.decision_reason = nil
        if Decidim::Bih.volunteer_application_review_required
          signup.assign_attributes(status: "pending", review_status: "pending", review_source: "application")
          signup.save!
          audit_signup!(signup, "volunteering_application_submitted")
          :pending_review
        else
          # The shared-engine automatic policy is an explicit decision; it does
          # not inherit the database default, which is deliberately pending.
          waiting = opportunity.signups.approved_waitlist.exists?
          place = !opportunity.full? && !waiting
          signup.assign_attributes(status: place ? "going" : "waitlisted",
                                   review_status: "automatic", review_source: "automatic",
                                   reviewed_at: Time.current,
                                   queued_at: place ? nil : Time.current)
          signup.save!
          audit_signup!(signup, "volunteering_application_automatically_accepted")
          place ? :signed_up : :waitlisted
        end
      end

      def audit_signup!(signup, event_type)
        Decidim::Bih::OperatorAuditEvent.record!(
          organization: current_organization, actor: signup.user, event_type:, resource: signup,
          metadata: { opportunity_id: signup.decidim_bih_volunteer_opportunity_id,
                      status: signup.status, review_status: signup.review_status }
        )
      end

      def selected_first_session(opportunity)
        raw = params[:first_session_at].to_s.strip
        return nil if raw.blank?

        zone = ActiveSupport::TimeZone[VolunteerOpportunity::SIGNUP_TIME_ZONE]
        local = zone.parse(raw)
        return nil unless local && local > Time.current
        return nil if opportunity.starts_at && local < opportunity.starts_at
        return nil if opportunity.ends_at && local > opportunity.ends_at

        local
      rescue ArgumentError
        nil
      end

      def signup_flash_key(outcome)
        case outcome
        when :not_found
          "invalid"
        when :deadline_closed
          "signup_deadline_closed"
        when :waitlisted
          "waitlisted"
        when :already_waitlisted
          "already_waitlisted"
        when :already
          "already_signed_up"
        when :pending_review
          "pending_review"
        else
          "signed_up"
        end
      end

      def lock_public_opportunity(id)
        opportunity = VolunteerOpportunity.publicly_visible.lock.find_by(
          id:,
          organization: current_organization
        )
        return unless opportunity
        return opportunity unless opportunity.partner_profile

        opportunity.partner_profile.lock!
        return opportunity if opportunity.partner_profile.volunteer_opportunity_eligible?

        nil
      end

      def promote_waitlisted_signup(opportunity)
        Decidim::Bih::VolunteerSeatAllocator.promote!(opportunity).first
      end

      def recommended_first(opportunities, scores)
        return opportunities if scores.blank?

        opportunities.sort_by do |opportunity|
          [
            -scores.fetch(opportunity, 0),
            opportunity.starts_at || Time.zone.at(0),
            -opportunity.created_at.to_i
          ]
        end
      end

      def local_area_options(kind)
        Decidim::Bih::LocalArea
          .where(organization: current_organization, kind:)
          .order(:slug)
          .map { |area| [area.translated_name, area.id] }
      end

      def selected_availability_area
        scope = params[:area_scope].to_s
        id = scope == "mz" ? params[:mz_local_area_id] : params[:komsiluk_local_area_id]

        selected_area_for(scope:, id:)
      end

      def selected_opportunity_komsiluk
        return nil unless selected_opportunity_area_scope == "komsiluk"

        selected_area_for(
          scope: "komsiluk",
          id: params[:opportunity_komsiluk_local_area_id].presence || params[:komsiluk_id]
        )
      end

      def selected_opportunity_location_text
        scope = selected_opportunity_area_scope
        return Decidim::Bih::VolunteeringTaxonomy.label(:area_scopes, "city") if scope == "city"
        return selected_area_for(scope: "mz", id: params[:opportunity_mz_local_area_id])&.translated_name if scope == "mz"

        params[:location].to_s.strip.presence
      end

      def selected_opportunity_area_scope
        scope = params[:opportunity_area_scope].to_s.presence
        scope ||= "komsiluk" if params[:opportunity_komsiluk_local_area_id].present? || params[:komsiluk_id].present?
        scope ||= "mz" if params[:opportunity_mz_local_area_id].present?
        scope ||= "city"
        return scope if Decidim::Bih::VolunteeringTaxonomy::AREA_SCOPES.include?(scope)

        "city"
      end

      def selected_area_for(scope:, id:)
        scope = scope.to_s
        return nil unless %w(mz komsiluk).include?(scope)
        return nil if id.blank?

        Decidim::Bih::LocalArea.find_by(organization: current_organization, kind: scope, id:)
      end

      def selected_category
        category = params[:category].to_s.strip
        return category if Decidim::Bih::VolunteeringTaxonomy::CATEGORIES.include?(category)

        nil
      end

      def selected_opportunity_kind
        params[:opportunity_kind].to_s.presence_in(VolunteerOpportunity::OPPORTUNITY_KINDS) || "volunteer"
      end

      def selected_org_bonus_recognition
        params[:org_bonus_recognition].to_s.presence_in(VolunteerOpportunity::ORG_BONUS_RECOGNITIONS)
      end

      def category_options(keys, scope)
        keys.map { |key| [I18n.t("#{scope}.#{key}"), key] }
      end

      def partner_profile_options(user)
        return [] unless user

        Decidim::Bih::PartnerMembership
          .for_user(user, organization: current_organization)
          .where(role: Decidim::Bih::PartnerMembership::VOLUNTEER_ROLES)
          .includes(:partner_profile)
          .map(&:partner_profile)
          .select { |profile| profile&.volunteer_opportunity_eligible? }
          .sort_by(&:display_name)
          .map { |profile| [profile.display_name, profile.id] }
      end

      def selected_partner_profile(user)
        return nil unless user
        return nil if params[:partner_profile_id].blank?

        profile = Decidim::Bih::PartnerProfile
                  .volunteer_opportunity_eligible
                  .where(organization: current_organization)
                  .find_by(id: params[:partner_profile_id])
        return nil unless profile

        membership = profile.memberships.accepted.find_by(decidim_user_id: user.id)
        return profile if membership&.volunteer_manager?

        nil
      end

      def manage_contribution_offer(action)
        user = current_organization_user
        return contribution_redirect(:login_required) unless user

        offer = Decidim::Bih::ContributionOffer
                .where(organization: current_organization)
                .includes(contribution_need: :partner_profile)
                .find_by(id: params[:id])
        result = Decidim::Bih::ManageContributionOffer.call(
          offer:,
          actor: user,
          action:,
          reason: params[:reason]
        )
        flash[result == :ok || result == :already ? :notice : :alert] =
          t("decidim.bih.volunteer.contributions.flash.manage_#{result}")
        redirect_to volunteer_path(tab: "moje", anchor: "moje-ponude")
      end

      def contribution_redirect(key, tab: "prilike")
        flash[:alert] = t("decidim.bih.volunteer.contributions.flash.#{key}")
        redirect_to volunteer_path(tab:)
      end

      def approved_project_options(user)
        profiles = partner_profiles_for(user, roles: Decidim::Bih::PartnerMembership::VOLUNTEER_ROLES)
        return [] if profiles.empty?

        active_project_ids = Decidim::Bih::ProjectDonationLink
                             .active
                             .where(organization: current_organization)
                             .pluck(:decidim_budgets_project_id)
        Decidim::Bih::PartnerProjectSubmission
          .approved
          .where(
            organization: current_organization,
            partner_profile: profiles,
            decidim_budgets_project_id: active_project_ids
          )
          .includes(:partner_profile, :project)
          .filter_map do |submission|
            next unless submission.project

            ["#{submission.partner_profile.display_name} — #{translated_project_title(submission.project)}", submission.project.id]
          end
          .sort_by(&:first)
      end

      def selected_budget_project(profile, raw_id)
        return if profile.blank? || raw_id.blank?

        submission = Decidim::Bih::PartnerProjectSubmission
                     .approved
                     .where(organization: current_organization, partner_profile: profile)
                     .find_by(decidim_budgets_project_id: raw_id)
        return unless submission&.project
        return unless Decidim::Bih::ProjectDonationLink.active.exists?(
          organization: current_organization,
          project: submission.project
        )

        submission.project
      end

      def selected_opportunity_project(user)
        return @selected_opportunity_project if defined?(@selected_opportunity_project)

        @selected_opportunity_project = selected_budget_project(selected_partner_profile(user), params[:budget_project_id])
      end

      def selected_partner_profile_for(user, raw_id, roles: Decidim::Bih::PartnerMembership::VOLUNTEER_ROLES)
        return if raw_id.blank?

        partner_profiles_for(user, roles:)
          .find { |profile| profile.id.to_s == raw_id.to_s }
      end

      def partner_profiles_for(user, roles:)
        accepted_partner_profiles_for(user, roles:)
          .select(&:volunteer_opportunity_eligible?)
      end

      def accepted_partner_profiles_for(user, roles:)
        return [] unless user

        Decidim::Bih::PartnerMembership
          .for_user(user, organization: current_organization)
          .where(role: roles)
          .includes(:partner_profile)
          .filter_map(&:partner_profile)
          .uniq
      end

      def translated_project_title(project)
        values = project.title
        return values unless values.respond_to?(:values)

        values[I18n.locale.to_s].presence || values[I18n.default_locale.to_s].presence || values.values.compact_blank.first
      end
    end
  end
end
