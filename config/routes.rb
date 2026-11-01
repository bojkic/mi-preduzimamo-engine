# frozen_string_literal: true

Decidim::Bih::Engine.routes.draw do
  get "service-evidence/:token", to: "evidence_shares#show", as: :service_evidence_share
  post "platform-receipt", to: "platform_receipts#create", as: :platform_receipt
  get "moj-nalog/kanali", to: "channel_connections#index", as: :channel_connections
  post "moj-nalog/kanali", to: "channel_connections#create"
  post "moj-nalog/kanali/potvrdi", to: "channel_connections#confirm", as: :confirm_channel_connections
  delete "moj-nalog/kanali/:channel", to: "channel_connections#destroy", as: :channel_connection

  post "push-notification-test", to: "web_push_tests#create", as: :web_push_test
  delete "push-subscription", to: "web_push_subscriptions#destroy", as: :web_push_subscription
  get "v/:token", to: "magic_links#show", as: :magic_link
  post "v/:token", to: "magic_links#consume", as: :consume_magic_link
  get "prijava", to: "phone_sessions#new", as: :phone_login
  post "prijava", to: "phone_sessions#create"
  post "prijava/kod", to: "phone_sessions#verify_code", as: :verify_phone_login_code
  get "prijave/:reference/status/:status_token", to: "reports#show_with_token", as: :report_status
  post "prijave/:reference/status/:status_token", to: "reports#case_reply", as: :report_case_reply
  get "prijave-pronadji", to: "reports#recover", as: :recover_report
  resources :reports, only: [:index, :new, :create, :show], param: :reference, path: "prijave" do
    # "Same problem / corroborate" from the duplicate interstitial: a public +1 on the
    # existing report's corroboration counter. No new report is created.
    member do
      post :corroborate, path: "potvrdi"
    end
  end
  get "mapa", to: "reports_map#show", as: :reports_map
  # Public per-MZ problem heatmap (category/severity counts by Mjesna zajednica; no PII).
  get "mapa-problema", to: "report_heatmap#index", as: :report_heatmap
  get "donacije", to: "donations#show", as: :donations
  get "projekti", to: "community_projects#index", as: :community_projects
  get "projekti/novi", to: "community_projects#new", as: :new_community_project
  post "projekti", to: "community_projects#create", as: :community_project_submissions
  get "projekti/prijave/:id/uredi", to: "community_projects#edit", as: :edit_community_project_submission
  patch "projekti/prijave/:id", to: "community_projects#update", as: :community_project_submission
  get "projekti/:id", to: "community_projects#show", as: :community_project
  get "uticaj", to: "impact#index", as: :impact
  # Projector screen for the 17.9. launch: a read-only aggregate page for a
  # hall full of people, no login required.
  get "ekran", to: "screen#show", as: :screen, defaults: { format: :html }
  get "mi-bot", to: "mi_bot#show", as: :mi_bot
  # Guided newcomer onboarding: "Šta mogu ovdje?" (vodic) walks through the four
  # pillars; "Zašto verifikacija?" (verifikacija) explains phone/SMS verification.
  get "vodic", to: "onboarding#guide", as: :onboarding_guide
  get "verifikacija", to: "onboarding#verification", as: :verification_explainer
  # Phone-first verification: "link sent" page, resend, forced SMS, hidden
  # code for feature phones, status polling for the desktop hand-off, and
  # number change. Decidim's own /sms/authorizations/edit redirects here.
  get "verifikacija/telefon", to: "phone_verification#show", as: :phone_verification
  post "verifikacija/telefon/ponovo", to: "phone_verification#resend", as: :resend_phone_verification
  post "verifikacija/telefon/kod", to: "phone_verification#confirm", as: :confirm_phone_verification
  get "verifikacija/telefon/status", to: "phone_verification#status", as: :phone_verification_status, defaults: { format: :json }
  delete "verifikacija/telefon", to: "phone_verification#change", as: :change_phone_verification
  # One-step registration (spec 5.2–5.4): one form opens the account, and the
  # pending page below it proves the phone. A host may also serve all of these
  # at a root path (Decidim::Bih.registration_base_path, e.g. "/registracija")
  # in front of the mount; both resolve to this controller, and every URL the
  # pages render is built from that base so a citizen who arrived at the short
  # path stays there.
  get "registracija", to: "registrations#new", as: :new_phone_registration
  post "registracija", to: "registrations#create", as: :phone_registrations
  get "registracija/potvrda", to: "registrations#pending", as: :pending_phone_registration
  post "registracija/potvrda/ponovo", to: "registrations#resend", as: :resend_phone_registration
  post "registracija/potvrda/kod", to: "registrations#confirm", as: :confirm_phone_registration
  # A POST, never a GET (R-D4): this poll can sign the waiting browser in.
  post "registracija/potvrda/status", to: "registrations#status", as: :phone_registration_status, defaults: { format: :json }
  delete "registracija/potvrda", to: "registrations#change", as: :change_phone_registration
  # The exit for a citizen who mistyped the number and no longer has the
  # browser they registered in: throw the never-verified account away and
  # register again with the same e-mail address.
  post "registracija/potvrda/pocni-ispocetka", to: "registrations#start_over", as: :restart_phone_registration
  # "Dobro došao/la" — the last step of the onboarding chain, shown once after
  # the number is verified and the komšiluk is picked. The GET only renders;
  # the POST ("Krenimo") is the only thing that marks the citizen welcomed.
  get "dobrodosli", to: "welcome#show", as: :welcome
  post "dobrodosli", to: "welcome#start", as: :start_welcome
  # The short invite link (the host may also serve it at a root path such as
  # /p/:code — Decidim::Bih.invite_short_path). Redirect only; the
  # registration form captures the code.
  get "p/:code", to: "invite_links#short", as: :short_invite, constraints: { code: /[\w-]+/ }
  # "Bodovi zajedništva" hub — four deep-linkable tabs
  get "zajednistvo", to: "community_hub#show", as: :community_hub

  # Legacy standalone routes redirect → hub (301) so existing links keep working.
  # The redeem POST stays as a real route (the rewards tab form posts here).
  get "tabla", to: redirect(status: 301) { |_params, req|
    "#{req.script_name.chomp("/")}/zajednistvo?tab=tabla"
  }, as: :leaderboard
  get "kako-funkcionise", to: redirect(status: 301) { |_params, req|
    "#{req.script_name.chomp("/")}/zajednistvo?tab=kako"
  }, as: :how_it_works
  get "nagrade", to: redirect(status: 301) { |_params, req|
    "#{req.script_name.chomp("/")}/zajednistvo?tab=nagrade"
  }, as: :rewards
  # Preserve ?ref= referral code so attribution still works through the redirect.
  get "pozovi", to: redirect(status: 301) { |_params, req|
    ref = req.params[:ref].presence
    base = req.script_name.chomp("/")
    ref ? "#{base}/zajednistvo?tab=pozovi&ref=#{CGI.escape(ref)}" : "#{base}/zajednistvo?tab=pozovi"
  }, as: :invite

  get "nagrade/zahtjevi/:id/zahvalnica", to: "rewards#certificate", as: :reward_certificate
  post "nagrade/zahtjevi/:id/zahvalnica", to: "rewards#download_certificate", as: :download_reward_certificate
  post "nagrade/redeem/:reward_key", to: "rewards#redeem", as: :redeem_reward
  post "nagrade/zahtjevi/:id/otkazi", to: "rewards#cancel", as: :cancel_reward_redemption

  # Potvrda dolaska na pozivnicu za lansiranje (bez koda/tokena u URL-u —
  # građanin se prijavljuje i potvrđuje sa svoje strane).
  post "pozivnica/potvrdi", to: "launch_invitations#confirm", as: :confirm_launch_invitation

  # Komšiluk picker (auth-gated; three methods: map-click, address suggest, dropdowns).
  get "komsiluk", to: "komsiluk#edit", as: :edit_komsiluk
  patch "komsiluk", to: "komsiluk#update", as: :komsiluk
  get "komsiluk/areas", to: "komsiluk#areas", as: :komsiluk_areas, defaults: { format: :json }
  post "komsiluk/suggest", to: "komsiluk#suggest", as: :komsiluk_suggest

  # Private board detail links remain usable across publication revisions.
  get "komsiluk-board/objava/:publication_key", to: "komsiluk_board#publication", as: :komsiluk_publication
  get "komsiluk-board/nacrt/fotografija", to: "komsiluk_board#draft_photo", as: :komsiluk_draft_photo
  resources :komsiluk_board, only: [:index, :create, :show, :edit, :update], path: "komsiluk-board" do
    member do
      patch :zatvori
      post :prijavi
      get :photo
      post :help
      patch :resolve
    end
  end

  # "Potvrdi e-mail" from Moj nalog. The POST asks for the message; the GET is
  # the link inside it and needs a signed-in citizen — the token proves an
  # ADDRESS, never a phone number, and never a session on its own.
  post "potvrdi-email", to: "email_confirmations#create", as: :request_email_confirmation
  get "potvrdi-email/:token", to: "email_confirmations#show", as: :confirm_email

  get "moj-nalog/poruke", to: "account_notification_settings#show", as: :account_notification_settings
  patch "moj-nalog/poruke", to: "account_notification_settings#update"
  post "moj-nalog/poruke/proba", to: "account_notification_settings#test_message", as: :account_test_message

  patch "moj-nalog/privatnost-poruka", to: "account#update_message_privacy", as: :account_message_privacy
  get "moj-nalog", to: "account#show", as: :account_overview
  patch "moj-nalog", to: "account#update"
  put "moj-nalog", to: "account#update"
  patch "moj-nalog/javno-priznanje", to: "account#update_public_recognition", as: :account_public_recognition
  get "moj-doprinos", to: "wallet#show", as: :wallet
  get "podrzi", to: "gifts#index", as: :gifts
  post "podrzi", to: "gifts#create", as: :gift
  get "organizacije", to: "organizations#index", as: :organizations
  get "organizacije/nova", to: "organizations#new", as: :new_organization_profile
  post "organizacije", to: "organizations#create", as: :organization_profiles
  get "organizacije/:id/uredi", to: "organizations#edit", as: :edit_organization_profile
  patch "organizacije/:id", to: "organizations#update", as: :update_organization_profile
  get "organizacija/:id", to: "organizations#show", as: :organization
  post "organizacija/:id/regrant", to: "organizations#regrant", as: :regrant_points
  post "organizacija/:id/potrosnja", to: "organizations#create_spending_request", as: :organization_spending_requests
  post "organizacija/:id/obavjestenja", to: "organizations#create_notice", as: :organization_notices
  post "organizacija/:id/clanovi", to: "organizations#add_member", as: :organization_memberships
  patch "organizacija/:id/clanovi/:membership_id", to: "organizations#update_member", as: :organization_membership
  patch "organizacija/clanstvo/:membership_id/prihvati", to: "organizations#accept_membership", as: :accept_organization_membership
  patch "organizacija/clanstvo/:membership_id/odbij", to: "organizations#decline_membership", as: :decline_organization_membership
  delete "organizacija/clanstvo/:membership_id/napusti", to: "organizations#leave_membership", as: :leave_organization_membership
  get "volontiranje", to: "volunteer#index", as: :volunteer
  post "volontiranje/dostupnost", to: "volunteer#register_availability", as: :volunteer_availability
  post "volontiranje/prilika", to: "volunteer#create_opportunity", as: :volunteer_opportunities
  post "volontiranje/prilika/pregled", to: "volunteer#preview_opportunity", as: :preview_volunteer_opportunity
  post "volontiranje/prilika/uredi-prije-slanja", to: "volunteer#edit_opportunity_preview", as: :edit_volunteer_opportunity_preview
  get "volontiranje/prilika/:id/ispravka", to: "volunteer#edit_opportunity_revision", as: :edit_volunteer_opportunity_revision
  post "volontiranje/prilika/:id/ispravka/pregled", to: "volunteer#preview_opportunity_revision", as: :preview_volunteer_opportunity_revision
  patch "volontiranje/prilika/:id/ispravka", to: "volunteer#resubmit_opportunity_revision", as: :resubmit_volunteer_opportunity_revision
  post "volontiranje/sati", to: "volunteer#log_hours", as: :volunteer_log_hours
  post "volontiranje/potrebe", to: "volunteer#create_contribution_need", as: :contribution_needs
  post "volontiranje/potrebe/:id/otkazi", to: "volunteer#cancel_contribution_need", as: :cancel_contribution_need
  post "volontiranje/potrebe/:need_id/ponude", to: "volunteer#create_contribution_offer", as: :contribution_need_offers
  post "volontiranje/ponude/:id/prihvati", to: "volunteer#accept_contribution_offer", as: :accept_contribution_offer
  post "volontiranje/ponude/:id/odbij", to: "volunteer#reject_contribution_offer", as: :reject_contribution_offer
  post "volontiranje/ponude/:id/isporuceno", to: "volunteer#deliver_contribution_offer", as: :deliver_contribution_offer
  post "volontiranje/ponude/:id/povuci", to: "volunteer#withdraw_contribution_offer", as: :withdraw_contribution_offer
  post "volontiranje/ponude/:id/potvrdi", to: "volunteer#confirm_contribution_offer", as: :confirm_contribution_offer
  # Volunteer RSVP / sign-up (register intent against an opportunity; enforces capacity).
  post "volontiranje/prijavi-se/:opportunity_id", to: "volunteer#signup", as: :volunteer_signup
  delete "volontiranje/prijavi-se/:opportunity_id", to: "volunteer#cancel_signup", as: :cancel_volunteer_signup

  # Public Mjesna zajednica / komšiluk directory (read-only: name, predsjednik,
  # telefon, boundary map). Reuses the stored GeoJSON; no auth required.
  get "mjesne-zajednice", to: "mz_directory#index", as: :mz_directory
  get "mjesne-zajednice/:slug", to: "mz_directory#show", as: :mz_area

  # JSON endpoints for the floating web-chat widget (same-origin fetches).
  get "chat/state", to: "concierge/web_chat#state", as: :web_chat_state
  post "chat/feedback", to: "concierge/web_chat#feedback", as: :web_chat_feedback
  post "chat", to: "concierge/web_chat#create", as: :web_chat
  root to: "reports#new"
end
