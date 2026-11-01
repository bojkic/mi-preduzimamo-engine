# frozen_string_literal: true

require "json"
require "active_support/key_generator"
require "active_support/message_encryptor"

module Decidim
  module Bih
    module Infobip
      # Small purpose-isolated wrapper used by outbound messaging jobs whose
      # recipient/content must never be serialized into ActiveJob/Sidekiq args.
      module EncryptedJobEnvelope
        module_function

        def seal(attributes, purpose:, salt:)
          encryptor(salt).encrypt_and_sign(JSON.generate(attributes), purpose:)
        end

        def open(ciphertext, purpose:, salt:)
          JSON.parse(encryptor(salt).decrypt_and_verify(ciphertext, purpose:))
        end

        def encryptor(salt)
          generator = ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base)
          key = generator.generate_key(salt, 32)
          ActiveSupport::MessageEncryptor.new(key)
        end
        private_class_method :encryptor
      end
    end
  end
end
