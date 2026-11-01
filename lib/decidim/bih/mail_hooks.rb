# frozen_string_literal: true

module Decidim
  module Bih
    # The ONE object ActionMailer knows about.
    #
    # It lives in lib/ rather than app/ for a reason that cost a debugging
    # cycle to find: an engine `initializer` block runs BEFORE the autoloaders
    # are set up, so naming an `app/` constant there raises — and a guarded
    # initializer would then swallow that and register nothing at all, silently.
    # A second reason: `app/` constants are reloadable, so in development each
    # reload produces a NEW module object, and Mail's registries de-duplicate by
    # identity — the same hook would be registered again on every reload.
    #
    # So registration takes this stable object, and the constants it delegates
    # to are resolved at DELIVERY time, when autoloading is long since ready.
    #
    # Order inside {delivering_email} is deliberate: the reply mailbox is set
    # first, so a correlation failure can never cost a citizen the address they
    # would reply to.
    module MailHooks
      module_function

      def delivering_email(message)
        MailReplyTo.delivering_email(message)
        Messaging::MailRecorder.delivering_email(message)
      end

      def delivered_email(message)
        Messaging::MailRecorder.delivered_email(message)
      end

      def install!
        ActionMailer::Base.register_interceptor(self)
        ActionMailer::Base.register_observer(self)
      end
    end
  end
end
