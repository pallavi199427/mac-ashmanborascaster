/* ── ASHMAN Broadcast Dashboard — Multi-Profile ── */

const POLL_MS = 3000;
const EVENTS_POLL_MS = 10000;
let actionInProgress = false;
let lastServiceState = null;
let prevNet = null;
let rxHistory = [];
let txHistory = [];
let profilesData = null; // { active: 'profile1', profiles: { ... } }
let openEditPanel = null;
let revealedKeys = {}; // profileId -> true/false

/* ── Clock ── */

function updateClock() {
  const el = document.getElementById('headerClock');
  if (el) {
    const now = new Date();
    el.textContent = now.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  }
}

/* ── Profiles: Load & Render ── */

async function loadProfiles() {
  try {
    const res = await fetch('/api/profiles');
    if (!res.ok) throw new Error('Failed to load profiles');
    profilesData = await res.json();
    renderProfiles();
    updatePlaybackEmbed(lastServiceState);
  } catch (e) {
    console.error('loadProfiles:', e);
    // Fallback: show empty
    const el = document.getElementById('profilesList');
    if (el) el.innerHTML = '<div style="padding:16px;color:var(--text-dim);font-size:12px;">Could not load profiles</div>';
  }
}

function renderProfiles() {
  const container = document.getElementById('profilesList');
  if (!container || !profilesData) return;

  const activeId = profilesData.active;
  const profiles = profilesData.profiles || {};
  let html = '';

  for (const [id, p] of Object.entries(profiles)) {
    const isActive = id === activeId;
    const label = isActive ? (lastServiceState ? 'STREAMING NOW' : 'ACTIVE') : 'STANDBY';
    const isOpen = openEditPanel === id;

    html += `
      <div class="profile-card ${isActive ? 'active' : ''}" id="profile-${id}" onclick="switchProfile('${id}')">
        <div class="profile-card-top">
          <div class="profile-card-indicator"></div>
          <div class="profile-card-info">
            <div class="profile-card-label">${esc(label)}</div>
            <div class="profile-card-name">${esc(p.name || id)}</div>
            <div class="profile-card-meta">${esc(p.resolution || '1920x1080')} &middot; ${esc(p.bitrate || '4000k')} &middot; ${esc(p.platform || 'youtube')}</div>
          </div>
          <button class="profile-edit-btn ${isOpen ? 'active' : ''}" onclick="event.stopPropagation(); toggleProfileEdit('${id}')">&#9998;</button>
        </div>
        <div class="profile-edit-panel ${isOpen ? 'open' : ''}" id="profEditPanel-${id}">
          <div class="profile-edit-row">
            <span class="profile-edit-label">Name</span>
            <div class="profile-edit-input">
              <input class="key-input" id="nameInput-${id}" value="${esc(p.name || '')}" autocomplete="off" spellcheck="false">
            </div>
          </div>
          <div class="profile-edit-row">
            <span class="profile-edit-label">Platform</span>
            <div class="profile-edit-input">
              <select class="key-input" id="platformInput-${id}">
                <option value="youtube" selected>YouTube</option>
              </select>
            </div>
          </div>
          <div class="profile-edit-row">
            <span class="profile-edit-label">Resolution</span>
            <div class="profile-edit-input">
              <select class="key-input" id="resolutionInput-${id}">
                <option value="1920x1080" ${(p.resolution || '1920x1080') === '1920x1080' ? 'selected' : ''}>1920x1080 (FHD)</option>
                <option value="1280x720"  ${(p.resolution || '1920x1080') === '1280x720'  ? 'selected' : ''}>1280x720 (HD)</option>
              </select>
            </div>
          </div>
          <div class="profile-edit-row">
            <span class="profile-edit-label">Bitrate</span>
            <span class="key-display" id="bitrateDisplay-${id}">${esc(p.bitrate || '--')}</span>
            <div class="profile-edit-input">
              <input class="key-input" id="bitrateInput-${id}" placeholder="e.g. 4000k" autocomplete="off" spellcheck="false">
            </div>
          </div>
          <div class="profile-edit-row">
            <span class="profile-edit-label">Stream Key</span>
            <span class="key-display" id="keyDisplay-${id}">${maskKey(p.stream_key)}</span>
            <button class="btn-sm btn-reveal" id="btnReveal-${id}" onclick="event.stopPropagation(); toggleReveal('${id}')">Reveal</button>
            <div class="profile-edit-input">
              <input class="key-input" id="keyInput-${id}" placeholder="Stream key..." autocomplete="off" spellcheck="false">
            </div>
          </div>
          <div class="profile-edit-row">
            <span class="profile-edit-label">Playback URL</span>
            <div class="profile-edit-input">
              <input class="key-input" id="playbackInput-${id}" value="${esc(p.playback_url || '')}" placeholder="https://youtu.be/..." autocomplete="off" spellcheck="false">
            </div>
          </div>
          <div class="profile-edit-actions">
            <button class="btn-sm btn-save" onclick="event.stopPropagation(); saveProfile('${id}')">Save Changes</button>
          </div>
          <div class="profile-edit-hint">Changes to the active profile require a broadcast restart.</div>
        </div>
      </div>`;
  }

  container.innerHTML = html;

  // Attach input listeners
  container.querySelectorAll('input, select').forEach(el => {
    el.addEventListener('click', e => e.stopPropagation());
  });
}

