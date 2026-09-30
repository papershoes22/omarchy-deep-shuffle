.pragma library

// Pure helpers for the deepshuffle widget: formatting, badges, archive progress.
// No QML types in here.

var PLAY = "󰐊", PAUSE = "󰏤", PREV = "󰒮", NEXT = "󰒭", STOP = "󰓛"
var SHUFFLE = "󰒟", REPEAT_ALL = "󰑖", REPEAT_ONE = "󰑘", REPEAT_OFF = "󰑗"
var NOTE = "󰝚", CLOUD = "󰅟", DISK = "󰋊", DOWNLOAD = "󰇚", VOLUME = "󰕾", MUTE = "󰖁"
var EXPAND = "󰊓", COLLAPSE = "󰊔", OPEN = "󰏌", CHECK = "󰄬", LOCK = "󰌾", CLOSE = "󰅖", ALERT = "󰀦", HOURGLASS = "󰔟", GLOW = "󰛨"

var PAGE = 300   // list rows per request

// Sidebar views; keys match the daemon's VIEWS.
var VIEW_LIST = [
  { key: "all", label: "All likes" },
  { key: "local", label: "Stored locally" },
  { key: "stream", label: "Streaming" },
  { key: "preview", label: "Go+ previews" },
  { key: "unavailable", label: "SoundCloud-only" },
  { key: "failed", label: "Failed", hideEmpty: true },
  { key: "unliked", label: "Unliked (kept)", hideEmpty: true }
]

var SORT_LIST = [
  { key: "liked", label: "Liked" },
  { key: "artist", label: "Artist" },
  { key: "title", label: "Title" },
  { key: "plays", label: "Plays" },
  { key: "duration", label: "Length" },
  { key: "archived", label: "Archived" }
]

function viewLabel(key) {
  for (var i = 0; i < VIEW_LIST.length; i++) if (VIEW_LIST[i].key === key) return VIEW_LIST[i].label.toLowerCase()
  return key
}

function merge(a, b) {
  var out = {}
  for (var k in a) if (a[k] !== "" && a[k] !== null && a[k] !== undefined) out[k] = a[k]
  for (var j in b) if (b[j] !== null && b[j] !== undefined) out[j] = b[j]
  return out
}

// ListModel wants consistent, non-null role types.
function listRows(rows) {
  var out = []
  for (var i = 0; i < (rows || []).length; i++) {
    var r = rows[i]
    out.push({
      sc_id: r.sc_id, title: r.title || "", artist: r.artist || "", duration: r.duration || 0,
      status: r.status || "", unliked: !!r.unliked, plays: r.plays || 0, genre: r.genre || "",
      permalink: r.permalink || "", archiving: !!r.archiving
    })
  }
  return out
}

function indexOfId(model, id) {
  for (var i = 0; i < model.count; i++) if (model.get(i).sc_id === id) return i
  return -1
}

function statusGlyph(status, archiving) {
  if (archiving) return DOWNLOAD
  switch (status) {
  case "archived": return CHECK
  case "linked": return CLOUD
  case "failed": return ALERT
  case "preview_only": return "30s"
  case "drm": return LOCK
  case "gone": return CLOSE
  }
  return ""
}

function statusTone(status, archiving) {
  if (archiving) return "accent"
  return status === "archived" ? "good" : status === "failed" ? "bad" : status === "preview_only" ? "warn" : "dim"
}

function statusLabel(status, archiving) {
  if (archiving) return "Queued: archive now"
  switch (status) {
  case "archived": return "Archived: plays from disk"
  case "linked": return "Not archived yet: streams from SoundCloud"
  case "failed": return "Archive failed 3×: still streams; hover the row for Archive now"
  case "preview_only": return "Go+ track: only a 30 s preview"
  case "drm": return "DRM-encrypted: SoundCloud only"
  case "gone": return "Removed or geo-blocked: SoundCloud only"
  }
  return status
}

function has(v) { return v !== null && v !== undefined && !isNaN(v) }

function pad(n) { return n < 10 ? "0" + n : "" + n }

// 125 -> "2:05"; 3725 -> "1:02:05"
function clock(secs) {
  if (!has(secs) || secs < 0) return "–:––"
  secs = Math.floor(secs)
  var h = Math.floor(secs / 3600), m = Math.floor(secs % 3600 / 60), s = secs % 60
  return h ? h + ":" + pad(m) + ":" + pad(s) : m + ":" + pad(s)
}

// 25200 -> "7h", 5400 -> "1h 30m", 600 -> "10m"
function eta(secs) {
  if (!has(secs) || secs <= 0) return ""
  var h = Math.floor(secs / 3600), m = Math.round(secs % 3600 / 60)
  if (h >= 10) return h + "h"
  if (h) return h + "h" + (m ? " " + m + "m" : "")
  return Math.max(1, m) + "m"
}

function thousands(n) { return has(n) ? String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ",") : "—" }

// Position right now, interpolated from the last snapshot while playing.
function livePos(p, nowSecs) {
  if (!p) return 0
  var pos = p.pos || 0
  if (p.state === "playing" && has(p.pos_at)) pos += Math.max(0, nowSecs - p.pos_at)
  return has(p.duration) && p.duration > 0 ? Math.min(pos, p.duration) : pos
}

function repeatGlyph(mode) { return mode === "one" ? REPEAT_ONE : mode === "off" ? REPEAT_OFF : REPEAT_ALL }

