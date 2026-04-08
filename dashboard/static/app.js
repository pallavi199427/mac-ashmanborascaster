/* ── ASHMAN Broadcast Dashboard — Multi-Profile + WebRTC Preview ── */

const POLL_MS = 3000;
const EVENTS_POLL_MS = 10000;
const PIPELINE_POLL_MS = 5000;
let actionInProgress = false;
let lastServiceState = null;
let prevNet = null;
let profilesData = null; // { active: 'profile1', profiles: { ... } }
let openEditPanel = null;
let revealedKeys = {}; // profileId -> true/false
let pipelineData = null; // { ingest: {running, metrics}, bridge: {running, status}, uplink: {running, metrics}, mediamtx: {running} }
let uptimeBase = null;        // server-reported uptime_s at last fetch
let uptimeEpoch = null;       // Date.now() when uptimeBase was set
let sessionStartedAt = null;  // Date.now() when user last clicked Go Live/Restart

/* ── WebRTC WHEP Player ── */
let whepPc = null;
let whepRetryTimer = null;
let whepDisconnectTimer = null;
let audioCtx = null;
let audioAnalyser = null;
let audioSource = null;
let vuAnimFrame = null;
let isMuted = true;
const WHEP_URL = window.location.protocol + '//' + window.location.host + '/whep';

async function startWhepPlayer() {
  stopWhepPlayer();

  try {
    const pc = new RTCPeerConnection({
      iceServers: [{ urls: 'stun:stun.l.google.com:19302' }]
    });
    whepPc = pc;

    pc.addTransceiver('video', { direction: 'recvonly' });
    pc.addTransceiver('audio', { direction: 'recvonly' });

    pc.ontrack = function(event) {
      console.log('[WHEP] ontrack: kind=' + event.track.kind + ' readyState=' + event.track.readyState);
      const video = document.getElementById('previewVideo');
      if (video && event.streams && event.streams[0]) {
        video.srcObject = event.streams[0];
        video.play().catch(function() {});
        const overlay = document.getElementById('previewOverlay');
        if (overlay) overlay.style.display = 'none';
        // Only set up audio meter when we receive the audio track
        if (event.track.kind === 'audio') {
          var stream = event.streams[0];
          var audioTracks = stream.getAudioTracks();
          console.log('[WHEP] Audio tracks: ' + audioTracks.length + ', enabled=' + (audioTracks[0] ? audioTracks[0].enabled : 'N/A'));
          setupAudioMeter(stream);
        }
      }
    };

    pc.oniceconnectionstatechange = function() {
      var state = pc.iceConnectionState;
      if (state === 'failed' || state === 'closed') {
        if (whepDisconnectTimer) { clearTimeout(whepDisconnectTimer); whepDisconnectTimer = null; }
        scheduleWhepRetry();
      } else if (state === 'disconnected') {
        // Grace period: disconnected is transient and often self-recovers
        if (!whepDisconnectTimer) {
          whepDisconnectTimer = setTimeout(function() {
            whepDisconnectTimer = null;
            if (whepPc && whepPc.iceConnectionState !== 'connected' && whepPc.iceConnectionState !== 'completed') {
              scheduleWhepRetry();
            }
          }, 3000);
        }
      } else if (state === 'connected' || state === 'completed') {
        if (whepDisconnectTimer) { clearTimeout(whepDisconnectTimer); whepDisconnectTimer = null; }
      }
    };

    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    const res = await fetch(WHEP_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/sdp' },
      body: pc.localDescription.sdp
    });

    if (!res.ok) {
      throw new Error('WHEP ' + res.status);
    }

    const answerSdp = await res.text();
    await pc.setRemoteDescription(new RTCSessionDescription({
      type: 'answer',
      sdp: answerSdp
    }));
  } catch (e) {
    console.log('[WHEP] Connection failed:', e.message);
    scheduleWhepRetry();
  }
}

function stopWhepPlayer() {
  if (whepRetryTimer) { clearTimeout(whepRetryTimer); whepRetryTimer = null; }
  if (whepDisconnectTimer) { clearTimeout(whepDisconnectTimer); whepDisconnectTimer = null; }
  if (vuAnimFrame) { cancelAnimationFrame(vuAnimFrame); vuAnimFrame = null; }
  if (audioSource) { audioSource.disconnect(); audioSource = null; }
  if (audioAnalyser) { audioAnalyser = null; }
  if (audioCtx) { audioCtx.close().catch(function() {}); audioCtx = null; }
  pendingAudioStream = null;
  if (whepPc) { whepPc.close(); whepPc = null; }
  const video = document.getElementById('previewVideo');
  if (video) video.srcObject = null;
  const overlay = document.getElementById('previewOverlay');
  if (overlay) overlay.style.display = '';
  resetVuMeter();
}

