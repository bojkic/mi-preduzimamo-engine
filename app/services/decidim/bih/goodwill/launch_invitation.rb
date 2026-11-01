# frozen_string_literal: true

require "rqrcode"

module Decidim
  module Bih
    module Goodwill
      # "Pozivnica za lansiranje 17.9." — nagrada koja je PRAG, ne kupovina.
      #
      # Razlike u odnosu na svaku postojeću nagradu:
      #   * bodovi se NE oduzimaju (reward.deducts_points? == false);
      #   * izdaje se SAMA na prelasku praga, bez klika građanina i bez
      #     ručne potvrde operatora;
      #   * nosi jednokratni ulazni kod koji se poništava na vratima.
      #
      # Idempotentnost NIJE u ovom kodu — garantuje je parcijalni jedinstveni
      # indeks idx_bih_auto_issued_one_per_user_reward. Ovdje samo hvatamo
      # RecordNotUnique i vraćamo postojeći red, pa dvije paralelne dodjele
      # bodova ne mogu izdati dvije pozivnice.
      class LaunchInvitation
        REWARD_KEY = "pozivnica_lansiranje"
        CONFIRMATION_WINDOW = 72.hours
        # Bez I, L, O, 0, 1 — operater kod čita naglas na vratima.
        CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
        CODE_GROUP_LENGTH = 5
        REMAINING_CACHE_TTL = 60.seconds

        class << self
          # Aktivna nagrada-pozivnica za organizaciju, ili nil.
          def reward_for(organization)
            return nil if organization.blank?

            reward = RewardsCatalog.find(REWARD_KEY, organization)
            return nil if reward.blank?
            return nil unless reward.respond_to?(:auto_issue_at_threshold?)
            return nil unless reward.auto_issue_at_threshold?

            reward
          end

          # Jeftina provjera koju zove Ledger na svakoj dodjeli bodova. Mora
          # takođe provjeriti rok — bez ovoga bi okidač poslije 16.9. i dalje
          # zakazivao job na SVAKOM lajku/glasu/komentaru platforme, zauvijek,
          # dok neko ručno ne deaktivira red nagrade.
          def enabled?(organization)
            return false if organization.blank?

            Rails.cache.fetch("goodwill:launch-invitation:enabled:#{organization.id}",
                              expires_in: REMAINING_CACHE_TTL) do
              reward = reward_for(organization)
              reward.present? && !reward.expired?
            end
          rescue StandardError
            false
          end

          # Preostale pozivnice u tekućem talasu. nil kad zaliha nije ograničena.
          def remaining(organization)
            reward = reward_for(organization)
            return nil if reward.blank? || reward.expired?

            reward.remaining_stock(organization)
          end

          # Izdaje pozivnicu ako je građanin prešao prag. Vraća RewardFulfillment
          # (novi ILI već postojeći) ili nil kada se ne izdaje.
          def issue_for(user)
            organization = user&.organization
            return nil if organization.blank?
            return nil unless eligible_citizen?(user)

            reward = reward_for(organization)
            return nil if reward.blank?

            # Postojeća pozivnica VAŽI bez obzira na rok — rok upravlja samo
            # izdavanjem NOVE pozivnice, nikad povratom već izdate. Zato ova
            # provjera mora doći PRIJE reward.expired?, inače građanin koji se
            # vrati poslije 16.9. dobije nil umjesto svoje važeće pozivnice.
            existing = find_existing(organization, user)
            return existing if existing

            return nil if reward.expired?
            return nil unless threshold_reached?(user, reward)

            create_invitation!(organization, user, reward)
          rescue ActiveRecord::RecordNotUnique
            # Izgubili smo trku sa paralelnim job-om; njegova pozivnica važi.
            find_existing(organization, user)
          rescue StockExhaustedError
            nil
          end

          # Inline SVG QR sa ulaznim kodom. Nikad ne diže izuzetak — pozivnica
          # se mora prikazati i kad renderovanje QR-a padne.
          def qr_svg(entry_code)
            return nil if entry_code.blank?

            RQRCode::QRCode.new(entry_code.to_s, level: :m)
                           .as_svg(module_size: 4, standalone: false, use_path: true)
          rescue StandardError => e
            Rails.logger.error("[launch_invitation] QR nije renderovan: #{e.class}")
            nil
          end

          # Kriptografski slučajan, čitljiv kod. 31^10 ~ 8.2e14 kombinacija.
          def generate_entry_code
            raw = Array.new(CODE_GROUP_LENGTH * 2) do
              CODE_ALPHABET[SecureRandom.random_number(CODE_ALPHABET.length)]
            end.join
            "MI-#{raw[0, CODE_GROUP_LENGTH]}-#{raw[CODE_GROUP_LENGTH, CODE_GROUP_LENGTH]}"
          end

          # Potvrda dolaska — jedna logika za dugme u habu (prijavljen građanin)
          # i za link iz poruke (token, bez prijave). Idempotentno: ponovljena
          # potvrda vraća :already_confirmed i ništa ne mijenja.
          #
          #   :confirmed          — upravo potvrđeno
          #   :already_confirmed  — već je bilo potvrđeno
          #   :deadline_passed    — rok od 72h je prošao (provjera PRIJE statusa,
          #                         da objasni ZAŠTO i kad je sweep već otkazao)
          #   :no_longer_valid    — otkazana / iskorištena / istekla
          def confirm_attendance!(invitation, actor:, via:)
            return :already_confirmed if invitation.attendance_confirmed_at.present?
            return :deadline_passed if invitation.confirmation_deadline_at&.past?
            return :no_longer_valid unless invitation.status == "reserved"

            invitation.update!(attendance_confirmed_at: Time.current)
            invitation.record_event!(
              "reserved",
              actor:,
              source: "public",
              actor_role: "citizen",
              metadata: {
                from_status: "reserved", to_status: "reserved",
                reward_key: invitation.reward_key, action: "attendance_confirmed", via:
              }
            )
            :confirmed
          end

          # Link „potvrdi dolazak jednim dodirom“ za SMS/Viber/e-mail: jednokratno
          # izdan LoginToken svrhe "invitation" (72h, vidi LoginToken), isporučen
          # kroz ISTU /v/:token rutu kao ostali linkovi — pa ga pokrivaju isti
          # throttle, isti nginx log-filter i ista no-store zaglavlja. Nikad ne
          # prijavljuje građanina; samo potvrđuje dolazak.
          def confirm_link_url(fulfillment)
            raw = Decidim::Bih::LoginToken.issue!(user: fulfillment.user, purpose: "invitation")
            Decidim::Bih.magic_link_url(raw, host: fulfillment.organization.host)
          end

          # Pozivnica na koju link/dugme cilja: automatski izdana, jedna po građaninu.
          def for_user(organization, user)
            find_existing(organization, user)
          end

          private

          def find_existing(organization, user)
            RewardFulfillment.find_by(
              organization:, user:, reward_key: REWARD_KEY, auto_issued: true
            )
          end

          # Samo stvarni, samostalno registrovani građani — nikad admini,
          # sistemski (managed) nalozi, staff role ni grupe.
          def eligible_citizen?(user)
            return false unless user.is_a?(Decidim::User)
            return false if user.blocked? || user.deleted?

            Account.invitation_eligible_accounts
                   .exists?(organization: user.organization, owner_id: user.id)
          end

          def threshold_reached?(user, reward)
            account = Ledger.new.account_for(user)
            account.contribution_score >= reward.cost.to_i
          end

          def create_invitation!(organization, user, reward)
            fulfillment = nil

            ActiveRecord::Base.transaction do
              AdvisoryLock.acquire!("goodwill-reward-stock:#{organization.id}:#{REWARD_KEY}")
              reward.lock! if reward.respond_to?(:lock!) && reward.persisted?

              remaining_now = reward.remaining_stock(organization)
              # NIKAD `return` iz transakcijskog bloka — u Rails 7 to COMMITUJE
              # transakciju. Izuzetak je jedini ispravan izlaz odavde.
              raise StockExhaustedError if remaining_now.present? && remaining_now <= 0

              issued_at = Time.current
              fulfillment = RewardFulfillment.create!(
                organization:,
                user:,
                ledger_transaction: nil,
                reward_key: REWARD_KEY,
                request_key: nil,
                cost: reward.cost,
                status: "reserved",
                auto_issued: true,
                entry_code: unique_entry_code(organization),
                issued_at:,
                confirmation_deadline_at: issued_at + CONFIRMATION_WINDOW,
                reward_expires_at: reward.expires_at
              )

              # Trag NE SMIJE sadržati kod — događaji se izvoze i pregledaju.
              fulfillment.record_event!(
                "reserved",
                actor: user,
                source: "system",
                actor_role: "system",
                metadata: {
                  from_status: nil,
                  to_status: "reserved",
                  reward_key: REWARD_KEY,
                  cost: reward.cost,
                  action: "auto_issue_at_threshold"
                }
              )
            end

            fulfillment
          end

          # Sudar je astronomski nevjerovatan, ali jedinstveni indeks je
          # autoritet — pokušaj nekoliko puta prije nego što odustaneš.
          def unique_entry_code(organization)
            5.times do
              code = generate_entry_code
              return code unless RewardFulfillment.exists?(organization:, entry_code: code)
            end
            raise "ne mogu generisati jedinstven ulazni kod"
          end
        end
      end
    end
  end
end
