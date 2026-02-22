const modeToggle = document.getElementById('modeToggle');
const overviewBox = document.getElementById('overviewBox');
const userBox = document.getElementById('userBox');
const controlBox = document.getElementById('controlBox');
const feedBody = document.getElementById('feedBody');
const authFeedBody = document.getElementById('authFeedBody');
const statusLine = document.getElementById('statusLine');
const overviewGrid = document.getElementById('overviewGrid');
const outcomesList = document.getElementById('outcomesList');
const liveMeta = document.getElementById('liveMeta');
const systemPill = document.getElementById('systemPill');
const adminPill = document.getElementById('adminPill');

let state = { canControl: false, isAdmin: false };
const REFRESH_INTERVAL_MS = 6000;
let refreshInFlight = false;
let nextRefreshAt = Date.now() + REFRESH_INTERVAL_MS;

async function apiGet(path) {
  const res = await fetch(path, { credentials: 'same-origin' });
  const text = await res.text();
  try { return { ok: res.ok, data: JSON.parse(text) }; } catch (_) { return { ok: res.ok, data: { raw: text } }; }
}

async function apiPost(path, payload) {
  const res = await fetch(path, {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: payload ? JSON.stringify(payload) : '{}'
  });
  const text = await res.text();
  try { return { ok: res.ok, data: JSON.parse(text) }; } catch (_) { return { ok: res.ok, data: { raw: text } }; }
}

function summarizeErrorPayload(payload, fallbackMessage) {
  if (!payload || typeof payload !== 'object') return fallbackMessage;

  if (payload.error && payload.error.message) {
    return payload.error.message;
  }

  if (typeof payload.raw === 'string') {
    const raw = payload.raw.trim();
    if (raw.toLowerCase().startsWith('<!doctype html') || raw.toLowerCase().startsWith('<html')) {
      return 'Dashboard API returned an HTML error page. Backend likely hit a transient DB issue; refreshing should recover.';
    }
    return raw.slice(0, 220);
  }

  return fallbackMessage;
}

function updateControlState() {
  const enabled = modeToggle.checked && state.canControl;
  document.querySelectorAll('[data-action]').forEach((btn) => { btn.disabled = !enabled; });
  document.querySelectorAll('button[data-action="mark-genuine"], button[data-action="mark-imposter"]').forEach((btn) => {
    btn.disabled = !enabled;
  });
  controlBox.textContent = enabled ? 'Control mode enabled.' : 'Control mode is disabled.';
}

function setLiveMeta(text) {
  if (!liveMeta) return;
  liveMeta.textContent = text;
}

function formatValue(value) {
  if (value === null || value === undefined || value === '') return '--';
  if (typeof value === 'number') return Number.isInteger(value) ? value.toString() : value.toFixed(4);
  return String(value);
}

function formatTime(value) {
  if (!value) return '--';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return `${date.toLocaleDateString()} ${date.toLocaleTimeString()}`;
}

function badgeClassForOutcome(outcome) {
  const normalized = String(outcome || '').toUpperCase();
  if (normalized === 'SUCCESS') return 'success';
  if (normalized === 'CHALLENGE') return 'challenge';
  if (normalized === 'DENIED') return 'denied';
  return '';
}

function rowClassForOutcome(outcome) {
  const normalized = String(outcome || '').toUpperCase();
  if (normalized === 'SUCCESS') return 'success';
  if (normalized === 'CHALLENGE') return 'challenge';
  if (normalized === 'DENIED') return 'denied';
  return '';
}

function badgeClassForVerdict(verdict) {
  const normalized = String(verdict || '').toUpperCase();
  if (normalized === 'AUTH_FAIL') return 'denied';
  if (normalized === 'AUTH_LOCK' || normalized === 'AUTH_RATE') return 'challenge';
  if (normalized === 'AUTH_OK') return 'success';
  return '';
}

