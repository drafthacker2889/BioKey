require 'json'
require 'openssl'
require 'securerandom'
require 'base64'
require 'fileutils'

input_path = ARGV[0]
if input_path.nil? || input_path.strip.empty?
  abort("Usage: ruby tools/encrypt_db_backup.rb <input_dump_path> [output_enc_path]")
end

unless File.exist?(input_path)
  abort("Input file not found: #{input_path}")
end

passphrase = ENV['DB_BACKUP_PASSPHRASE'].to_s
if passphrase.empty?
  abort('Set DB_BACKUP_PASSPHRASE in environment before running this script.')
end

output_path = ARGV[1]
if output_path.nil? || output_path.strip.empty?
  basename = File.basename(input_path)
  output_path = File.join('secure-backups', "#{basename}.enc")
end

plaintext = File.binread(input_path)
salt = SecureRandom.random_bytes(16)
iterations = 200_000
key = OpenSSL::PKCS5.pbkdf2_hmac(passphrase, salt, iterations, 32, 'sha256')
iv = SecureRandom.random_bytes(12)

cipher = OpenSSL::Cipher.new('aes-256-gcm')
cipher.encrypt
cipher.key = key
cipher.iv = iv

ciphertext = cipher.update(plaintext) + cipher.final
tag = cipher.auth_tag

payload = {
  version: 1,
  cipher: 'aes-256-gcm',
  kdf: {
    algorithm: 'pbkdf2_hmac',
    digest: 'sha256',
    iterations: iterations,
    salt_b64: Base64.strict_encode64(salt)
  },
  iv_b64: Base64.strict_encode64(iv),
  tag_b64: Base64.strict_encode64(tag),
  data_b64: Base64.strict_encode64(ciphertext),
  source_file: File.basename(input_path),
  encrypted_at: Time.now.utc.iso8601
}

FileUtils.mkdir_p(File.dirname(output_path))
File.write(output_path, JSON.pretty_generate(payload))

puts "Encrypted backup created: #{output_path}"
puts "Encrypted size: #{File.size(output_path)} bytes"