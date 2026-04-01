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
TARGET_PRICE = "9.99"

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

def api_patch(path, body, token)
  uri = URI("https://api.appstoreconnect.apple.com#{path}")
  req = Net::HTTP::Patch.new(uri)
  req["Authorization"] = "Bearer #{token}"
  req["Content-Type"]  = "application/json"
  req.body = body.to_json
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
  [res.code.to_i, JSON.parse(res.body)]
end

token = generate_token

# Step 1: Find the $9.99 price point
puts "Fetching price points..."
points = []
next_url = "/v2/inAppPurchases/#{IAP_ID}/pricePoints?filter[territory]=USA&limit=200"
while next_url
  resp = api_get(next_url, token)
  points.concat(resp["data"] || [])
  next_url = resp.dig("links", "next")&.then { |u| URI.parse(u).request_uri }
end
puts "Total: #{points.length} price points"

target = points.find { |p| p["attributes"]["customerPrice"] == TARGET_PRICE }
abort "❌ $#{TARGET_PRICE} price point not found" unless target
price_point_id = target["id"]
puts "Found $#{TARGET_PRICE} price point: #{price_point_id}"

# Step 2: Check existing price schedules
puts "\nChecking existing price schedules..."
schedules = api_get("/v1/inAppPurchasePriceSchedules?filter[inAppPurchase]=#{IAP_ID}&include=manualPrices", token)
puts "Schedules found: #{schedules['data']&.length || 0}"
puts JSON.pretty_generate(schedules["data"]) if schedules["data"]&.any?

# Step 3: Update IAP directly with basePriceTier via PATCH
puts "\nPatching IAP with $#{TARGET_PRICE} price via basePriceTier..."
status, resp = api_patch("/v2/inAppPurchases/#{IAP_ID}", {
  data: {
    type: "inAppPurchases",
    id: IAP_ID,
    attributes: {}
  }
}, token)
puts "PATCH result (#{status}): #{JSON.pretty_generate(resp)}"

# Step 4: Try creating a fresh price schedule with the correct price point
puts "\nCreating fresh price schedule at $#{TARGET_PRICE}..."
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

puts "Price schedule result (#{status}): #{JSON.pretty_generate(resp)}"