function renderOverview(payload) {
  if (!overviewGrid || !outcomesList) return;

  const metrics = [
    { label: 'Attempts (24h)', value: payload.attempts_24h },
    { label: 'Attempts (7d)', value: payload.attempts_7d },
    { label: 'Avg Coverage (24h)', value: payload.avg_coverage_24h },
    { label: 'Uptime (sec)', value: payload.uptime_seconds },
    { label: 'Rate Limit Hits (24h)', value: payload.rate_limit_hits_24h },
    { label: 'Lockouts (24h)', value: payload.lockouts_24h }
  ];

  overviewGrid.innerHTML = metrics.map((metric) => `
    <article class="metric">
      <p class="metric-label">${metric.label}</p>
      <p class="metric-value">${formatValue(metric.value)}</p>
    </article>
  `).join('');

  const outcomes = payload.outcomes_7d || {};
  const chips = Object.keys(outcomes).length === 0
    ? '<span class="chip">No outcomes</span>'
    : Object.entries(outcomes).map(([name, count]) => {
        const cls = badgeClassForOutcome(name) || 'warn';
        return `<span class="chip ${cls}">${name}: ${count}</span>`;
      }).join('');

  outcomesList.innerHTML = chips;
}

function renderFeed(attempts) {
  feedBody.innerHTML = '';
  attempts.forEach((item) => {
    const tr = document.createElement('tr');
    const safeLabel = item.label || 'UNLABELED';
    const outcome = item.outcome || '--';
    const outcomeClass = badgeClassForOutcome(outcome);
    const rowClass = rowClassForOutcome(outcome);
    tr.className = `feed-row ${rowClass}`.trim();
    tr.innerHTML = `
      <td>${formatTime(item.created_at)}</td>
      <td>${item.user_id || '--'}</td>
      <td><span class="badge ${outcomeClass}">${outcome}</span></td>
      <td>${formatValue(item.score)}</td>
      <td>${formatValue(item.coverage_ratio)}</td>
      <td>${formatValue(item.matched_pairs)}</td>
      <td>${item.ip_address || '--'}</td>
      <td>${item.request_id || '--'}</td>
      <td><span class="badge label">${safeLabel}</span></td>
      <td>
        <button class="btn mini-btn" data-action="mark-genuine" data-id="${item.id}">Genuine</button>
        <button class="btn btn-danger mini-btn" data-action="mark-imposter" data-id="${item.id}">Imposter</button>
      </td>
    `;
    feedBody.appendChild(tr);
  });

  document.querySelectorAll('button[data-action="mark-genuine"], button[data-action="mark-imposter"]').forEach((btn) => {
    btn.disabled = !(modeToggle.checked && state.canControl);
    btn.addEventListener('click', () => runLabelAction(btn.getAttribute('data-id'), btn.getAttribute('data-action')));
  });
}

function renderAuthFeed(events) {
  if (!authFeedBody) return;

  authFeedBody.innerHTML = '';
  events.forEach((item) => {
    const tr = document.createElement('tr');
    const verdict = item.verdict || '--';
    const verdictClass = badgeClassForVerdict(verdict);

    tr.innerHTML = `
      <td>${formatTime(item.attempted_at)}</td>
      <td>${item.user_id || '--'}</td>
      <td><span class="badge ${verdictClass}">${verdict}</span></td>
      <td>${formatValue(item.score)}</td>
      <td>${item.ip_address || '--'}</td>
      <td>${item.request_id || '--'}</td>
    `;

    authFeedBody.appendChild(tr);
  });
}

async function runLabelAction(attemptId, action) {
  if (!modeToggle.checked || !state.canControl) {
    controlBox.textContent = 'Enable control mode and login as admin first.';
    return;
  }

  const label = action === 'mark-genuine' ? 'GENUINE' : 'IMPOSTER';
  if (!confirm(`Mark attempt ${attemptId} as ${label}?`)) return;

  const response = await apiPost(`/admin/api/attempt/${attemptId}/label`, { label });
  controlBox.textContent = JSON.stringify(response.data, null, 2);
  await loadFeed();
}

async function loadOverview() {
  const response = await apiGet('/admin/api/overview');
  if (!response.ok) {
    const message = summarizeErrorPayload(response.data, 'Unable to load overview.');
    overviewBox.textContent = message;
    statusLine.textContent = message;
    systemPill.textContent = 'System: Degraded';
    systemPill.className = 'pill bad';
    if (overviewGrid) overviewGrid.innerHTML = '';
    if (outcomesList) outcomesList.innerHTML = '<span class="chip bad">Data unavailable</span>';
    setLiveMeta(`Refresh failed at ${new Date().toLocaleTimeString()}`);
    return;
  }

  const payload = response.data;
  state.canControl = !!payload.can_control;
  state.isAdmin = !!payload.is_admin;
  statusLine.textContent = `DB: ${payload.db_connected ? 'connected' : 'error'} | Uptime: ${payload.uptime_seconds}s | Admin: ${state.isAdmin ? 'yes' : 'no'}`;
  systemPill.textContent = payload.db_connected ? 'System: Healthy' : 'System: DB Error';
  systemPill.className = `pill ${payload.db_connected ? 'good' : 'bad'}`;
  adminPill.textContent = state.isAdmin ? 'Admin: Authenticated' : 'Admin: Read-only';
  adminPill.className = `pill ${state.isAdmin ? 'good' : ''}`;
  setLiveMeta(`Last refresh: ${new Date().toLocaleTimeString()}`);
  renderOverview(payload);
  overviewBox.textContent = JSON.stringify(payload, null, 2);
  updateControlState();
}

