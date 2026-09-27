const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');
const https = require('https');

const SCREEN_DIR = path.join(__dirname, 'screens');
if (!fs.existsSync(SCREEN_DIR)) fs.mkdirSync(SCREEN_DIR, { recursive: true });

const CHROME_PATH = String.raw`C:\Users\Pichau\AppData\Local\ms-playwright\chromium-1243\chrome-win64\chrome.exe`;

let shotIndex = 0;
// Issue 2/6: viewport screenshots (not fullPage) - a fullPage capture of a `position: fixed`
// MUI fullScreen Dialog can appear to "overlap mid-page" purely as a stitching artifact of the
// fullPage capture, not a real bug. Viewport screenshots show what a real user sees.
async function shot(page, name) {
  shotIndex += 1;
  const file = path.join(SCREEN_DIR, `${String(shotIndex).padStart(2, '0')}-${name}.png`);
  await page.screenshot({ path: file, fullPage: false });
  console.log('SCREENSHOT', file);
  return file;
}

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

// Issue 3: every response with an error status is logged with its URL, so 404s (and any other
// unexpected 4xx/5xx) seen during the run can be triaged instead of only "the console had an
// error" - most 404s for static assets don't log to the console at all.
const badResponses = [];

(async () => {
  const browser = await chromium.launch({
    headless: true,
    executablePath: CHROME_PATH,
    ignoreHTTPSErrors: true,
  });
  const context = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1440, height: 900 } });
  const page = await context.newPage();
  page.setDefaultTimeout(20000);
  // Editor template swaps show a window.confirm() when replacing non-empty content - auto-accept
  // it so headless runs don't hang on the default browser dialog.
  page.on('dialog', (dialog) => dialog.accept());
  page.on('console', (msg) => {
    if (msg.type() === 'error') log('BROWSER CONSOLE ERROR:', msg.text());
  });
  page.on('response', (res) => {
    if (res.status() >= 400) {
      badResponses.push({ status: res.status(), url: res.url() });
      log('BAD RESPONSE', res.status(), res.url());
    }
  });
  page.on('request', (req) => {
    if (req.url().includes('/operation-policies/test')) {
      log('REQUEST', req.method(), req.url());
      log('REQUEST BODY', req.postData());
    }
  });
  page.on('response', async (res) => {
    if (res.url().includes('/operation-policies/test')) {
      log('RESPONSE STATUS', res.status());
      try {
        const body = await res.text();
        log('RESPONSE BODY', body.slice(0, 3000));
      } catch (e) { /* ignore */ }
    }
  });

  const results = {};

  try {
    log('STEP 1: navigate to publisher login');
    await page.goto('https://localhost:9443/publisher/', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(1500);
    await shot(page, 'login-page');

    log('STEP 2: fill login form');
    // WSO2 default login page usually has input[name=username] and input[name=password]
    const userSel = 'input[name="username"], #usernameUserInput, input#username';
    const passSel = 'input[name="password"], #password, input#password';
    await page.waitForSelector(userSel, { timeout: 15000 });
    await page.fill(userSel, 'admin');
    await page.fill(passSel, 'admin');
    await shot(page, 'login-filled');
    await Promise.all([
      page.waitForNavigation({ waitUntil: 'domcontentloaded', timeout: 20000 }).catch(() => {}),
      page.click('button[type="submit"], #loginButton, input[type="submit"]'),
    ]);
    await page.waitForTimeout(2000);
    await shot(page, 'after-login');
    results.login = 'PASS';
  } catch (e) {
    results.login = `FAIL: ${e.message}`;
    await shot(page, 'login-error');
  }

  try {
    log('STEP 3: navigate to policies/create');
    await page.goto('https://localhost:9443/publisher/policies/create', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(2000);
    await shot(page, 'policies-create-page');
    results.navigateCreate = 'PASS';
  } catch (e) {
    results.navigateCreate = `FAIL: ${e.message}`;
    await shot(page, 'navigate-create-error');
  }

  const uniqueSuffix = Date.now();
  const policyName = `SmokeTestPolicy${uniqueSuffix}`;

  try {
    log('STEP 4: fill name/version');
    await page.waitForSelector('#name', { timeout: 15000 });
    await page.fill('#name', policyName);
    await page.fill('#version', '1');
    await shot(page, 'name-version-filled');
    results.fillNameVersion = 'PASS';
  } catch (e) {
    results.fillNameVersion = `FAIL: ${e.message}`;
    await shot(page, 'fill-name-version-error');
  }

  try {
    log('STEP 5: switch to "Write in editor"');
    await page.click('[data-testid="policy-source-tab-editor"]');
    await page.waitForTimeout(500);
    await shot(page, 'write-in-editor-tab');
    results.switchToEditorTab = 'PASS';
  } catch (e) {
    results.switchToEditorTab = `FAIL: ${e.message}`;
    await shot(page, 'switch-editor-tab-error');
  }

  try {
    log('STEP 6: open full editor workspace');
    await page.click('[data-testid="open-full-policy-editor-btn"]');
    await page.waitForSelector('[data-testid="policy-editor-workspace"]', { timeout: 15000 });
    await page.waitForTimeout(500);
    await shot(page, 'editor-workspace-open');
    results.openFullEditor = 'PASS';
  } catch (e) {
    results.openFullEditor = `FAIL: ${e.message}`;
    await shot(page, 'open-full-editor-error');
  }

  try {
    log('STEP 6b: verify the Policy Editor dialog is truly full-screen at 1440x900 and 1280x720 '
      + '(viewport screenshots, not fullPage - Issue 2)');
    const checkFullScreen = async (width, height, label) => {
      await page.setViewportSize({ width, height });
      await page.waitForTimeout(300);
      const box = await page.locator('[data-testid="policy-editor-workspace"]').boundingBox();
      const file = await shot(page, `editor-fullscreen-${label}`);
      const matches = box && Math.abs(box.width - width) <= 2 && Math.abs(box.height - height) <= 2
        && Math.abs(box.x) <= 2 && Math.abs(box.y) <= 2;
      log(`fullscreen check ${label}: box=${JSON.stringify(box)} viewport=${width}x${height} match=${matches}`);
      return { file, matches, box };
    };
    const at1440 = await checkFullScreen(1440, 900, '1440x900');
    const at1280 = await checkFullScreen(1280, 720, '1280x720');
    // Restore the viewport used by the rest of the script.
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.waitForTimeout(300);
    results.fullScreenCheck = (at1440.matches && at1280.matches)
      ? 'PASS (dialog bounding box == viewport at both sizes)'
      : `FAIL (1440x900 box=${JSON.stringify(at1440.box)}, 1280x720 box=${JSON.stringify(at1280.box)})`;
  } catch (e) {
    results.fullScreenCheck = `FAIL: ${e.message}`;
  }

  try {
    log('STEP 6c: open the Mediators palette (docked panel bug fix verification)');
    await page.click('[data-testid="policy-editor-palette-btn"]');
    await page.waitForSelector('[data-testid="mediator-palette"]', { timeout: 5000 });
    await page.waitForTimeout(400);
    await shot(page, 'mediators-palette-open');
    const paletteVisible = await page.locator('[data-testid="mediator-palette"]').isVisible();
    results.mediatorsPaletteOpens = paletteVisible ? 'PASS' : 'FAIL (palette not visible)';
    // Close it again so it doesn't cover the editor for the rest of the run.
    await page.click('[data-testid="policy-editor-palette-btn"]');
    await page.waitForTimeout(300);
  } catch (e) {
    results.mediatorsPaletteOpens = `FAIL: ${e.message}`;
    await shot(page, 'mediators-palette-error');
  }

  try {
    log('STEP 7: apply "Token exchange + auth" template');
    await page.click('[data-testid="policy-editor-templates-btn"]');
    await page.waitForTimeout(300);
    await shot(page, 'templates-menu-open');
    await page.click('text=Token exchange + auth');
    await page.waitForTimeout(1000);
    await shot(page, 'template-applied');
    results.applyTemplate = 'PASS';
  } catch (e) {
    results.applyTemplate = `FAIL: ${e.message}`;
    await shot(page, 'apply-template-error');
  }

  try {
    log('STEP 8: verify diagram renders nodes (>=17)');
    await page.waitForTimeout(1000);
    const nodeCount = await page.locator('[data-testid^="flow-node-"]').count();
    log('flow node count =', nodeCount);
    results.diagramNodeCount = nodeCount;
    // Design spec change: runs of >= 3 consecutive property/header mediators now auto-collapse
    // into a single stacked "Properties x N" card (fewer, higher-signal boxes), so the raw
    // flow-node-* count for this template is intentionally lower than before grouping existed.
    results.diagramCheck = nodeCount >= 8 ? 'PASS' : `FAIL (count=${nodeCount})`;
    await shot(page, 'diagram-rendered');
  } catch (e) {
    results.diagramCheck = `FAIL: ${e.message}`;
    await shot(page, 'diagram-check-error');
  }

  try {
    log('STEP 8a: clear the editor and insert a Filter (then/else) snippet to show branch lanes');
    await page.locator('[data-testid="policy-editor-code-editor-pane"] .monaco-editor').first().click();
    await page.keyboard.press('Control+A');
    await page.keyboard.press('Delete');
    await page.click('[data-testid="policy-editor-palette-btn"]');
    await page.waitForSelector('[data-testid="mediator-palette-item-filter-then-else"]', { timeout: 5000 });
    await page.click('[data-testid="mediator-palette-item-filter-then-else"]');
    await page.waitForTimeout(600);
    await shot(page, 'branch-lanes-filter-example');
    results.branchLanesExample = 'PASS';
    // Close the palette and restore the template for the rest of the run.
    await page.click('[data-testid="policy-editor-palette-btn"]');
    await page.waitForTimeout(200);
    await page.click('[data-testid="policy-editor-templates-btn"]');
    await page.waitForTimeout(300);
    await page.click('text=Token exchange + auth');
    await page.waitForTimeout(800);
  } catch (e) {
    results.branchLanesExample = `FAIL: ${e.message}`;
    await shot(page, 'branch-lanes-error');
  }

  try {
    log('STEP 8b: add detected variables (username/password/token_url) as attributes');
    for (const name of ['username', 'password', 'token_url']) {
      const chip = page.locator(`[data-testid="variable-chip-add-${name}"]`);
      if (await chip.count() > 0) {
        await chip.click();
        await page.waitForTimeout(200);
      }
    }
    await shot(page, 'variables-added-as-attributes');
    results.addVariablesAsAttributes = 'PASS';
  } catch (e) {
    results.addVariablesAsAttributes = `FAIL: ${e.message}`;
    await shot(page, 'add-variables-error');
  }

  try {
    // UX polish (item 3): the bottom Test panel now starts COLLAPSED (a slim bar - just its own
    // sticky toolbar: env selector / Run / last-run status chip) so the diagram/editor above get
    // the full canvas until the user expands it or clicks Run. Capture that default state, then
    // expand it explicitly before touching attributes/mocks below (Run would also auto-expand
    // it, but those need to be filled in first).
    log('STEP 8c: capture the default-collapsed test panel, then expand it');
    await shot(page, 'test-panel-collapsed-state');
    await page.click('[data-testid="policy-editor-test-panel-collapse-btn"]');
    await page.waitForTimeout(400);
    await shot(page, 'test-panel-expanded');
    results.expandTestPanel = 'PASS';
  } catch (e) {
    results.expandTestPanel = `FAIL: ${e.message}`;
    await shot(page, 'expand-test-panel-error');
  }

  try {
    log('STEP 9: fill attribute values (username/password/token_url)');
    const fillAttr = async (name, value) => {
      const loc = page.locator(`[data-testid="test-panel-attr-${name}"] input`).first();
      await loc.scrollIntoViewIfNeeded();
      await loc.fill(value);
    };
    await fillAttr('username', 'testuser');
    await fillAttr('password', 'testpass');
    await fillAttr('token_url', 'https://idp.example.com/token');
    await shot(page, 'attributes-filled');
    results.fillAttributes = 'PASS';
  } catch (e) {
    results.fillAttributes = `FAIL: ${e.message}`;
    await shot(page, 'fill-attributes-error');
  }

  try {
    log('STEP 10: add mock for token URL, status 200');
    // Mocks accordion is collapsed by default - expand it first
    await page.click('text=Mocks');
    await page.waitForTimeout(300);
    await page.click('[data-testid="test-panel-add-mock"]');
    await page.waitForTimeout(300);
    const mockUrlField = page.locator('[data-testid="test-panel-mock-url-0"] input').first();
    await mockUrlField.fill('https://idp.example.com/token*');
    const mockStatusField = page.locator('[data-testid="test-panel-mock-status-0"] input').first();
    await mockStatusField.fill('200');
    // Response body field has no data-testid; find by label text within the mock card
    const mockCard = page.locator('[data-testid="test-panel-mock-0"]');
    const bodyField = mockCard.getByLabel(/Response body/i);
    await bodyField.fill('{"access_token":"abc"}');
    await shot(page, 'mock-configured-200');
    // Close-up of the redesigned two-row mock card (URL/match-type/method, then
    // status/delay/content-type/delete) - crop to the card's bounding box.
    const mockCardBox = await mockCard.boundingBox();
    if (mockCardBox) {
      shotIndex += 1;
      const cropFile = path.join(SCREEN_DIR, `${String(shotIndex).padStart(2, '0')}-mock-card-closeup.png`);
      await page.screenshot({
        path: cropFile,
        clip: {
          x: mockCardBox.x, y: mockCardBox.y, width: mockCardBox.width, height: mockCardBox.height,
        },
      });
      log('SCREENSHOT', cropFile);
    }
    results.addMock200 = 'PASS';
  } catch (e) {
    results.addMock200 = `FAIL: ${e.message}`;
    await shot(page, 'add-mock-200-error');
  }

  try {
    log('STEP 11: run test (expect COMPLETED)');
    const runBtn = page.locator('[data-testid="test-panel-run-btn"]');
    log('run button disabled?', await runBtn.isDisabled());
    await runBtn.click();
    await page.waitForSelector(
      '[data-testid="test-results-status-COMPLETED"], [data-testid="test-results-status-FAULT"], [data-testid="test-results-status-ERROR"], [data-testid="test-results-status-TIMEOUT"], [data-testid="test-results-error"]',
      { timeout: 30000 },
    );
    const panelText = await page.locator('[data-testid="test-panel"]').innerText();
    log('TEST PANEL TEXT (200 run):', panelText.slice(0, 2000));
    await shot(page, 'test-result-200');
    const completedVisible = await page.locator('[data-testid="test-results-status-COMPLETED"]').count();
    results.runTest200 = completedVisible > 0 ? 'PASS (COMPLETED)' : 'FAIL (not COMPLETED)';
  } catch (e) {
    results.runTest200 = `FAIL: ${e.message}`;
    await shot(page, 'run-test-200-error');
  }

  try {
    log('STEP 11b: assert the diagram trace overlay shows executed nodes (Issue 6)');
    const executedCount = await page.locator('[data-testid$="-executed"]').count();
    log('executed trace node count (200 run) =', executedCount);
    await shot(page, 'diagram-trace-overlay-200');
    results.traceOverlay200 = executedCount > 0 ? `PASS (${executedCount} executed nodes)` : 'FAIL (no executed nodes marked)';
  } catch (e) {
    results.traceOverlay200 = `FAIL: ${e.message}`;
  }

  try {
    log('STEP 12: change mock status to 401, run again (expect FAULT)');
    const mockStatusField = page.locator('[data-testid="test-panel-mock-status-0"] input').first();
    await mockStatusField.fill('401');
    await shot(page, 'mock-configured-401');
    await page.click('[data-testid="test-panel-run-btn"]');
    await page.waitForSelector(
      '[data-testid="test-results-status-COMPLETED"], [data-testid="test-results-status-FAULT"], [data-testid="test-results-status-ERROR"], [data-testid="test-results-status-TIMEOUT"], [data-testid="test-results-error"]',
      { timeout: 30000 },
    );
    await shot(page, 'test-result-401');
    const faultVisible = await page.locator('[data-testid="test-results-status-FAULT"]').count();
    results.runTest401 = faultVisible > 0 ? 'PASS (FAULT)' : 'FAIL (not FAULT)';
    if (faultVisible > 0) {
      const faultText = await page.locator('[data-testid="test-results-status-FAULT"]').innerText();
      log('FAULT banner text:', faultText);
      // Contract: a <call blocking="true"> mock returning 401 must fault at the call's nodeId (10)
      // - the sandbox must not pretend the flow continued past it (sandbox-contract.md).
      results.faultMentionsNode10 = /node 10\b|\b10\)/.test(faultText) ? 'PASS' : `FAIL (banner: ${faultText})`;
    } else {
      results.faultMentionsNode10 = 'FAIL (no FAULT banner to check)';
    }
  } catch (e) {
    results.runTest401 = `FAIL: ${e.message}`;
    await shot(page, 'run-test-401-error');
  }

  try {
    log('STEP 12b: assert the diagram trace overlay for the 401/FAULT run');
    const executedCount = await page.locator('[data-testid$="-executed"]').count();
    log('executed trace node count (401 run) =', executedCount);
    await shot(page, 'diagram-trace-overlay-401');
    results.traceOverlay401 = executedCount > 0 ? `PASS (${executedCount} executed nodes)` : 'FAIL (no executed nodes marked)';
  } catch (e) {
    results.traceOverlay401 = `FAIL: ${e.message}`;
  }

  try {
    log('STEP 13: close workspace and save policy');
    await page.click('[aria-label="close-policy-editor-workspace"]');
    await page.waitForTimeout(500);
    await shot(page, 'workspace-closed');
    await page.click('[data-testid="policy-create-save-btn"]');
    await page.waitForTimeout(3000);
    await shot(page, 'after-save');
    results.savePolicy = 'PASS (clicked save)';
  } catch (e) {
    results.savePolicy = `FAIL: ${e.message}`;
    await shot(page, 'save-policy-error');
  }

  try {
    log('STEP 14: verify policy appears in list (increase page size, then scan)');
    await page.goto('https://localhost:9443/publisher/policies', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(1500);
    // Bump "Rows per page" to the max option so our newly-created policy (near the end
    // alphabetically) is included on a single page.
    try {
      await page.locator('text=Rows per page:').locator('..').locator('div[role="combobox"], select').first().click();
      await page.waitForTimeout(300);
      const options = page.locator('li[role="option"], option');
      const count = await options.count();
      if (count > 0) {
        await options.last().click();
        await page.waitForTimeout(1000);
      }
    } catch (e) {
      log('rows-per-page change failed (non-fatal):', e.message);
    }
    await shot(page, 'policies-list-full-page');
    let found = await page.locator(`text=${policyName}`).count();
    if (found === 0) {
      // Paginate forward looking for it, up to 10 pages
      for (let i = 0; i < 10 && found === 0; i += 1) {
        const nextBtn = page.locator('button[aria-label="Go to next page"], button:has-text(">")').last();
        if (await nextBtn.isEnabled().catch(() => false)) {
          await nextBtn.click();
          await page.waitForTimeout(800);
          found = await page.locator(`text=${policyName}`).count();
        } else {
          break;
        }
      }
    }
    await shot(page, 'policies-list-searched');
    results.verifyInList = found > 0 ? 'PASS' : 'FAIL (not found in list)';
  } catch (e) {
    results.verifyInList = `FAIL: ${e.message}`;
    await shot(page, 'verify-list-error');
  }

  await browser.close();

  // Issue 6: clean up the test policy this run created, via REST (DCR + password grant), so
  // repeated smoke runs don't pile up SmokeTestPolicy<timestamp> entries in the CP's policy list.
  try {
    log('CLEANUP: deleting the smoke-test policy via REST');
    const cleanup = await cleanupSmokeTestPolicy(policyName);
    results.cleanup = cleanup;
  } catch (e) {
    results.cleanup = `FAIL: ${e.message}`;
  }

  results.badResponses = badResponses;
  console.log('\n=== SMOKE TEST RESULTS ===');
  console.log(JSON.stringify(results, null, 2));
  fs.writeFileSync(path.join(__dirname, 'results.json'), JSON.stringify(results, null, 2));
})();

