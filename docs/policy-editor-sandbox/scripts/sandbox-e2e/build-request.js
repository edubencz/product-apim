const fs = require('fs');
const scenario = process.argv[2];

let seqFile = __dirname + '/lean-auth-rendered.xml';
if (scenario === 'respond') {
  seqFile = __dirname + '/respond-early-rendered.xml';
}
const seq = fs.readFileSync(seqFile, 'utf8');

const base = {
  renderedSequence: seq,
  flow: 'request',
  sampleRequest: {
    method: 'POST',
    path: '/orders/1',
    headers: { 'Content-Type': 'application/json' },
    body: '{"a":1}',
    contentType: 'application/json'
  },
  extraProperties: {},
  captureSnapshots: false
};

let mocks = [];
if (scenario === 'ok') {
  mocks = [{ id: 'm1', urlPattern: 'https://idp.example.com/token*', matchType: 'GLOB', method: 'POST',
    status: 200, headers: { 'Content-Type': 'application/json' }, body: '{"access_token":"abc"}',
    contentType: 'application/json', delayMs: 0 }];
} else if (scenario === 'unauthorized') {
  mocks = [{ id: 'm1', urlPattern: 'https://idp.example.com/token*', matchType: 'GLOB', method: 'POST',
    status: 401, headers: { 'Content-Type': 'application/json' }, body: '{"error":"invalid"}',
    contentType: 'application/json', delayMs: 0 }];
} else if (scenario === 'blank-method') {
  mocks = [{ id: 'm1', urlPattern: 'https://idp.example.com/token*', matchType: 'GLOB', method: '',
    status: 200, headers: { 'Content-Type': 'application/json' }, body: '{"access_token":"abc"}',
    contentType: 'application/json', delayMs: 0 }];
} else if (scenario === 'respond') {
  mocks = [];
} else if (scenario === 'concurrency') {
  mocks = [{ id: 'm1', urlPattern: 'https://idp.example.com/token*', matchType: 'GLOB', method: 'POST',
    status: 200, headers: { 'Content-Type': 'application/json' }, body: '{"access_token":"abc"}',
    contentType: 'application/json', delayMs: 3000 }];
} else {
  throw new Error('unknown scenario ' + scenario);
}
base.mocks = mocks;
process.stdout.write(JSON.stringify(base));
