/* ── YT SDI Streamer Dashboard ── */

const POLL_MS = 3000;
const EVENTS_POLL_MS = 10000;
let keyRevealed = false;
let actionInProgress = false;
let lastServiceState = null; // true = running, false = stopped, null = unknown
let prevNet = null; // { rx_bytes, tx_bytes, ts } for rate calculation
let presets = {};         // populated from /api/presets
let activePreset = null;  // 'low' | 'standard' | 'high' | null

/* ── Polling ── */

async function fetchMetrics() {
  try {
    const res = await fetch('/api/metrics');
    const m = await res.json();
    if (res.ok) {
      updateMetrics(m);
    } else {
      updateMetrics({ service_running: m.service_running === true, ...m });
    }
    setConn(true);
  } catch {
    setConn(false);
    updateButtonStates(null);
  }
}

async function fetchEvents() {
  try {
    const res = await fetch('/api/events?n=50');
    if (!res.ok) return;
    const events = await res.json();
    updateEvents(events);
  } catch { /* silent */ }
}

/* ── Update UI ── */

function updateMetrics(m) {
  const running = m.service_running !== false;
  lastServiceState = running;

  // Mode badge
  const badge = document.getElementById('modeBadge');
  if (!running) {
    badge.textContent = 'STOPPED';
    badge.className = 'mode-badge mode-stopped';
  } else {
    const mode = (m.mode || '').toLowerCase();
    badge.textContent = mode || '---';
    badge.className = 'mode-badge ' +
      (mode === 'live' ? 'mode-live pulse-live' : mode === 'standby' ? 'mode-standby' : 'mode-unknown');
  }

  // Service card
  setText('s-mode', running ? (m.mode || '-') : 'STOPPED');
  setText('s-state', running ? (m.state || '-') : 'stopped');
  setText('s-bitrate', m.bitrate || '-');
  setText('s-ts', m.ts ? fmtTime(m.ts) : '-');

  // FFmpeg stats
  const ff = m.ffmpeg || {};
  setText('s-fps', running && ff.fps ? ff.fps : '-');
  setText('s-speed', running && ff.speed ? ff.speed.trim() : '-');
  setText('s-enc-bitrate', running && ff.enc_bitrate && ff.enc_bitrate !== '0' ? ff.enc_bitrate.trim() : '-');
  const speedEl = document.getElementById('s-speed');
  if (speedEl && running && ff.speed) {
    const sv = parseFloat(ff.speed);
    speedEl.className = 'stat-value' + (sv >= 0.95 && sv <= 1.05 ? ' good' : sv > 0 ? ' warn' : '');
  }

  // Uptime featured
  const uptimeEl = document.getElementById('s-uptime');
  if (uptimeEl) uptimeEl.textContent = running ? fmtUptime(m.uptime_s) : '--:--:--';

  // State color
  const stateEl = document.getElementById('s-state');
  if (stateEl) {
    stateEl.className = 'stat-value' +
      (!running ? ' bad' : m.state === 'running' ? ' good' : ' warn');
  }

  // Network card
  const n = m.network || {};
  setText('n-iface', friendlyNet(n.iface, n.service, running));
  setText('n-ip', friendlyNet(n.ip, null, running));
  setText('n-gw', n.gateway || '-');

  // Network transfer rates
  const nowMs = Date.now();
  if (prevNet && n.rx_bytes != null && n.tx_bytes != null) {
    const dtSec = (nowMs - prevNet.ts) / 1000;
    if (dtSec > 0) {
      const rxRate = Math.max(0, (n.rx_bytes - prevNet.rx) / dtSec);
      const txRate = Math.max(0, (n.tx_bytes - prevNet.tx) / dtSec);
      setText('n-rx-rate', fmtRate(rxRate));
      setText('n-tx-rate', fmtRate(txRate));
    }
  }
  if (n.rx_bytes != null) {
    prevNet = { rx: n.rx_bytes, tx: n.tx_bytes, ts: nowMs };
  }

  const ping = n.ping || {};
  if (ping && typeof ping === 'object' && ping.loss != null) {
    setText('n-loss', ping.loss + '%');
    setText('n-avg', ping.avg_ms + ' ms');
    setText('n-jitter', ping.jitter_ms + ' ms');
    const lossEl = document.getElementById('n-loss');
    if (lossEl) {
      const lv = parseFloat(ping.loss);
      lossEl.className = 'stat-value' + (lv === 0 ? ' good' : lv < 5 ? ' warn' : ' bad');
    }
  } else {
    setText('n-loss', 'off');
    setText('n-avg', '-');
    setText('n-jitter', '-');
  }

  // Update button states
  updateButtonStates(running);

  // Control bar: status dot + label
  const controlDot = document.getElementById('controlDot');
  const statusLabel = document.getElementById('serviceStatusText');
  if (controlDot) {
    controlDot.className = 'control-dot ' + (running ? 'running' : 'stopped');
  }
  if (statusLabel) {
    statusLabel.textContent = running ? 'Live Broadcast Active' : 'Broadcast Offline';
  }
}

