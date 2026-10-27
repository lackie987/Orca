// Orca developer tools — page-side agent.
//
// Two jobs: report what the page does (console lines and network traffic) and answer the queries
// the panel asks (evaluate, DOM, styles, storage). Nothing here changes page behaviour: every
// wrapped function calls the original and returns its own result untouched, and every capture
// failure is swallowed so a broken capture can never break the page.
(function () {
  'use strict';

  if (window.__ORCA_DEVTOOLS__) {
    return;
  }

  var CONSOLE_LIMIT = 800;
  var NETWORK_LIMIT = 400;
  var NETWORK_BODY_BUDGET = 100;
  var TEXT_LIMIT = 2000;
  var BODY_LIMIT = 64 * 1024;

  var consoleEntries = [];
  var networkRecords = [];
  var refs = new Map();
  var seenResources = new Set();
  var nextReference = 1;
  var nextId = 1;
  var overlay = null;

  // MARK: - Transport

  function post(channel, payload) {
    try {
      window.webkit.messageHandlers.devToolsAgent.postMessage({ channel: channel, payload: payload });
    } catch (error) {
      // A page without the Orca bridge (or a torn-down message handler) simply reports nowhere.
    }
  }

  function truncate(text, limit) {
    if (typeof text !== 'string') {
      return '';
    }
    return text.length > limit ? text.slice(0, limit) + '\n… (' + (text.length - limit) + ' more characters)' : text;
  }

  // MARK: - Value description

  function kindOf(value) {
    if (value === null) return 'null';
    if (value === undefined) return 'undefined';
    if (Array.isArray(value)) return 'array';
    if (value instanceof Error) return 'error';
    if (typeof value === 'object' && value.nodeType === 1) return 'node';
    if (typeof value === 'object' && value.nodeType === 3) return 'text';
    return typeof value;
  }

  function literal(value) {
    switch (kindOf(value)) {
      case 'string':
        return JSON.stringify(value.length > 60 ? value.slice(0, 60) + '…' : value);
      case 'number':
        return Object.is(value, -0) ? '-0' : String(value);
      case 'bigint':
        return String(value) + 'n';
      case 'boolean':
        return String(value);
      case 'undefined':
        return 'undefined';
      case 'null':
        return 'null';
      case 'symbol':
        return String(value);
      case 'function':
        return 'ƒ ' + (value.name || 'anonymous') + '()';
      case 'error':
        return (value.name || 'Error') + ': ' + (value.message || '');
      case 'node':
        return '<' + value.tagName.toLowerCase() + (value.id ? '#' + value.id : '') +
          (value.classList && value.classList.length ? '.' + Array.prototype.join.call(value.classList, '.') : '') + '>';
      case 'text':
        return '#text ' + literal(value.textContent || '');
      case 'array':
        return 'Array(' + value.length + ')';
      default:
        break;
    }
    try {
      if (value instanceof Date) return value.toISOString();
      if (value instanceof RegExp) return String(value);
      if (value instanceof Map) return 'Map(' + value.size + ')';
      if (value instanceof Set) return 'Set(' + value.size + ')';
      if (value instanceof Promise) return 'Promise {…}';
      if (value instanceof ArrayBuffer) return 'ArrayBuffer(' + value.byteLength + ')';
      if (ArrayBuffer.isView(value)) return value.constructor.name + '(' + value.length + ')';
    } catch (error) {
      return String(value);
    }
    return kindOf(value) === 'object' ? 'Object' : String(value);
  }

  function previewOf(value) {
    var keys;
    try {
      keys = Object.keys(value);
    } catch (error) {
      return '…';
    }
    var parts = [];
    for (var index = 0; index < keys.length && index < 5; index += 1) {
      var entry;
      try {
        entry = literal(value[keys[index]]);
      } catch (error) {
        entry = '…';
      }
      parts.push(keys[index] + ': ' + entry);
    }
    if (keys.length > 5) {
      parts.push('…');
    }
    return '{' + parts.join(', ') + '}';
  }

  // Keeps a live reference so the panel can expand a collapsed object later, without copying it.
  function keepReference(value) {
    var id = 'r' + nextReference;
    nextReference += 1;
    refs.set(id, value);
    if (refs.size > 1000) {
      var oldest = refs.keys().next();
      if (!oldest.done) {
        refs.delete(oldest.value);
      }
    }
    return id;
  }

  function serialize(value, depth) {
    var kind = kindOf(value);
    var node = { kind: kind, text: literal(value) };

    if (kind === 'error') {
      node.text = (value.name || 'Error') + ': ' + (value.message || '');
      node.stack = truncate(String(value.stack || ''), TEXT_LIMIT);
      node.ref = keepReference(value);
      return node;
    }
    if (kind === 'node') {
      node.ref = keepReference(value);
      node.text = literal(value);
      return node;
    }
    if (kind !== 'object' && kind !== 'array') {
      return node;
    }

    node.ref = keepReference(value);
    node.expandable = true;
    if (kind === 'array') {
      node.text = 'Array(' + value.length + ')';
    } else if (value instanceof Map) {
      node.text = 'Map(' + value.size + ')';
    } else if (value instanceof Set) {
      node.text = 'Set(' + value.size + ')';
    } else if (value instanceof Date) {
      node.text = value.toISOString();
      node.expandable = false;
      return node;
    } else if (value instanceof RegExp) {
      node.text = String(value);
      node.expandable = false;
      return node;
    } else if (value instanceof Promise) {
      node.text = 'Promise';
      node.expandable = false;
      return node;
    } else {
      node.text = 'Object';
    }
    node.summary = previewOf(value);

    if (depth > 0) {
      node.keys = describeChildren(value, depth - 1);
    }
    return node;
  }

  function describeChildren(value, depth) {
    var rows = [];
    var push = function (key, child) {
      if (rows.length >= 30) {
        return;
      }
      var node;
      try {
        node = serialize(child, depth);
      } catch (error) {
        node = { kind: 'object', text: '…' };
      }
      node.key = key;
      rows.push(node);
    };

    try {
      if (value instanceof Map) {
        value.forEach(function (child, key) {
          push(String(key), child);
        });
      } else if (value instanceof Set) {
        value.forEach(function (child) {
          push(String(rows.length), child);
        });
      } else {
        Object.keys(value).forEach(function (key) {
          push(key, value[key]);
        });
      }
    } catch (error) {
      rows.push({ key: 'error', kind: 'string', text: 'Could not read the object: ' + error.message });
    }

    if (value && value.nodeType === 1) {
      rows = [];
      Array.prototype.forEach.call(value.children, function (child) {
        push(String(rows.length), child);
      });
    }
    return rows;
  }

  // MARK: - Console

  function record(level, values, stack) {
    var entry = {
      id: nextId,
      level: level,
      time: Date.now(),
      url: location.href,
      stack: truncate(String(stack || ''), TEXT_LIMIT),
      args: [],
    };
    nextId += 1;
    for (var index = 0; index < values.length && index < 8; index += 1) {
      try {
        entry.args.push(serialize(values[index], 0));
      } catch (error) {
        entry.args.push({ kind: 'string', text: '⚠ Could not read argument ' + index });
      }
    }
    consoleEntries.push(entry);
    if (consoleEntries.length > CONSOLE_LIMIT) {
      consoleEntries.splice(0, consoleEntries.length - CONSOLE_LIMIT);
    }
    post('console', entry);
    return entry;
  }

  ['log', 'info', 'warn', 'error', 'debug', 'trace'].forEach(function (level) {
    var original = console[level];
    if (typeof original !== 'function') {
      return;
    }
    console[level] = function () {
      try {
        record(level, Array.prototype.slice.call(arguments), level === 'trace' ? new Error().stack : '');
      } catch (error) {
        // Capture must never break the call it observes.
      }
      return original.apply(console, arguments);
    };
  });

  window.addEventListener('error', function (event) {
    try {
      if (event.error) {
        record('error', [event.error], event.error && event.error.stack);
        return;
      }
      record('error', [event.message + ' (' + (event.filename || '') + ':' + event.lineno + ')'], '');
    } catch (error) {}
  });

  window.addEventListener('unhandledrejection', function (event) {
    try {
      record('error', [event.reason], event.reason && event.reason.stack);
    } catch (error) {}
  });

  // MARK: - Network

  function now() {
    return (window.performance && performance.now) ? performance.now() : Date.now();
  }

  function absolute(url) {
    try {
      return new URL(String(url), location.href).href;
    } catch (error) {
      return String(url);
    }
  }

  function headerList(raw) {
    var headers = {};
    if (typeof raw !== 'string') {
      return headers;
    }
    raw.split(/\r?\n/).forEach(function (line) {
      var index = line.indexOf(':');
      if (index > 0) {
        headers[line.slice(0, index).trim().toLowerCase()] = line.slice(index + 1).trim();
      }
    });
    return headers;
  }

  function bodyText(body) {
    if (body === null || body === undefined) return '';
    if (typeof body === 'string') return truncate(body, BODY_LIMIT);
    if (typeof URLSearchParams !== 'undefined' && body instanceof URLSearchParams) return truncate(body.toString(), BODY_LIMIT);
    if (typeof FormData !== 'undefined' && body instanceof FormData) {
      var pairs = [];
      body.forEach(function (value, key) {
        pairs.push(key + '=' + (typeof value === 'string' ? value : '[file]'));
      });
      return truncate(pairs.join('&'), BODY_LIMIT);
    }
    if (typeof Blob !== 'undefined' && body instanceof Blob) return '[Blob ' + body.size + ' bytes]';
    if (body instanceof ArrayBuffer || ArrayBuffer.isView(body)) return '[binary ' + (body.byteLength || body.length) + ' bytes]';
    try {
      return truncate(JSON.stringify(body), BODY_LIMIT);
    } catch (error) {
      return '';
    }
  }

  function publicRecord(record) {
    return {
      id: record.id,
      kind: record.kind,
      method: record.method || 'GET',
      url: record.url,
      status: record.status || 0,
      statusText: record.statusText || '',
      type: record.type || '',
      requestBody: record.requestBody || '',
      responseBody: record.responseBody || '',
      requestHeaders: record.requestHeaders || {},
      responseHeaders: record.responseHeaders || {},
      size: record.size || 0,
      duration: record.duration || 0,
      start: record.start || 0,
      error: record.error || '',
    };
  }

  function beginRequest(kind, method, url) {
    var record = {
      id: 'n' + nextId,
      kind: kind,
      method: method || 'GET',
      url: absolute(url),
      start: now(),
      status: 0,
      statusText: '',
      type: '',
      requestBody: '',
      responseBody: '',
      requestHeaders: {},
      responseHeaders: {},
      size: 0,
      duration: 0,
      error: '',
    };
    nextId += 1;
    networkRecords.push(record);
    if (networkRecords.length > NETWORK_LIMIT) {
      networkRecords.splice(0, networkRecords.length - NETWORK_LIMIT);
    }
    post('network', { phase: 'start', record: publicRecord(record) });
    return record;
  }

  function finishRequest(record, extra) {
    record.duration = Math.round((now() - record.start) * 10) / 10;
    if (extra) {
      Object.keys(extra).forEach(function (key) {
        record[key] = extra[key];
      });
    }
    // Bodies are the bulk of the memory a capture keeps; only the newest windows are worth it.
    if (networkRecords.length > NETWORK_BODY_BUDGET) {
      for (var index = 0; index < networkRecords.length - NETWORK_BODY_BUDGET; index += 1) {
        networkRecords[index].responseBody = '';
        networkRecords[index].requestBody = '';
      }
    }
    post('network', { phase: 'end', record: publicRecord(record) });
  }

  var originalFetch = window.fetch;
  if (typeof originalFetch === 'function') {
    window.fetch = function (input, init) {
      var method = 'GET';
      var url = '';
      var body = '';
      try {
        if (typeof Request !== 'undefined' && input instanceof Request) {
          method = input.method || 'GET';
          url = input.url;
        } else {
          url = String(input);
          method = (init && init.method) || 'GET';
        }
        body = bodyText(init && init.body);
      } catch (error) {}

      var record = beginRequest('fetch', method, url);
      record.requestBody = body;
      if (init && init.headers) {
        try {
          var supplied = new Headers(init.headers);
          supplied.forEach(function (value, key) {
            record.requestHeaders[key] = value;
          });
        } catch (error) {}
      }

      var promise;
      try {
        promise = originalFetch.apply(this, arguments);
      } catch (error) {
        finishRequest(record, { error: String(error) });
        throw error;
      }

      // A separate branch observes the response; the caller's promise keeps its own resolution.
      promise.then(function (response) {
        try {
          var type = response.headers.get('content-type') || '';
          var snapshot = {
            status: response.status,
            statusText: response.statusText,
            type: type,
            size: Number(response.headers.get('content-length')) || 0,
          };
          response.headers.forEach(function (value, key) {
            record.responseHeaders[key] = value;
          });
          finishRequest(record, snapshot);
          response.clone().text().then(function (text) {
            record.responseBody = truncate(text, BODY_LIMIT);
            record.size = record.size || text.length;
            post('network', { phase: 'end', record: publicRecord(record) });
          }, function () {});
        } catch (error) {
          finishRequest(record, {});
        }
        return response;
      }, function (error) {
        finishRequest(record, { error: String(error && error.message || error) });
      });

      return promise;
    };
  }

  var XHR = window.XMLHttpRequest;
  if (XHR && XHR.prototype) {
    var originalOpen = XHR.prototype.open;
    var originalSend = XHR.prototype.send;
    var originalSetHeader = XHR.prototype.setRequestHeader;

    XHR.prototype.open = function (method, url) {
      try {
        this.__orcaRecord = beginRequest('xhr', method, url);
      } catch (error) {}
      return originalOpen.apply(this, arguments);
    };

    XHR.prototype.setRequestHeader = function (name, value) {
      try {
        if (this.__orcaRecord) {
          this.__orcaRecord.requestHeaders[String(name).toLowerCase()] = String(value);
        }
      } catch (error) {}
      return originalSetHeader.apply(this, arguments);
    };

    XHR.prototype.send = function (body) {
      try {
        var record = this.__orcaRecord;
        if (record) {
          record.requestBody = bodyText(body);
          var xhr = this;
          xhr.addEventListener('loadend', function () {
            var snapshot = {
              status: xhr.status,
              statusText: xhr.statusText,
              type: xhr.getResponseHeader('content-type') || '',
              responseHeaders: headerList(xhr.getAllResponseHeaders()),
            };
            try {
              if (!xhr.responseType || xhr.responseType === 'text') {
                snapshot.responseBody = truncate(xhr.responseText || '', BODY_LIMIT);
                snapshot.size = (xhr.responseText || '').length;
              } else if (xhr.responseType === 'json') {
                snapshot.responseBody = truncate(JSON.stringify(xhr.response), BODY_LIMIT);
              } else {
                snapshot.responseBody = '[' + xhr.responseType + ' response]';
              }
            } catch (error) {}
            if (xhr.status === 0) {
              snapshot.error = 'Request did not complete (network error, CORS or abort)';
            }
            finishRequest(record, snapshot);
          });
        }
      } catch (error) {}
      return originalSend.apply(this, arguments);
    };
  }

  var NativeWebSocket = window.WebSocket;
  if (typeof NativeWebSocket === 'function') {
    var OrcaWebSocket = function (url, protocols) {
      var socket = protocols === undefined
        ? new NativeWebSocket(url)
        : new NativeWebSocket(url, protocols);
      try {
        var record = beginRequest('websocket', 'WS', url);
        record.status = 101;
        record.statusText = 'Switching Protocols';
        finishRequest(record, {});
        var frames = 0;
        socket.addEventListener('message', function () {
          frames += 1;
          if (frames === 1 || frames % 20 === 0) {
            record.responseBody = frames + ' message' + (frames === 1 ? '' : 's') + ' received';
            post('network', { phase: 'end', record: publicRecord(record) });
          }
        });
        socket.addEventListener('close', function () {
          record.responseBody = 'Closed after ' + frames + ' message' + (frames === 1 ? '' : 's');
          post('network', { phase: 'end', record: publicRecord(record) });
        });
      } catch (error) {}
      return socket;
    };
    OrcaWebSocket.prototype = NativeWebSocket.prototype;
    ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED'].forEach(function (name) {
      if (name in NativeWebSocket) {
        OrcaWebSocket[name] = NativeWebSocket[name];
      }
    });
    window.WebSocket = OrcaWebSocket;
  }

  // Everything that is not fetch/XHR (modules, stylesheets, images, fonts) only shows up in the
  // resource timeline; those rows carry timing and size but no status, which is what the browser
  // itself exposes for them.
  if (window.PerformanceObserver) {
    try {
      var observer = new PerformanceObserver(function (list) {
        list.getEntries().forEach(function (entry) {
          try {
            var initiator = entry.initiatorType || 'other';
            if (initiator === 'fetch' || initiator === 'xmlhttprequest' || initiator === 'websocket' || initiator === 'beacon') {
              return;
            }
            if (!entry.name || entry.name.indexOf('data:') === 0 || entry.name.indexOf('blob:') === 0) {
              return;
            }
            var key = entry.name + '@' + Math.round(entry.startTime);
            if (seenResources.has(key)) {
              return;
            }
            seenResources.add(key);
            post('network', {
              phase: 'end',
              record: {
                id: 'res' + seenResources.size,
                kind: 'resource',
                method: initiator,
                url: entry.name,
                status: 0,
                statusText: '',
                type: initiator,
                requestBody: '',
                responseBody: '',
                requestHeaders: {},
                responseHeaders: {},
                size: entry.transferSize || entry.encodedBodySize || 0,
                duration: Math.round((entry.duration || 0) * 10) / 10,
                start: Math.round(entry.startTime || 0),
                error: '',
              },
            });
          } catch (error) {}
        });
      });
      observer.observe({ type: 'resource', buffered: true });
    } catch (error) {}
  }

  // MARK: - DOM

  function nodeAt(path) {
    var node = document.documentElement;
    if (!path || !path.length) {
      return node;
    }
    for (var index = 0; index < path.length; index += 1) {
      if (!node) {
        return null;
      }
      node = node.children[path[index]] || null;
    }
    return node;
  }

  function pathOf(node) {
    var path = [];
    var current = node;
    while (current && current !== document.documentElement) {
      var parent = current.parentElement;
      if (!parent) {
        return null;
      }
      path.unshift(Array.prototype.indexOf.call(parent.children, current));
      current = parent;
    }
    return path;
  }

  function describeNode(node, path) {
    return {
      path: path,
      tag: node.tagName ? node.tagName.toLowerCase() : '#',
      id: node.id || '',
      classes: node.classList ? Array.prototype.slice.call(node.classList) : [],
      children: node.children ? node.children.length : 0,
      text: truncate(String(node.textContent || '').replace(/\s+/g, ' ').trim(), 60),
      attributes: (function () {
        var list = [];
        Array.prototype.forEach.call(node.attributes || [], function (attribute) {
          list.push([attribute.name, truncate(attribute.value, 200)]);
        });
        return list;
      })(),
    };
  }

  function childrenOf(path) {
    var node = nodeAt(path);
    if (!node) {
      return { children: [], error: 'Element no longer in the document' };
    }
    var rows = [];
    Array.prototype.forEach.call(node.children, function (child, index) {
      rows.push(describeNode(child, (path || []).concat([index])));
    });
    return { children: rows };
  }

  function boxOf(path) {
    var node = nodeAt(path);
    if (!node) {
      return { error: 'Element no longer in the document' };
    }
    var rect = node.getBoundingClientRect();
    var computed = getComputedStyle(node);
    return {
      rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
      margin: [computed.marginTop, computed.marginRight, computed.marginBottom, computed.marginLeft],
      border: [computed.borderTopWidth, computed.borderRightWidth, computed.borderBottomWidth, computed.borderLeftWidth],
      padding: [computed.paddingTop, computed.paddingRight, computed.paddingBottom, computed.paddingLeft],
    };
  }

  var STYLE_GROUPS = [
    ['Layout', ['display', 'position', 'top', 'right', 'bottom', 'left', 'z-index', 'float', 'overflow', 'box-sizing']],
    ['Box', ['width', 'height', 'min-width', 'max-width', 'min-height', 'max-height', 'margin', 'padding', 'border']],
    ['Flex / Grid', ['flex', 'flex-direction', 'justify-content', 'align-items', 'gap', 'grid-template-columns']],
    ['Text', ['font-family', 'font-size', 'font-weight', 'line-height', 'letter-spacing', 'color', 'text-align', 'white-space']],
    ['Paint', ['background-color', 'background-image', 'border-radius', 'box-shadow', 'opacity', 'transform', 'filter']],
  ];

  function stylesOf(path) {
    var node = nodeAt(path);
    if (!node) {
      return { error: 'Element no longer in the document' };
    }
    var computed = getComputedStyle(node);
    var groups = STYLE_GROUPS.map(function (group) {
      return {
        title: group[0],
        rows: group[1].map(function (property) {
          return [property, computed.getPropertyValue(property)];
        }),
      };
    });

    // Matched rules are read from the sheets the page can see; a cross-origin sheet is reported as
    // skipped rather than guessed at.
    var rules = [];
    var skipped = 0;
    Array.prototype.forEach.call(document.styleSheets, function (sheet) {
      var list;
      try {
        list = sheet.cssRules;
      } catch (error) {
        skipped += 1;
        return;
      }
      Array.prototype.forEach.call(list || [], function (rule) {
        if (!rule.selectorText || !rule.style) {
          return;
        }
        try {
          if (!node.matches(rule.selectorText)) {
            return;
          }
        } catch (error) {
          return;
        }
        var declarations = [];
        Array.prototype.forEach.call(rule.style, function (property) {
          declarations.push([property, rule.style.getPropertyValue(property)]);
        });
        if (declarations.length) {
          rules.push({ selector: rule.selectorText, declarations: declarations });
        }
      });
    });

    return {
      groups: groups,
      rules: rules.slice(0, 60),
      skippedSheets: skipped,
      attributes: describeNode(node, path).attributes,
    };
  }

  function clearHighlight() {
    if (overlay && overlay.parentNode) {
      overlay.parentNode.removeChild(overlay);
    }
    overlay = null;
  }

  function highlight(path) {
    clearHighlight();
    if (!path) {
      return {};
    }
    var node = nodeAt(path);
    if (!node) {
      return { error: 'Element no longer in the document' };
    }
    var rect = node.getBoundingClientRect();
    var box = document.createElement('div');
    box.setAttribute('data-orca-devtools-overlay', 'on');
    box.style.cssText = [
      'position:fixed',
      'pointer-events:none',
      'z-index:2147483647',
      'left:' + rect.left + 'px',
      'top:' + rect.top + 'px',
      'width:' + rect.width + 'px',
      'height:' + rect.height + 'px',
      'background:rgba(111,168,220,0.18)',
      'outline:1px solid rgba(111,168,220,0.9)',
      'box-sizing:border-box',
    ].join(';');
    var label = document.createElement('div');
    label.style.cssText = [
      'position:absolute',
      'left:0',
      'top:' + (rect.top < 22 ? '0' : '-19px'),
      'padding:1px 5px',
      'font:10px/1.6 -apple-system,sans-serif',
      'background:#6fa8dc',
      'color:#0b0b0b',
      'border-radius:2px',
      'white-space:nowrap',
    ].join(';');
    label.textContent = node.tagName.toLowerCase() + ' ' + Math.round(rect.width) + ' × ' + Math.round(rect.height);
    box.appendChild(label);
    (document.body || document.documentElement).appendChild(box);
    overlay = box;
    return { rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height } };
  }

  // MARK: - Storage

  function dumpStorage(store) {
    var rows = [];
    try {
      for (var index = 0; index < store.length; index += 1) {
        var key = store.key(index);
        var value;
        try {
          value = store.getItem(key);
        } catch (error) {
          value = '⚠ ' + error.message;
        }
        rows.push([key, truncate(String(value), BODY_LIMIT)]);
      }
    } catch (error) {
      return { rows: [], error: error.message };
    }
    return { rows: rows };
  }

  function storageList() {
    return {
      local: dumpStorage(window.localStorage),
      session: dumpStorage(window.sessionStorage),
      origin: location.origin,
    };
  }

  function storageStore(name) {
    return name === 'session' ? window.sessionStorage : window.localStorage;
  }

  // MARK: - Evaluation

  async function evaluate(code) {
    var source = String(code || '');
    if (!source.trim()) {
      return { ok: true, value: { kind: 'undefined', text: '' } };
    }
    try {
      var value;
      try {
        value = await new Function('return (' + source + ')').call(window);
      } catch (inner) {
        if (!(inner instanceof SyntaxError)) {
          throw inner;
        }
        // Statements (declarations, loops, `await`) are a second attempt, not a fallback for errors.
        value = await new Function('return (async () => { ' + source + ' })()').call(window);
      }
      return { ok: true, value: serialize(value, 2) };
    } catch (error) {
      return {
        ok: false,
        error: {
          name: (error && error.name) || 'Error',
          message: String((error && error.message) || error),
          stack: truncate(String((error && error.stack) || ''), TEXT_LIMIT),
        },
      };
    }
  }

  // MARK: - Command dispatch

  async function handle(command) {
    var name = (command && command.name) || '';
    var args = (command && command.args) || {};
    switch (name) {
      case 'console.backlog':
        return { entries: consoleEntries };
      case 'console.clear':
        consoleEntries.length = 0;
        return {};
      case 'console.eval':
        return await evaluate(args.code);
      case 'object.expand':
        return expandReference(args.ref);
      case 'network.backlog':
        return { records: networkRecords.map(publicRecord) };
      case 'network.clear':
        networkRecords.length = 0;
        return {};
      case 'dom.children':
        return childrenOf(args.path || []);
      case 'dom.styles':
        return stylesOf(args.path || []);
      case 'dom.box':
        return boxOf(args.path || []);
      case 'dom.highlight':
        return highlight(args.path || null);
      case 'dom.path':
        return { path: pathOf(args.node || document.activeElement) };
      case 'storage.list':
        return storageList();
      case 'storage.set':
        try {
          storageStore(args.area).setItem(args.key, args.value);
          return { ok: true };
        } catch (error) {
          return { ok: false, error: error.message };
        }
      case 'storage.remove':
        try {
          storageStore(args.area).removeItem(args.key);
          return { ok: true };
        } catch (error) {
          return { ok: false, error: error.message };
        }
      case 'storage.clear':
        try {
          storageStore(args.area).clear();
          return { ok: true };
        } catch (error) {
          return { ok: false, error: error.message };
        }
      default:
        return { error: 'Unknown command: ' + name };
    }
  }

  function expandReference(reference) {
    var value = refs.get(reference);
    if (value === undefined) {
      return { keys: [], error: 'Reference expired' };
    }
    try {
      return { keys: describeChildren(value, 1) };
    } catch (error) {
      return { keys: [], error: error.message };
    }
  }

  Object.defineProperty(window, '__ORCA_DEVTOOLS__', {
    configurable: true,
    value: {
      version: 1,
      handle: handle,
      // The panel's element picker uses this to translate a click into a tree path.
      pathOf: pathOf,
    },
  });

  post('ready', { url: location.href });
})();
