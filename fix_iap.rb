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

def api_post(path, body, token)
  uri = URI("https://api.appstoreconnect.apple.com#{path}")
  req = Net::HTTP::Post.new(uri)
  req["Authorization"] = "Bearer #{token}"
  req["Content-Type"]  = "application/json"
  req.body = body.to_json
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
  [res.code.to_i, JSON.parse(res.body)]
end

token = generate_token

# Step 1: Add localization (v1 endpoint)
puts "Adding en-US localization..."
status, resp = api_post("/v1/inAppPurchaseLocalizations", {
  data: {
    type: "inAppPurchaseLocalizations",
    attributes: {
      locale:       "en-US",
      name:         "PocketREPL Pro",
      description:  "Unlimited AI, local models & full JS runtime."
    },
    relationships: {
      inAppPurchaseV2: {
        data: { type: "inAppPurchases", id: IAP_ID }
      }
    }
  }
}, token)

if status == 201
  puts "✅ Localization added"
else
  puts "❌ Localization failed (#{status}): #{JSON.pretty_generate(resp)}"
end

# Step 2: Look up price points for USA to find $2.99
puts "\nFetching price points for USA..."
pp_resp = api_get("/v2/inAppPurchases/#{IAP_ID}/pricePoints?filter[territory]=USA&limit=50", token)
points = pp_resp["data"] || []
puts "Got #{points.length} price points"

# Find the $2.99 point
target = points.find { |p| p["attributes"]["customerPrice"] == "2.99" }
unless target
  # Print first 10 to see what's available
  puts "Available prices: #{points.first(10).map { |p| p['attributes']['customerPrice'] }.inspect}"
  puts "⚠️  $2.99 price point not found, you'll need to set the price manually in App Store Connect"
  exit 0
end

price_point_id = target["id"]
puts "Found $2.99 price point: #{price_point_id}"

# Step 3: Create price schedule
puts "\nSetting price schedule ($2.99)..."
status, resp = api_post("/v1/inAppPurchasePriceSchedules", {
  data: {
    type: "inAppPurchasePriceSchedules",
    relationships: {
      inAppPurchase: {
        data: { type: "inAppPurchases", id: IAP_ID }
      },
      baseTerritory: {
        data: { type: "territories", id: "USA" }
      },
      manualPrices: {
        data: [{ type: "inAppPurchasePrices", id: "${p0}" }]
      }
    }
  },
  included: [
    {
      type: "inAppPurchasePrices",
      id: "${p0}",
      attributes: { startDate: nil },
      relationships: {
        inAppPurchasePricePoint: {
          data: { type: "inAppPurchasePricePoints", id: price_point_id }
        },
        territory: {
          data: { type: "territories", id: "USA" }
        }
      }
    }
  ]
}, token)

if status == 201
  puts "✅ Price set to $2.99"
else
  puts "❌ Price failed (#{status}): #{JSON.pretty_generate(resp)}"
  puts "⚠️  Set the price manually in App Store Connect"
end

puts "\n✅ All done! IAP id #{IAP_ID} (com.bontecou.PocketREPL.pro) is ready."
puts "Go to App Store Connect → PocketREPL → In-App Purchases to submit it for review."