/**
 * Issue 6: after the browser-driven part of the smoke test finishes, delete the
 * `SmokeTestPolicy<timestamp>` common operation policy it created, via the publisher v4 REST API -
 * DCR (client-registration) + password grant for a short-lived admin token scoped to
 * `apim:common_operation_policy_manage`, then `DELETE /operation-policies/{id}`. Token/DCR
 * artifacts are written to disk only transiently and removed again at the end, per the task's
 * "delete token files afterwards" instruction.
 * @param {string} policyNameToDelete The policy display/name to look up and delete
 * @returns {Promise<string>} A PASS/FAIL summary string
 */
async function cleanupSmokeTestPolicy(policyNameToDelete) {
  const CP_HOST = 'localhost';
  const CP_PORT = 9443;
  const dcrFile = path.join(__dirname, `.cleanup-dcr-${Date.now()}.json`);
  const tokenFile = path.join(__dirname, `.cleanup-token-${Date.now()}.json`);

  function requestJson(options, body) {
    return new Promise((resolve, reject) => {
      const req = https.request({ ...options, host: CP_HOST, port: CP_PORT, rejectUnauthorized: false }, (res) => {
        let data = '';
        res.on('data', (chunk) => { data += chunk; });
        res.on('end', () => {
          let parsed = null;
          try { parsed = data ? JSON.parse(data) : null; } catch (e) { parsed = data; }
          resolve({ status: res.statusCode, body: parsed });
        });
      });
      req.on('error', reject);
      if (body) req.write(body);
      req.end();
    });
  }

  try {
    // 1. DCR: register a throwaway client for the password grant.
    const dcrBody = JSON.stringify({
      clientName: `policy-editor-smoke-cleanup-${Date.now()}`,
      owner: 'admin',
      grantType: 'password refresh_token',
      saasApp: true,
    });
    const dcrAuth = Buffer.from('admin:admin').toString('base64');
    const dcrRes = await requestJson({
      path: '/client-registration/v0.17/register',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(dcrBody),
        Authorization: `Basic ${dcrAuth}`,
      },
    }, dcrBody);
    fs.writeFileSync(dcrFile, JSON.stringify(dcrRes.body, null, 2));
    if (dcrRes.status >= 300 || !dcrRes.body || !dcrRes.body.clientId) {
      return `FAIL (DCR failed: ${dcrRes.status} ${JSON.stringify(dcrRes.body)})`;
    }

    // 2. Password grant token, scoped to apim:common_operation_policy_manage.
    const tokenAuth = Buffer.from(`${dcrRes.body.clientId}:${dcrRes.body.clientSecret}`).toString('base64');
    const tokenBody = 'grant_type=password&username=admin&password=admin'
      + '&scope=apim%3Acommon_operation_policy_manage';
    const tokenRes = await requestJson({
      path: '/oauth2/token',
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Content-Length': Buffer.byteLength(tokenBody),
        Authorization: `Basic ${tokenAuth}`,
      },
    }, tokenBody);
    fs.writeFileSync(tokenFile, JSON.stringify(tokenRes.body, null, 2));
    if (tokenRes.status >= 300 || !tokenRes.body || !tokenRes.body.access_token) {
      return `FAIL (token grant failed: ${tokenRes.status} ${JSON.stringify(tokenRes.body)})`;
    }
    const accessToken = tokenRes.body.access_token;

    // 3. Find the policy by name, then delete it. This list endpoint has no server-side name
    // filter (a `query` param returns 404 "API Policy Not Found"), so fetch the (common) policy
    // list and filter client-side - SmokeTestPolicy<timestamp> sorts near the end, well within
    // one page at limit=500.
    const listRes = await requestJson({
      path: '/api/am/publisher/v4/operation-policies?limit=500',
      method: 'GET',
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    const match = listRes.body && Array.isArray(listRes.body.list)
      ? listRes.body.list.find((p) => p.name === policyNameToDelete || p.displayName === policyNameToDelete)
      : null;
    if (!match) {
      return `FAIL (policy "${policyNameToDelete}" not found via GET /operation-policies: `
        + `${listRes.status} ${JSON.stringify(listRes.body).slice(0, 500)})`;
    }

    const deleteRes = await requestJson({
      path: `/api/am/publisher/v4/operation-policies/${match.id}`,
      method: 'DELETE',
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    const outcome = (deleteRes.status >= 200 && deleteRes.status < 300)
      ? `PASS (deleted policy id=${match.id})`
      : `FAIL (delete returned ${deleteRes.status}: ${JSON.stringify(deleteRes.body)})`;
    return outcome;
  } finally {
    // Always remove the transient DCR/token files, whether cleanup succeeded or not.
    [dcrFile, tokenFile].forEach((f) => {
      try {
        if (fs.existsSync(f)) fs.unlinkSync(f);
      } catch (e) {
        log('WARN: failed to delete cleanup artifact', f, e.message);
      }
    });
  }
}