function scheduleWhepRetry() {
  if (whepRetryTimer) return;
  whepRetryTimer = setTimeout(function() {
    whepRetryTimer = null;
    startWhepPlayer();
  }, 5000);
}

/* ── Audio VU Meter ── */
let pendingAudioStream = null;

function setupAudioMeter(stream) {
  pendingAudioStream = stream;
  // Create AudioContext eagerly — it may start suspended, that's OK
  // The analyser will be connected and ready for when context resumes on click
  initAudioContext(stream);
  if (!vuAnimFrame) updateVuMeter();
}

function initAudioContext(stream) {
  if (!stream) return;
  if (audioSource) { audioSource.disconnect(); audioSource = null; }
  if (audioCtx) { audioCtx.close().catch(function() {}); audioCtx = null; }
  audioAnalyser = null;

  try {
    var ctx = new (window.AudioContext || window.webkitAudioContext)();
    audioCtx = ctx;
    audioSource = ctx.createMediaStreamSource(stream);
    audioAnalyser = ctx.createAnalyser();
    audioAnalyser.fftSize = 2048;
    audioAnalyser.smoothingTimeConstant = 0.3;
    audioSource.connect(audioAnalyser);
    // Do NOT connect to ctx.destination — we don't want to double-play audio
    console.log('[Audio] AudioContext created, state=' + ctx.state);

    ctx.onstatechange = function() {
      console.log('[Audio] AudioContext state changed to: ' + ctx.state);
    };

    if (ctx.state === 'suspended') {
      console.log('[Audio] Context suspended — will resume on first user click');
      ctx.resume().catch(function() {});
    }
  } catch(e) {
    console.log('[Audio] Failed to create AudioContext:', e);
  }
}

// Resume AudioContext on any user click (browser autoplay policy)
document.addEventListener('click', function resumeAudio() {
  if (audioCtx && audioCtx.state === 'suspended') {
    audioCtx.resume().then(function() {
      console.log('[Audio] Resumed on click, state=' + audioCtx.state);
    });
  }
  // If context was destroyed (e.g. after reconnect) but stream exists, recreate
  if (pendingAudioStream && !audioCtx) {
    console.log('[Audio] Recreating AudioContext on user gesture');
    initAudioContext(pendingAudioStream);
  }
}, { once: false });

function updateVuMeter() {
  // Keep animation frame loop alive so AudioContext stays active for mute/unmute
  vuAnimFrame = requestAnimationFrame(updateVuMeter);
}

function resetVuMeter() {
  // No visual elements to reset
}

function toggleMute() {
  var video = document.getElementById('previewVideo');
  var btn = document.getElementById('muteBtn');
  if (!video || !btn) return;

  // Create AudioContext on this user gesture if not yet created
  if (!audioCtx && pendingAudioStream) {
    console.log('[Audio] Creating AudioContext from mute toggle');
    initAudioContext(pendingAudioStream);
  } else if (audioCtx && audioCtx.state === 'suspended') {
    audioCtx.resume();
  }

  isMuted = !isMuted;
  video.muted = isMuted;
  btn.innerHTML = isMuted
    ? '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M16.5 12c0-1.77-1.02-3.29-2.5-4.03v2.21l2.45 2.45c.03-.2.05-.41.05-.63zm2.5 0c0 .94-.2 1.82-.54 2.64l1.51 1.51C20.63 14.91 21 13.5 21 12c0-4.28-2.99-7.86-7-8.77v2.06c2.89.86 5 3.54 5 6.71zM4.27 3L3 4.27 7.73 9H3v6h4l5 5v-6.73l4.25 4.25c-.67.52-1.42.93-2.25 1.18v2.06c1.38-.31 2.63-.95 3.69-1.81L19.73 21 21 19.73l-9-9L4.27 3zM12 4L9.91 6.09 12 8.18V4z"/></svg>'
    : '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z"/></svg>';
  btn.title = isMuted ? 'Unmute audio' : 'Mute audio';
}

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

