#!/usr/bin/env ruby
require 'net/http'
require 'json'
require 'openssl'
require 'base64'
require 'time'

# --- Config ---
KEY_ID      = "T7KGDK4Y4V"
ISSUER_ID   = "6c3b3640-c6bf-40a9-b6e5-57cda2c7776e"
KEY_PATH    = "/Users/codybontecou/dev/AuthKey_T7KGDK4Y4V.p8"
APP_BUNDLE  = "com.bontecou.PocketREPL"
PRODUCT_ID  = "com.bontecou.PocketREPL.pro"

# --- JWT ---
def generate_token
  private_key = OpenSSL::PKey::EC.new(File.read(KEY_PATH))
  header  = Base64.urlsafe_encode64({ alg: "ES256", kid: KEY_ID, typ: "JWT" }.to_json, padding: false)
  payload = Base64.urlsafe_encode64({
    iss: ISSUER_ID,
    iat: Time.now.to_i,
    exp: Time.now.to_i + 1200,
    aud: "appstoreconnect-v1"
  }.to_json, padding: false)
  signing_input = "#{header}.#{payload}"
  digest    = OpenSSL::Digest::SHA256.new
  signature = private_key.sign(digest, signing_input)
  der = OpenSSL::ASN1.decode(signature)
  r = der.value[0].value.to_s(2).rjust(32, "\x00")[-32..]
  s = der.value[1].value.to_s(2).rjust(32, "\x00")[-32..]
  sig_b64 = Base64.urlsafe_encode64(r + s, padding: false)
  "#{signing_input}.#{sig_b64}"
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

# 1. Find app ID
puts "Looking up app #{APP_BUNDLE}..."
apps = api_get("/v1/apps?filter[bundleId]=#{APP_BUNDLE}", token)
app = apps["data"]&.first
abort "App not found!" unless app
app_id = app["id"]
puts "Found app: #{app['attributes']['name']} (id: #{app_id})"

# 2. Check if IAP already exists
puts "\nChecking existing IAPs..."
iaps = api_get("/v1/apps/#{app_id}/inAppPurchasesV2", token)
existing = iaps["data"]&.find { |i| i["attributes"]["productId"] == PRODUCT_ID }
if existing
  puts "IAP already exists: #{existing['attributes']['productId']} (id: #{existing['id']})"
  exit 0
end

# 3. Create the IAP
puts "\nCreating IAP #{PRODUCT_ID}..."
status, resp = api_post("/v2/inAppPurchases", {
  data: {
    type: "inAppPurchases",
    attributes: {
      name:               "PocketREPL Pro",
      productId:          PRODUCT_ID,
      inAppPurchaseType:  "NON_CONSUMABLE",
      familySharable:     true
    },
    relationships: {
      app: {
        data: { type: "apps", id: app_id }
      }
    }
  }
}, token)

if status == 201
  iap_id = resp["data"]["id"]
  puts "✅ IAP created! id: #{iap_id}"
else
  puts "❌ Failed (#{status}): #{JSON.pretty_generate(resp)}"
  exit 1
end

# 4. Add English localization
puts "\nAdding en-US localization..."
status, resp = api_post("/v2/inAppPurchaseLocalizations", {
  data: {
    type: "inAppPurchaseLocalizations",
    attributes: {
      locale:       "en-US",
      name:         "PocketREPL Pro",
      description:  "Unlock unlimited AI conversations, local model support, and full JavaScript runtime access."
    },
    relationships: {
      inAppPurchaseV2: {
        data: { type: "inAppPurchases", id: iap_id }
      }
    }
  }
}, token)

if status == 201
  puts "✅ Localization added"
else
  puts "❌ Localization failed (#{status}): #{JSON.pretty_generate(resp)}"
end

# 5. Set price ($2.99 = tier 3)
puts "\nSetting price schedule ($2.99)..."
status, resp = api_post("/v1/inAppPurchasePriceSchedules", {
  data: {
    type: "inAppPurchasePriceSchedules",
    relationships: {
      inAppPurchase: {
        data: { type: "inAppPurchases", id: iap_id }
      },
      baseTerritory: {
        data: { type: "territories", id: "USA" }
      },
      manualPrices: {
        data: [
          { type: "inAppPurchasePrices", id: "${price0}" }
        ]
      }
    }
  },
  included: [
    {
      type: "inAppPurchasePrices",
      id: "${price0}",
      attributes: { startDate: nil },
      relationships: {
        inAppPurchasePricePoint: {
          data: { type: "inAppPurchasePricePoints", id: "eyJhIjoiMSIsInQiOiIzIn0=" } # tier 3
        },
        territory: {
          data: { type: "territories", id: "USA" }
        }
      }
    }
  ]
}, token)

if status == 201
  puts "✅ Price schedule set"
else
  puts "⚠️  Price schedule (#{status}): #{JSON.pretty_generate(resp)}"
  puts "    (You may need to set the price manually in App Store Connect)"
end

puts "\nDone! Visit App Store Connect → Your App → In-App Purchases to review and submit for review."
