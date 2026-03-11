import jwt from 'jsonwebtoken';
import fs from 'fs';
import https from 'https';

const KEY_ID = 'T7KGDK4Y4V';
const ISSUER_ID = '6c3b3640-c6bf-40a9-b6e5-57cda2c7776e';
const KEY_PATH = '/Users/codybontecou/dev/AuthKey_T7KGDK4Y4V.p8';
const TEAM_ID = '67KC823C9A';
const BUNDLE_IDENTIFIER = 'com.bontecou.PocketREPL';

const privateKey = fs.readFileSync(KEY_PATH, 'utf8');

const token = jwt.sign({}, privateKey, {
  algorithm: 'ES256',
  expiresIn: '20m',
  issuer: ISSUER_ID,
  audience: 'appstoreconnect-v1',
  header: {
    alg: 'ES256',
    kid: KEY_ID,
    typ: 'JWT'
  }
});

function makeRequest(method, path, data = null) {
  return new Promise((resolve, reject) => {
    const options = {
      hostname: 'api.appstoreconnect.apple.com',
      port: 443,
      path: path,
      method: method,
      headers: {
        'Authorization': `Bearer ${token}`,
        'Content-Type': 'application/json'
      }
    };

    const req = https.request(options, (res) => {
      let body = '';
      res.on('data', chunk => body += chunk);
      res.on('end', () => {
        try {
          resolve({ status: res.statusCode, data: JSON.parse(body) });
        } catch {
          resolve({ status: res.statusCode, data: body });
        }
      });
    });

    req.on('error', reject);
    if (data) req.write(JSON.stringify(data));
    req.end();
  });
}

async function createApp() {
  console.log('Creating app on App Store Connect...');
  
  // First, search for existing bundle ID
  console.log('Looking for bundle ID...');
  const bundleSearch = await makeRequest('GET', `/v1/bundleIds?filter[identifier]=${BUNDLE_IDENTIFIER}`);
  
  let bundleId;
  
  if (bundleSearch.data.data && bundleSearch.data.data.length > 0) {
    bundleId = bundleSearch.data.data[0].id;
    console.log('Found existing bundle ID:', bundleId);
  } else {
    console.log('Bundle ID not found. Registering...');
    
    const registerPayload = {
      data: {
        type: 'bundleIds',
        attributes: {
          name: 'PocketREPL',
          identifier: BUNDLE_IDENTIFIER,
          platform: 'IOS'
        }
      }
    };
    
    const registerResult = await makeRequest('POST', '/v1/bundleIds', registerPayload);
    console.log('Register bundle result:', JSON.stringify(registerResult, null, 2));
    
    if (registerResult.status === 201 || registerResult.status === 200) {
      bundleId = registerResult.data.data.id;
      console.log('Registered bundle ID:', bundleId);
    } else {
      console.error('Failed to register bundle ID');
      return;
    }
  }

  // Now create the app
  console.log('Creating app...');
  const createPayload = {
    data: {
      type: 'apps',
      attributes: {
        name: 'PocketREPL',
        bundleId: BUNDLE_IDENTIFIER,
        sku: 'pocketrepl-ios-2026',
        primaryLocale: 'en-US'
      },
      relationships: {
        bundleId: {
          data: {
            type: 'bundleIds',
            id: bundleId
          }
        }
      }
    }
  };

  const result = await makeRequest('POST', '/v1/apps', createPayload);
  console.log('Create app result:', JSON.stringify(result, null, 2));
  
  if (result.status === 201) {
    console.log('✅ App created successfully!');
    console.log('App ID:', result.data.data.id);
  } else if (result.data.errors) {
    console.log('❌ Error:', result.data.errors[0].detail);
  }
}

createApp().catch(console.error);
