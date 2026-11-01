# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "base64"
require "open3"
require "active_storage/service/encrypted_private_disk_service"

module Decidim
  module Bih
    module RailsHarness
      class EncryptedPrivateDiskServiceTest < ActiveSupport::TestCase
        setup do
          @root = Dir.mktmpdir("private-storage-")
          @keys = { "v1" => "a" * 32, "v2" => "b" * 32 }
          @service = storage("v1")
          @key = "ab#{"c" * 26}"
          @bytes = "private evidence\x00".b * 5000
          @checksum = OpenSSL::Digest::MD5.base64digest(@bytes)
        end

        teardown { FileUtils.remove_entry(@root) }

        def storage(version)
          ActiveStorage::Service::EncryptedPrivateDiskService.new(root: @root, key_version: version,
                                                                  key_provider: ->(value) { @keys.fetch(value, nil) })
        end

        def upload = @service.upload(@key, StringIO.new(@bytes), checksum: @checksum)

        test "ciphertext retains plaintext download open checksum and chunk semantics" do
          upload
          raw = File.binread(@service.path_for(@key))
          refute_includes raw, "private evidence"
          assert raw.start_with?(ActiveStorage::Service::EncryptedPrivateDiskService::MAGIC)
          assert_equal @bytes, @service.download(@key)
          chunks = []
          @service.download(@key) { |part| chunks << part }
          assert_equal @bytes, chunks.join
          assert_equal @bytes.byteslice(7..23), @service.download_chunk(@key, 7..23)
          @service.open(@key, checksum: @checksum) { |file| assert_equal @bytes, file.read }
          # Named inherited backup ACLs retain read mask; everyone remains excluded.
          assert_equal 0o640, File.stat(@service.path_for(@key)).mode & 0o777
        end

        test "atomic ciphertext writes preserve inherited named backup read ACL without world access" do
          skip "POSIX ACL utilities unavailable" unless File.executable?("/usr/bin/setfacl") && File.executable?("/usr/bin/getfacl")
          uid = Process.uid.to_s
          _output, status = Open3.capture2e("/usr/bin/setfacl", "-m", "d:u:#{uid}:rwx,d:o:---", @root)
          assert status.success?
          upload
          acl, status = Open3.capture2e("/usr/bin/getfacl", "-cn", @service.path_for(@key))
          assert status.success?
          assert_match(/user:#{uid}:rwx.*effective:r--/, acl)
          assert_includes acl, "mask::r--"
          assert_includes acl, "other::---"
        end

        test "tampering and key substitution authenticate before the first plaintext yield" do
          upload
          raw = File.binread(@service.path_for(@key))
          raw.setbyte(raw.bytesize - 1, raw.getbyte(raw.bytesize - 1) ^ 1)
          File.binwrite(@service.path_for(@key), raw)
          yielded = false
          assert_raises(ActiveStorage::IntegrityError) { @service.download(@key) { yielded = true } }
          refute yielded
          upload
          other = "de#{"f" * 26}"
          FileUtils.mkdir_p(File.dirname(@service.path_for(other)))
          FileUtils.cp(@service.path_for(@key), @service.path_for(other))
          assert_raises(ActiveStorage::IntegrityError) { @service.download(other) }
        end

        test "rotation reads explicitly retained versions and rejects unavailable keys" do
          upload
          rotated = storage("v2")
          assert_equal @bytes, rotated.download(@key)
          @keys.delete("v1")
          assert_raises(ActiveStorage::Service::EncryptedPrivateDiskService::Unavailable) { rotated.download(@key) }
        end

        test "bad checksums oversize and interrupted atomic writes preserve the original" do
          upload
          original = File.binread(@service.path_for(@key))
          assert_raises(ActiveStorage::IntegrityError) { @service.upload(@key, StringIO.new("changed"), checksum: @checksum) }
          assert_raises(ActiveStorage::IntegrityError) do
            @service.upload(@key, StringIO.new("x" * (@service.max_bytes + 1)))
          end
          File.stub(:rename, ->(*) { raise IOError, "synthetic write interruption" }) do
            assert_raises(IOError) { @service.upload(@key, StringIO.new("changed")) }
          end
          assert_equal original, File.binread(@service.path_for(@key))
        end

        test "malformed envelopes and inherited plaintext write or bearer URL APIs fail closed" do
          FileUtils.mkdir_p(File.dirname(@service.path_for(@key)))
          ["plaintext", ActiveStorage::Service::EncryptedPrivateDiskService::MAGIC, ""].each do |bad|
            File.binwrite(@service.path_for(@key), bad)
            assert_raises(ActiveStorage::IntegrityError) { @service.download(@key) }
          end
          error = ActiveStorage::Service::EncryptedPrivateDiskService::Unavailable
          assert_raises(error) { @service.url(@key) }
          assert_raises(error) { @service.url_for_direct_upload(@key) }
          assert_raises(error) { @service.headers_for_direct_upload(@key) }
          assert_raises(error) { @service.compose([@key], "other") }
        end
      end
    end
  end
end
