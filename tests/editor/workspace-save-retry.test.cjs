// Synthetic DOM + transport tests: execute the real editor script, never a game runtime.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { randomUUID } = require('node:crypto');
const script = fs.readFileSync(path.join(__dirname, '../../src/NikkeLocalLab.Admin.Api/wwwroot/editor/editor.js'), 'utf8');
const bossScript = fs.readFileSync(path.join(__dirname, '../../src/NikkeLocalLab.Admin.Api/wwwroot/editor/boss-seasons.js'), 'utf8');
const validationScript = fs.readFileSync(path.join(__dirname, '../../src/NikkeLocalLab.Admin.Api/wwwroot/editor/user-validation.js'), 'utf8');
function editor() {
  const elements = new Map();
  const element = () => ({ _value: '', get value() { return this._value; }, set value(value) { this._value = String(value); },
    disabled: false, hidden: false, dataset: {}, children: [], style: {},
    textContent: '', listeners: {}, addEventListener(name, callback) { this.listeners[name] = callback; }, setAttribute() {},
    appendChild(child) { this.children.push(child); }, replaceChildren() { this.children = []; },
    append(...children) { this.children.push(...children); }, prepend(child) { this.children.unshift(child); }, querySelector() { return null; },
    querySelectorAll() { return []; }, classList: { add() {}, remove() {}, toggle() {} } });
  const byId = id => { if (!elements.has(id)) elements.set(id, element()); return elements.get(id); };
  const tabs = ['home', 'account', 'raid', 'advanced'].map(name => ({ ...element(), dataset: { tabPanel: name }, inert: false }));
  const context = vm.createContext({ document: { getElementById: byId, createElement: element,
    querySelectorAll: selector => selector === '.tab-panel' ? tabs : [] },
    window: { prompt: () => 'copy', confirm: () => true }, crypto: { randomUUID }, Headers, setTimeout, clearTimeout, console });
  vm.runInContext(bossScript + '\n' + validationScript + '\n' + script, context);
  vm.runInContext(`
    const realLoadAccount = loadAccount;
    const realQueueAccountProfileEdits = queueAccountProfileEdits;
    const realRenderEditOperations = renderEditOperations;
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

test('loading mixed stored levels, syncing the catalog and preparing Save leave no level edits', async () => {
  const ui = editor();
  ui.byId('account-uid').value = 'account-a';
  ui.run(`
    const mixedProfile = {characterCatalog:{}, combatSupportCatalog:{}, values:[
      {fieldCode:'synchro_level',subjectUid:null,integerValue:782},
      {fieldCode:'character_level',subjectUid:'a',integerValue:782},
      ...Array.from({length:88},(_,i)=>({fieldCode:'character_level',subjectUid:'low-'+i,integerValue:1}))]};
    refreshWorkspaceSaveRecovery = async () => {};
    renderWorkspaceSaveRecovery = () => {};
    renderAccounts = () => {}; renderProgression = () => {}; updateRaidActions = () => {};
    renderAccountSummary = () => {}; loadLocalState = async () => {};
    api = async url => {
      if(url.endsWith('/profile')) return {payload:mixedProfile,etag:'profile-current'};
      if(url.endsWith('/workspace')) return {payload:{accountLabel:'synthetic',validationStatusCode:'ready'}};
      if(url.endsWith('/fetched-snapshots/latest')) throw new Error('fetched_snapshot_observation_not_found');
      if(url.endsWith('/characters/sync')) return {payload:{statusCode:'unchanged'}};
      throw new Error('unexpected test request');
    };
    loadPresentationCatalog = async () => {};
    renderEditOperations = realRenderEditOperations;
  `);
  await ui.run('realLoadAccount()');
  assert.equal(ui.run('state.editOperations.length'), 0);
  assert.equal(ui.byId('pending-edit-count').textContent, '변경 0건');
  assert.equal(ui.run('configuredSynchroLevel()'), 782);
  assert.equal(ui.run('synchronizedLevelEditor("low-0").children[0].value'), '782');
  await ui.run('syncCharacters()');
  ui.run('realQueueAccountProfileEdits()');
  assert.equal(ui.run('state.editOperations.length'), 0);
  assert.equal(ui.run('profileValues("character_level","low-0")[0].integerValue'), 1);
  ui.run('queueIntegerValue("skill_1_level","a","7",1); realQueueAccountProfileEdits()');
  assert.equal(ui.run('state.editOperations.length'), 1);
  assert.equal(ui.run('state.editOperations[0].fieldCode'), 'skill_1_level');
});

test('explicit synchro changes are reversible and clearing edits does not regenerate them', () => {
  const ui = editor();
  ui.run(`state.currentProfile={values:[
    {fieldCode:'synchro_level',subjectUid:null,integerValue:782},
    {fieldCode:'character_level',subjectUid:'a',integerValue:1},
    {fieldCode:'character_level',subjectUid:'b',integerValue:782}]};
    queueIntegerValue('skill_1_level','a','7',1);
    queueIntegerValue('character_level','a','10',1);`);
  ui.byId('general-synchro').value = '800';
  ui.byId('general-synchro').listeners.change();
  assert.equal(ui.run('state.editOperations.length'), 4);
  assert.equal(ui.run('effectiveProfileValue("character_level","a").integerValue'), 800);
  ui.run('realQueueAccountProfileEdits()');
  assert.equal(ui.run('state.editOperations.length'), 4);
  ui.byId('general-synchro').value = '782';
  ui.byId('general-synchro').listeners.change();
  assert.equal(ui.run('state.editOperations.length'), 2);
  assert.equal(ui.run('effectiveProfileValue("character_level","a").integerValue'), 10);
  ui.byId('general-synchro').value = '900';
  ui.byId('general-synchro').listeners.change();
  ui.run('clearEditOperations(); realQueueAccountProfileEdits()');
  assert.equal(ui.byId('general-synchro').value, '782');
  assert.equal(ui.run('state.editOperations.length'), 0);
  assert.equal(ui.run('effectiveProfileValue("character_level","a").integerValue'), 1);
});

test('own all adds only missing characters across filters, preserves edits and clears without saving', () => {
  const ui = editor();
  for (const id of ['nikke-filter-burst', 'nikke-filter-manufacturer', 'nikke-filter-class', 'nikke-filter-element']) ui.byId(id).value = 'all';
  ui.byId('general-synchro').value = '200';
  ui.run(`
    state.currentProfile = { values: [{ fieldCode: 'character_level', subjectUid: 'a', integerValue: 200 }] };
    state.presentation.characters = ['a', 'b', 'c'].map(characterUid => ({ characterUid, displayName: characterUid }));
    state.presentationByCharacter = new Map(state.presentation.characters.map(item => [item.characterUid, item]));
    state.editOperations = [{fieldCode:'skill_1_level', subjectUid:'a', valueKind:'integer', integerValue:7}];
  `);
  ui.byId('nikke-search').value = 'a';
  ui.run('ownAllNikkes()');
  assert.equal(ui.run('state.editOperations.length'), 3);
  assert.equal(ui.run('state.editOperations.find(item => item.subjectUid === "a").integerValue'), 7);
  assert.equal(ui.run('state.currentProfile.values.length'), 1);
  assert.equal(ui.byId('own-all-nikkes').disabled, true);
  assert.equal(ui.byId('nikke-count').textContent, '보유 1 / 전체 1');
  ui.run('ownAllNikkes()');
  assert.equal(ui.run('state.editOperations.length'), 3);
  ui.byId('nikke-search').value = '';
  ui.run('renderNikkeCards()');
  assert.equal(ui.byId('nikke-count').textContent, '보유 3 / 전체 3');
  ui.run('clearEditOperations()');
  assert.equal(ui.byId('nikke-count').textContent, '보유 1 / 전체 3');
  assert.equal(ui.byId('own-all-nikkes').disabled, false);
  ui.run('state.workspaceSaveBusy = true; ownAllNikkes()');
  assert.equal(ui.run('state.editOperations.length'), 0);
});

test('season sync uses the real editor transport with JSON and CSRF', async () => {
  const ui = editor(); const requests = [];
  ui.run("state.csrf = 'synthetic-csrf'");
  ui.context.fetch = async (url, options) => {
    requests.push({ url, options });
    assert.equal(options.headers.get('Content-Type'), 'application/json');
    assert.equal(options.headers.get('X-NLL-CSRF'), 'synthetic-csrf');
    assert.deepEqual(JSON.parse(options.body), {});
    assert.equal(options.credentials, 'same-origin');
    return new Response(JSON.stringify({ statusCode: 'unchanged', addedSeasonCount: 0 }),
      { headers: { 'Content-Type': 'application/json' } });
  };
  await ui.run('bossSeasons.syncCatalog()');
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, '/admin-api/v1/boss-seasons/sync');
  assert.equal(requests[0].options.method, 'POST');
  assert.match(ui.byId('boss-season-sync-status').textContent, /동기화 완료/);
});

test('character sync refreshes metadata without owning characters or losing edits and pins ownership save', async () => {
  const ui = editor(); const requests = [];
  for (const id of ['nikke-filter-burst', 'nikke-filter-manufacturer', 'nikke-filter-class', 'nikke-filter-element']) ui.byId(id).value = 'all';
  ui.run(`state.csrf = 'synthetic-csrf'; state.currentProfile = {characterCatalog:{catalogSnapshotUid:'old'},
    values:[{fieldCode:'character_level',subjectUid:'a',integerValue:200}]};
    state.editOperations = [{fieldCode:'skill_1_level',subjectUid:'a',valueKind:'integer',integerValue:7}];`);
  ui.context.fetch = async (url, options) => {
    requests.push({url, options});
    if (url.endsWith('/characters/sync')) {
      assert.equal(options.headers.get('X-NLL-CSRF'), 'synthetic-csrf');
      assert.equal(options.headers.get('Content-Type'), 'application/json');
      assert.deepEqual(JSON.parse(options.body), {});
      return new Response(JSON.stringify({statusCode:'updated',addedCharacterCount:1}), {headers:{'Content-Type':'application/json'}});
    }
    return new Response(JSON.stringify({contractId:'nll/control-center-presentation/v1',characterCatalogUid:'new',
      characters:['a','b'].map(characterUid => ({characterUid,displayName:characterUid}))}));
  };
  await ui.run('syncCharacters()');
  assert.equal(requests.length, 2);
  assert.equal(ui.run('state.presentation.characters.length'), 2);
  assert.equal(ui.run('state.editOperations.length'), 1);
  assert.equal(ui.run('ownedNikkeSubjects().has("b")'), false);
  ui.run('ownAllNikkes()');
  assert.equal(ui.run('state.editOperations.find(row=>row.fieldCode==="character_catalog").referenceUid'), 'new');
  assert.equal(ui.run('state.editOperations.find(row=>row.fieldCode==="skill_1_level").integerValue'), 7);
  assert.equal(ui.run('ownedNikkeSubjects().has("b")'), true);
  assert.equal(ui.byId('sync-characters').disabled, false);
});

test('failed character sync keeps the current catalog and edits', async () => {
  const ui = editor();
  ui.run(`state.csrf='synthetic'; state.presentation.characters=[{characterUid:'old'}];`);
  ui.context.fetch = async () => new Response(JSON.stringify({statusCode:'failed',failureCode:'character_catalog_sync_failed'}));
  await ui.run('syncCharacters()');
  assert.equal(ui.run('state.presentation.characters[0].characterUid'), 'old');
  assert.equal(ui.byId('sync-characters').disabled, false);
});

test('synchronized character is selectable in details immediately without a workspace save', async () => {
  const ui = editor(); const requests = [];
  const select = ui.byId('nikke-subject');
  let selected = '';
  // A real HTML select rejects values absent from its options. A plain value
  // property hid the stale-options bug in the original sync test.
  Object.defineProperty(select, 'value', {
    get: () => selected,
    set: value => { selected = select.children.some(option => option.value === value) ? value : ''; }
  });
  for (const id of ['nikke-filter-burst', 'nikke-filter-manufacturer', 'nikke-filter-class', 'nikke-filter-element']) ui.byId(id).value = 'all';
  ui.run(`state.csrf='synthetic'; state.currentProfile={values:[]};
    state.presentation.characters=[{characterUid:'old',displayName:'기존 니케'}];
    state.presentationByCharacter=new Map(state.presentation.characters.map(row=>[row.characterUid,row]));
    state.editOperations=[{fieldCode:'commander_level',subjectUid:null,valueKind:'integer',integerValue:123}];
    renderNikkeEditor();`);
  select.value = 'old';
  ui.context.fetch = async (url, options) => {
    requests.push(url);
    return new Response(JSON.stringify(url.endsWith('/characters/sync')
      ? {statusCode:'updated',addedCharacterCount:1}
      : {contractId:'nll/control-center-presentation/v1',characters:[
        {characterUid:'old',displayName:'기존 니케'},
        {characterUid:'new',displayName:'새 니케',portraitPath:'/editor/assets/characters/new.png',burstStep:3,elementCode:'fire'}
      ]}));
  };
  await ui.run('syncCharacters()');
  select.value = 'new';
  assert.equal(select.value, 'new');
  ui.run('renderNikkeFields()');
  assert.equal(ui.byId('nikke-selected-name').textContent, '새 니케');
  assert.equal(ui.byId('selected-nikke-portrait').children[0].src, '/editor/assets/characters/new.png');
  assert.equal(ui.run('state.editOperations.length'), 1);
  assert.equal(ui.run('state.editOperations[0].integerValue'), 123);
  assert.deepEqual(requests, ['/admin-api/v1/characters/sync','/editor/presentation.json']);
});

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
  assert.equal(ui.byId('workspace-save-recovery-list').children.length, 0);
  assert.equal(ui.byId('workspace-save-history-list').children[0].children[1].textContent, '완료 기록 확인');
});

test('busy save stays quiet with completed history while duplicate edits remain blocked', async () => {
  const ui = editor();
  ui.context.api = async () => ({ payload: [{ ...pending, statusCode: 'completed', recoveryCode: 'completed_receipt' }] });
  ui.run('state.workspaceSaveBusy = true;');
  await ui.run('refreshWorkspaceSaveRecovery()');
  assert.equal(ui.byId('workspace-save-recovery').hidden, true);
  assert.equal(ui.byId('workspace-save-history').hidden, false);
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
