# frozen_string_literal: true

require "active_storage/service/disk_service"
require "active_support/key_generator"
require "openssl"
require "tempfile"

module ActiveStorage
  class Service::EncryptedPrivateDiskService < Service::DiskService
    MAGIC = "BIH_PRIVATE_BLOB\x00\x01".b.freeze
    NONCE_BYTES = 12
    TAG_BYTES = 16
    MAX_BYTES = 25 * 1024 * 1024
    KEY_VERSION = /\A[a-zA-Z0-9_-]{1,32}\z/
    class Unavailable < StandardError; end

    attr_reader :max_bytes

    def initialize(root:, key_version: "v1", max_bytes: MAX_BYTES, key_provider: nil, **options)
      raise Unavailable, "Private storage cannot be public" if options.delete(:public)
      raise Unavailable, "Invalid private storage key version" unless KEY_VERSION.match?(key_version.to_s)

      @key_version = key_version.to_s
      @max_bytes = Integer(max_bytes)
      raise Unavailable, "Invalid private storage bound" unless @max_bytes.positive? && @max_bytes <= MAX_BYTES

      @key_provider = key_provider || method(:derived_key)
      super(root:, public: false, **options)
    end

    def upload(key, io, checksum: nil, **)
      plaintext = io.read(max_bytes + 1).to_s.b
      raise ActiveStorage::IntegrityError, "Private upload exceeds its bound" if plaintext.bytesize > max_bytes
      raise ActiveStorage::IntegrityError, "Private upload checksum mismatch" if checksum && OpenSSL::Digest::MD5.base64digest(plaintext) != checksum

      ciphertext = encrypt(key, plaintext)
      destination = make_path_for(key)
      # No plaintext tempfile; an unsuccessful write leaves the previous file intact.
      Tempfile.create([".private-write-", ".tmp"], File.dirname(destination)) do |file|
        file.binmode
        file.write(ciphertext)
        file.flush
        file.fsync
        # Preserve inherited named backup ACL read access; no world permission.
        file.chmod(0o640)
        File.rename(file.path, destination)
      end
    end

    def download(key)
      bytes = decrypt(key)
      return bytes unless block_given?

      # Entire GCM envelope has authenticated before the first plaintext yield.
      offset = 0
      while offset < bytes.bytesize
        yield bytes.byteslice(offset, 64 * 1024)
        offset += 64 * 1024
      end
    end

    def download_chunk(key, range)
      decrypt(key).byteslice(range) || "".b
    end

    def compose(*) = raise(Unavailable, "Private files require authenticated server-side upload")

    def url(*) = raise(Unavailable, "Private files require an authorized download")

    def url_for_direct_upload(*) = raise(Unavailable, "Private files require server-side upload")

    def headers_for_direct_upload(*) = raise(Unavailable, "Private files require server-side upload")

    private

    def encrypt(key, plaintext)
      version = @key_version.b
      header = MAGIC + [version.bytesize].pack("C") + version
      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.encrypt
      cipher.key = encryption_key(@key_version)
      nonce = cipher.random_iv
      cipher.auth_data = header + key.to_s.b
      encrypted = plaintext.empty? ? "".b : cipher.update(plaintext)
      encrypted << cipher.final
      header + nonce + cipher.auth_tag(TAG_BYTES) + encrypted
    end

    def decrypt(key)
      bytes = File.binread(path_for(key), max_bytes + MAGIC.bytesize + 1 + 32 + NONCE_BYTES + TAG_BYTES + 1).to_s.b
      raise ActiveStorage::IntegrityError, "Invalid private storage envelope" unless bytes.start_with?(MAGIC)

      length = bytes.getbyte(MAGIC.bytesize)
      raise ActiveStorage::IntegrityError, "Invalid private storage envelope" unless length&.between?(1, 32)

      header_size = MAGIC.bytesize + 1 + length
      version = bytes.byteslice(MAGIC.bytesize + 1, length)
      raise ActiveStorage::IntegrityError, "Invalid private storage envelope" unless KEY_VERSION.match?(version.to_s)

      encrypted_size = bytes.bytesize - header_size - NONCE_BYTES - TAG_BYTES
      raise ActiveStorage::IntegrityError, "Invalid private storage envelope" unless encrypted_size.between?(0, max_bytes)

      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.decrypt
      cipher.key = encryption_key(version)
      cipher.iv = bytes.byteslice(header_size, NONCE_BYTES)
      cipher.auth_tag = bytes.byteslice(header_size + NONCE_BYTES, TAG_BYTES)
      cipher.auth_data = bytes.byteslice(0, header_size) + key.to_s.b
      encrypted = bytes.byteslice(header_size + NONCE_BYTES + TAG_BYTES, encrypted_size)
      plaintext = encrypted.empty? ? "".b : cipher.update(encrypted)
      plaintext + cipher.final
    rescue Errno::ENOENT
      raise ActiveStorage::FileNotFoundError
    rescue OpenSSL::Cipher::CipherError, ArgumentError
      raise ActiveStorage::IntegrityError, "Private storage authentication failed"
    end

    def encryption_key(version)
      value = @key_provider.call(version)
      raise Unavailable, "Private storage key unavailable" unless value.is_a?(String) && value.bytesize == 32

      value
    end

    def derived_key(version)
      secret = if version == @key_version
                 Rails.application.secret_key_base
               else
                 Rails.application.credentials.dig(:report_private_storage, :previous_secret_key_bases, version.to_sym)
               end
      raise Unavailable, "Private storage key unavailable" unless secret.is_a?(String) && secret.present?

      ActiveSupport::KeyGenerator.new(secret).generate_key("decidim-bih/private-blob/#{version}", 32)
    end
  end
end
