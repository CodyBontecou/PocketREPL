import jwt from 'jsonwebtoken';
import fs from 'fs';
import https from 'https';

const KEY_ID = 'T7KGDK4Y4V';
const ISSUER_ID = '6c3b3640-c6bf-40a9-b6e5-57cda2c7776e';
const KEY_PATH = '/Users/codybontecou/dev/AuthKey_T7KGDK4Y4V.p8';
const BUNDLE_ID = 'com.bontecou.PocketREPL';

const privateKey = fs.readFileSync(KEY_PATH, 'utf8');

const token = jwt.sign({}, privateKey, {
  algorithm: 'ES256',
  expiresIn: '20m',
  issuer: ISSUER_ID,
  audience: 'appstoreconnect-v1',
  header: { alg: 'ES256', kid: KEY_ID, typ: 'JWT' }
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

async function uploadMetadata() {
  // Find the app
  console.log('Finding app...');
  const appsResult = await makeRequest('GET', `/v1/apps?filter[bundleId]=${BUNDLE_ID}`);
  
  if (!appsResult.data.data || appsResult.data.data.length === 0) {
    console.error('App not found!');
    return;
  }
  
  const appId = appsResult.data.data[0].id;
  console.log('Found app:', appId);
  
  // Get the edit version
  console.log('Getting edit version...');
  const versionsResult = await makeRequest('GET', `/v1/apps/${appId}/appStoreVersions?filter[appStoreState]=PREPARE_FOR_SUBMISSION&filter[platform]=IOS`);
  
  if (!versionsResult.data.data || versionsResult.data.data.length === 0) {
    console.error('No edit version found!');
    console.log(JSON.stringify(versionsResult.data, null, 2));
    return;
  }
  
  const versionId = versionsResult.data.data[0].id;
  console.log('Found version:', versionId);
  
  // Get localizations
  console.log('Getting localizations...');
  const locResult = await makeRequest('GET', `/v1/appStoreVersions/${versionId}/appStoreVersionLocalizations`);
  
  let locId;
  if (locResult.data.data && locResult.data.data.length > 0) {
    locId = locResult.data.data.find(l => l.attributes.locale === 'en-US')?.id;
  }
  
  // Read metadata files
  const description = fs.readFileSync('./fastlane/metadata/en-US/description.txt', 'utf8').trim();
  const keywords = fs.readFileSync('./fastlane/metadata/en-US/keywords.txt', 'utf8').trim();
  const supportUrl = fs.readFileSync('./fastlane/metadata/en-US/support_url.txt', 'utf8').trim();
  const marketingUrl = fs.readFileSync('./fastlane/metadata/en-US/marketing_url.txt', 'utf8').trim();
  const privacyUrl = fs.readFileSync('./fastlane/metadata/en-US/privacy_url.txt', 'utf8').trim();
  
  if (locId) {
    console.log('Updating localization:', locId);
    const updateResult = await makeRequest('PATCH', `/v1/appStoreVersionLocalizations/${locId}`, {
      data: {
        type: 'appStoreVersionLocalizations',
        id: locId,
        attributes: {
          description: description,
          keywords: keywords,
          supportUrl: supportUrl,
          marketingUrl: marketingUrl
        }
      }
    });
    
    if (updateResult.status === 200) {
      console.log('✅ Description, keywords, URLs updated');
    } else {
      console.log('Error updating localization:', JSON.stringify(updateResult.data, null, 2));
    }
  } else {
    console.log('Creating en-US localization...');
    const createResult = await makeRequest('POST', `/v1/appStoreVersionLocalizations`, {
      data: {
        type: 'appStoreVersionLocalizations',
        attributes: {
          locale: 'en-US',
          description: description,
          keywords: keywords,
          supportUrl: supportUrl,
          marketingUrl: marketingUrl
        },
        relationships: {
          appStoreVersion: {
            data: { type: 'appStoreVersions', id: versionId }
          }
        }
      }
    });
    
    if (createResult.status === 201) {
      console.log('✅ Localization created');
    } else {
      console.log('Error creating localization:', JSON.stringify(createResult.data, null, 2));
    }
  }
  
  // Update app info (privacy URL goes at app level)
  console.log('Updating app info...');
  const appInfoResult = await makeRequest('GET', `/v1/apps/${appId}/appInfos`);
  
  if (appInfoResult.data.data && appInfoResult.data.data.length > 0) {
    const appInfoId = appInfoResult.data.data[0].id;
    
    // Get app info localizations
    const appInfoLocResult = await makeRequest('GET', `/v1/appInfos/${appInfoId}/appInfoLocalizations`);
    
    if (appInfoLocResult.data.data && appInfoLocResult.data.data.length > 0) {
      const enLoc = appInfoLocResult.data.data.find(l => l.attributes.locale === 'en-US');
      if (enLoc) {
        const subtitle = fs.readFileSync('./fastlane/metadata/en-US/subtitle.txt', 'utf8').trim();
        const name = fs.readFileSync('./fastlane/metadata/en-US/name.txt', 'utf8').trim();
        
        const updateAppInfoResult = await makeRequest('PATCH', `/v1/appInfoLocalizations/${enLoc.id}`, {
          data: {
            type: 'appInfoLocalizations',
            id: enLoc.id,
            attributes: {
              name: name,
              subtitle: subtitle,
              privacyPolicyUrl: privacyUrl
            }
          }
        });
        
        if (updateAppInfoResult.status === 200) {
          console.log('✅ App info (name, subtitle, privacy URL) updated');
        } else {
          console.log('Error updating app info:', JSON.stringify(updateAppInfoResult.data, null, 2));
        }
      }
    }
  }
  
  console.log('\n✅ Metadata upload complete!');
}

uploadMetadata().catch(console.error);
