const modeToggle = document.getElementById('modeToggle');
const overviewBox = document.getElementById('overviewBox');
const userBox = document.getElementById('userBox');
const controlBox = document.getElementById('controlBox');
const feedBody = document.getElementById('feedBody');
const statusLine = document.getElementById('statusLine');

let state = { canControl: false, isAdmin: false };

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

function updateControlState() {
  const enabled = modeToggle.checked && state.canControl;
  document.querySelectorAll('[data-action]').forEach((btn) => { btn.disabled = !enabled; });
  controlBox.textContent = enabled ? 'Control mode enabled.' : 'Control mode is disabled.';
}

function renderFeed(attempts) {
  feedBody.innerHTML = '';
  attempts.forEach((item) => {
    const tr = document.createElement('tr');
    tr.innerHTML = `<td>${item.created_at || ''}</td><td>${item.user_id || ''}</td><td>${item.outcome || ''}</td><td>${item.score ?? ''}</td><td>${item.coverage_ratio ?? ''}</td><td>${item.matched_pairs ?? ''}</td><td>${item.ip_address || ''}</td><td>${item.request_id || ''}</td>`;
    feedBody.appendChild(tr);
  });
}

async function loadOverview() {
  const response = await apiGet('/admin/api/overview');
  if (!response.ok) {
    overviewBox.textContent = JSON.stringify(response.data, null, 2);
    return;
  }

  const payload = response.data;
  state.canControl = !!payload.can_control;
  state.isAdmin = !!payload.is_admin;
  statusLine.textContent = `DB: ${payload.db_connected ? 'connected' : 'error'} | Uptime: ${payload.uptime_seconds}s | Admin: ${state.isAdmin ? 'yes' : 'no'}`;
  overviewBox.textContent = JSON.stringify(payload, null, 2);
  updateControlState();
}

async function loadFeed() {
  const response = await apiGet('/admin/api/feed?limit=40');
  if (!response.ok) {
    controlBox.textContent = JSON.stringify(response.data, null, 2);
    return;
  }
  renderFeed(response.data.attempts || []);
}

async function loadUser() {
  const userId = document.getElementById('userIdInput').value;
  if (!userId) {
    userBox.textContent = 'User ID is required.';
    return;
  }
  const response = await apiGet(`/admin/api/user/${userId}`);
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

loadOverview();
loadFeed();
setInterval(loadFeed, 10000);