function clearBroadcastStatus() {
  setText('s-mode', '-');
  setText('s-state', 'switching...');
  setText('s-bitrate', '-');
  setText('s-fps', '-');
  setText('s-speed', '-');
  setText('s-ts', '-');
  var stateEl = document.getElementById('s-state');
  if (stateEl) stateEl.className = 'stat-value warn';
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
      clearBroadcastStatus();
      const pName = profilesData.profiles[id] ? profilesData.profiles[id].name : id;
      if (restart) {
        showToast('Switched to ' + pName + '. Restarting broadcast...', true);
      } else {
        showToast('Switched to ' + pName + '. Click GO LIVE to start broadcasting.', true);
      }
      if (restart) {
        // Restart ingest first (picks up new bitrate), then uplink (copies new stream)
        // Bridge/mediamtx stay running so preview is not interrupted
        await fetch('/api/control', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ action: 'restart', service: 'ingest' })
        });
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

/* ── Pipeline Polling ── */

async function fetchPipeline() {
  try {
    const res = await fetch('/api/pipeline');
    if (!res.ok) return;
    pipelineData = await res.json();
    updatePipelineDots();
  } catch { /* silent */ }
}

function updatePipelineDots() {
  if (!pipelineData) return;

  // Ingest dot: green if running, grey if stopped
  const ingest = pipelineData.ingest || {};
  const ingestMetrics = ingest.metrics || {};
  let ingestCls = 'status-dot';
  if (ingest.running) {
    ingestCls = 'status-dot ok';
  }
  ['dot-ingest', 'dot-ingest-m'].forEach(function(id) {
    const el = document.getElementById(id);
    if (el) el.className = ingestCls;
  });

  // Bridge dot (HUB): green if bridge + mediamtx running
  const bridge = pipelineData.bridge || {};
  const mediamtx = pipelineData.mediamtx || {};
  let hubCls = 'status-dot';
  if (bridge.running && mediamtx.running) {
    hubCls = 'status-dot ok';
  } else if (bridge.running || mediamtx.running) {
    hubCls = 'status-dot warn';
  }
  ['dot-hub', 'dot-hub-m'].forEach(function(id) {
    const el = document.getElementById(id);
    if (el) el.className = hubCls;
  });

  // Uplink dot: use network ping data from uplink metrics
  const uplink = pipelineData.uplink || {};
  const uplinkMetrics = uplink.metrics || {};
  let uplinkCls = 'status-dot';
  if (uplink.running) {
    const ping = uplinkMetrics.network && uplinkMetrics.network.ping;
    if (ping && typeof ping === 'object' && ping.loss != null) {
      const loss = parseFloat(ping.loss);
      uplinkCls = 'status-dot ' + (loss === 0 ? 'ok' : loss < 5 ? 'warn' : 'err');
    } else {
      uplinkCls = 'status-dot warn';
    }
  }
  ['dot-uplink', 'dot-uplink-m'].forEach(function(id) {
    const el = document.getElementById(id);
    if (el) el.className = uplinkCls;
  });

  // Preview badge: update resolution from ingest metrics
  const previewInfo = document.getElementById('previewInfo');
  if (previewInfo && ingest.running) {
    const fmt = ingestMetrics.format || 'WebRTC';
    previewInfo.textContent = fmt;
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

  // Pipeline status dots are now handled by fetchPipeline(), not here

  // Uptime — only tick when state is "running" (actually streaming)
  const isStreaming = running && m.state === 'running';
  if (isStreaming && m.uptime_s != null) {
    // Reject stale uptime from previous session: if we know when we clicked Go Live,
    // the server's uptime_s must be <= time elapsed since then (plus a 5s grace period)
    const maxAllowedUptime = sessionStartedAt != null
      ? (Date.now() - sessionStartedAt) / 1000 + 5
      : Infinity;
    if (m.uptime_s > maxAllowedUptime) {
      // Server hasn't restarted ffmpeg yet — still showing old session uptime, ignore
    } else if (uptimeBase == null) {
      // First valid lock-in for this session
      uptimeBase = m.uptime_s;
      uptimeEpoch = Date.now();
    } else {
      // Re-lock if server uptime dropped significantly (ffmpeg restarted internally)
      const expectedUptime = uptimeBase + (Date.now() - uptimeEpoch) / 1000;
      if (m.uptime_s < expectedUptime - 10) {
        uptimeBase = m.uptime_s;
        uptimeEpoch = Date.now();
      }
    }
  } else if (!isStreaming) {
    uptimeBase = null;
    uptimeEpoch = null;
    const uptimeEl = document.getElementById('s-uptime');
    if (uptimeEl) uptimeEl.textContent = '00:00:00';
  }

  // Broadcast status panel
  setText('s-mode', running ? (m.mode || '-') : 'STOPPED');
  setText('s-state', running ? (m.state || '-') : 'stopped');
  setText('s-bitrate', m.bitrate || '-');
  setText('s-ts', m.ts ? fmtTime(m.ts) : '-');

  // FFmpeg stats
  const ff = m.ffmpeg || {};
  setText('s-fps', running && ff.fps ? ff.fps : '-');
  setText('s-speed', running && ff.speed ? ff.speed.trim() : '-');
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

// updateStatusDots is now replaced by updatePipelineDots() via fetchPipeline()

function updateNetwork(m, running) {
  const n = m.network || {};

  setText('n-iface', friendlyNet(n.iface, n.service, running));
  setText('n-ip', friendlyNet(n.ip, null, running));
  setText('n-gw', n.gateway || '-');

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
  const btnBwCheck = document.getElementById('btn-bwcheck');

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
    if (btnBwCheck) {
      btnBwCheck.disabled = true;
      btnBwCheck.title = 'Streaming is live — stop broadcast before running a bandwidth test';
    }
  } else if (running === false) {
    if (btnGoLive) { btnGoLive.style.display = ''; btnGoLive.disabled = false; }
    if (btnStopLive) { btnStopLive.style.display = 'none'; btnStopLive.disabled = true; }
    if (btnRestart) btnRestart.disabled = true;
    if (btnBwCheck) {
      btnBwCheck.disabled = false;
      btnBwCheck.title = 'Test upload bandwidth before going live';
    }
  } else {
    if (btnGoLive) { btnGoLive.style.display = ''; btnGoLive.disabled = true; }
    if (btnStopLive) { btnStopLive.style.display = 'none'; btnStopLive.disabled = true; }
    if (btnRestart) btnRestart.disabled = true;
    if (btnBwCheck) {
      btnBwCheck.disabled = false;
      btnBwCheck.title = 'Test upload bandwidth before going live';
    }
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

  // Clear stale uptime immediately so ticker doesn't flash old values
  uptimeBase = null;
  uptimeEpoch = null;
  if (action === 'start' || action === 'restart') sessionStartedAt = Date.now();
  else sessionStartedAt = null;
  var uptimeEl = document.getElementById('s-uptime');
  if (uptimeEl) uptimeEl.textContent = '00:00:00';

  const btnId = action === 'start' ? 'btn-golive' : action === 'stop' ? 'btn-stoplive' : 'btn-restart';
  const btn = document.getElementById(btnId);
  const orig = btn ? btn.innerHTML : '';
  if (btn) btn.innerHTML = '<span class="spinner"></span>' + capitalize(action) + '...';
  updateButtonStates(lastServiceState);

  try {
    // Restart ingest in background so it picks up current profile bitrate
    // (fire-and-forget — old ingest keeps running until launchd replaces it)
    if (action === 'start' || action === 'restart') {
      fetch('/api/control', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'restart', service: 'ingest' })
      }).catch(function() {});
    }
    const res = await fetch('/api/control', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action, service: 'uplink' })
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