function friendlyNet(val, fallback, running) {
  if (!val || val === 'unknown') {
    if (fallback && fallback !== 'unknown') return fallback;
    return running ? 'Detecting...' : '\u2014';
  }
  return val;
}

function updateButtonStates(running) {
  const btnStart = document.getElementById('btn-start');
  const btnStop = document.getElementById('btn-stop');
  const btnRestart = document.getElementById('btn-restart');

  if (actionInProgress) {
    btnStart.disabled = true;
    btnStop.disabled = true;
    btnRestart.disabled = true;
    return;
  }

  if (running === true) {
    btnStart.disabled = true;
    btnStop.disabled = false;
    btnRestart.disabled = false;
  } else if (running === false) {
    btnStart.disabled = false;
    btnStop.disabled = true;
    btnRestart.disabled = true;
  } else {
    // Unknown — disable all until we know
    btnStart.disabled = true;
    btnStop.disabled = true;
    btnRestart.disabled = true;
  }
}

function updateEvents(events) {
  const tbody = document.getElementById('eventsBody');
  if (!events.length) {
    tbody.innerHTML = '<tr><td colspan="4" class="no-data">No events recorded yet</td></tr>';
    return;
  }
  const rows = events.reverse().map(e => {
    const ts = fmtTime(e.ts || '');
    const lvl = e.level || 'INFO';
    const ev = e.event || '';
    const msg = e.msg || e.message || '';
    return '<tr>' +
      '<td>' + esc(ts) + '</td>' +
      '<td class="lvl-' + esc(lvl) + '">' + esc(lvl) + '</td>' +
      '<td>' + esc(ev) + '</td>' +
      '<td title="' + esc(msg) + '">' + esc(msg) + '</td>' +
      '</tr>';
  }).join('');
  tbody.innerHTML = rows;
}

/* ── Controls ── */

function ctrlAction(action) {
  // Start is safe, no confirmation needed
  if (action === 'start') {
    executeAction(action);
    return;
  }
  // Stop/Restart need confirmation
  showConfirmModal(action);
}

function showConfirmModal(action) {
  const modal = document.getElementById('confirmModal');
  const msg = document.getElementById('confirmMsg');
  const btnConfirm = document.getElementById('confirmBtn');

  msg.textContent = 'Are you sure you want to ' + action + ' the broadcast?';
  btnConfirm.textContent = capitalize(action);
  btnConfirm.className = 'btn ' + (action === 'stop' ? 'btn-stop' : 'btn-restart');
  btnConfirm.onclick = function() {
    hideConfirmModal();
    executeAction(action);
  };
  modal.classList.add('show');
}

function hideConfirmModal() {
  document.getElementById('confirmModal').classList.remove('show');
}

