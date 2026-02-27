require 'json'
require 'openssl'
require 'base64'
require 'fileutils'

input_path = ARGV[0]
if input_path.nil? || input_path.strip.empty?
  abort("Usage: ruby tools/decrypt_db_backup.rb <input_enc_path> [output_dump_path]")
end

unless File.exist?(input_path)
  abort("Input file not found: #{input_path}")
end

passphrase = ENV['DB_BACKUP_PASSPHRASE'].to_s
if passphrase.empty?
  abort('Set DB_BACKUP_PASSPHRASE in environment before running this script.')
end

payload = JSON.parse(File.read(input_path))
unless payload['cipher'] == 'aes-256-gcm' && payload['kdf'].is_a?(Hash)
  abort('Unsupported encrypted backup format')
end

salt = Base64.decode64(payload.dig('kdf', 'salt_b64').to_s)
iterations = payload.dig('kdf', 'iterations').to_i
key = OpenSSL::PKCS5.pbkdf2_hmac(passphrase, salt, iterations, 32, 'sha256')
iv = Base64.decode64(payload['iv_b64'].to_s)
tag = Base64.decode64(payload['tag_b64'].to_s)
ciphertext = Base64.decode64(payload['data_b64'].to_s)

cipher = OpenSSL::Cipher.new('aes-256-gcm')
cipher.decrypt
cipher.key = key
cipher.iv = iv
cipher.auth_tag = tag

plaintext = cipher.update(ciphertext) + cipher.final

output_path = ARGV[1]
if output_path.nil? || output_path.strip.empty?
  src = payload['source_file'] || File.basename(input_path, '.enc')
  output_path = File.join('exports', 'db_backups', src)
end

FileUtils.mkdir_p(File.dirname(output_path))
File.binwrite(output_path, plaintext)

puts "Decrypted backup created: #{output_path}"
puts "Decrypted size: #{File.size(output_path)} bytes"