/* ── Bandwidth Speed Test ── */

let bwPollTimer = null;

function runSpeedTest() {
  if (lastServiceState === true) return; // blocked while streaming
  const btn = document.getElementById('btn-bwcheck');
  if (btn) { btn.disabled = true; btn.innerHTML = '<span class="spinner"></span>Testing...'; }

  // Always show the result area — never hide it once revealed
  const area = document.getElementById('bw-result-area');
  if (area) area.style.display = '';
  setText('bw-speed', 'Testing...');
  // Keep Required/Tested/Verdict from last run visible until new result arrives
  const verdictEl = document.getElementById('bw-verdict');
  if (verdictEl) { verdictEl.textContent = ''; verdictEl.className = 'bw-verdict'; }
  const suggEl = document.getElementById('bw-suggestion');
  if (suggEl) suggEl.style.display = 'none';

  fetch('/api/speedtest/run', { method: 'POST' })
    .then(r => r.json())
    .then(data => {
      if (data.status === 'running' || data.status === 'done') {
        pollSpeedTestResult();
      } else {
        finishSpeedTest(false, data.message || 'Failed to start test');
      }
    })
    .catch(e => finishSpeedTest(false, e.message));
}

function pollSpeedTestResult() {
  if (bwPollTimer) clearTimeout(bwPollTimer);
  bwPollTimer = setTimeout(function() {
    fetch('/api/speedtest/result')
      .then(r => r.json())
      .then(data => {
        if (data.status === 'running') {
          // Show live current speed while test is in progress
          if (data.current_mbps != null) {
            setText('bw-speed', data.current_mbps.toFixed(1) + ' Mbps ↑');
            const btn = document.getElementById('btn-bwcheck');
            if (btn) btn.innerHTML = '<span class="spinner"></span>' + data.current_mbps.toFixed(0) + ' Mbps...';
          }
          pollSpeedTestResult();
        } else if (data.status === 'done') {
          renderSpeedTestResult(data);
        } else {
          finishSpeedTest(false, data.message || 'Test failed');
        }
      })
      .catch(e => finishSpeedTest(false, e.message));
  }, 1000);
}