function maskKey(key) {
  if (!key || key.length === 0) return '(not set)';
  if (key.length <= 4) return '****';
  return '*'.repeat(key.length - 4) + key.slice(-4);
}

/* ── Profile Edit Toggle ── */

function toggleProfileEdit(id) {
  if (openEditPanel === id) {
    openEditPanel = null;
  } else {
    openEditPanel = id;
  }
  renderProfiles();
}

/* ── Profile Switch ── */

function switchProfile(id) {
  if (!profilesData || profilesData.active === id) return;

  const p = profilesData.profiles[id];
  if (!p || !p.stream_key) {
    showToast('Cannot switch: "' + (p ? p.name : id) + '" has no stream key set.', false);
    return;
  }

  if (lastServiceState) {
    // Broadcasting — confirm switch
    const modal = document.getElementById('confirmModal');
    const msg = document.getElementById('confirmMsg');
    const btnConfirm = document.getElementById('confirmBtn');
    msg.textContent = 'Switch to "' + (p ? p.name : id) + '" and restart broadcast?';
    btnConfirm.textContent = 'Switch & Restart';
    btnConfirm.onclick = function() {
      hideConfirmModal();
      doSwitchProfile(id, true);
    };
    modal.classList.add('show');
  } else {
    doSwitchProfile(id, false);
  }
}

async function doSwitchProfile(id, restart) {
  try {
    const res = await fetch('/api/profiles/switch', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ profile_id: id })
    });
    const data = await res.json();
    if (data.ok) {
      profilesData.active = id;
      renderProfiles();
      showToast('Switched to profile. ' + (restart ? 'Restarting...' : ''), true);
      if (restart) {
        executeAction('restart');
      }
    } else {
      showToast('Switch failed: ' + (data.error || ''), false);
    }
  } catch (e) {
    showToast('Switch failed: ' + e.message, false);
  }
}

/* ── Save Profile ── */

async function saveProfile(id) {
  if (!profilesData || !profilesData.profiles[id]) return;

  const nameInput = document.getElementById('nameInput-' + id);
  const platformInput = document.getElementById('platformInput-' + id);
  const resolutionInput = document.getElementById('resolutionInput-' + id);
  const bitrateInput = document.getElementById('bitrateInput-' + id);
  const keyInput = document.getElementById('keyInput-' + id);
  const playbackInput = document.getElementById('playbackInput-' + id);
  const updates = {};
  if (nameInput && nameInput.value.trim()) updates.name = nameInput.value.trim();
  if (platformInput) updates.platform = platformInput.value;
  if (resolutionInput) updates.resolution = resolutionInput.value;
  if (bitrateInput && bitrateInput.value.trim()) updates.bitrate = bitrateInput.value.trim();
  if (keyInput && keyInput.value.trim()) updates.stream_key = keyInput.value.trim();
  if (playbackInput) updates.playback_url = playbackInput.value.trim();

  if (Object.keys(updates).length === 0) {
    showToast('No changes to save', false);
    return;
  }

  try {
    const res = await fetch('/api/profiles/' + id, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(updates)
    });
    const data = await res.json();
    if (data.ok) {
      const streamFields = ['bitrate', 'resolution', 'stream_key'];
      const needsRestart = profilesData.active === id && streamFields.some(f => f in updates);
      showToast('Profile saved.' + (needsRestart ? ' Restart to apply.' : ''), true);
      // Update local data
      Object.assign(profilesData.profiles[id], updates);
      // Clear inputs
      if (bitrateInput) bitrateInput.value = '';
      if (keyInput) keyInput.value = '';
      if (playbackInput) playbackInput.value = '';
      renderProfiles();
      updatePlaybackEmbed(lastServiceState);
    } else {
      showToast('Save failed: ' + (data.error || ''), false);
    }
  } catch (e) {
    showToast('Save failed: ' + e.message, false);
  }
}

