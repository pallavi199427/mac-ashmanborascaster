#!/usr/bin/env python3
"""Patch app.js on Mac — fix uptime ticker: smooth ticking, restart detection, no stale flash."""

p = "/usr/local/lib/yt-dashboard/static/app.js"

with open(p) as f:
    c = f.read()

changed = False

# 1. Add globals if missing
if "uptimeBase" not in c:
    c = c.replace(
        "let pipelineData = null;",
        "let pipelineData = null;\nlet uptimeBase = null;\nlet uptimeEpoch = null;"
    )
    changed = True

# 2. Replace the entire uptime block in updateMetrics — handles all previous patch states
# Pattern A: original unpatched
OLD_A = (
    "  // Uptime in control bar\n"
    "  const uptimeEl = document.getElementById('s-uptime');\n"
    "  if (uptimeEl) uptimeEl.textContent = running ? fmtUptime(m.uptime_s) : '00:00:00';"
)
# Pattern B: first patch (set every poll)
OLD_B = (
    "if (isStreaming && m.uptime_s != null) { uptimeBase = m.uptime_s; uptimeEpoch = Date.now(); }"
)
# Pattern C: second patch (set once, no restart detection)
OLD_C = (
    "  if (isStreaming && m.uptime_s != null) {\n"
    "    if (uptimeBase == null) {\n"
    "      uptimeBase = m.uptime_s;\n"
    "      uptimeEpoch = Date.now();\n"
    "    }\n"
    "  } else if (!isStreaming) {"
)

NEW_UPTIME_BLOCK = (
    "  if (isStreaming && m.uptime_s != null) {\n"
    "    if (uptimeBase == null) {\n"
    "      uptimeBase = m.uptime_s;\n"
    "      uptimeEpoch = Date.now();\n"
    "    } else {\n"
    "      var expectedUptime = uptimeBase + (Date.now() - uptimeEpoch) / 1000;\n"
    "      if (m.uptime_s < expectedUptime - 10) {\n"
    "        uptimeBase = m.uptime_s;\n"
    "        uptimeEpoch = Date.now();\n"
    "      }\n"
    "    }\n"
    "  } else if (!isStreaming) {"
)

if OLD_C in c:
    c = c.replace(OLD_C, NEW_UPTIME_BLOCK)
    changed = True
elif OLD_B in c:
    # Replace just the set-every-poll line — need to reconstruct surrounding context
    OLD_B_FULL = (
        "  var isStreaming = running && m.state === 'running';\n"
        "  if (isStreaming && m.uptime_s != null) { uptimeBase = m.uptime_s; uptimeEpoch = Date.now(); }\n"
        "  else if (!isStreaming) { uptimeBase = null; uptimeEpoch = null;"
        " var uptimeEl = document.getElementById('s-uptime');"
        " if (uptimeEl) uptimeEl.textContent = '00:00:00'; }"
    )
    NEW_B_FULL = (
        "  var isStreaming = running && m.state === 'running';\n"
        "  if (isStreaming && m.uptime_s != null) {\n"
        "    if (uptimeBase == null) { uptimeBase = m.uptime_s; uptimeEpoch = Date.now(); }\n"
        "    else { var expectedUptime = uptimeBase + (Date.now() - uptimeEpoch) / 1000;\n"
        "      if (m.uptime_s < expectedUptime - 10) { uptimeBase = m.uptime_s; uptimeEpoch = Date.now(); } }\n"
        "  } else if (!isStreaming) { uptimeBase = null; uptimeEpoch = null;"
        " var uptimeEl = document.getElementById('s-uptime');"
        " if (uptimeEl) uptimeEl.textContent = '00:00:00'; }"
    )
    if OLD_B_FULL in c:
        c = c.replace(OLD_B_FULL, NEW_B_FULL)
        changed = True
    else:
        c = c.replace(OLD_B, NEW_B_FULL.split("\n")[1])  # fallback minimal replace
        changed = True
elif OLD_A in c:
    NEW_A = (
        "  // Uptime — only tick when actually streaming\n"
        "  var isStreaming = running && m.state === 'running';\n"
        "  if (isStreaming && m.uptime_s != null) {\n"
        "    if (uptimeBase == null) { uptimeBase = m.uptime_s; uptimeEpoch = Date.now(); }\n"
        "    else { var expectedUptime = uptimeBase + (Date.now() - uptimeEpoch) / 1000;\n"
        "      if (m.uptime_s < expectedUptime - 10) { uptimeBase = m.uptime_s; uptimeEpoch = Date.now(); } }\n"
        "  } else if (!isStreaming) { uptimeBase = null; uptimeEpoch = null;\n"
        "    var uptimeEl2 = document.getElementById('s-uptime');\n"
        "    if (uptimeEl2) uptimeEl2.textContent = '00:00:00'; }"
    )
    c = c.replace(OLD_A, NEW_A)
    changed = True

# 3. Add 1-second ticker in init (if not already there)
TICKER = (
    "  setInterval(function() {\n"
    "    var el = document.getElementById('s-uptime');\n"
    "    if (el && uptimeBase != null && uptimeEpoch != null) {\n"
    "      el.textContent = fmtUptime(uptimeBase + (Date.now() - uptimeEpoch) / 1000);\n"
    "    }\n"
    "  }, 1000);"
)
if "uptimeBase != null" not in c:
    c = c.replace(
        "setInterval(updateClock, 1000);",
        "setInterval(updateClock, 1000);\n" + TICKER
    )
    changed = True

# 4. Clear stale uptime on button press (if not already there)
RESET_BLOCK = (
    "\n  // Clear stale uptime immediately so ticker doesn't flash old values\n"
    "  uptimeBase = null;\n"
    "  uptimeEpoch = null;\n"
    "  var uptimeElReset = document.getElementById('s-uptime');\n"
    "  if (uptimeElReset) uptimeElReset.textContent = '00:00:00';\n"
)
if "Clear stale uptime" not in c:
    c = c.replace(
        "async function executeAction(action) {\n  actionInProgress = true;\n",
        "async function executeAction(action) {\n  actionInProgress = true;\n" + RESET_BLOCK
    )
    changed = True

with open(p, "w") as f:
    f.write(c)

if changed:
    print("Done — refresh browser (Cmd+Shift+R)")
else:
    print("WARNING: No patterns matched — file may already be up to date or in unexpected state")
    print("Check the uptime block in", p, "manually")