async function executeAction(action) {
  actionInProgress = true;
  const btn = document.getElementById('btn-' + action);
  const orig = btn.innerHTML;
  btn.innerHTML = '<span class="spinner"></span>' + capitalize(action) + 'ing...';
  updateButtonStates(lastServiceState);

  try {
    const res = await fetch('/api/control', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action })
    });
    const data = await res.json();
    showToast(
      data.ok ? 'Broadcast ' + action + ' succeeded' : 'Broadcast ' + action + ' failed: ' + (data.error || ''),
      data.ok
    );
    // Refresh state quickly after action
    setTimeout(fetchMetrics, 1500);
    setTimeout(fetchMetrics, 4000);
  } catch (e) {
    showToast('Broadcast ' + action + ' failed: ' + e.message, false);
  } finally {
    actionInProgress = false;
    btn.innerHTML = orig;
    updateButtonStates(lastServiceState);
  }
}

/* ── Stream Key ── */

async function loadKey() {
  try {
    const reveal = keyRevealed ? '?reveal=true' : '';
    const res = await fetch('/api/stream-key' + reveal);
    const data = await res.json();
    document.getElementById('keyDisplay').textContent = data.key || '???';
  } catch {
    document.getElementById('keyDisplay').textContent = 'Error loading key';
  }
}

function toggleReveal() {
  keyRevealed = !keyRevealed;
  const btn = document.getElementById('btnReveal');
  btn.textContent = keyRevealed ? 'Hide' : 'Reveal';
  loadKey();
}

async function saveKey() {
  const input = document.getElementById('keyInput');
  const btn = document.getElementById('btnSaveKey');
  const key = input.value.trim();
  if (!key) return;

  btn.disabled = true;
  btn.textContent = 'Saving...';
  try {
    const res = await fetch('/api/stream-key', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ key })
    });
    const data = await res.json();
    if (data.ok) {
      showToast('Stream key saved. Restart broadcast to apply.', true);
      input.value = '';
      updateSaveKeyBtn();
      loadKey();
    } else {
      showToast('Failed: ' + (data.error || ''), false);
    }
  } catch (e) {
    showToast('Failed: ' + e.message, false);
  } finally {
    btn.disabled = false;
    btn.textContent = 'Save Key';
    updateSaveKeyBtn();
  }
}

function updateSaveKeyBtn() {
  const input = document.getElementById('keyInput');
  const btn = document.getElementById('btnSaveKey');
  if (btn) btn.disabled = !input.value.trim();
}

/* ── Bitrate ── */

async function loadBitrate() {
  try {
    const res = await fetch('/api/bitrate');
    const data = await res.json();
    document.getElementById('bitrateDisplay').textContent = data.bitrate || '???';
  } catch {
    document.getElementById('bitrateDisplay').textContent = 'Error loading bitrate';
  }
}

async function saveBitrate() {
  const input = document.getElementById('bitrateInput');
  const btn = document.getElementById('btnSaveBitrate');
  const bitrate = input.value.trim();
  if (!bitrate) return;

  btn.disabled = true;
  btn.textContent = 'Saving...';
  try {
    const res = await fetch('/api/bitrate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ bitrate })
    });
    const data = await res.json();
    if (data.ok) {
      showToast('Bitrate saved. Restart broadcast to apply.', true);
      input.value = '';
      updateSaveBitrateBtn();
      loadBitrate();
      activePreset = null;
      highlightPreset();
    } else {
      showToast('Failed: ' + (data.error || ''), false);
    }
  } catch (e) {
    showToast('Failed: ' + e.message, false);
  } finally {
    btn.disabled = false;
    btn.textContent = 'Save';
    updateSaveBitrateBtn();
  }
}

function updateSaveBitrateBtn() {
  const input = document.getElementById('bitrateInput');
  const btn = document.getElementById('btnSaveBitrate');
  if (btn) btn.disabled = !input.value.trim();
}