function stateGlyph(state) {
  return state === "playing" ? PLAY : state === "paused" ? PAUSE : state === "loading" ? "󰔟" : NOTE
}

// Small uppercase badges for the now-playing track: [{ text, tone }], tone = good|warn|bad|dim
function badges(t) {
  if (!t) return []
  var out = []
  if (t.source === "local") out.push({ text: "LOCAL", tone: "good" })
  else out.push({ text: "STREAM", tone: "dim" })
  if (t.status === "preview_only") out.push({ text: "PREVIEW", tone: "warn" })
  else if (t.status === "failed") out.push({ text: "ARCHIVE FAILED", tone: "bad" })
  else if (t.status === "linked") out.push({ text: "QUEUED", tone: "dim" })
  if (t.genre) out.push({ text: String(t.genre).toUpperCase(), tone: "dim" })
  if (t.play_count) out.push({ text: t.play_count + (t.play_count === 1 ? " PLAY" : " PLAYS"), tone: "dim" })
  return out
}

// Archive progress from state.archive.counts. Preview-only, DRM and gone tracks
// can never be archived, so they're left out of the denominator.
var SECS_PER_TRACK = 13

function archiveProgress(a) {
  var c = a && a.counts ? a.counts : null
  if (!c) return null
  var never = (c.preview_only || 0) + (c.drm || 0) + (c.gone || 0)
  var archivable = Math.max(1, (c.total || 0) - never)
  return {
    archived: c.archived || 0,
    archivable: archivable,
    fraction: (c.archived || 0) / archivable,
    queued: c.queued || 0,
    failed: c.failed || 0,
    preview: c.preview_only || 0,
    drm: c.drm || 0,
    gone: c.gone || 0,
    eta: eta((c.queued || 0) * SECS_PER_TRACK)
  }
}

function archiveStateLabel(a) {
  if (!a) return "not running"
  if (a.paused || a.state === "paused") return "paused"
  switch (a.state) {
  case "downloading": return "downloading"
  case "sleeping": return "between tracks"
  case "idle": return "up to date"
  case "rate_limited": return "rate limited"
  case "stopped": return "stopped"
  case "off": return "off"
  }
  return a.state || "?"
}

function filterLabel(f) {
  if (!f) return "all likes"
  var parts = []
  if (f.view && f.view !== "all") parts.push(viewLabel(f.view))
  if (f.local) parts.push("archived")
  if (f.genre) parts.push(f.genre)
  if (f.artist) parts.push(f.artist)
  if (f.query) parts.push("“" + f.query + "”")
  return parts.length ? parts.join(" · ") : "all likes"
}

function parseThemeColors(text) {
  var out = { green: "", red: "", yellow: "" }
  var src = String(text || "")
  var keys = ["green", "red", "yellow"]
  for (var i = 0; i < keys.length; i++) {
    var m = src.match(new RegExp("^\\s*" + keys[i] + "\\s*=\\s*\"(#[0-9a-fA-F]{6,8})\"", "m"))
    if (m) out[keys[i]] = m[1]
  }
  return out
}

// ---- equalizer + visualizer

var EQ_LABELS = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
var PRESET_LABELS = { flat: "Flat", bass: "Bass", treble: "Treble", vocal: "Vocal", loudness: "Loudness",
                      electronic: "Electronic", hiphop: "Hip-hop", custom: "Custom" }

function presetLabel(name) { return PRESET_LABELS[name] || name }

function dbLabel(g) {
  if (!has(g)) return ""
  var v = Math.round(g * 2) / 2
  return (v > 0 ? "+" : "") + v + " dB"
}

// Average `bars` (0..100) into n groups, 0..1.
function groupBars(bars, n) {
  var out = []
  var len = (bars || []).length
  for (var i = 0; i < n; i++) {
    if (!len) { out.push(0); continue }
    var a = Math.floor(i * len / n), b = Math.max(a + 1, Math.floor((i + 1) * len / n)), sum = 0
    for (var j = a; j < b; j++) sum += bars[j]
    out.push(sum / (b - a) / 100)
  }
  return out
}

// ---- manual sync (sync.json, written by `deepshuffle sync`)
var SYNC_STALE = 10 * 60   // a "running" older than this was killed mid-way

function isoSecs(iso) { var t = Date.parse(iso || ""); return isNaN(t) ? 0 : t / 1000 }

function ago(iso, nowSecs) {
  var d = Math.max(0, nowSecs - isoSecs(iso))
  if (d < 60) return "just now"
  if (d < 3600) return Math.floor(d / 60) + "m ago"
  if (d < 86400) return Math.floor(d / 3600) + "h ago"
  return Math.floor(d / 86400) + "d ago"
}

function syncRunning(s, nowSecs) {
  return !!s && s.state === "running" && nowSecs - isoSecs(s.started) < SYNC_STALE
}

function syncLine(s, nowSecs) {
  if (!s) return "Likes sync daily; tap Sync now to check for new ones"
  if (syncRunning(s, nowSecs)) return "Checking SoundCloud for new likes…"
  if (s.state === "error") return "Sync failed " + ago(s.at, nowSecs) + ": " + s.error
  if (s.state !== "done") return ""
  var parts = [s.new ? s.new + " new like" + (s.new === 1 ? "" : "s") : "no new likes"]
  if (s.unliked) parts.push(s.unliked + " unliked")
  return "Synced " + ago(s.at, nowSecs) + " · " + parts.join(" · ")
}
