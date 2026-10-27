// Orca developer tools — panel front end.
//
// Everything shown here comes from the page's agent: live events it pushes, or answers to the
// commands this file asks for. The panel keeps no independent copy of the app's state, so a reload
// simply starts from an empty back log again.
(() => {
  'use strict';

  const channelName = 'devToolsPanel';
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[channelName];
  const CONSOLE_VISIBLE_LIMIT = 800;

  const state = {
    tab: 'console',
    filter: '',
    open: false,
    pageReady: false,
    consoleEntries: [],
    requests: new Map(),
    selectedRequest: null,
    selectedPath: null,
    expandedPaths: new Set(),
    lastHighlight: null,
    storage: { area: 'local', rows: [], origin: '', selected: null, editing: null },
  };

  // MARK: - Small helpers

  const role = (name) => document.querySelector('[data-role="' + name + '"]');

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
  }

  function formatSize(bytes) {
    if (!bytes) return '';
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' kB';
    return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
  }

  function formatTime(timestamp) {
    const date = new Date(timestamp);
    const pad = (value, size) => String(value).padStart(size, '0');
    return pad(date.getHours(), 2) + ':' + pad(date.getMinutes(), 2) + ':' + pad(date.getSeconds(), 2) +
      '.' + pad(date.getMilliseconds(), 3);
  }

  function setStatus(text, live) {
    role('status').textContent = text;
    role('status-dot').dataset.live = live ? 'true' : 'false';
  }

  /// Posting a command to the shell; it answers with the page's reply to that command.
  async function call(name, args) {
    if (!handler) return null;
    try {
      return await handler.postMessage({ kind: 'command', name: name, args: args || {} });
    } catch (error) {
      setStatus(String(error && error.message || error), false);
      return null;
    }
  }

  // MARK: - Theme and visibility

  function applyTheme(theme) {
    const appearance = theme && theme.appearance === 'light' ? 'light' : 'dark';
    document.documentElement.dataset.theme = appearance;
  }

  async function setVisible(open) {
    state.open = open;
    if (open) {
      await refreshAll();
    } else {
      // The highlight is drawn inside the page; leaving it behind would put a box on the app.
      highlight(null);
    }
  }

  async function onPageReady(ready) {
    state.pageReady = ready;
    setStatus(ready ? 'Page agent connected' : 'Waiting for the page…', ready);
    if (ready && state.open) {
      await refreshAll();
    }
  }

  // MARK: - Tabs

  function selectTab(name) {
    state.tab = name;
    for (const tab of document.querySelectorAll('.tab')) {
      tab.setAttribute('aria-selected', tab.dataset.tab === name ? 'true' : 'false');
    }
    for (const page of document.querySelectorAll('.page')) {
      page.dataset.active = page.dataset.page === name ? 'true' : 'false';
    }
    applyFilter();
    if (name !== 'elements') highlight(null);
    // Console and network fill themselves from live events; the two views that are read on demand
    // are refreshed so they never show a document or a store from before the last navigation.
    if (name === 'elements') loadDomTree();
    if (name === 'storage') loadStorage();
  }

  /// Re-reads everything the panel shows; used when it opens and when a new document reports in.
  async function refreshAll() {
    if (!state.pageReady) return;
    await refreshConsole();
    await refreshNetwork();
    if (state.tab === 'elements') await loadDomTree();
    if (state.tab === 'storage') await loadStorage();
  }

  // MARK: - Console

  function consoleRow(entry) {
    const row = el('div', 'entry');
    row.dataset.level = entry.level || 'log';
    row.dataset.id = entry.id;
    row.appendChild(el('span', 'level', entry.level === 'result' ? 'return' : entry.level || 'log'));

    const values = el('div', 'values');
    for (const argument of entry.args || []) {
      values.appendChild(valueNode(argument));
    }
    row.appendChild(values);
    return row;
  }

  function valueNode(node) {
    if (!node) {
      return el('span', 'value undefined', 'undefined');
    }
    const kind = node.kind || 'object';
    const span = el('span', 'value ' + kind);
    const expandable = node.ref && (kind === 'object' || kind === 'array' || kind === 'node' || kind === 'error');

    if (expandable) {
      const toggle = el('span', 'toggle', '▸');
      toggle.addEventListener('click', () => toggleValue(toggle, node));
      span.appendChild(toggle);
    }
    span.appendChild(document.createTextNode(node.text === undefined ? '' : node.text));
    if (node.summary) {
      span.appendChild(document.createTextNode(' '));
      span.appendChild(el('span', 'summary', node.summary));
    }
    if (node.keys && node.keys.length) {
      const box = el('div', 'children');
      for (const child of node.keys) {
        box.appendChild(childRow(child));
      }
      span.appendChild(box);
    }
    return span;
  }

  function childRow(item) {
    const row = el('div', 'child');
    if (item.key !== undefined && item.key !== null && item.key !== '') {
      row.appendChild(el('span', 'key', item.key + ':'));
    }
    row.appendChild(valueNode(item));
    return row;
  }

  async function toggleValue(toggle, node) {
    const open = toggle.dataset.open === 'true';
    if (open) {
      toggle.dataset.open = 'false';
      toggle.textContent = '▸';
      const existing = toggle.parentElement.querySelector('.children');
      if (existing) existing.hidden = true;
      return;
    }
    toggle.dataset.open = 'true';
    toggle.textContent = '▾';
    let box = toggle.parentElement.querySelector('.children');
    if (box) {
      box.hidden = false;
      return;
    }
    const answer = await call('object.expand', { ref: node.ref });
    box = el('div', 'children');
    if (!answer || answer.error) {
      box.appendChild(el('div', 'child', answer && answer.error ? answer.error : 'Not available'));
    } else {
      for (const child of answer.keys || []) {
        box.appendChild(childRow(child));
      }
      if (!answer.keys || !answer.keys.length) {
        box.appendChild(el('div', 'child', '—'));
      }
    }
    toggle.parentElement.appendChild(box);
  }

  function appendConsole(entry) {
    state.consoleEntries.push(entry);
    if (state.consoleEntries.length > CONSOLE_VISIBLE_LIMIT) {
      state.consoleEntries.shift();
    }

    const log = role('console-log');
    const pinned = log.scrollHeight - log.scrollTop - log.clientHeight < 24;
    const row = consoleRow(entry);
    applyRowFilter(row);
    log.appendChild(row);
    while (log.childElementCount > CONSOLE_VISIBLE_LIMIT) {
      log.firstElementChild.remove();
    }
    if (pinned) log.scrollTop = log.scrollHeight;
    updateCount('console', state.consoleEntries.length);
  }

  function renderConsole() {
    const log = role('console-log');
    log.textContent = '';
    for (const entry of state.consoleEntries) {
      const row = consoleRow(entry);
      applyRowFilter(row);
      log.appendChild(row);
    }
    log.scrollTop = log.scrollHeight;
    updateCount('console', state.consoleEntries.length);
  }

  async function refreshConsole() {
    const answer = await call('console.backlog');
    if (!answer || !answer.entries) return;
    state.consoleEntries = answer.entries.slice();
    renderConsole();
  }

  async function evaluate(code) {
    const trimmed = code.trim();
    if (!trimmed) return;
    appendConsole({ id: 'in' + Date.now(), level: 'input', args: [{ kind: 'string', text: trimmed }] });
    const answer = await call('console.eval', { code: trimmed });
    if (!answer) return;
    if (answer.ok) {
      appendConsole({ id: 'out' + Date.now(), level: 'result', args: [answer.value] });
      return;
    }
    appendConsole({
      id: 'err' + Date.now(),
      level: 'error',
      args: [{ kind: 'error', text: answer.error.name + ': ' + answer.error.message }],
    });
  }

  // MARK: - Network

  function networkRow(record) {
    const row = el('div', 'network-row');
    row.dataset.id = record.id;

    const url = el('span', 'url');
    try {
      const parsed = new URL(record.url);
      url.appendChild(el('span', 'host', parsed.host));
      url.appendChild(document.createTextNode(parsed.pathname + parsed.search));
    } catch (error) {
      url.textContent = record.url;
    }
    row.appendChild(url);
    row.appendChild(el('span', 'method', record.method || ''));
    const status = el('span', 'status', record.status ? String(record.status) : (record.error ? 'failed' : '—'));
    if (record.error || record.status >= 400) status.dataset.bad = 'true';
    else if (record.status && record.status < 400) status.dataset.ok = 'true';
    row.appendChild(status);
    row.appendChild(el('span', 'kind', record.kind || ''));
    row.appendChild(el('span', 'size', formatSize(record.size)));
    row.appendChild(el('span', 'time', record.duration ? record.duration + ' ms' : ''));

    row.addEventListener('click', () => selectRequest(record.id));
    return row;
  }

  function upsertRequest(record) {
    if (!record || !record.id) return;
    const merged = Object.assign({}, state.requests.get(record.id) || {}, record);
    state.requests.set(record.id, merged);

    const rows = role('network-rows');
    const existing = rows.querySelector('[data-id="' + record.id + '"]');
    if (existing) {
      const fresh = networkRow(merged);
      applyRowFilter(fresh);
      existing.replaceWith(fresh);
    } else {
      const fresh = networkRow(merged);
      applyRowFilter(fresh);
      rows.appendChild(fresh);
      const list = rows.parentElement;
      const pinned = list.scrollHeight - list.scrollTop - list.clientHeight < 24;
      if (pinned) list.scrollTop = list.scrollHeight;
    }
    updateCount('network', state.requests.size);
    if (state.selectedRequest === record.id) {
      renderRequestDetail(merged);
    }
  }

  async function refreshNetwork() {
    const answer = await call('network.backlog');
    if (!answer || !answer.records) return;
    state.requests.clear();
    role('network-rows').textContent = '';
    for (const record of answer.records) {
      state.requests.set(record.id, record);
      const row = networkRow(record);
      applyRowFilter(row);
      role('network-rows').appendChild(row);
    }
    updateCount('network', state.requests.size);
    if (state.selectedRequest && state.requests.has(state.selectedRequest)) {
      renderRequestDetail(state.requests.get(state.selectedRequest));
    } else {
      state.selectedRequest = null;
      const detail = role('network-detail');
      detail.textContent = '';
      detail.appendChild(el('p', 'hint', 'Select a request to see its headers and body.'));
    }
  }

  function selectRequest(id) {
    state.selectedRequest = id;
    for (const row of document.querySelectorAll('.network-row')) {
      row.dataset.selected = row.dataset.id === id ? 'true' : 'false';
    }
    const record = state.requests.get(id);
    if (record) renderRequestDetail(record);
  }

  function renderRequestDetail(record) {
    const detail = role('network-detail');
    detail.textContent = '';

    detail.appendChild(el('h4', null, 'General'));
    const general = el('div', 'kv');
    const rows = [
      ['Request URL', record.url],
      ['Method', record.method],
      ['Status', record.status ? record.status + ' ' + (record.statusText || '') : (record.error || 'no response')],
      ['Kind', record.kind],
      ['Started', record.start ? Math.round(record.start) + ' ms after navigation' : ''],
      ['Duration', record.duration ? record.duration + ' ms' : ''],
      ['Size', formatSize(record.size)],
    ];
    for (const [key, value] of rows) {
      if (!value) continue;
      const line = el('div');
      line.appendChild(el('span', 'k', key));
      line.appendChild(el('span', 'v', String(value)));
      general.appendChild(line);
    }
    detail.appendChild(general);

    if (record.error) {
      detail.appendChild(el('h4', null, 'Error'));
      detail.appendChild(el('pre', null, record.error));
    }

    const headerSection = (title, headers) => {
      const keys = Object.keys(headers || {});
      if (!keys.length) return;
      detail.appendChild(el('h4', null, title));
      const box = el('div', 'kv');
      for (const key of keys) {
        const line = el('div');
        line.appendChild(el('span', 'k', key));
        line.appendChild(el('span', 'v', String(headers[key])));
        box.appendChild(line);
      }
      detail.appendChild(box);
    };

    headerSection('Request headers', record.requestHeaders);
    headerSection('Response headers', record.responseHeaders);

    if (record.requestBody) {
      detail.appendChild(el('h4', null, 'Request body'));
      detail.appendChild(el('pre', null, pretty(record.requestBody)));
    }
    if (record.responseBody) {
      detail.appendChild(el('h4', null, 'Response body'));
      detail.appendChild(el('pre', null, pretty(record.responseBody)));
    }
  }

  /// JSON is pretty-printed for reading; anything else is shown exactly as captured.
  function pretty(text) {
    const trimmed = String(text).trim();
    if (!trimmed || (trimmed[0] !== '{' && trimmed[0] !== '[')) return String(text);
    try {
      return JSON.stringify(JSON.parse(trimmed), null, 2);
    } catch (error) {
      return String(text);
    }
  }

  // MARK: - Elements

  function domRow(item, depth) {
    const fragment = document.createDocumentFragment();
    const row = el('div', 'node');
    row.style.paddingLeft = 4 + depth * 12 + 'px';
    row.dataset.path = JSON.stringify(item.path);

    const caret = el('span', 'toggle', item.children ? '▸' : ' ');
    row.appendChild(caret);

    let label = '<' + item.tag;
    if (item.id) label += '#' + item.id;
    if (item.classes && item.classes.length) label += '.' + item.classes.join('.');
    row.appendChild(el('span', 'tag', label + '>'));
    if (item.text) {
      row.appendChild(el('span', 'text', ' ' + item.text.slice(0, 60)));
    }

    // Each row owns the container its children will be fetched into, so collapsing a branch keeps
    // whatever was already expanded below it.
    const container = el('div', 'dom-children');
    container.hidden = true;
    fragment.appendChild(row);
    fragment.appendChild(container);

    if (item.children) {
      caret.addEventListener('click', (event) => {
        event.stopPropagation();
        toggleDom(caret, container, item);
      });
    }
    row.addEventListener('click', () => selectElement(item.path));
    row.addEventListener('mouseenter', () => highlight(item.path));
    return fragment;
  }

  async function toggleDom(caret, container, item) {
    const expanded = caret.dataset.open === 'true';
    if (expanded) {
      caret.dataset.open = 'false';
      caret.textContent = '▸';
      container.hidden = true;
      return;
    }
    caret.dataset.open = 'true';
    caret.textContent = '▾';
    if (!container.dataset.loaded) {
      const answer = await call('dom.children', { path: item.path });
      container.dataset.loaded = 'true';
      container.textContent = '';
      if (!answer || answer.error) {
        container.appendChild(el('div', 'node', answer && answer.error ? answer.error : 'Not available'));
      } else {
        for (const child of answer.children || []) {
          container.appendChild(domRow(child, item.path.length + 1));
        }
      }
    }
    container.hidden = false;
  }

  async function loadDomTree() {
    const tree = role('dom-tree');
    tree.textContent = '';
    const answer = await call('dom.children', { path: [] });
    if (!answer || answer.error) {
      tree.appendChild(el('p', 'hint', answer && answer.error ? answer.error : 'The document is not available.'));
      return;
    }
    // The root row is <html>; its children are what the agent answered with.
    const root = el('div', 'node');
    const caret = el('span', 'toggle', '▾');
    root.appendChild(caret);
    root.appendChild(el('span', 'tag', '<html>'));
    const container = el('div', 'dom-children');
    for (const child of answer.children || []) {
      container.appendChild(domRow(child, 1));
    }
    tree.appendChild(root);
    tree.appendChild(container);
    root.dataset.path = '[]';
    root.addEventListener('click', () => selectElement([]));
    root.addEventListener('mouseenter', () => highlight([]));
    caret.addEventListener('click', (event) => {
      event.stopPropagation();
      const hidden = !container.hidden;
      container.hidden = hidden;
      caret.textContent = hidden ? '▸' : '▾';
    });
  }

  async function selectElement(path) {
    state.selectedPath = path;
    for (const row of document.querySelectorAll('.node')) {
      row.dataset.selected = row.dataset.path === JSON.stringify(path) ? 'true' : 'false';
    }
    highlight(path);

    const detail = role('dom-detail');
    detail.textContent = '';
    const [styles, box] = await Promise.all([
      call('dom.styles', { path: path }),
      call('dom.box', { path: path }),
    ]);
    if (!styles || styles.error) {
      detail.appendChild(el('p', 'hint', styles && styles.error ? styles.error : 'No style information.'));
      return;
    }

    if (box && !box.error) {
      detail.appendChild(el('h4', null, 'Box model'));
      const model = el('div', 'box-model');
      const layer = (label, values) => {
        const node = el('div', 'layer');
        node.appendChild(el('span', 'label', label));
        node.appendChild(document.createTextNode(values.join('  ')));
        model.appendChild(node);
      };
      layer('margin', box.margin);
      layer('border', box.border);
      layer('padding', box.padding);
      layer('size', [Math.round(box.rect.width) + ' × ' + Math.round(box.rect.height)]);
      detail.appendChild(model);
    }

    if (styles.attributes && styles.attributes.length) {
      detail.appendChild(el('h4', null, 'Attributes'));
      const box2 = el('div', 'kv');
      for (const [key, value] of styles.attributes) {
        const line = el('div');
        line.appendChild(el('span', 'k', key));
        line.appendChild(el('span', 'v', value));
        box2.appendChild(line);
      }
      detail.appendChild(box2);
    }

    for (const group of styles.groups || []) {
      detail.appendChild(el('h4', null, group.title));
      const box3 = el('div', 'kv');
      for (const [property, value] of group.rows) {
        const line = el('div');
        line.appendChild(el('span', 'k', property));
        line.appendChild(el('span', 'v', value));
        box3.appendChild(line);
      }
      detail.appendChild(box3);
    }

    if (styles.rules && styles.rules.length) {
      detail.appendChild(el('h4', null, 'Matched rules'));
      const rules = el('div', 'rules');
      for (const rule of styles.rules) {
        const block = el('div', 'rule');
        block.appendChild(el('div', 'selector', rule.selector));
        for (const [property, value] of rule.declarations) {
          const line = el('div', 'decl');
          line.appendChild(el('span', 'prop', property + ': '));
          line.appendChild(document.createTextNode(value + ';'));
          block.appendChild(line);
        }
        rules.appendChild(block);
      }
      detail.appendChild(rules);
    }

    if (styles.skippedSheets) {
      detail.appendChild(el('p', 'hint', styles.skippedSheets + ' cross-origin stylesheet(s) cannot be read.'));
    }
  }

  function highlight(path) {
    const key = path ? JSON.stringify(path) : null;
    if (key === state.lastHighlight) return;
    state.lastHighlight = key;
    call('dom.highlight', { path: path });
  }

  // MARK: - Storage

  function renderStoreRows() {
    const rows = role('store-rows');
    rows.textContent = '';
    role('store-origin').textContent = state.storage.origin || '';
    if (!state.storage.rows.length) {
      rows.appendChild(el('p', 'hint', 'This store is empty.'));
      return;
    }
    for (const [key, value] of state.storage.rows) {
      const row = el('div', 'store-row');
      row.dataset.key = key;
      row.dataset.selected = key === state.storage.selected ? 'true' : 'false';
      row.appendChild(el('span', 'key', key));
      row.appendChild(el('span', 'value', String(value).replace(/\s+/g, ' ').slice(0, 200)));
      row.addEventListener('click', () => openEditor(key, String(value)));
      rows.appendChild(row);
    }
  }

  async function loadStorage() {
    const answer = await call('storage.list');
    if (!answer) return;
    const area = answer[state.storage.area] || { rows: [] };
    state.storage.rows = area.rows || [];
    state.storage.origin = answer.origin || '';
    renderStoreRows();
  }

  function openEditor(key, value) {
    state.storage.selected = key;
    state.storage.editing = key;
    for (const row of document.querySelectorAll('.store-row')) {
      row.dataset.selected = row.dataset.key === key ? 'true' : 'false';
    }
    role('store-key').value = key || '';
    role('store-value').value = value || '';
    role('store-editor').hidden = false;
    // A brand new key starts in the key field; an existing one is usually edited by its value.
    (key ? role('store-value') : role('store-key')).focus();
  }

  function closeEditor() {
    state.storage.editing = null;
    role('store-editor').hidden = true;
  }

  async function saveStorage() {
    const key = role('store-key').value;
    if (!key) {
      setStatus('A storage key cannot be empty', false);
      return;
    }
    const answer = await call('storage.set', {
      area: state.storage.area,
      key: key,
      value: role('store-value').value,
    });
    if (!answer || !answer.ok) {
      setStatus((answer && answer.error) || 'Could not write the item', false);
      return;
    }
    state.storage.selected = key;
    closeEditor();
    await loadStorage();
  }

  async function deleteStorage() {
    const key = role('store-key').value;
    if (!key) return;
    const answer = await call('storage.remove', { area: state.storage.area, key: key });
    if (!answer || !answer.ok) {
      setStatus((answer && answer.error) || 'Could not remove the item', false);
      return;
    }
    state.storage.selected = null;
    closeEditor();
    await loadStorage();
  }

  // MARK: - Filtering

  function applyRowFilter(row) {
    if (!state.filter) {
      row.classList.remove('hidden');
      return;
    }
    const matches = row.textContent.toLowerCase().includes(state.filter);
    row.classList.toggle('hidden', !matches);
  }

  function applyFilter() {
    const filter = state.filter;
    if (document.querySelector('[data-page="console"]').dataset.active === 'true') {
      for (const row of document.querySelectorAll('.entry')) applyRowFilter(row);
    }
    if (document.querySelector('[data-page="network"]').dataset.active === 'true') {
      for (const row of document.querySelectorAll('.network-row')) applyRowFilter(row);
    }
    if (document.querySelector('[data-page="elements"]').dataset.active === 'true') {
      for (const row of document.querySelectorAll('.node')) {
        const matches = !filter || row.textContent.toLowerCase().includes(filter);
        row.dataset.hidden = matches ? 'false' : 'true';
      }
    }
    if (document.querySelector('[data-page="storage"]').dataset.active === 'true') {
      for (const row of document.querySelectorAll('.store-row')) applyRowFilter(row);
    }
  }

  function updateCount(name, count) {
    const badge = document.querySelector('[data-count="' + name + '"]');
    if (badge) badge.textContent = String(count);
  }

  // MARK: - Wiring

  function wire() {
    for (const tab of document.querySelectorAll('.tab')) {
      tab.addEventListener('click', () => selectTab(tab.dataset.tab));
    }

    role('filter').addEventListener('input', (event) => {
      state.filter = event.target.value.trim().toLowerCase();
      applyFilter();
    });

    document.querySelector('[data-action="clear"]').addEventListener('click', async () => {
      if (state.tab === 'console') {
        await call('console.clear');
        state.consoleEntries = [];
        renderConsole();
      } else if (state.tab === 'network') {
        await call('network.clear');
        state.requests.clear();
        state.selectedRequest = null;
        role('network-rows').textContent = '';
        role('network-detail').textContent = '';
        role('network-detail').appendChild(el('p', 'hint', 'Select a request to see its headers and body.'));
        updateCount('network', 0);
      } else if (state.tab === 'storage') {
        await clearStorage();
      }
    });

    document.querySelector('[data-action="close"]').addEventListener('click', () => {
      handler.postMessage({ kind: 'panel', name: 'close' });
    });

    const form = role('console-form');
    const input = role('console-input');
    const commandHistory = [];
    let historyIndex = -1;

    form.addEventListener('submit', (event) => {
      event.preventDefault();
      const code = input.value;
      input.value = '';
      if (code.trim()) {
        commandHistory.push(code);
      }
      historyIndex = commandHistory.length;
      evaluate(code);
    });

    input.addEventListener('keydown', (event) => {
      if (event.key === 'ArrowUp') {
        event.preventDefault();
        historyIndex = Math.max(0, Math.min(historyIndex, commandHistory.length) - 1);
        input.value = commandHistory[historyIndex] || '';
      } else if (event.key === 'ArrowDown') {
        event.preventDefault();
        historyIndex = Math.min(commandHistory.length, historyIndex + 1);
        input.value = commandHistory[historyIndex] || '';
      }
    });

    for (const button of document.querySelectorAll('.areas button')) {
      button.addEventListener('click', async () => {
        state.storage.area = button.dataset.area;
        for (const other of document.querySelectorAll('.areas button')) {
          other.dataset.selected = other === button ? 'true' : 'false';
        }
        closeEditor();
        await loadStorage();
      });
    }

    document.querySelector('[data-action="storage-add"]').addEventListener('click', () => openEditor('', ''));
    document.querySelector('[data-action="storage-reload"]').addEventListener('click', loadStorage);
    document.querySelector('[data-action="storage-clear"]').addEventListener('click', clearStorage);
    document.querySelector('[data-action="store-save"]').addEventListener('click', saveStorage);
    document.querySelector('[data-action="store-delete"]').addEventListener('click', deleteStorage);
    document.querySelector('[data-action="store-cancel"]').addEventListener('click', closeEditor);

    document.addEventListener('keydown', (event) => {
      if (!event.metaKey) return;
      const order = ['console', 'network', 'elements', 'storage'];
      const index = Number(event.key);
      if (index >= 1 && index <= order.length) {
        event.preventDefault();
        selectTab(order[index - 1]);
      }
    });

    document.addEventListener('mouseleave', () => highlight(null));
    role('dom-tree').addEventListener('mouseleave', () => highlight(null));
  }

  let clearArmed = false;
  async function clearStorage() {
    const button = document.querySelector('[data-action="storage-clear"]');
    if (!clearArmed) {
      clearArmed = true;
      button.textContent = 'Sure?';
      setTimeout(() => {
        clearArmed = false;
        button.textContent = 'Clear all';
      }, 3000);
      return;
    }
    clearArmed = false;
    button.textContent = 'Clear all';
    const answer = await call('storage.clear', { area: state.storage.area });
    if (!answer || !answer.ok) {
      setStatus((answer && answer.error) || 'Could not clear the store', false);
      return;
    }
    state.storage.selected = null;
    closeEditor();
    await loadStorage();
  }

  // MARK: - Shell messages

  function receive(payload) {
    if (!payload) return;
    switch (payload.type) {
      case 'theme':
        applyTheme(payload.theme);
        break;
      case 'visibility':
        setVisible(!!payload.open);
        break;
      case 'page':
        onPageReady(!!payload.ready);
        break;
      case 'event':
        if (payload.channel === 'console') {
          appendConsole(payload.payload);
        } else if (payload.channel === 'network') {
          upsertRequest(payload.payload && payload.payload.record);
        }
        break;
      default:
        break;
    }
  }

  window.__orcaDevtoolsPanel = { receive: receive };

  async function init() {
    wire();
    applyTheme({ appearance: 'dark' });
    role('meta').textContent = 'F12 toggles the panel';
    if (!handler) {
      setStatus('Orca bridge is not available', false);
      return;
    }
    const info = await handler.postMessage({ kind: 'init' });
    if (!info) return;
    applyTheme(info.theme);
    state.open = !!info.open;
    state.pageReady = !!info.pageReady;
    setStatus(info.pageReady ? 'Page agent connected' : 'Waiting for the page…', !!info.pageReady);
    if (info.pageReady) {
      await refreshAll();
    }
  }

  init();
})();