function renderSpeedTestResult(data) {
  const measuredMbps = data.mbps;

  let requiredMbps = null;
  let requiredLabel = '-';
  if (profilesData && profilesData.active && profilesData.profiles) {
    const p = profilesData.profiles[profilesData.active];
    if (p && p.bitrate) {
      const kbps = parseInt(p.bitrate.replace('k', ''), 10);
      if (!isNaN(kbps)) {
        requiredMbps = Math.round(kbps * 1.2) / 1000;
        requiredLabel = requiredMbps.toFixed(1) + ' Mbps (' + p.bitrate + ' +20%)';
      }
    }
  }

  setText('bw-speed', measuredMbps.toFixed(1) + ' Mbps');
  setText('bw-required', requiredLabel);
  setText('bw-tested-at', new Date(data.ts * 1000).toLocaleTimeString());

  let verdict, verdictClass, suggestionText;
  if (requiredMbps === null) {
    verdict = measuredMbps.toFixed(1) + ' Mbps measured';
    verdictClass = 'bw-verdict';
    suggestionText = null;
  } else {
    const ratio = measuredMbps / requiredMbps;
    if (ratio >= 1.3) {
      verdict = 'GOOD — sufficient bandwidth';
      verdictClass = 'bw-verdict good';
      suggestionText = null;
    } else if (ratio >= 1.0) {
      verdict = 'MARGINAL — close to limit';
      verdictClass = 'bw-verdict warn';
      suggestionText = buildSuggestion(measuredMbps);
    } else {
      verdict = 'INSUFFICIENT — stream may fail';
      verdictClass = 'bw-verdict bad';
      suggestionText = buildSuggestion(measuredMbps);
    }
  }

  const verdictEl = document.getElementById('bw-verdict');
  if (verdictEl) { verdictEl.textContent = verdict; verdictEl.className = verdictClass; }

  const suggEl = document.getElementById('bw-suggestion');
  if (suggEl) {
    if (suggestionText) {
      suggEl.textContent = suggestionText;
      suggEl.style.display = '';
    } else {
      suggEl.style.display = 'none';
    }
  }

  finishSpeedTest(true, null);
}

function buildSuggestion(measuredMbps) {
  if (!profilesData || !profilesData.profiles) return null;
  const currentActiveId = profilesData.active;
  let bestId = null, bestKbps = 0;
  for (const [id, p] of Object.entries(profilesData.profiles)) {
    if (id === currentActiveId) continue;
    const kbps = parseInt((p.bitrate || '0').replace('k', ''), 10);
    const neededMbps = Math.round(kbps * 1.2) / 1000;
    if (neededMbps <= measuredMbps && kbps > bestKbps) {
      bestKbps = kbps;
      bestId = id;
    }
  }
  if (bestId) {
    const p = profilesData.profiles[bestId];
    return 'Consider switching to "' + (p.name || bestId) + '" (' + p.bitrate + ')';
  }
  return 'Bandwidth may be insufficient for any configured profile.';
}