async function loadFeed() {
  const response = await apiGet('/admin/api/feed?limit=40');
  if (!response.ok) {
    controlBox.textContent = summarizeErrorPayload(response.data, 'Unable to load feed right now.');
    setLiveMeta(`Feed refresh failed at ${new Date().toLocaleTimeString()}`);
    return;
  }
  renderFeed(response.data.attempts || []);
}

async function loadAuthFeed() {
  const response = await apiGet('/admin/api/auth-feed?limit=40');
  if (!response.ok) {
    setLiveMeta(`Auth feed refresh failed at ${new Date().toLocaleTimeString()}`);
    return;
  }

  renderAuthFeed(response.data.events || []);
}

async function refreshDashboardCycle() {
  if (refreshInFlight) return;

  refreshInFlight = true;
  setLiveMeta('Refreshing...');
  try {
    await loadOverview();
    await loadFeed();
    await loadAuthFeed();
  } finally {
    refreshInFlight = false;
    nextRefreshAt = Date.now() + REFRESH_INTERVAL_MS;
  }
}

function startRefreshLoop() {
  setInterval(() => {
    if (!refreshInFlight) {
      const remainingMs = Math.max(0, nextRefreshAt - Date.now());
      const remainingSec = Math.ceil(remainingMs / 1000);
      if (remainingSec > 0) {
        setLiveMeta(`Next refresh in ${remainingSec}s`);
      }
    }

    if (Date.now() >= nextRefreshAt) {
      refreshDashboardCycle();
    }
  }, 1000);
}

async function loadUser() {
  const userId = document.getElementById('userIdInput').value;
  if (!userId) {
    userBox.textContent = 'User ID is required.';
    return;
  }
  const response = await apiGet(`/admin/api/user/${userId}`);
  if (!response.ok) {
    userBox.textContent = summarizeErrorPayload(response.data, 'Unable to load user details.');
    return;
  }
  userBox.textContent = JSON.stringify(response.data, null, 2);
}

async function runControl(action) {
  if (!modeToggle.checked || !state.canControl) {
    controlBox.textContent = 'Enable control mode and login as admin first.';
    return;
  }

  const userId = document.getElementById('controlUserId').value;
  let response;

  if (action === 'recalibrate') {
    if (!userId) return controlBox.textContent = 'User ID is required for recalibration.';
    if (!confirm(`Recalibrate thresholds for user ${userId}?`)) return;
    response = await apiPost(`/admin/api/recalibrate/${userId}`);
  } else if (action === 'reset') {
    if (!userId) return controlBox.textContent = 'User ID is required for reset.';
    if (!confirm(`Reset biometric profile and score history for user ${userId}?`)) return;
    response = await apiPost(`/admin/api/reset-user/${userId}`);
  } else if (action === 'export') {
    if (!confirm('Export dataset now?')) return;
    response = await apiPost('/admin/api/export-dataset', { format: 'json' });
  } else if (action === 'evaluate') {
    if (!confirm('Run evaluation report generation now?')) return;
    response = await apiPost('/admin/api/run-evaluation');
  } else if (action === 'cleanup') {
    if (!confirm('Delete expired sessions now?')) return;
    response = await apiPost('/admin/api/cleanup-sessions');
  }

  controlBox.textContent = JSON.stringify(response.data, null, 2);
  await loadOverview();
  await loadFeed();
}

document.getElementById('loadUserBtn').addEventListener('click', loadUser);
modeToggle.addEventListener('change', updateControlState);
document.querySelectorAll('[data-action]').forEach((btn) => {
  btn.addEventListener('click', () => runControl(btn.getAttribute('data-action')));
});

refreshDashboardCycle();
startRefreshLoop();
