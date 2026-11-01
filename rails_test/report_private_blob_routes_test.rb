# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class ReportPrivateBlobRoutesTest < ActionDispatch::IntegrationTest
        setup { host! create_organization.host }

        test "generic redirect proxy and representation routes cannot expose private ciphertext or decrypted bytes" do
          blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("private fixture"), filename: "fixture.txt",
                                                        content_type: "text/plain", service_name: ReportPrivateStorage.service_name)
          routes = Rails.application.routes.url_helpers
          get routes.rails_service_blob_proxy_path(blob.signed_id, blob.filename)
          assert_response :not_found
          get routes.rails_service_blob_path(blob.signed_id, blob.filename)
          assert_response :not_found
          # An arbitrary representation key must still fail at private-blob authorization first.
          get "/rails/active_storage/representations/proxy/#{blob.signed_id}/invalid/fixture.txt"
          assert_response :not_found
        ensure
          blob&.purge
        end

        test "ordinary public blob routes retain their existing storage behavior" do
          blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("public fixture"), filename: "fixture.txt", content_type: "text/plain")
          get Rails.application.routes.url_helpers.rails_service_blob_proxy_path(blob.signed_id, blob.filename)
          assert_response :success
          assert_equal "public fixture", response.body
        ensure
          blob&.purge
        end
      end
    end
  end
end
