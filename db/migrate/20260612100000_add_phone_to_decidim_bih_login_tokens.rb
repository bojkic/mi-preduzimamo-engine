# frozen_string_literal: true

# Adds a nullable +phone+ column to decidim_bih_login_tokens so that a
# "verify" token knows the phone it was issued for.
#
# This allows ViberVerifyFlow to recover the verified phone when it consumes
# a token via the inbound Viber channel — without relying on sms authorization
# resolution round-trips that may fail due to phone-format ambiguity.
#
# The column is NULLABLE because:
#   * "login" tokens (passwordless sign-in) are not phone-bound.
#   * A token issued before this migration existed has no phone.
# Only "verify" tokens minted via InfobipGateway carry a real phone value.
class AddPhoneToDecidimBihLoginTokens < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_login_tokens, :phone, :string
  end
end
