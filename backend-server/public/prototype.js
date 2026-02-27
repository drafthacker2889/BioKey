const tokenKey = 'prototypeAuthToken';
const sessionKey = 'prototypeTypingSessionId';

function getToken() {
  return localStorage.getItem(tokenKey);
}

function setToken(token) {
  localStorage.setItem(tokenKey, token);
}

function clearToken() {
  localStorage.removeItem(tokenKey);
}

function getClientSessionId() {
  let value = localStorage.getItem(sessionKey);
  if (!value) {
    value = `sess_${Date.now()}_${Math.random().toString(16).slice(2, 10)}`;
    localStorage.setItem(sessionKey, value);
  }
  return value;
}

async function api(path, options = {}) {
  const token = getToken();
  const headers = Object.assign({}, options.headers || {});
  if (token) headers.Authorization = `Bearer ${token}`;

  const response = await fetch(path, {
    credentials: 'same-origin',
    ...options,
    headers
  });

  const text = await response.text();
  let body;
  try {
    body = JSON.parse(text);
  } catch (_) {
    body = { raw: text };
  }

  return { ok: response.ok, status: response.status, body };
}

function initLoginPage() {
  const form = document.getElementById('loginForm');
  if (!form) return;

  const status = document.getElementById('statusBox');
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    status.textContent = 'Logging in...';

    const username = document.getElementById('username').value.trim();
    const password = document.getElementById('password').value;

    const result = await api('/v1/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, password })
    });

    if (!result.ok) {
      status.textContent = `Login failed (${result.status}): ${result.body?.error?.message || 'Unknown error'}`;
      return;
    }

    setToken(result.body.token);
    status.textContent = 'Login success. Redirecting...';
    window.location.href = '/prototype/feed';
  });
}

function captureTyping(target, context, fieldName, sink) {
  let lastKeyDownAt = null;
  let lastKeyUpAt = null;

  target.addEventListener('keydown', (event) => {
    const now = performance.now();
    const eventData = {
      event_type: 'KEY_DOWN',
      key_value: event.key,
      key_code: event.keyCode,
      dwell_ms: null,
      flight_ms: lastKeyUpAt ? Number((now - lastKeyUpAt).toFixed(3)) : null,
      typed_length: target.value.length,
      cursor_pos: target.selectionStart,
      client_ts_ms: Date.now(),
      metadata: {
        context,
        shift: event.shiftKey,
        ctrl: event.ctrlKey,
        alt: event.altKey
      }
    };

    lastKeyDownAt = now;
    sink(context, fieldName, eventData);
  });

  target.addEventListener('keyup', (event) => {
    const now = performance.now();
    const eventData = {
      event_type: 'KEY_UP',
      key_value: event.key,
      key_code: event.keyCode,
      dwell_ms: lastKeyDownAt ? Number((now - lastKeyDownAt).toFixed(3)) : null,
      flight_ms: null,
      typed_length: target.value.length,
      cursor_pos: target.selectionStart,
      client_ts_ms: Date.now(),
      metadata: {
        context,
        shift: event.shiftKey,
        ctrl: event.ctrlKey,
        alt: event.altKey
      }
    };

    lastKeyUpAt = now;
    sink(context, fieldName, eventData);
  });
}

function initFeedPage() {
  const profileLine = document.getElementById('profileLine');
  if (!profileLine) return;

  const captureStatus = document.getElementById('captureStatus');
  const logoutBtn = document.getElementById('logoutBtn');
  const postBtn = document.getElementById('postBtn');
  const commentBtn = document.getElementById('commentBtn');
  const postTitle = document.getElementById('postTitle');
  const postBody = document.getElementById('postBody');
  const commentBody = document.getElementById('commentBody');

  const clientSessionId = getClientSessionId();
  const queue = [];

  const pushEvent = (context, fieldName, eventData) => {
    queue.push(eventData);
    if (queue.length > 5000) queue.shift();
    captureStatus.textContent = `Session: ${clientSessionId}\nQueued events: ${queue.length}`;
  };

  async function flushEvents(context, fieldName, maxBatch = 120) {
    if (queue.length === 0) return;

    const batch = queue.splice(0, maxBatch);
    const result = await api('/prototype/api/typing-events', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        context,
        field_name: fieldName,
        client_session_id: clientSessionId,
        events: batch
      })
    });

    if (!result.ok) {
      queue.unshift(...batch);
      captureStatus.textContent = `Capture error (${result.status}): ${result.body?.error?.message || 'Unknown'}\nQueued events: ${queue.length}`;
      return;
    }

    captureStatus.textContent = `Captured batch: ${result.body.inserted}\nQueued events: ${queue.length}`;
  }

  async function loadProfile() {
    const profile = await api('/prototype/api/profile');
    if (!profile.ok) {
      clearToken();
      window.location.href = '/prototype/login';
      return;
    }

    profileLine.textContent = `Logged in as ${profile.body.username} (user_id=${profile.body.user_id})`;
  }

  captureTyping(postTitle, 'post_composer', 'post_title', pushEvent);
  captureTyping(postBody, 'post_composer', 'post_body', pushEvent);
  captureTyping(commentBody, 'comment_box', 'comment_body', pushEvent);

  postBtn?.addEventListener('click', async () => {
    await flushEvents('post_composer', 'post_body');
    alert('Mock post published. Typing data captured.');
  });

  commentBtn?.addEventListener('click', async () => {
    await flushEvents('comment_box', 'comment_body');
    alert('Mock comment submitted. Typing data captured.');
  });

  logoutBtn?.addEventListener('click', async () => {
    try {
      await api('/v1/auth/logout', { method: 'POST' });
    } catch (_) {
      // ignore
    }
    clearToken();
    window.location.href = '/prototype/login';
  });

  window.addEventListener('beforeunload', () => {
    if (queue.length === 0) return;
    navigator.sendBeacon('/prototype/api/typing-events', JSON.stringify({
      context: 'background_flush',
      field_name: 'mixed',
      client_session_id: clientSessionId,
      events: queue.splice(0, Math.min(queue.length, 120))
    }));
  });

  setInterval(() => {
    flushEvents('ambient_capture', 'mixed', 80);
  }, 4000);

  loadProfile();
}

initLoginPage();
initFeedPage();
