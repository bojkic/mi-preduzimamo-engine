# frozen_string_literal: true

require "faraday"

module Decidim
  module Bih
    module Odoo
      # Thin JSON-RPC client for an Odoo instance (https://www.odoo.com), the
      # reusable machinery behind donation/accounting integrations (e.g. mirroring
      # the foundation's donation totals into a Decidim Accountability dashboard).
      #
      # Odoo authenticates with (database, login, api_key) — the API key replaces
      # the password but the DB name and a user login are still required. Reads
      # all four from the environment so the code is testable without them; when
      # unconfigured, callers fall back rather than erroring.
      #
      #   ODOO_URL      e.g. "https://fondacijabijeljina.com"
      #   ODOO_DB       the Odoo database name
      #   ODOO_LOGIN    a user login (email/username) the api key belongs to
      #   ODOO_API_KEY  the user's API key (Settings → Account Security → API Keys)
      #
      # Usage once ODOO_DB + ODOO_LOGIN are known:
      #   client = Decidim::Bih::Odoo::Client.new
      #   client.read("account.move", [["move_type", "=", "entry"]], %w[name amount_total])
      class Client
        DEFAULT_TIMEOUT = 15

        attr_reader :base_url, :db, :login, :api_key

        def initialize(base_url: ENV.fetch("ODOO_URL", nil),
                       db: ENV.fetch("ODOO_DB", nil),
                       login: ENV.fetch("ODOO_LOGIN", nil),
                       api_key: ENV.fetch("ODOO_API_KEY", nil),
                       timeout: DEFAULT_TIMEOUT)
          @base_url = base_url
          @db = db
          @login = login
          @api_key = api_key
          @timeout = timeout
        end

        # True only when every credential needed to authenticate is present.
        def configured?
          [base_url, db, login, api_key].all?(&:present?)
        end

        # The authenticated user id (memoized). Raises Error when unconfigured or
        # when Odoo rejects the credentials.
        def uid
          @uid ||= begin
            result = call("common", "authenticate", [db, login, api_key, {}])
            raise Error, "Odoo authentication failed (check ODOO_DB/ODOO_LOGIN/ODOO_API_KEY)" unless result.is_a?(Integer)

            result
          end
        end

        # Calls a model method, e.g. execute_kw("res.partner", "search_read",
        # [[["is_company", "=", true]]], { fields: ["name"], limit: 10 }).
        def execute_kw(model, method, args, kwargs = {})
          call("object", "execute_kw", [db, uid, api_key, model, method, args, kwargs])
        end

        # Convenience: search_read records matching +domain+ for +fields+.
        def read(model, domain = [], fields = [], limit: 100)
          execute_kw(model, "search_read", [domain], { fields: fields, limit: limit })
        end

        private

        # Issues an Odoo JSON-RPC call and returns the `result`, raising Error on a
        # JSON-RPC fault or transport failure.
        def call(service, method, args)
          Decidim::Bih::Instrumentation.instrument(
            "odoo.rpc",
            provider: "odoo",
            service: service,
            method: method,
            model: method == "execute_kw" ? args[3] : nil,
            configured: configured?
          ) do |event|
            raise Error, "Odoo client is not configured (set ODOO_URL/ODOO_DB/ODOO_LOGIN/ODOO_API_KEY)" unless configured?

            response = connection.post("/jsonrpc") do |req|
              req.headers["Content-Type"] = "application/json"
              req.body = { jsonrpc: "2.0", method: "call",
                           params: { service: service, method: method, args: args } }.to_json
            end
            event[:http_status] = response.status
            handle(response)
          end
        rescue Faraday::Error => e
          raise Error, "Odoo transport error: #{Decidim::Bih::LogRedactor.error_message(e)}"
        end

        def handle(response)
          raise Error, "Odoo HTTP #{response.status}" unless response.success?

          body = response.body.is_a?(Hash) ? response.body : JSON.parse(response.body.to_s)
          if body["error"]
            # Provider fault text may echo donor names or arbitrary payloads;
            # keep it out of exceptions, notification subscribers and job logs.
            raise Error, "Odoo fault", cause: nil
          end

          body["result"]
        rescue JSON::ParserError
          raise Error, "Odoo returned non-JSON", cause: nil
        end

        def connection
          @connection ||= Faraday.new(url: base_url) do |f|
            f.options.timeout = @timeout
            f.options.open_timeout = @timeout
            f.adapter Faraday.default_adapter
          end
        end
      end
    end
  end
end
