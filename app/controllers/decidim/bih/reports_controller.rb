# frozen_string_literal: true

module Decidim
  module Bih
    # Public, ANONYMOUS intake surface for the "Bice riseno" civic
    # problem-reporting feature. Inheriting from Decidim::ApplicationController
    # gives us current_organization (derived from the request host) and the
    # Decidim layout without requiring an authenticated user — citizens can
    # report and check status without an account.
    class ReportsController < Decidim::ApplicationController
      include Decidim::Bih::CurrentOrganizationUser

      # Public, PII-safe issue-tracker index of citizen reports. Tenant-scoped
      # to current_organization, newest-first, filterable by status, category
      # and a reference text search. Like the map, it never exposes reporter
      # contact details or the free-text description.
      REPORTS_PER_PAGE = 12

      before_action :set_map_defaults, only: [:new, :create]
      before_action :set_report_summary, only: [:index, :new, :create, :show, :show_with_token]
      before_action :protect_status_token_response, only: [:show_with_token, :case_reply]

      def index
        @mine = params[:view] == "mine"
        if @mine && current_organization_user.blank?
          flash[:alert] = t(".login_required")
          destination = decidim_bih.reports_path(view: "mine")
          CitizenReturnPath.store(session, organization: current_organization, path: destination)
          return redirect_to(decidim.new_user_session_path(redirect_url: destination))
        end
        protect_private_report_index if @mine

        @statuses = Decidim::Bih::ReportStatusPresenter.filter_statuses
        @categories = Decidim::Bih::ReportTaxonomy::CATEGORIES.map(&:to_s)
        @status = params[:status].presence_in(@statuses)
        @category = params[:category].presence_in(@categories)
        @query = params[:q].to_s.strip

        # Typing a full report number into the list search opens that report
        # directly; this replaced the separate "Provjera statusa" box.
        if @query.present? && !@mine
          exact = Decidim::Bih::Report.publicly_visible.find_by(organization: current_organization, reference: @query.upcase)
          return redirect_to(report_path(reference: exact.reference)) if exact
        end

        @reports = filtered_reports
                   .order(created_at: :desc, id: :desc)
                   .page(params[:page])
                   .per(REPORTS_PER_PAGE)
      end

      def new
        @form = ReportForm.new(report_prefill_params)
      end

      def create
        response.cache_control.replace(no_store: true, private: true)
        @form = ReportForm.new(form_params)

        return head :ok if @form.honeypot_filled?

        unless @form.valid?
          flash.now[:alert] = t(".error")
          return render :new, status: :unprocessable_entity
        end

        restore_photo_draft!

        # Duplicate detection runs on the WEB path only (NOT inside ReportIntake,
        # so the Viber/bot intake is untouched). Skipped once the citizen has
        # confirmed their report is genuinely new via the interstitial.
        unless @form.confirmed_new
          @duplicate = Decidim::Bih::DuplicateFinder.new.call(
            organization: current_organization,
            latitude: @form.latitude,
            longitude: @form.longitude,
            category: nil # web intake has no category; AI assigns it later
          )
          if @duplicate
            preserve_photo_draft! if @form.photo.present? && @photo_draft.nil?
            return render :duplicate, status: :ok
          end
        end

        intake = Decidim::Bih::ReportIntake.new
        report = submit_report(intake)

        flash[:notice] = t(".success", reference: report.reference)
        # Carry the awarded amount through the redirect so the tracker show page
        # can surface the "+N bodova zajedništva" recognition banner WITH a link
        # to the community hub (a flash callout can't hold a link). When the
        # award is nil/zero (signed-out report, daily cap reached) the banner is
        # simply not shown. A flash int survives exactly one redirect, so the
        # banner appears right after submission and never on a later status revisit.
        awarded = intake.awarded_points.to_i
        if awarded.positive?
          flash[:bih_points_awarded] = awarded
        else
          outcome_notice = t("decidim.bih.goodwill.report_outcomes.#{intake.award_outcome}", points: 0,
                                                                                             default: "The report is saved; point eligibility is available in your wallet.")
          flash[:notice] = "#{flash[:notice]} #{outcome_notice}"
        end
        redirect_to report_status_path(reference: report.reference, status_token: report.status_token)
      rescue ReportPhotoDraft::Invalid
        @form.photo_draft_token = nil
        @form.errors.add(:photo, t("decidim.bih.photo_draft.unavailable"))
        flash.now[:alert] = t("decidim.bih.photo_draft.unavailable")
        render :new, status: :unprocessable_entity
      rescue ActiveRecord::RecordInvalid
        # Backstop: a model validation the form did not catch (e.g. a photo whose
        # ActiveStorage-derived type differs from the declared one) must not 500.
        flash.now[:alert] = t(".error")
        render :new, status: :unprocessable_entity
      end

      def show
        @report = Decidim::Bih::Report.publicly_visible.find_by!(
          organization: current_organization,
          reference: params[:reference]
        )
      rescue ActiveRecord::RecordNotFound
        flash[:alert] = t(".not_found")
        redirect_to new_report_path
      end

      def show_with_token
        @report = Decidim::Bih::Report.find_by!(
          organization: current_organization,
          reference: params[:reference],
          status_token: params[:status_token]
        )
        if params[:photo_message_id].present?
          photo = @report.case_messages.find(params[:photo_message_id]).photo
          raise ActiveRecord::RecordNotFound unless photo.attached?

          return send_data ReportPrivateStorage.download!(photo.blob), type: photo.content_type, disposition: "attachment",
                                                                       filename: "#{@report.reference}-photo#{File.extname(photo.filename.to_s)}"
        end
        @private_report = true
        @report.case_messages.where(actor_role: "staff", read_at: nil).update_all(read_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        protect_status_token_from_rendered_metadata
        render :show
      rescue ActiveRecord::RecordNotFound
        flash[:alert] = t("decidim.bih.reports.show.not_found")
        redirect_to new_report_path
      end

      def case_reply
        report = Report.find_by!(organization: current_organization, reference: params[:reference], status_token: params[:status_token])
        details = params.require(:case_message).permit(:body, :feedback, :photo, :answers_message_id)
        actor = current_organization_user if current_organization_user == report.author
        ReportCaseWorkflow.new(report, actor).reply(body: details[:body], feedback: details[:feedback].presence, photo: details[:photo],
                                                    answers_message_id: details[:answers_message_id].presence)
        redirect_to report_status_path(reference: report.reference, status_token: report.status_token), notice: t("decidim.bih.report_case.message_saved")
      rescue ReportCaseWorkflow::Invalid, ActiveRecord::RecordInvalid => e
        redirect_to report_status_path(reference: report.reference, status_token: report.status_token), alert: e.message
      end

      # "Same problem / corroborate" from the duplicate interstitial. Atomically bumps
      # the existing report's PUBLIC corroboration counter (never the binding
      # vote) and sends the citizen to its tracker — no new report is created.
      # Org-scoped: a reference that does not belong to this organization is
      # treated as not found, so corroboration can never cross tenants.
      def corroborate
        report = Decidim::Bih::Report.publicly_visible.find_by!(
          organization: current_organization,
          reference: params[:reference]
        )
        discard_photo_draft
        result = Goodwill::CorroborateReport.call(report:, user: current_organization_user)
        flash[:notice] = t("decidim.bih.goodwill.report_outcomes.#{result.outcome}", points: result.transaction&.credited_amount.to_i,
                                                                                     default: t(".thanks"))
        flash[:bih_points_awarded] = result.transaction.credited_amount if result.transaction
        redirect_to report_path(reference: result.report.reference)
      rescue ActiveRecord::RecordNotFound
        flash[:alert] = t("decidim.bih.reports.show.not_found")
        redirect_to new_report_path
      end

      # Direct recovery task for a returning citizen who kept the report
      # reference. This deliberately redirects to the public tracker; a private
      # token is never accepted, logged or reflected by this endpoint.
      def recover
        reference = params[:reference].to_s.strip.upcase
        report = Decidim::Bih::Report.publicly_visible.find_by(organization: current_organization, reference:)
        if report
          redirect_to report_path(reference: report.reference)
        else
          flash[:alert] = t("decidim.bih.reports.show.not_found")
          redirect_to reports_path(q: reference.presence)
        end
      end

      private

      def set_map_defaults
        if (coordinates = report_prefill_params).present?
          @map_center = [coordinates[:latitude].to_f, coordinates[:longitude].to_f]
          @map_zoom = [Decidim::Bih.map_default_zoom.to_i, 15].max
        else
          @map_center = Decidim::Bih.map_default_center
          @map_zoom = Decidim::Bih.map_default_zoom
        end
      end

      def set_report_summary
        @report_summary = Decidim::Bih::PublicReportSummary.new(current_organization).call
      end

      def filtered_reports
        scope = Decidim::Bih::Report.where(organization: current_organization)
        scope = scope.where(author: current_organization_user) if @mine
        scope = scope.publicly_visible unless @mine
        scope = Decidim::Bih::ReportStatusPresenter.filter(scope, @status)
        scope = scope.where(category: @category) if @category
        scope = scope.where("reference ILIKE ?", "%#{sanitize_sql_like(@query)}%") if @query.present?
        scope
      end

      # Through the cache_control API, not a raw header: Decidim's
      # HttpCachingDisabler already populated that API and ActionDispatch
      # merges it over the raw header at commit, dropping `private` on a
      # signed-in response (see PhoneVerificationActions#protect_response) —
      # and "my reports" is only ever rendered for a signed-in citizen.
      def protect_private_report_index
        response.cache_control.replace(no_store: true, private: true)
        response.set_header("Pragma", "no-cache")
        response.set_header("X-Robots-Tag", "noindex, nofollow")
        response.set_header("Referrer-Policy", Decidim::Bih::PRIVATE_PAGE_REFERRER_POLICY)
      end

      def sanitize_sql_like(value)
        ActiveRecord::Base.sanitize_sql_like(value)
      end

      def protect_status_token_from_rendered_metadata
        public_status_path_parameters = request.path_parameters.except(:status_token, "status_token").merge(action: "show")
        public_status_parameters = request.parameters.except(:status_token, "status_token").merge(action: "show")

        request.env["action_dispatch.request.path_parameters"] = public_status_path_parameters
        request.env["action_dispatch.request.parameters"] = public_status_parameters
        @decidim_meta_url = "#{request.base_url}#{report_path(reference: @report.reference)}"
      end

      # Same reason as #protect_private_report_index: the cache_control API is
      # what survives ActionDispatch's commit-time merge.
      def protect_status_token_response
        response.cache_control.replace(no_store: true, private: true)
        response.set_header("Pragma", "no-cache")
        response.set_header("X-Robots-Tag", "noindex, nofollow")
        response.set_header("Referrer-Policy", Decidim::Bih::PRIVATE_PAGE_REFERRER_POLICY)
      end

      # A signed-in citizen sees no contact fields: the verified account phone
      # is forwarded to the city service unless they ticked "anonymous". Typed
      # contact (e.g. a re-submitted duplicate form) still wins when present.
      def signed_in_contact_attributes
        user = current_organization_user
        return {} if user.blank? || @form.anonymous || @form.reporter_phone.present?

        phone = Decidim::Bih::CitizenPhone.for(user).presence
        phone ? { reporter_phone: phone } : {}
      end

      def submit_report(intake)
        intake_attributes = {
          organization: current_organization,
          locale: I18n.locale.to_s,
          author: current_organization_user, # nil when not logged in or cross-org => no goodwill award
          **@form.to_intake_attributes.merge(signed_in_contact_attributes)
        }
        if @photo_draft
          @photo_draft.consume! { |photo| intake.call(**intake_attributes, photo:) }
        else
          intake.call(**intake_attributes)
        end
      end

      def restore_photo_draft!
        return if @form.photo_draft_token.blank?

        @photo_draft = ReportPhotoDraft.for_owner!(token: @form.photo_draft_token, organization: current_organization, owner: session[:report_photo_owner])
        @photo_draft.with_lock do
          # A repeated confirmation still returns its existing report, even if
          # the browser resubmits different photo controls.
          next if @photo_draft.consumed_report_id.present?

          if @form.remove_saved_photo
            @photo_draft.destroy!
            @photo_draft = nil
            @form.photo_draft_token = nil
          elsif @form.photo.present?
            preserve_photo_draft!
          end
        end
      end

      def discard_photo_draft
        return if params[:photo_draft_token].blank?

        draft = ReportPhotoDraft.for_owner!(token: params[:photo_draft_token], organization: current_organization, owner: session[:report_photo_owner])
        draft.with_lock { draft.destroy! if draft.consumed_report_id.blank? }
      rescue ReportPhotoDraft::Invalid, ActiveRecord::RecordNotFound
        # Expired or foreign uploads never prevent corroborating a public report.
        nil
      end

      def preserve_photo_draft!
        session[:report_photo_owner] ||= SecureRandom.hex(32)
        @photo_draft = ReportPhotoDraft.store!(organization: current_organization, owner: session[:report_photo_owner], upload: @form.photo)
        @form.photo_draft_token = @photo_draft.token
      end

      def form_params
        params.fetch(:report, {}).permit(
          :description,
          :address,
          :latitude,
          :longitude,
          :reporter_email,
          :reporter_phone,
          :anonymous,
          :public_location_exact,
          :website,
          :photo,
          :confirmed_new,
          :photo_draft_token,
          :remove_saved_photo
        )
      end

      def report_prefill_params
        latitude = bounded_coordinate(params[:latitude] || params[:lat], -90, 90)
        longitude = bounded_coordinate(params[:longitude] || params[:lon] || params[:lng], -180, 180)
        return {} if latitude.nil? || longitude.nil?

        { latitude:, longitude: }
      end

      def bounded_coordinate(value, min, max)
        return nil if value.to_s.strip.blank?

        numeric = Float(value)
        numeric.between?(min, max) ? numeric : nil
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