/* ── Settings Tabs ── */

function switchSettingsTab(tab) {
  document.querySelectorAll('.settings-tab').forEach(t => t.classList.remove('active'));
  document.querySelectorAll('.settings-panel').forEach(p => p.classList.remove('active'));
  document.getElementById('tab-' + tab).classList.add('active');
  document.getElementById('panel-' + tab).classList.add('active');
}

/* ── Quality Presets ── */

async function loadPresets() {
  try {
    const res = await fetch('/api/presets');
    presets = await res.json();
    renderPresets();
    detectActivePreset();
  } catch {
    document.getElementById('presetsGrid').innerHTML =
      '<div class="no-data">Failed to load presets</div>';
  }
}

function renderPresets() {
  const grid = document.getElementById('presetsGrid');
  const order = ['low', 'standard', 'high'];
  grid.innerHTML = order.map(key => {
    const p = presets[key];
    if (!p) return '';
    return '<div class="glass preset-card" id="preset-' + key + '" onclick="selectPreset(\'' + key + '\')">' +
      '<span class="preset-check">&#10003;</span>' +
      '<div class="preset-name">' + esc(p.label) + '</div>' +
      '<div class="preset-bitrate">' + esc(p.bitrate) + '</div>' +
      '<div class="preset-desc">' + esc(p.description) + '</div>' +
      '</div>';
  }).join('');
}

async function detectActivePreset() {
  try {
    const res = await fetch('/api/bitrate');
    const data = await res.json();
    const current = (data.bitrate || '').trim();
    activePreset = null;
    for (const [key, p] of Object.entries(presets)) {
      if (p.bitrate === current) {
        activePreset = key;
        break;
      }
    }
    highlightPreset();
  } catch { /* silent */ }
}

function highlightPreset() {
  document.querySelectorAll('.preset-card').forEach(c => c.classList.remove('selected'));
  if (activePreset) {
    const el = document.getElementById('preset-' + activePreset);
    if (el) el.classList.add('selected');
  }
  const status = document.getElementById('presetStatus');
  if (status) {
    status.textContent = activePreset
      ? presets[activePreset].label + ' preset is active'
      : 'Custom bitrate in use';
  }
}

async function selectPreset(key) {
  const p = presets[key];
  if (!p) return;

  document.querySelectorAll('.preset-card').forEach(c => c.style.pointerEvents = 'none');
  const status = document.getElementById('presetStatus');
  status.textContent = 'Applying ' + p.label + ' preset...';

  try {
    const res = await fetch('/api/bitrate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ bitrate: p.bitrate })
    });
    const data = await res.json();
    if (data.ok) {
      activePreset = key;
      highlightPreset();
      loadBitrate();
      showToast(p.label + ' preset applied. Restart broadcast to take effect.', true);
    } else {
      showToast('Failed: ' + (data.error || ''), false);
    }
  } catch (e) {
    showToast('Failed: ' + e.message, false);
  } finally {
    document.querySelectorAll('.preset-card').forEach(c => c.style.pointerEvents = '');
  }
}

/* ── Playback URL ── */

async function loadPlaybackUrl() {
  try {
    const res = await fetch('/api/playback-url');
    const data = await res.json();
    const display = document.getElementById('playbackUrlDisplay');
    display.textContent = data.url || '(not set)';
  } catch {
    document.getElementById('playbackUrlDisplay').textContent = 'Error loading URL';
  }
}

async function savePlaybackUrl() {
  const input = document.getElementById('playbackUrlInput');
  const btn = document.getElementById('btnSavePlaybackUrl');
  const url = input.value.trim();
  if (!url) return;

  btn.disabled = true;
  btn.textContent = 'Saving...';
  try {
    const res = await fetch('/api/playback-url', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ url })
    });
    const data = await res.json();
    if (data.ok) {
      showToast('Playback URL saved.', true);
      input.value = '';
      updateSavePlaybackUrlBtn();
      loadPlaybackUrl();
    } else {
      showToast('Failed: ' + (data.error || ''), false);
    }
  } catch (e) {
    showToast('Failed: ' + e.message, false);
  } finally {
    btn.disabled = false;
    btn.textContent = 'Save';
    updateSavePlaybackUrlBtn();
  }
}

