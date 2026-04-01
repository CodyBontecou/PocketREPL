#!/usr/bin/env ruby
require 'net/http'
require 'json'
require 'openssl'
require 'base64'
require 'time'

KEY_ID    = "T7KGDK4Y4V"
ISSUER_ID = "6c3b3640-c6bf-40a9-b6e5-57cda2c7776e"
KEY_PATH  = "/Users/codybontecou/dev/AuthKey_T7KGDK4Y4V.p8"
IAP_ID    = "6761124210"

def generate_token
  private_key = OpenSSL::PKey::EC.new(File.read(KEY_PATH))
  header  = Base64.urlsafe_encode64({ alg: "ES256", kid: KEY_ID, typ: "JWT" }.to_json, padding: false)
  payload = Base64.urlsafe_encode64({
    iss: ISSUER_ID, iat: Time.now.to_i, exp: Time.now.to_i + 1200, aud: "appstoreconnect-v1"
  }.to_json, padding: false)
  signing_input = "#{header}.#{payload}"
  digest    = OpenSSL::Digest::SHA256.new
  signature = private_key.sign(digest, signing_input)
  der = OpenSSL::ASN1.decode(signature)
  r = der.value[0].value.to_s(2).rjust(32, "\x00")[-32..]
  s = der.value[1].value.to_s(2).rjust(32, "\x00")[-32..]
  "#{signing_input}.#{Base64.urlsafe_encode64(r + s, padding: false)}"
end

def api_get(path, token)
  uri = URI("https://api.appstoreconnect.apple.com#{path}")
  req = Net::HTTP::Get.new(uri)
  req["Authorization"] = "Bearer #{token}"
  req["Content-Type"]  = "application/json"
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
  JSON.parse(res.body)
end

token = generate_token

# Check IAP details
puts "IAP details:"
iap = api_get("/v2/inAppPurchases/#{IAP_ID}", token)
puts JSON.pretty_generate(iap["data"]&.dig("attributes"))

# Check price schedule
puts "\nPrice schedule:"
schedule = api_get("/v2/inAppPurchases/#{IAP_ID}/priceSchedule?include=manualPrices,baseTerritory", token)
puts JSON.pretty_generate(schedule)
