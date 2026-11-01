# frozen_string_literal: true

module Decidim
  module Bih
    # Process-wide "stop starting new provider calls" flag. The engine installs
    # it on Sidekiq's :quiet event, which fires on TSTP (release drain,
    # mi_restart_services) and at the start of every TERM shutdown. Long jobs
    # check it between provider calls so they leave a resumable lease instead
    # of starting a call Sidekiq's shutdown timeout will cut off.
    #
    # Lives in lib/ and is required by the engine: the initializer registers
    # it before the autoloaders are set up.
    module WorkerShutdown
      @requested = false

      class << self
        def requested? = @requested

        def request! = (@requested = true)

        # Tests only; a quieted Sidekiq process never un-quiets.
        def reset! = (@requested = false)

        # +config+ is the Sidekiq server configuration (anything with #on).
        def install!(config)
          config.on(:quiet) { request! }
        end
      end
    end
  end
end
