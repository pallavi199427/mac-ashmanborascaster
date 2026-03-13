# Open Issues

## Audio VU Meter Not Working (WebRTC Preview)

**Status:** Fixed (pending deploy)

**Root cause:**
The bridge was encoding audio as AAC (`-c:a aac`), but WebRTC only supports Opus. MediaMTX was receiving AAC over RTSP and passing an audio track to the browser, but the browser's WebRTC decoder couldn't play AAC — resulting in a silent audio track (VU meter flat, `-∞ dB`).

**Fix:**
Changed `yt_bridge.sh` audio codec from `-c:a aac` to `-c:a libopus`. Opus is the native WebRTC audio codec, so MediaMTX can pass it through directly to the browser without transcoding.

**Deploy steps:**
1. SCP updated `yt_bridge.sh` to Mac
2. Restart the bridge service (`ytctl restart bridge` or restart the whole stack)
3. Verify: open dashboard, click page to resume AudioContext, check VU meter shows levels