/* ── Reveal Key ── */

function toggleReveal(id) {
  if (!profilesData || !profilesData.profiles[id]) return;
  const display = document.getElementById('keyDisplay-' + id);
  const btn = document.getElementById('btnReveal-' + id);
  if (!display) return;

  if (revealedKeys[id]) {
    // Hide
    revealedKeys[id] = false;
    display.textContent = maskKey(profilesData.profiles[id].stream_key);
    if (btn) btn.textContent = 'Reveal';
  } else {
    // Reveal — fetch from backend for the active profile, or show local for non-active
    if (profilesData.active === id) {
      fetch('/api/stream-key?reveal=true')
        .then(r => r.json())
        .then(data => {
          revealedKeys[id] = true;
          display.textContent = data.key || '(empty)';
          if (btn) btn.textContent = 'Hide';
        })
        .catch(() => {
          display.textContent = 'Error';
        });
    } else {
      // For non-active profiles, show from local data
      revealedKeys[id] = true;
      const key = profilesData.profiles[id].stream_key;
      display.textContent = key || '(empty)';
      if (btn) btn.textContent = 'Hide';
    }
  }
}

/* ── Polling ── */

async function fetchMetrics() {
  try {
    const res = await fetch('/api/metrics');
    const m = await res.json();
    if (res.ok) {
      updateMetrics(m);
    } else {
      updateMetrics({ ...m, service_running: false });
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
  const prevState = lastServiceState;
  lastServiceState = running;

  // Broadcast status (control bar)
  const broadcastDot = document.getElementById('broadcastDot');
  const broadcastLabel = document.getElementById('broadcastLabel');
  if (broadcastDot) {
    broadcastDot.className = 'broadcast-dot ' + (running ? 'live' : 'stopped');
  }
  if (broadcastLabel) {
    const mode = running ? (m.mode || 'LIVE').toUpperCase() : 'STOPPED';
    broadcastLabel.textContent = 'BROADCAST: ' + mode;
  }

  // Preview LIVE badge
  const previewLive = document.getElementById('previewLive');
  if (previewLive) previewLive.style.display = running ? 'inline' : 'none';

  // Header status dots
  updateStatusDots(m, running);

  // Uptime in control bar
  const uptimeEl = document.getElementById('s-uptime');
  if (uptimeEl) uptimeEl.textContent = running ? fmtUptime(m.uptime_s) : '00:00:00';

  // Broadcast status panel
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

  // State color
  const stateEl = document.getElementById('s-state');
  if (stateEl) {
    stateEl.className = 'stat-value' +
      (!running ? ' bad' : m.state === 'running' ? ' good' : ' warn');
  }

  // Network panel
  updateNetwork(m, running);

  // Re-render profile labels if service state changed
  if (prevState !== running && profilesData) {
    renderProfiles();
  }

  // Playback embed
  updatePlaybackEmbed(running);

  // Button states
  updateButtonStates(running);
}

function updatePlaybackEmbed(running) {
  const placeholder = document.getElementById('playbackPlaceholder');
  const embedDiv = document.getElementById('playbackEmbed');
  const header = document.getElementById('playbackHeader');

  const activeId = profilesData && profilesData.active;
  const activeProfile = activeId && profilesData && profilesData.profiles[activeId];
  const playbackUrl = activeProfile && activeProfile.playback_url;

  console.log('[Playback] running=' + running + ' activeId=' + activeId + ' playbackUrl=' + playbackUrl + ' profilesData=' + (profilesData ? 'loaded' : 'null'));

  let embedUrl = null;
  if (playbackUrl) {
    try {
      const u = new URL(playbackUrl);
      let videoId = null;
      if (u.hostname === 'youtu.be') {
        videoId = u.pathname.replace('/', '');
      } else if (u.searchParams.get('v')) {
        videoId = u.searchParams.get('v');
      } else {
        const liveMatch = u.pathname.match(/\/live\/([^/?]+)/);
        if (liveMatch) videoId = liveMatch[1];
      }
      if (videoId) embedUrl = 'https://www.youtube.com/embed/' + videoId + '?autoplay=1&mute=1';
      console.log('[Playback] hostname=' + u.hostname + ' videoId=' + videoId + ' embedUrl=' + embedUrl);
    } catch(e) { console.log('[Playback] URL parse error:', e); }
  }

  console.log('[Playback] final check: running=' + running + ' embedUrl=' + embedUrl);

  if (running && embedUrl) {
    if (placeholder) placeholder.style.display = 'none';
    if (header) header.style.display = 'block';
    if (embedDiv) {
      embedDiv.style.display = 'block';
      const existing = embedDiv.querySelector('iframe');
      if (!existing || existing.src !== embedUrl) {
        embedDiv.innerHTML = '<iframe src="' + embedUrl + '" allow="autoplay; encrypted-media" allowfullscreen></iframe>';
      }
    }
    return;
  }

  // No embed — show placeholder
  if (placeholder) placeholder.style.display = '';
  if (header) header.style.display = 'none';
  if (embedDiv) { embedDiv.style.display = 'none'; embedDiv.innerHTML = ''; }
}

function updateStatusDots(m, running) {
  const dotIngest = document.getElementById('dot-ingest');
  const dotUplink = document.getElementById('dot-uplink');

  if (dotIngest) {
    if (!running) {
      dotIngest.className = 'status-dot';
    } else if (m.sdi_signal === 1) {
      dotIngest.className = 'status-dot ok';
    } else {
      dotIngest.className = 'status-dot err';
    }
  }

  if (dotUplink) {
    const ping = m.network && m.network.ping;
    if (!running) {
      dotUplink.className = 'status-dot';
    } else if (ping && typeof ping === 'object' && ping.loss != null) {
      const loss = parseFloat(ping.loss);
      dotUplink.className = 'status-dot ' + (loss === 0 ? 'ok' : loss < 5 ? 'warn' : 'err');
    } else {
      dotUplink.className = 'status-dot warn';
    }
  }
}

function updateNetwork(m, running) {
  const n = m.network || {};

  setText('n-iface', friendlyNet(n.iface, n.service, running));
  setText('n-ip', friendlyNet(n.ip, null, running));
  setText('n-gw', n.gateway || '-');

  const nowMs = Date.now();
  if (prevNet && n.rx_bytes != null && n.tx_bytes != null) {
    const dtSec = (nowMs - prevNet.ts) / 1000;
    if (dtSec > 1 && (n.rx_bytes !== prevNet.rx || n.tx_bytes !== prevNet.tx)) {
      const rxRate = Math.max(0, (n.rx_bytes - prevNet.rx) / dtSec);
      const txRate = Math.max(0, (n.tx_bytes - prevNet.tx) / dtSec);
      rxHistory.push(rxRate);
      txHistory.push(txRate);
      if (rxHistory.length > 3) rxHistory.shift();
      if (txHistory.length > 3) txHistory.shift();
      prevNet = { rx: n.rx_bytes, tx: n.tx_bytes, ts: nowMs };
    }
  } else if (n.rx_bytes != null) {
    prevNet = { rx: n.rx_bytes, tx: n.tx_bytes, ts: nowMs };
  }
  if (!running) {
    rxHistory = [];
    txHistory = [];
    setText('n-rx-rate', '-');
    setText('n-tx-rate', '-');
  } else if (rxHistory.length > 0) {
    const avgRx = rxHistory.reduce((a, b) => a + b, 0) / rxHistory.length;
    const avgTx = txHistory.reduce((a, b) => a + b, 0) / txHistory.length;
    setText('n-rx-rate', fmtRate(avgRx));
    setText('n-tx-rate', fmtRate(avgTx));
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
    setText('n-loss', '-');
    setText('n-avg', '-');
    setText('n-jitter', '-');
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
  const btnGoLive = document.getElementById('btn-golive');
  const btnStopLive = document.getElementById('btn-stoplive');
  const btnRestart = document.getElementById('btn-restart');

  if (actionInProgress) {
    if (btnGoLive) btnGoLive.disabled = true;
    if (btnStopLive) btnStopLive.disabled = true;
    if (btnRestart) btnRestart.disabled = true;
    return;
  }

  if (running === true) {
    if (btnGoLive) { btnGoLive.style.display = 'none'; btnGoLive.disabled = true; }
    if (btnStopLive) { btnStopLive.style.display = ''; btnStopLive.disabled = false; }
    if (btnRestart) btnRestart.disabled = false;
  } else if (running === false) {
    if (btnGoLive) { btnGoLive.style.display = ''; btnGoLive.disabled = false; }
    if (btnStopLive) { btnStopLive.style.display = 'none'; btnStopLive.disabled = true; }
    if (btnRestart) btnRestart.disabled = true;
  } else {
    if (btnGoLive) { btnGoLive.style.display = ''; btnGoLive.disabled = true; }
    if (btnStopLive) { btnStopLive.style.display = 'none'; btnStopLive.disabled = true; }
    if (btnRestart) btnRestart.disabled = true;
  }
}

function updateEvents(events) {
  const tbody = document.getElementById('eventsBody');
  if (!events.length) {
    tbody.innerHTML = '<tr><td colspan="3" class="no-data">No events recorded yet</td></tr>';
    return;
  }
  const rows = events.reverse().map(e => {
    const ts = fmtTime(e.ts || '');
    const lvl = e.level || 'INFO';
    const msg = e.msg || e.message || '';
    return '<tr>' +
      '<td>' + esc(ts) + '</td>' +
      '<td class="lvl-' + esc(lvl) + '">' + esc(lvl) + '</td>' +
      '<td title="' + esc(msg) + '">' + esc(msg) + '</td>' +
      '</tr>';
  }).join('');
  tbody.innerHTML = rows;
}

/* ── Controls ── */

function ctrlAction(action) {
  if (action === 'start') {
    const activeId = profilesData && profilesData.active;
    const activeProfile = activeId && profilesData.profiles[activeId];
    if (!activeProfile || !activeProfile.stream_key) {
      showToast('Cannot go live: active profile has no stream key set. Set it in Stream Profiles.', false);
      return;
    }
    executeAction(action);
    return;
  }
  showConfirmModal(action);
}

function showConfirmModal(action) {
  const modal = document.getElementById('confirmModal');
  const msg = document.getElementById('confirmMsg');
  const btnConfirm = document.getElementById('confirmBtn');

  msg.textContent = 'Are you sure you want to ' + action + ' the broadcast?';
  btnConfirm.textContent = capitalize(action);
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
  const btnId = action === 'start' ? 'btn-golive' : action === 'stop' ? 'btn-stoplive' : 'btn-restart';
  const btn = document.getElementById(btnId);
  const orig = btn ? btn.innerHTML : '';
  if (btn) btn.innerHTML = '<span class="spinner"></span>' + capitalize(action) + '...';
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
    setTimeout(fetchMetrics, 1500);
    setTimeout(fetchMetrics, 4000);
  } catch (e) {
    showToast('Broadcast ' + action + ' failed: ' + e.message, false);
  } finally {
    actionInProgress = false;
    if (btn) btn.innerHTML = orig;
    updateButtonStates(lastServiceState);
  }
}

/* ── Utilities ── */

function setText(id, val) {
  const el = document.getElementById(id);
  if (el) el.textContent = val != null ? val : '-';
}

function setConn(ok) {
  const dot = document.getElementById('conn');
  if (dot) dot.className = 'conn-dot ' + (ok ? 'ok' : 'err');

  const hubDot = document.getElementById('dot-hub');
  if (hubDot) hubDot.className = 'status-dot ' + (ok ? 'ok' : 'err');
}

function fmtUptime(s) {
  if (s == null) return '00:00:00';
  s = Math.floor(s);
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  const pad = n => String(n).padStart(2, '0');
  if (d > 0) return d + 'd ' + pad(h) + ':' + pad(m) + ':' + pad(sec);
  return pad(h) + ':' + pad(m) + ':' + pad(sec);
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
  updateButtonStates(null);

  // Clock
  updateClock();
  setInterval(updateClock, 1000);

  // Modal
  const modal = document.getElementById('confirmModal');
  if (modal) modal.addEventListener('click', function(e) {
    if (e.target === modal) hideConfirmModal();
  });
  document.addEventListener('keydown', function(e) {
    if (e.key === 'Escape') hideConfirmModal();
  });

  // Load profiles then metrics
  loadProfiles();
  fetchMetrics();
  fetchEvents();
  setInterval(fetchMetrics, POLL_MS);
  setInterval(fetchEvents, EVENTS_POLL_MS);
});
