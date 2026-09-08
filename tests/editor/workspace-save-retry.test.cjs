// Synthetic DOM + transport tests: execute the real editor script, never a game runtime.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { randomUUID } = require('node:crypto');
const script = fs.readFileSync(path.join(__dirname, '../../src/NikkeLocalLab.Admin.Api/wwwroot/editor/editor.js'), 'utf8');
function editor() {
  const elements = new Map();
  const element = () => ({ value: '', disabled: false, hidden: false, dataset: {}, children: [],
    textContent: '', listeners: {}, addEventListener(name, callback) { this.listeners[name] = callback; }, setAttribute() {},
    appendChild(child) { this.children.push(child); }, replaceChildren() { this.children = []; },
    querySelectorAll() { return []; }, classList: { add() {}, remove() {}, toggle() {} } });
  const byId = id => { if (!elements.has(id)) elements.set(id, element()); return elements.get(id); };
  const tabs = ['home', 'account', 'raid', 'advanced'].map(name => ({ ...element(), dataset: { tabPanel: name }, inert: false }));
  const context = vm.createContext({ document: { getElementById: byId, createElement: element,
    querySelectorAll: selector => selector === '.tab-panel' ? tabs : [] },
    window: { prompt: () => 'copy', confirm: () => true }, crypto: { randomUUID }, Headers, setTimeout, clearTimeout, console });
  vm.runInContext(script, context);
  vm.runInContext(`
    state.accountUid = 'account-a'; state.profileRevisionUid = 'profile-before';
    state.lobbyRevisionUid = 'lobby-before'; state.walletRevisionUid = 'wallet-before';
    state.currentWorkspace = { accountLabel: 'source', baseRevisions: { revisionSetSha256: 'workspace-before' } };
    queueAccountProfileEdits = () => {}; listAccounts = async () => {}; loadAccount = async () => {};
    invalidateEditPreview = () => {}; renderEditOperations = () => {};
  `, context);
  for (const [id, value] of Object.entries({ 'account-label': 'source', 'display-name': 'commander',
    'commander-level': '10', 'jewel-balance': '100', 'credit-balance': '200' })) byId(id).value = value;
  return { context, byId, tabs, run: code => vm.runInContext(code, context) };
}

for (const saveAs of [false, true]) test(`same-page ${saveAs ? 'Save As' : 'Save'} retry retains original request without preview`, async () => {
  const ui = editor(); let previews = 0; let posts = 0; const requests = [];
  ui.context.api = async (url, options = {}) => {
    if (url.endsWith('/profile/preview')) {
      if (++previews > 1) throw Error('account_workspace_revision_conflict');
      return { payload: { candidateDraftUid: 'candidate', candidateSha256: 'hash', diffSha256: 'diff' } };
    }
    if (url.includes('/workspace') && options.method) {
      requests.push(JSON.stringify({ url, ...options }));
      if (++posts === 1) throw Error('response_lost');
      return { payload: { accountUid: 'account-a', operationUid: options.body.operationUid } };
    }
    return { payload: [] };
  };
  await assert.rejects(ui.run(`saveEverything(${saveAs})`), /response_lost/);
  assert.equal(ui.byId('workspace-save-recovery').hidden, false);
  ui.byId('commander-level').value = '999';
  ui.byId('account-label').value = 'changed-after-error';
  await ui.run(`saveEverything(${saveAs})`);
  assert.equal(previews, 1); assert.equal(posts, 2); assert.equal(requests[0], requests[1]);
  assert.equal(ui.byId('workspace-save-recovery').hidden, true);
});

const pending = { operationUid: 'save-op', sourceAccountUid: 'account-a', saveAs: true,
  statusCode: 'pending', requestSha256: 'original-hash', createdAtUtc: '2026-09-01T00:00:00Z',
  recoveryCode: 'exact_request_available' };

