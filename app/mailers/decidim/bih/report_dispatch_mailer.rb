# frozen_string_literal: true

module Decidim
  module Bih
    class ReportDispatchMailer < ActionMailer::Base
      def delivery(dispatch_id)
        dispatch = ReportDispatch.find(dispatch_id)
        snapshot = dispatch.snapshot
        ReportEvidence.attach(self, snapshot.fetch("attachments", []))
        transport = ReportMailbox::Transport.options!
        threading = snapshot.slice("reply_to", "in_reply_to", "references").compact_blank.symbolize_keys
        mail(**transport, **threading, to: snapshot.fetch("to"), from: transport[:from] || snapshot.fetch("from"), subject: snapshot.fetch("subject"),
             body: snapshot.fetch("body"), content_type: "text/plain; charset=UTF-8", message_id: dispatch.message_id)
      end
    end
  end
end
