// Explicit synthetic measurement helper. No external packages, user profile,
// operational DB credentials, game assets or production editor modifications.
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const readline = require('node:readline');
const assert = require('node:assert/strict');
const edge = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
function validate(input) {
  const url = new URL(input.address);
  assert.equal(url.protocol, 'http:'); assert.equal(url.hostname, '127.0.0.1');
  assert.ok(url.port && !url.username && !url.password && url.pathname === '/' && !url.search && !url.hash);
  assert.equal(typeof input.code, 'string'); assert.ok(input.code.length > 0);
  assert.ok(Array.isArray(input.accountUids) && [1, 10].includes(input.accountUids.length));
  assert.equal(new Set(input.accountUids).size, input.accountUids.length);
  assert.ok(input.accountUids.every(uid => /^[0-9a-f-]{36}$/.test(uid)));
}
class Cdp {
  constructor(socket) {
    this.socket = socket; this.next = 0; this.pending = new Map(); this.events = [];
    socket.addEventListener('message', event => {
      const item = JSON.parse(event.data);
      if (item.id) {
        const pending = this.pending.get(item.id); this.pending.delete(item.id);
        if (pending) { clearTimeout(pending.timer); item.error ? pending.reject(new Error('cdp_rejected')) : pending.resolve(item.result); }
      } else { for (const listener of this.events) listener(item); }
    });
  }
  send(method, params = {}, sessionId) {
    return new Promise((resolve, reject) => {
      const id = ++this.next;
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error('cdp_timeout')); }, 45000);
      this.pending.set(id, { resolve, reject, timer });
      this.socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    });
  }
  close() {
    this.socket.close();
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(new Error('cdp_closed')); }
    this.pending.clear();
  }
}
async function measure() {
  const lines = readline.createInterface({ input: process.stdin, crlfDelay: Infinity })[Symbol.asyncIterator]();
  const input = JSON.parse((await lines.next()).value); validate(input);
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'nll-editor-dom-'));
  let browser, cdp, stage = 'browser_start', result = { status: 'failed', cleanupVerified: false };
  try {
    const edgeSha256 = crypto.createHash('sha256').update(await fs.readFile(edge)).digest('hex');
    browser = spawn(edge, ['--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
      '--disable-background-networking', '--disable-component-update', '--disable-sync', '--disable-extensions',
      '--disable-features=MediaRouter', '--window-size=1280,900', '--remote-debugging-port=0',
      '--remote-debugging-address=127.0.0.1', '--proxy-server=http://127.0.0.1:9',
      '--proxy-bypass-list=127.0.0.1;localhost', `--user-data-dir=${root}`, 'about:blank'],
    { stdio: 'ignore', windowsHide: true });
    let spawnFailed = false; browser.on('error', () => { spawnFailed = true; });
    let portInfo;
    const deadline = Date.now() + 20000;
    while (!portInfo && Date.now() < deadline && !spawnFailed && browser.exitCode === null) {
      try { portInfo = (await fs.readFile(path.join(root, 'DevToolsActivePort'), 'utf8')).trim().split(/\r?\n/); }
      catch { await delay(50); }
    }
    assert.ok(portInfo && /^\d+$/.test(portInfo[0]) && portInfo[1].startsWith('/devtools/browser/'));
    const socket = new WebSocket(`ws://127.0.0.1:${portInfo[0]}${portInfo[1]}`);
    await Promise.race([new Promise((resolve, reject) => { socket.addEventListener('open', resolve, { once: true });
      socket.addEventListener('error', reject, { once: true }); }), delay(5000).then(() => { throw new Error('socket_timeout'); })]);
    cdp = new Cdp(socket);
    stage = 'cdp_setup';
    const version = await cdp.send('Browser.getVersion');
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    const send = (method, params) => cdp.send(method, params, sessionId);
    const responses = []; let blocked = 0;
    cdp.events.push(event => {
      if (event.sessionId !== sessionId) return;
      if (event.method === 'Fetch.requestPaused') {
        const url = event.params.request.url;
        const allowed = new URL(url).origin === input.address;
        if (!allowed) blocked++;
        void send(allowed ? 'Fetch.continueRequest' : 'Fetch.failRequest', {
          requestId: event.params.requestId, ...(!allowed ? { errorReason: 'BlockedByClient' } : {})
        }).catch(() => {});
      }
      if (event.method === 'Network.responseReceived' && event.params.response.url.includes('/admin-api/v1/accounts'))
        responses.push(event.params.response.status);
    });
    await send('Network.enable'); await send('Page.enable'); await send('Runtime.enable');
    await send('Fetch.enable', { patterns: [{ urlPattern: '*', requestStage: 'Request' }] });
    stage = 'editor_navigation';
    await send('Page.navigate', { url: `${input.address}/editor/` });
    const evaluate = async expression => {
      const response = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
      if (response.exceptionDetails) {
        const code = /Error: (editor_not_ready|bootstrap_failed|dom_timeout|dom_content_mismatch|dom_hidden|resource_graph_mismatch)/
          .exec(response.exceptionDetails.exception?.description || '');
        if (code) stage = code[1];
        throw new Error('page_evaluation_failed');
      }
      return response.result.value;
    };
    await evaluate(`new Promise((resolve, reject) => {
      const deadline = Date.now()+10000;
      const poll=()=>document.querySelector('#refresh-accounts') && document.readyState==='complete' ? resolve(true) :
        Date.now()>deadline ? reject(new Error('editor_not_ready')) : setTimeout(poll,20); poll(); })`);
    stage = 'bootstrap';
    assert.equal(await evaluate(`(async()=>{
      const response=await fetch('/admin-auth/v1/bootstrap',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({code:${JSON.stringify(input.code)}})});
      if(!response.ok) throw new Error('bootstrap_failed');
      document.querySelector('#app-shell').inert=false;
      document.querySelector('#refresh-accounts').disabled=false; return true; })()`), true);
    input.code = null;
    assert.equal(responses.length, 0);
    process.stdout.write('READY\n'); assert.equal((await lines.next()).value, 'GO');
    stage = 'editor_read';
    const observation = await evaluate(`new Promise((resolve,reject)=>{
      const expected=${JSON.stringify(input.accountUids)}.sort();
      const list=document.querySelector('#account-list'); performance.clearResourceTimings();
      const started=performance.now();
      const timer=setTimeout(()=>{observer.disconnect();reject(new Error('dom_timeout'));},30000);
      const observer=new MutationObserver(()=>{
        const buttons=[...list.querySelectorAll('button[data-account-uid]')];
        if(buttons.length!==expected.length) return;
        observer.disconnect();
        const domMs=performance.now()-started;
        requestAnimationFrame(()=>requestAnimationFrame(()=>{
          clearTimeout(timer);
          const ids=buttons.map(button=>button.dataset.accountUid).sort();
          if(JSON.stringify(ids)!==JSON.stringify(expected) || buttons.some(button=>button.querySelector('.account-level strong')?.textContent!=='100'))
            return reject(new Error('dom_content_mismatch'));
          if(list.getBoundingClientRect().width<=0 || getComputedStyle(list).visibility==='hidden') return reject(new Error('dom_hidden'));
          const reads=performance.getEntriesByType('resource').filter(entry=>new URL(entry.name).pathname.startsWith('/admin-api/v1/accounts'));
          if(reads.length!==1+expected.length) return reject(new Error('resource_graph_mismatch'));
          const httpMs=Math.max(...reads.map(entry=>entry.responseEnd))-started;
          resolve({accounts:expected.length, httpRequests:reads.length, httpCompleteMs:httpMs, domMutationMs:domMs,
            twoAnimationFramesMs:performance.now()-started, httpToDomMs:domMs-httpMs});
        }));
      });
      observer.observe(list,{childList:true,subtree:true}); document.querySelector('#refresh-accounts').click();
    })`);
    stage = 'network_validation';
    assert.equal(responses.length, 1 + input.accountUids.length); assert.ok(responses.every(status => status === 200));
    assert.equal(blocked, 0);
    for (const key of ['httpCompleteMs', 'domMutationMs', 'twoAnimationFramesMs']) assert.ok(Number.isFinite(observation[key]) && observation[key] >= 0);
    assert.ok(observation.domMutationMs >= observation.httpCompleteMs && observation.twoAnimationFramesMs >= observation.domMutationMs);
    result = { status: 'passed', ...observation, browserVersion: version.product, edgeSha256,
      boundary: 'real editor refresh handler; ResourceTiming responseEnd / MutationObserver / two rAF callbacks; not compositor paint or WebView2 timing' };
  } catch { result = { status: 'failed', failureStage: stage, cleanupVerified: false }; }
  finally {
    // Browser.close closes this isolated profile's full tree, not the user's browser.
    if (cdp) { try { await cdp.send('Browser.close'); } catch {} cdp.close(); }
    if (browser?.pid && browser.exitCode === null) {
      try { await Promise.race([once(browser, 'exit'), delay(10000).then(() => { throw new Error('browser_exit_timeout'); })]); }
      catch { /* Parent kills its own Node/browser tree and records cleanup unproven. */ }
    }
    const stopped = !browser?.pid || browser.exitCode !== null;
    if (stopped) {
      assert.equal(path.dirname(root), os.tmpdir()); assert.ok(path.basename(root).startsWith('nll-editor-dom-'));
      try { await fs.rm(root, { recursive: true, force: false, maxRetries: 10, retryDelay: 100 }); result.cleanupVerified = true; }
      catch { result.cleanupVerified = false; }
    }
  }
  process.stdout.write(JSON.stringify(result)+'\n');
  process.exitCode = result.status === 'passed' && result.cleanupVerified ? 0 : 1;
  // Closing readline prevents a successful helper from waiting on parent stdin.
  process.stdin.destroy();
}
if (process.argv.includes('--self-test')) {
  const input = {address:'http://127.0.0.1:1234',code:'synthetic',accountUids:['11111111-1111-4111-8111-111111111111']};
  validate(input);
  for (const address of ['https://127.0.0.1:1234','http://localhost:1234','http://example.com','http://127.0.0.1:1234/path','http://user@127.0.0.1:1234'])
    assert.throws(()=>validate({...input,address}));
  assert.throws(()=>validate({...input,accountUids:[]}));
  console.log('Editor DOM helper: loopback/input guard checks passed; no browser launched.');
} else {
  const watchdog = setTimeout(()=>{ process.stderr.write('dom_watchdog_timeout\n'); process.exitCode=1; },80000);
  measure().catch(()=>{process.exitCode=1;process.stdin.destroy();}).finally(()=>clearTimeout(watchdog));
}