test('fresh editor discovers durable Save As and explicitly resumes its source, without preview', async () => {
  const ui = editor(); const writes = [];
  ui.run("state.accountUid = 'partial-copy';");
  ui.context.item = pending;
  ui.context.api = async (url, options = {}) => {
    if (!options.method) return { payload: [pending] };
    writes.push({ url, options });
    return { payload: { accountUid: 'partial-copy', sourceAccountUid: 'account-a', operationUid: 'save-op' } };
  };
  await ui.run('refreshWorkspaceSaveRecovery()');
  assert.equal(writes.length, 0);
  assert.equal(ui.byId('workspace-save-recovery').hidden, false);
  assert.deepEqual(ui.tabs.map(tab => tab.inert), [false, true, true, true]);
  await assert.rejects(ui.run('saveEverything(false)'), /account_workspace_save_pending/);
  await ui.run('resumeWorkspaceSave(item)');
  assert.equal(writes.length, 1);
  assert.equal(writes[0].url, '/admin-api/v1/accounts/account-a/workspace/saves/resume');
  assert.equal(writes[0].options.headers['If-Match'], '"original-hash"');
  assert.equal(JSON.stringify(writes[0].options.body), '{"operationUid":"save-op"}');
});

for (const recoveryCode of ['original_request_required', 'request_invalid'])
  test(`fresh editor preserves ${recoveryCode} without enabling writes or guessing a request`, async () => {
    const ui = editor(); let writes = 0;
    ui.context.item = { ...pending, recoveryCode };
    ui.context.api = async (_, options = {}) => {
      if (options.method) writes++;
      return { payload: [ui.context.item] };
    };
    await ui.run('refreshWorkspaceSaveRecovery()');
    assert.equal(ui.byId('workspace-save-recovery').hidden, false);
    const row = ui.byId('workspace-save-recovery-list').children[0];
    assert.equal(row.children.some(child => child.type === 'button'), false);
    await assert.rejects(ui.run('resumeWorkspaceSave(item)'), /original_request_required/);
    await assert.rejects(ui.run('saveEverything(false)'), /account_workspace_save_pending/);
    assert.equal(writes, 0);
    assert.equal(ui.run('state.workspaceSaveBusy'), false);
  });

test('completed receipts remain available without showing the recovery panel or repeating a save', async () => {
  const ui = editor(); let writes = 0;
  ui.context.api = async (_, options = {}) => {
    if (options.method) writes++;
    return { payload: [{ ...pending, statusCode: 'completed', recoveryCode: 'completed_receipt', completedReceipt: {} }] };
  };
  await ui.run('refreshWorkspaceSaveRecovery()');
  assert.equal(writes, 0);
  assert.equal(ui.byId('workspace-save-recovery').hidden, true);
  assert.equal(ui.tabs.some(tab => tab.inert), false);
  assert.equal(ui.run("state.workspaceSaveRecovery.get('account-a')[0].statusCode"), 'completed');
  assert.equal(ui.byId('workspace-save-recovery-list').children[0].children[1].textContent, '완료 기록 확인');
});

test('busy save remains visible with completed history and hides when no action remains', async () => {
  const ui = editor();
  ui.context.api = async () => ({ payload: [{ ...pending, statusCode: 'completed', recoveryCode: 'completed_receipt' }] });
  ui.run('state.workspaceSaveBusy = true;');
  await ui.run('refreshWorkspaceSaveRecovery()');
  assert.equal(ui.byId('workspace-save-recovery').hidden, false);
  assert.equal(ui.tabs.every(tab => tab.inert), true);
  ui.run('state.workspaceSaveBusy = false; renderWorkspaceSaveRecovery();');
  assert.equal(ui.byId('workspace-save-recovery').hidden, true);
  assert.equal(ui.tabs.some(tab => tab.inert), false);
});

