#!/usr/bin/env ruby
require 'net/http'
require 'json'
require 'openssl'
require 'base64'
require 'time'


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

# Check the active iapPriceSchedule via the relationship link
puts "Checking iapPriceSchedule..."
schedule = api_get("/v2/inAppPurchases/#{IAP_ID}/iapPriceSchedule?include=manualPrices", token)
puts JSON.pretty_generate(schedule)

# Check the manual prices directly
puts "\nChecking manualPrices on schedule..."
manual = api_get("/v1/inAppPurchasePriceSchedules/#{IAP_ID}/manualPrices?include=inAppPurchasePricePoint,territory", token)
manual["data"]&.each do |price|
  point = manual["included"]&.find { |i| i["type"] == "inAppPurchasePricePoints" && manual["data"].any? { |d| d.dig("relationships","inAppPurchasePricePoint","data","id") == i["id"] } }
  territory = manual["included"]&.find { |i| i["type"] == "territories" }
  puts "  Price entry id: #{price['id']}"
  puts "  Start: #{price.dig('attributes','startDate') || 'immediate'}, End: #{price.dig('attributes','endDate') || 'none'}"
  puts "  Territory: #{territory&.dig('id')}"
  if point
    puts "  Customer price: #{point.dig('attributes','customerPrice')}"
    puts "  Proceeds: #{point.dig('attributes','proceeds')}"
  end
end