function finishSpeedTest(ok, errorMsg) {
  const btn = document.getElementById('btn-bwcheck');
  if (btn) { btn.disabled = false; btn.innerHTML = 'BW CHECK'; }
  if (errorMsg) {
    setText('bw-speed', 'Error');
    const verdictEl = document.getElementById('bw-verdict');
    if (verdictEl) { verdictEl.textContent = errorMsg; verdictEl.className = 'bw-verdict bad'; }
    showToast('Speed test failed: ' + errorMsg, false);
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

  const hubCls = 'status-dot ' + (ok ? 'ok' : 'err');
  const hubDot = document.getElementById('dot-hub');
  if (hubDot) hubDot.className = hubCls;
  const hubDotM = document.getElementById('dot-hub-m');
  if (hubDotM) hubDotM.className = hubCls;
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

  // Uptime ticker — increments client-side every second between server polls
  setInterval(function() {
    const el = document.getElementById('s-uptime');
    if (!el) return;
    if (uptimeBase != null && uptimeEpoch != null) {
      const elapsed = (Date.now() - uptimeEpoch) / 1000;
      el.textContent = fmtUptime(uptimeBase + elapsed);
    }
  }, 1000);

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
  fetchPipeline();
  setInterval(fetchMetrics, POLL_MS);
  setInterval(fetchEvents, EVENTS_POLL_MS);
  setInterval(fetchPipeline, PIPELINE_POLL_MS);

  // Restore last BW CHECK result if available
  fetch('/api/speedtest/result')
    .then(r => r.json())
    .then(data => {
      if (data.status === 'done' && data.mbps != null) {
        const area = document.getElementById('bw-result-area');
        if (area) area.style.display = '';
        renderSpeedTestResult(data);
      }
    })
    .catch(() => {});

  // Start WebRTC preview player
  startWhepPlayer();
});

// ---------- Network Configuration ----------

function openNetConfig() {
  const form = document.getElementById('net-config');
  const stats = document.getElementById('net-stats');
  const status = document.getElementById('nc-status');
  if (!form) return;
  status.textContent = 'Loading...';
  status.className = 'form-status';
  form.style.display = '';
  stats.style.display = 'none';

  fetch('/api/network')
    .then(r => r.json())
    .then(data => {
      status.textContent = '';
      // Populate interface dropdown
      const sel = document.getElementById('nc-iface');
      sel.innerHTML = '';
      (data.interfaces || []).forEach(iface => {
        const opt = document.createElement('option');
        opt.value = iface.name;
        opt.textContent = iface.name + ' (' + iface.device + ')';
        if (iface.name === data.active_service) opt.selected = true;
        sel.appendChild(opt);
      });

      // Set mode
      const radios = document.querySelectorAll('input[name="nc-mode"]');
      radios.forEach(r => { r.checked = (r.value === (data.dhcp ? 'dhcp' : 'static')); });

      // Populate fields
      document.getElementById('nc-ip').value = data.ip || '';
      document.getElementById('nc-subnet').value = data.subnet || '';
      document.getElementById('nc-gateway').value = data.gateway || '';
      document.getElementById('nc-dns').value = (data.dns || []).join(', ');

      toggleNetMode();
    })
    .catch(err => {
      status.textContent = 'Failed to load network config';
      status.className = 'form-status error';
    });
}

function closeNetConfig() {
  const form = document.getElementById('net-config');
  const stats = document.getElementById('net-stats');
  if (form) form.style.display = 'none';
  if (stats) stats.style.display = '';
}

function toggleNetMode() {
  const mode = document.querySelector('input[name="nc-mode"]:checked');
  const fields = document.getElementById('nc-static-fields');
  if (!mode || !fields) return;
  const isStatic = mode.value === 'static';
  fields.style.opacity = isStatic ? '1' : '0.4';
  fields.querySelectorAll('input').forEach(inp => { inp.disabled = !isStatic; });
}

function applyNetConfig() {
  const status = document.getElementById('nc-status');
  const mode = document.querySelector('input[name="nc-mode"]:checked');
  if (!mode) return;

  const payload = {
    service: document.getElementById('nc-iface').value,
    mode: mode.value
  };

  if (mode.value === 'static') {
    payload.ip = document.getElementById('nc-ip').value.trim();
    payload.subnet = document.getElementById('nc-subnet').value.trim();
    payload.gateway = document.getElementById('nc-gateway').value.trim();
    if (!payload.ip || !payload.subnet) {
      status.textContent = 'IP and Subnet are required for static mode';
      status.className = 'form-status error';
      return;
    }
  }

  const dnsVal = document.getElementById('nc-dns').value.trim();
  if (dnsVal) {
    payload.dns = dnsVal.split(/[,\s]+/).filter(d => d);
  }

  status.textContent = 'Applying...';
  status.className = 'form-status';

  fetch('/api/network', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload)
  })
    .then(r => r.json())
    .then(data => {
      if (data.ok) {
        status.textContent = 'Network settings applied';
        status.className = 'form-status success';
        setTimeout(closeNetConfig, 2000);
      } else {
        status.textContent = data.error || 'Failed to apply';
        status.className = 'form-status error';
      }
    })
    .catch(err => {
      status.textContent = 'Network error';
      status.className = 'form-status error';
    });
}