test('pending save remains visible alongside completed history until it completes', async () => {
  const ui = editor();
  let outstanding = true;
  ui.context.api = async () => ({ payload: [
    { ...pending, operationUid: 'older-save', statusCode: 'completed', recoveryCode: 'completed_receipt' },
    { ...pending, statusCode: outstanding ? 'pending' : 'completed',
      recoveryCode: outstanding ? 'exact_request_available' : 'completed_receipt' }
  ] });
  await ui.run('refreshWorkspaceSaveRecovery()');
  assert.equal(ui.byId('workspace-save-recovery').hidden, false);
  assert.deepEqual(ui.tabs.map(tab => tab.inert), [false, true, true, true]);
  outstanding = false;
  await ui.run('refreshWorkspaceSaveRecovery()');
  assert.equal(ui.byId('workspace-save-recovery').hidden, true);
  assert.equal(ui.tabs.some(tab => tab.inert), false);
  assert.equal(ui.run("state.workspaceSaveRecovery.get('account-a').length"), 2);
});

test('double click before the first read completes admits only one request', async () => {
  const ui = editor(); let release; let previews = 0; let writes = 0;
  const read = new Promise(resolve => { release = resolve; });
  ui.context.api = async (url, options = {}) => {
    if (url.endsWith('/workspace/saves')) { await read; return { payload: [] }; }
    if (url.endsWith('/profile/preview')) { previews++; return { payload: { candidateDraftUid: 'c', candidateSha256: 'h', diffSha256: 'd' } }; }
    if (options.method) writes++;
    return { payload: { accountUid: 'account-a' } };
  };
  const first = ui.run('saveEverything(false)');
  assert.equal(ui.tabs.every(tab => tab.inert), true);
  await assert.rejects(ui.run('saveEverything(false)'), /account_workspace_save_in_progress/);
  release(); await first;
  assert.equal(previews, 1); assert.equal(writes, 1);
  assert.equal(ui.run('state.workspaceSaveBusy'), false);
});

for (const readFails of [false, true])
  test(`definite rejection ${readFails ? 'retains request when discovery fails' : 'unlocks only after confirming no claim'}`, async () => {
    const ui = editor(); let reads = 0;
    ui.context.api = async (url) => {
      if (url.endsWith('/workspace/saves')) {
        if (++reads > 1 && readFails) throw Error('read_failed');
        return { payload: [] };
      }
      if (url.endsWith('/profile/preview')) return { payload: { candidateDraftUid: 'c', candidateSha256: 'h', diffSha256: 'd' } };
      throw Object.assign(Error('account_workspace_revision_conflict'), { status: 409 });
    };
    await assert.rejects(ui.run('saveEverything(false)'), /account_workspace_revision_conflict/);
    assert.equal(ui.run("state.workspaceSaveAttempts.has('account-a')"), readFails);
    assert.equal(ui.tabs[1].inert, readFails);
    assert.equal(ui.byId('workspace-save-recovery').hidden, !readFails);
  });

test('account switch preserves only its own exact retry and blocks a change of save mode', async () => {
  const ui = editor();
  ui.context.api = async (url, options = {}) => {
    if (!options.method) return { payload: [] };
    if (url.endsWith('/profile/preview')) return { payload: { candidateDraftUid: 'c', candidateSha256: 'h', diffSha256: 'd' } };
    throw Error('response_lost');
  };
  await assert.rejects(ui.run('saveEverything(true)'), /response_lost/);
  await assert.rejects(ui.run('saveEverything(false)'), /account_workspace_save_pending/);
  ui.run("state.accountUid = 'account-b'; renderWorkspaceSaveRecovery();");
  assert.equal(ui.byId('workspace-save-recovery').hidden, true);
  assert.equal(ui.tabs.some(tab => tab.inert), false);
  ui.run("state.accountUid = 'account-a'; renderWorkspaceSaveRecovery();");
  assert.equal(ui.byId('workspace-save-recovery-list').children[0].textContent, '원래 요청 다시 전송');
  assert.equal(ui.tabs[1].inert, true);
});
