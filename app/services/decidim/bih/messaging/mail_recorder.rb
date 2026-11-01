# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # Correlates ONE outbound mail to its intent, and records what SMTP
      # actually proved.
      #
      # ActionMailer gives two hooks, and the difference between them is the
      # whole point of this class. `delivering_email` runs BEFORE the SMTP
      # conversation — that is where the leg is claimed, so a crash mid-send
      # leaves a claimed row rather than nothing. `delivered_email` runs AFTER
      # the delivery method returned without raising, and that is evidence of
      # **SMTP ACCEPTANCE** — the next hop took the message. It is not inbox
      # placement, it is not a bounce that has not arrived yet, and it is
      # certainly not reading. Those are separate observations with separate
      # sources, and {Attempt#observe!} is where they merge.
      #
      # The header is an internal reference and it is REMOVED before the message
      # leaves the building. A correlation id in a header that reaches the
      # recipient's mail server is an identifier we exported for no reason.
      #
      # Only enrolled mailers stamp themselves. A mailer that does not is not
      # broken and is not silently half-covered: it keeps its own evidence until
      # its own task adapts it, and {Reconciliation} lists its class as having
      # no attempts rather than pretending it delivered.
      module MailRecorder
        HEADER = "X-MI-Intent"
        VERSION = "v1"
        SEPARATOR = "|"
        ATTEMPT_IVAR = :@decidim_bih_messaging_attempt_id
        GROUP = "email"
        CHANNEL = "email"
        ACCEPTED_REASON = "smtp_accepted"

        module_function

        # Built by the mailer, read by the interceptor. Deliberately carries no
        # address and no token: an organization id, a registry key, a recipient
        # KIND, an optional account id and a correlation key the producer
        # already uses for its own deduplication.
        def reference(message_class:, organization_id:, correlation_key:, recipient_kind: "account", account_id: nil)
          raise ArgumentError, "unknown message class #{message_class.inspect}" unless MessageClass.known?(message_class.to_s)
          raise ArgumentError, "correlation key must not contain #{SEPARATOR}" if correlation_key.to_s.include?(SEPARATOR)

          [VERSION, organization_id, message_class, recipient_kind, account_id, correlation_key].join(SEPARATOR)
        end

        def parse(value)
          version, organization_id, message_class, recipient_kind, account_id, correlation_key =
            value.to_s.split(SEPARATOR, 6)
          return nil unless version == VERSION && correlation_key.to_s.present?
          return nil unless MessageClass.known?(message_class.to_s)

          { organization_id: organization_id.to_i, message_class:, recipient_kind:,
            account_id: account_id.to_s.empty? ? nil : account_id.to_i, correlation_key: }
        end

        # ---- ActionMailer hooks ---------------------------------------------

        def delivering_email(message)
          reference = message[HEADER]&.to_s
          # Removed whatever happens next: an unparseable reference is still an
          # internal identifier and still must not be transmitted.
          message[HEADER] = nil
          return if reference.blank?

          attempt = claim(reference, message)
          message.instance_variable_set(ATTEMPT_IVAR, attempt.id) if attempt
        rescue StandardError => e
          # A hook that raises breaks the mail it is riding on.
          log("delivering", e)
        end

        def delivered_email(message)
          attempt_id = message.instance_variable_get(ATTEMPT_IVAR)
          return if attempt_id.nil?

          attempt = Attempt.find_by(id: attempt_id)
          attempt&.observe!(outcome: Outcome::ACCEPTED, reason: ACCEPTED_REASON)
        rescue StandardError => e
          log("delivered", e)
        end

        # ---- internals -------------------------------------------------------

        def claim(reference, message)
          parsed = parse(reference)
          return nil if parsed.nil?

          organization = Decidim::Organization.find_by(id: parsed.fetch(:organization_id))
          return nil if organization.nil?

          address = Array(message.to).first
          recipient = recipient_for(parsed, organization, address)
          return nil if recipient.nil?

          Correlation.observe!(
            organization:, message_class: parsed.fetch(:message_class),
            recipient:, correlation_key: parsed.fetch(:correlation_key),
            group: GROUP, channel: CHANNEL, outcome: Outcome::CLAIMED,
            destination: { kind: :email, value: address }
          )
        end

        # A recipient without an account gets a scoped safe reference built from
        # its OWN destination — never an account matched by e-mail address. That
        # is the whole reason the reference carries a kind: a report's contact
        # address and a citizen's account address can be the same string and are
        # still not the same recipient.
        def recipient_for(parsed, organization, address)
          kind = parsed[:recipient_kind].to_s
          return nil unless RecipientContext::KINDS.include?(kind)

          account_id = parsed[:account_id]
          if RecipientContext::ACCOUNT_BACKED_KINDS.include?(kind)
            return nil if account_id.nil?

            return RecipientContext.staff(organization_id: organization.id, account_id:, audience_role: "staff") if kind == "staff"

            return RecipientContext.account(organization_id: organization.id, account_id:)
          end

          RecipientContext.new(kind:, organization_id: organization.id,
                               destination: address, destination_channel: "email")
        end

        def log(phase, error)
          Rails.logger.warn("[messaging] mail recorder #{phase}: #{error.class}")
        end
      end
    end
  end
end