function updateSavePlaybackUrlBtn() {
  const input = document.getElementById('playbackUrlInput');
  const btn = document.getElementById('btnSavePlaybackUrl');
  if (btn) btn.disabled = !input.value.trim();
}

/* ── Utilities ── */

function setText(id, val) {
  const el = document.getElementById(id);
  if (el) el.textContent = val != null ? val : '-';
}

function setConn(ok) {
  const dot = document.getElementById('conn');
  const label = document.getElementById('connLabel');
  dot.className = 'conn-dot ' + (ok ? 'ok' : 'err');
  if (label) label.textContent = ok ? 'Dashboard Online' : 'Dashboard Offline';
}

function fmtUptime(s) {
  if (s == null) return '--:--:--';
  s = Math.floor(s);
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  const pad = n => String(n).padStart(2, '0');
  if (d > 0) return d + 'd ' + pad(h) + ':' + pad(m) + ':' + pad(sec);
  return pad(h) + ':' + pad(m) + ':' + pad(sec);
}

function fmtBytes(b) {
  if (b == null) return '-';
  if (b >= 1e9) return (b / 1e9).toFixed(2) + ' GB';
  if (b >= 1e6) return (b / 1e6).toFixed(1) + ' MB';
  if (b >= 1e3) return (b / 1e3).toFixed(1) + ' KB';
  return b + ' B';
}

function fmtRate(bps) {
  if (bps == null || bps <= 0) return '-';
  if (bps >= 1e6) return (bps / 1e6).toFixed(2) + ' MB/s';
  if (bps >= 1e3) return (bps / 1e3).toFixed(1) + ' KB/s';
  return Math.round(bps) + ' B/s';
}

function fmtTime(ts) {
  if (!ts) return '-';
  const d = new Date(ts);
  if (isNaN(d.getTime())) return ts;
  return d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

function capitalize(s) {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

function esc(s) {
  const d = document.createElement('div');
  d.textContent = s;
  return d.innerHTML;
}

function showToast(msg, ok) {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.className = 'toast show ' + (ok ? 'ok' : 'err');
  clearTimeout(t._timer);
  t._timer = setTimeout(() => { t.className = 'toast'; }, ok ? 3500 : 5000);
}

/* ── Init ── */
document.addEventListener('DOMContentLoaded', () => {
  // Disable all buttons until first poll
  updateButtonStates(null);
  updateSaveKeyBtn();

  // Key input listener for save button state
  const keyInput = document.getElementById('keyInput');
  if (keyInput) keyInput.addEventListener('input', updateSaveKeyBtn);

  // Bitrate input listener for save button state
  const bitrateInput = document.getElementById('bitrateInput');
  if (bitrateInput) bitrateInput.addEventListener('input', updateSaveBitrateBtn);

  // Close modal on backdrop click
  const modal = document.getElementById('confirmModal');
  if (modal) modal.addEventListener('click', function(e) {
    if (e.target === modal) hideConfirmModal();
  });

  // Close modal on Escape
  document.addEventListener('keydown', function(e) {
    if (e.key === 'Escape') hideConfirmModal();
  });

  // Playback URL input listener
  const playbackUrlInput = document.getElementById('playbackUrlInput');
  if (playbackUrlInput) playbackUrlInput.addEventListener('input', updateSavePlaybackUrlBtn);

  fetchMetrics();
  fetchEvents();
  loadKey();
  loadBitrate();
  loadPresets();
  loadPlaybackUrl();
  setInterval(fetchMetrics, POLL_MS);
  setInterval(fetchEvents, EVENTS_POLL_MS);
});
