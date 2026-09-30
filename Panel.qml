import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Dropdown for sclikes, in two sizes:
//  - compact: now playing, scrubber, transport, volume, up next, archive progress
//  - expanded (⤢): a full player in its own window (a normal Hyprland toplevel, so it stays
//    open while you work elsewhere), with a library sidebar (views, genres, artists), a
//    searchable, sortable track list, and the compact body as the now-playing column
// Data comes from two places. state.json is written by the `sclikes` daemon about once a
// second while playing (sections "player" and "archive"). A persistent connection to
// ctl.sock sends commands; each request carries an id, and its reply is routed back to
// the caller. Player commands reply with a fresh player snapshot.
// Play on a remote machine (`sclikes play-on remote`): the local daemon stops and `sclikes remote`
// serves the same ctl.sock and state.json, relayed from the other machine's daemon over ssh, so
// everything here works unchanged. Only volume (the remote's output, reported in state.json's sysvol)
// and sync go their own way.
Panel {
  id: root
  moduleName: "io.github.papershoes22.sclikes"
  ipcTarget: "io.github.papershoes22.sclikes"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/sclikes"
  readonly property string themeColorsPath: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"

  property var st: null          // whole state.json
  property var pl: null          // player snapshot (newest of file / socket reply)
  property string cmdError: ""   // last error reply from the daemon
  property real now: Date.now() / 1000
  property var themeColors: ({ green: "", red: "", yellow: "" })

  // ---- full-player state (kept here so it survives switching modes)
  property bool expanded: false   // the full-player window is open
  readonly property bool shown: root.opened || root.expanded
  property string view: "all"
  property string query: ""
  property string artistFilter: ""
  property string genreFilter: ""
  property string sortKey: "liked"
  property int rowsTotal: 0
  property bool rowsLoading: false
  property int listGen: 0
  property int selIndex: -1
  property var facets: null
  property var searchItem: null   // set by the full view
  property var listItem: null
  property string lastArchivedAt: ""

  // ---- manual sync (sync.json; runs the same unit as the daily timer)
  property var syncInfo: null
  property bool syncRequested: false   // clicked, the unit hasn't written "running" yet
  readonly property bool syncing: syncRequested || Model.syncRunning(syncInfo, now)

  // ---- visualizer / equalizer / screensaver
  property var vizFrame: []         // newest frame from the daemon (cava, ~30 fps); nothing binds to it
  property var vizBars: []          // copied from vizFrame only while the dropdown/overlay is visible
  property var pillBars: [0, 0, 0, 0, 0]
  property bool vizAvailable: false // cava installed (daemon says so, or frames arrive)
  property bool showEq: false
  property var saverWindows: ({})   // Omarchy screensaver windows (address -> true)
  property int saverCount: 0
  readonly property var eq: pl && pl.eq ? pl.eq : null
  readonly property bool saverActive: saverCount > 0 && daemonUp && pstate === "playing"
  readonly property var anchorWindow: root.anchorItem ? root.anchorItem.QsWindow.window : null

  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.5)
  readonly property color faint: Qt.darker(fg, 2.2)
  readonly property color goodColor: themeColors.green !== "" ? themeColors.green : "#9ece6a"
  readonly property color badColor: themeColors.red !== "" ? themeColors.red : (root.bar ? root.bar.urgent : "#f7768e")
  readonly property color warnColor: themeColors.yellow !== "" ? themeColors.yellow : "#e0af68"
  // Accent follows the current cover art (daemon: track.color, the art's dominant vivid hue), re-lit
  // so it reads on this theme's background. Grey art or no track → the theme accent. Bar pill untouched.
  readonly property bool hasArtColor: !!(track && track.color)
  readonly property color artColor: hasArtColor ? track.color : Color.accent
  readonly property bool lightText: fg.hslLightness > 0.5
  property color accent: hasArtColor
    ? Qt.hsla(artColor.hslHue, Math.max(0.45, artColor.hslSaturation), lightText ? 0.66 : 0.40, 1)
    : Color.accent
  Behavior on accent { ColorAnimation { duration: 700; easing.type: Easing.InOutQuad } }
  property real tintStrength: hasArtColor ? 1 : 0
  Behavior on tintStrength { NumberAnimation { duration: 700 } }
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  // ---- derived state
  readonly property bool daemonUp: ctl.connected
  readonly property var track: pl && pl.track ? pl.track : null
  readonly property string pstate: pl ? pl.state : "stopped"
  readonly property bool playing: pstate === "playing" || pstate === "loading"
  readonly property real duration: pl && Model.has(pl.duration) ? pl.duration : (track ? track.duration : 0)
  readonly property real pos: Model.livePos(pl, now)
  readonly property var archive: st ? st.archive : null
  readonly property var sysSink: Pipewire.defaultAudioSink
  readonly property var remoteVol: remoteMode && st && st.sysvol ? st.sysvol : null
  readonly property int sysVolume: remoteMode ? (remoteVol ? remoteVol.volume : 0)
                                  : sysSink && sysSink.audio ? Math.round(sysSink.audio.volume * 100) : 0
  readonly property bool sysMuted: remoteMode ? (remoteVol ? remoteVol.muted : false)
                                   : sysSink && sysSink.audio ? sysSink.audio.muted : false

  // ---- where the music plays (play-on.json, written by `sclikes play-on`); the remote machine is
  // optional (`sclikes config remote <ssh-host>`), and the switch only shows once one is set
  property var playOnInfo: ({ on: "here", busy: false, error: "" })
  property var config: ({})
  readonly property bool remoteMode: playOnInfo.on === "remote"
  readonly property var remote: remoteMode && st && st.remote ? st.remote : null
  readonly property string remoteHost: remote ? remote.host : (playOnInfo.host || config.remote || "")
  readonly property bool remoteSet: remoteHost !== ""
  readonly property bool remoteAway: remoteMode && remote !== null && !remote.connected
  readonly property string playOnError: playOnInfo.error || (remoteAway ? remote.error : "")
  readonly property string playOnStatus: playOnInfo.busy ? "switching…"
    : playOnError ? playOnError
    : remoteMode ? (remote && remote.connected ? "connected to " + remoteHost : "connecting to " + remoteHost + "…") : ""
  readonly property var progress: Model.archiveProgress(archive)
  readonly property string artSource: {
    var a = track ? track.art : ""
    if (!a) return ""
    return a.indexOf("/") === 0 ? Util.fileUrl(a) : a
  }
  readonly property var listFilter: ({ view: view, query: query, artist: artistFilter, genre: genreFilter, sort: sortKey })

  // ---- bar-facing state (read by BarWidget.qml)
  readonly property string pillGlyph: !daemonUp ? Model.NOTE : Model.stateGlyph(pstate)
  readonly property string pillText: track && pstate !== "stopped" ? (track.artist + " – " + track.title) : ""
  readonly property bool pillActive: daemonUp && pstate === "playing"
  readonly property real pillProgress: duration > 0 && pstate !== "stopped" ? pos / duration : 0
  readonly property string tooltip: {
    if (!daemonUp) return "sclikes: daemon not running (systemctl --user start sclikes)"
    var s = track ? track.artist + " – " + track.title + "\n" + Model.clock(pos) + " / " + Model.clock(duration)
                    + " · " + (track.source === "local" ? "local" : "streaming")
                  : "sclikes: nothing queued"
    if (pstate === "stopped") s = "Stopped" + (track ? " · " + track.artist + " – " + track.title : "")
    if (progress) s += "\nArchive " + Model.thousands(progress.archived) + " / " + Model.thousands(progress.archivable)
                       + " · " + Model.archiveStateLabel(archive)
    return s + "\nMiddle: play/pause · Right: next · Scroll: volume"
  }

  // ---- panel plumbing (same contract as the built-in popups)
  function open() {
    root.controller.show()
    stateFile.reload()
    if (!ctl.connected) ctl.connected = true
  }
  function openFromHotkey() { open() }
  function close() { root.controller.hide() }
  function toggle() { if (root.opened) close(); else open() }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }
  // The dropdown and the full-player window swap places: expanding closes the dropdown,
  // collapsing from the window reopens it.
  function setExpanded(on) {
    if (on === root.expanded) return
    root.expanded = on
    if (on) { root.close(); refreshLibrary() }
    else root.open()
  }

  // ---- commands
  property int reqId: 0
  property var pending: ({})   // id -> callback(reply)

  function send(cmd, args, cb) {
    if (!ctl.connected) {
      root.cmdError = "The sclikes daemon isn't running"
      ctl.connected = true
      return
    }
    var id = ++root.reqId
    if (cb) root.pending[id] = cb
    ctl.write(JSON.stringify({ id: id, cmd: cmd, args: args || {} }) + "\n")
    ctl.flush()
  }
  function onReply(r) {
    if (r.viz !== undefined) {
      root.vizFrame = r.viz
      if (!root.vizAvailable && r.viz.some(function(v) { return v > 0 })) root.vizAvailable = true
      return
    }
    var cb = r.id !== undefined ? root.pending[r.id] : undefined
    if (cb) { delete root.pending[r.id]; cb(r); return }
    if (r.ok) { root.pl = r.data; root.cmdError = "" }
    else showError(r.error)
  }
  function showError(msg) { root.cmdError = msg || "error"; clearError.restart() }

  function playPause() { send("pause") }
  function next() { send("next") }
  function prev() { send("prev") }
  function stop() { send("stop") }
  function seekTo(secs) { send("seek", { to: String(Math.max(0, Math.round(secs))) }) }
  function seekBy(delta) { send("seek", { to: (delta >= 0 ? "+" : "") + delta }) }
  // Volume controls drive the *system* output (same knob as the fn keys and Omarchy's volume pill);
  // mpv's own volume stays at 100 so there's only one level to think about.
  // omarchy-audio-output-* resolve through any DSP sink to the physical one; the relative form shows the OSD.
  // Playing remotely, the daemon's `vol` does the same there (its output, not this machine's).
  function setVolume(v) {
    if (root.remoteMode) { send("vol", { to: String(Math.round(v)) }); return }
    run(["bash", "-c", "pactl set-sink-volume \"$(omarchy-audio-output-sink)\" " + Math.round(v) + "%"])
  }
  function volumeBy(delta) {
    var d = (delta >= 0 ? "+" : "") + Math.round(delta)
    if (root.remoteMode) send("vol", { to: d })
    else run(["omarchy-audio-output-volume", d])
  }
  function playOn(where) {
    if (root.playOnInfo.busy) return
    if (where === root.playOnInfo.on && !root.playOnError) return
    root.playOnInfo = Object.assign({}, root.playOnInfo, { busy: true, error: "" })
    run([Quickshell.env("HOME") + "/.local/bin/sclikes", "play-on", where])
  }
  function toggleShuffle() { send("shuffle", { mode: "toggle" }) }
  function cycleRepeat() { send("repeat") }
  function playId(id) { send("play", { sc_id: id }) }
  function setEqPreset(name) { send("eq", { preset: name }) }
  function setEqBand(i, g) { send("eq", { band: i, gain: g }) }

  // Omarchy's screensaver is a terminal window per monitor; show the music overlay above it.
  function onHyprEvent(event) {
    var name = String(event && event.name ? event.name : "")
    var parts
    if (name === "openwindow") {
      parts = event.parse ? event.parse(4) : String(event.data).split(",")
      if (String(parts[2] || "") === "org.omarchy.screensaver") {
        root.saverWindows[String(parts[0])] = true
        root.saverCount = Object.keys(root.saverWindows).length
      }
    } else if (name === "closewindow") {
      parts = event.parse ? event.parse(1) : String(event.data).split(",")
      if (root.saverWindows[String(parts[0])]) {
        delete root.saverWindows[String(parts[0])]
        root.saverCount = Object.keys(root.saverWindows).length
      }
    }
  }
  // Throttle: the pill gets ~15 fps, the big spectra 30 fps and only while on screen. Binding
  // every frame into hidden panels on both monitors cost ~30% CPU in the shell.
  readonly property bool vizBig: root.shown || root.saverActive
  // Widget setting: the pill's mini spectrum keeps cava running and repaints the bar while music plays
  // (measured ~6-20% shell CPU). Off: frames are only requested while the dropdown/overlay is visible.
  // "On" | "External" (not on the laptop's built-in panel) | "Off"; per bar, since each monitor has its own.
  readonly property string pillVizMode: String(setting("pillVisualizer", "On"))
  readonly property string screenName: root.anchorWindow && root.anchorWindow.screen ? String(root.anchorWindow.screen.name) : ""
  readonly property bool internalScreen: /^(eDP|LVDS|DSI)/.test(root.screenName)
  readonly property bool pillViz: pillVizMode === "On" || (pillVizMode === "External" && !internalScreen)
  function setPillVizMode(mode) { run(["omarchy", "bar", "set", "io.github.papershoes22.sclikes", "pillVisualizer", mode]) }
  // Widget setting: "Vivid" tints the pill with the cover's colour (capsule, thumbnail, hue-shifted bars,
  // bass glow riding the spectrum frames) or "Classic" (plain bar text).
  readonly property string pillStyle: String(setting("pillStyle", "Vivid"))
  readonly property bool pillVivid: pillStyle !== "Classic"
  function setPillStyle(mode) { run(["omarchy", "bar", "set", "io.github.papershoes22.sclikes", "pillStyle", mode]) }
  // Accent hue for hue-shifted pill bars; achromatic theme accents report -1.
  readonly property real accentHue: accent.hslHue >= 0 ? accent.hslHue : 0.6
  // Widget setting: a glow across this bar that pulses with the bass ("On" | "External" | "Off").
  readonly property string barGlowMode: String(setting("barGlow", "Off"))
  readonly property bool barGlow: barGlowMode === "On" || (barGlowMode === "External" && !internalScreen)
  function setBarGlowMode(mode) { run(["omarchy", "bar", "set", "io.github.papershoes22.sclikes", "barGlow", mode]) }
  // One-click toggle (full player, g): Off <-> the last mode that wasn't Off, so "External" survives.
  property string lastGlowMode: "On"
  onBarGlowModeChanged: if (barGlowMode !== "Off") lastGlowMode = barGlowMode
  Component.onCompleted: if (barGlowMode !== "Off") lastGlowMode = barGlowMode
  function toggleBarGlow() { setBarGlowMode(barGlowMode === "Off" ? lastGlowMode : "Off") }
  readonly property bool glowActive: barGlow && pillActive && root.anchorWindow !== null
  property real glowLevel: 0   // bass 0..1, stepped by the viz timer, smoothed by the glow window
  readonly property bool vizWanted: root.daemonUp && (root.vizBig || root.pillViz || root.barGlow)
  property bool vizSubscribed: false
  function syncViz() {
    if (!ctl.connected || root.vizWanted === root.vizSubscribed) return
    root.vizSubscribed = root.vizWanted
    send(root.vizWanted ? "viz_subscribe" : "viz_unsubscribe", {}, function(r) {
      if (r.ok && r.data && r.data.available !== undefined) root.vizAvailable = r.data.available
    })
  }
  onVizWantedChanged: syncViz()
  Timer {
    interval: root.vizBig ? 33 : root.barGlow ? 66 : 125
    running: root.vizAvailable && root.pillActive && (root.pillViz || root.vizBig || root.barGlow)
    repeat: true
    onTriggered: {
      if (root.vizBig) root.vizBars = root.vizFrame
      root.pillBars = Model.groupBars(root.vizFrame, 5)
      if (root.barGlow) {
        var b = Math.min(1, 1.5 * Math.sqrt(Math.max(root.pillBars[0] || 0, root.pillBars[1] || 0)))
        // Snap up on a hit, fall back gently.
        root.glowLevel = b > root.glowLevel ? b : root.glowLevel * 0.8 + b * 0.2
      }
    }
  }
  onPillActiveChanged: if (!pillActive) { vizBars = []; pillBars = [0, 0, 0, 0, 0]; glowLevel = 0 }

  Connections {
    target: Hyprland
    function onRawEvent(event) { root.onHyprEvent(event) }
  }
  function run(argv) { Util.execArgv(argv) }
  readonly property bool archiveOff: archive !== null && archive.state === "off"
  function setArchiving(on) { run([Quickshell.env("HOME") + "/.local/bin/sclikes", "config", "archive", on ? "on" : "off"]) }
  function toggleArchive() {
    run(["sclikes", "archive", archive && archive.paused ? "resume" : "pause"])
  }
  function syncNow() {
    if (root.syncing) return
    root.syncRequested = true
    syncRequestTimeout.restart()
    if (root.remoteMode) run(["ssh", "-o", "BatchMode=yes", root.remoteHost,
                           "systemctl --user start --no-block sclikes-sync.service"])
    else run(["systemctl", "--user", "start", "--no-block", "sclikes-sync.service"])
  }
  Timer { id: syncRequestTimeout; interval: 20 * 1000; onTriggered: root.syncRequested = false }
  function startDaemon() {
    run(["systemctl", "--user", "start", root.remoteMode ? "sclikes-remote.service" : "sclikes.service"])
    reconnect.restart()
  }

  // ---- library (full player)
  function refreshLibrary() {
    send("facets", {}, function(r) { if (r.ok) root.facets = r.data })
    reloadList()
  }
  function reloadList() {
    var gen = ++root.listGen
    root.rowsLoading = true
    var args = Model.merge(root.listFilter, { offset: 0, limit: Model.PAGE })
    send("list", args, function(r) {
      if (gen !== root.listGen) return   // a newer search superseded this one
      root.rowsLoading = false
      if (!r.ok) { showError(r.error); return }
      trackModel.clear()
      trackModel.append(Model.listRows(r.data.rows))
      root.rowsTotal = r.data.total
      root.selIndex = trackModel.count ? 0 : -1
      if (root.listItem) root.listItem.positionViewAtBeginning()
    })
  }
  function loadMore() {
    if (root.rowsLoading || trackModel.count >= root.rowsTotal) return
    var gen = root.listGen
    root.rowsLoading = true
    send("list", Model.merge(root.listFilter, { offset: trackModel.count, limit: Model.PAGE }), function(r) {
      if (gen !== root.listGen) return
      root.rowsLoading = false
      if (r.ok) trackModel.append(Model.listRows(r.data.rows))
    })
  }
  // Clicking a row plays the list as shown (same filter and order) starting at that track.
  function playRow(i) {
    var row = trackModel.get(i)
    if (!row) return
    if (row.status === "drm" || row.status === "gone") { run(["xdg-open", row.permalink]); return }
    send("play", Model.merge(root.listFilter, { sc_id: row.sc_id }))
  }
  function playList(shuffle) {
    send("play", Model.merge(root.listFilter, { shuffle: shuffle }))
  }
  function archiveNow(i) {
    var row = trackModel.get(i)
    if (!row) return
    send("archive_now", { sc_id: row.sc_id }, function(r) {
      if (!r.ok) { showError(r.error); return }
      var j = Model.indexOfId(trackModel, r.data.sc_id)
      if (j >= 0) trackModel.setProperty(j, "archiving", r.data.status === "queued")
    })
  }
  function moveSelection(delta) {
    if (!trackModel.count) return
    root.selIndex = Math.max(0, Math.min(trackModel.count - 1, root.selIndex + delta))
    if (root.listItem) root.listItem.positionViewAtIndex(root.selIndex, ListView.Contain)
  }
  function setView(v) { root.view = v; root.artistFilter = ""; root.genreFilter = "" }

  onListFilterChanged: if (root.expanded) listDebounce.restart()
  Timer { id: listDebounce; interval: 160; onTriggered: root.reloadList() }

  // Keep list rows in step with the archiver: when a track finishes, update its row in place.
  onArchiveChanged: {
    var last = archive && archive.last ? archive.last : null
    if (!last || !last.at || last.at === root.lastArchivedAt) return
    root.lastArchivedAt = last.at
    var j = Model.indexOfId(trackModel, last.sc_id)
    if (j >= 0) {
      trackModel.setProperty(j, "status", last.status)
      trackModel.setProperty(j, "archiving", false)
    }
  }

  ListModel { id: trackModel }

  Socket {
    id: ctl
    path: root.stateDir + "/ctl.sock"
    connected: true
    onConnectionStateChanged: {
      if (!connected) { root.pending = ({}); root.rowsLoading = false; return }
      root.cmdError = ""
      root.send("status")
      root.vizSubscribed = false
      root.syncViz()
      if (root.expanded) root.refreshLibrary()
    }
    parser: SplitParser {
      property int vizSkip: 0
      onRead: function(line) {
        // Spectrum frames arrive ~30/s; with only the pill showing, parse one in four.
        if (line.charCodeAt(2) === 118 && line.indexOf('{"viz"') === 0 && !root.vizBig && (++vizSkip % 4) !== 0) return
        var r
        try { r = JSON.parse(line) } catch (e) { return }
        root.onReply(r)
      }
    }
  }

  // The daemon restarts (upgrades, crashes); keep trying to reconnect.
  Timer {
    id: reconnect
    interval: 3000
    running: !ctl.connected
    repeat: true
    onTriggered: ctl.connected = true
  }

  Timer { id: clearError; interval: 6000; onTriggered: root.cmdError = "" }

  PwObjectTracker { objects: root.sysSink ? [root.sysSink] : [] }

  FileView {
    id: stateFile
    path: root.stateDir + "/state.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var s = JSON.parse(text())
        root.st = s
        // Take the file's player section unless a socket reply is newer.
        if (s.player && (!root.pl || (s.player.pos_at || 0) >= (root.pl.pos_at || 0))) root.pl = s.player
      } catch (e) { /* keep last good */ }
    }
  }

  FileView {
    path: Quickshell.env("HOME") + "/.config/sclikes/config.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.config = JSON.parse(text()) } catch (e) { /* keep last good */ }
    }
  }

  FileView {
    path: root.stateDir + "/play-on.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.playOnInfo = JSON.parse(text()) } catch (e) { /* keep last good */ }
    }
  }

  // Playing remotely, sync status is the remote's (mirrored by `sclikes remote`).
  FileView {
    path: root.stateDir + (root.remoteMode ? "/sync-remote.json" : "/sync.json")
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var s = JSON.parse(text())
        var finished = s.state !== "running" && root.syncInfo && root.syncInfo.state === "running"
        root.syncInfo = s
        root.now = Date.now() / 1000
        if (s.state === "running" || finished) root.syncRequested = false
        if (finished && s.new && root.expanded) root.refreshLibrary()
      } catch (e) { /* keep last good */ }
    }
  }

  // Keeps "synced 5m ago" honest while the panel is open and nothing is playing.
  Timer {
    interval: 30 * 1000
    running: root.shown && !root.playing
    repeat: true
    triggeredOnStart: true
    onTriggered: root.now = Date.now() / 1000
  }

  FileView {
    path: root.themeColorsPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.themeColors = Model.parseThemeColors(text())
  }

  // Scrubber clock: smooth while visible, coarse otherwise (the pill's progress line).
  Timer {
    interval: root.shown ? 250 : 1000
    running: root.playing
    repeat: true
    triggeredOnStart: true
    onTriggered: root.now = Date.now() / 1000
  }

  // inotify misses the odd atomic rename; also keeps the archive section fresh.
  Timer {
    interval: 30 * 1000
    running: true
    repeat: true
    onTriggered: stateFile.reload()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    // omarchy-shell io.github.papershoes22.sclikes expand   (open straight into the full player)
    function expand(): void { root.setExpanded(true) }
    function collapse(): void { root.expanded = false }
    // omarchy-shell io.github.papershoes22.sclikes sync   (check SoundCloud for new likes now)
    function sync(): void { root.syncNow() }
    // omarchy-shell io.github.papershoes22.sclikes search "hucci"   (full player, filtered)
    function search(q: string): void { root.query = q; root.setExpanded(true) }
    // omarchy-shell io.github.papershoes22.sclikes artist "Artist Name"   (full player, that artist's likes)
    function artist(name: string): void { root.artistFilter = name; root.setExpanded(true) }
    // omarchy-shell io.github.papershoes22.sclikes playPause | next | prev | stop
    function playPause(): void { root.playPause() }
    function next(): void { root.next() }
    function prev(): void { root.prev() }
    function stop(): void { root.stop() }
    // omarchy-shell io.github.papershoes22.sclikes playOn remote | here
    function playOn(where: string): void { root.playOn(where) }
    function togglePlayOn(): void { root.playOn(root.remoteMode ? "here" : "remote") }
  }

  // ---------------------------------------------------------------- small components

  component SmallText: Text {
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    textFormat: Text.PlainText
    elide: Text.ElideRight
  }

  component Caption: SmallText {
    font.pixelSize: Style.font.caption
    font.letterSpacing: 1
    color: root.faint
  }

  component Badge: Rectangle {
    id: badge
    property string label: ""
    property string tone: "dim"
    readonly property color toneColor: tone === "good" ? root.goodColor : tone === "warn" ? root.warnColor
                                      : tone === "bad" ? root.badColor : root.dim
    width: badgeText.implicitWidth + Style.space(8)
    height: badgeText.implicitHeight + Style.space(3)
    radius: Style.cornerRadius
    color: Util.alpha(toneColor, 0.14)
    Text {
      id: badgeText
      anchors.centerIn: parent
      text: badge.label
      color: badge.toneColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 0.5
    }
  }

  component Chip: Rectangle {
    id: chip
    property string label: ""
    property bool active: false
    signal clicked()
    width: chipText.implicitWidth + Style.space(12)
    height: chipText.implicitHeight + Style.space(6)
    radius: Style.cornerRadius
    color: active ? Style.selectedFillFor(root.fg, root.accent, root.badColor)
         : (chipArea.containsMouse ? Style.hoverFillFor(root.fg, root.accent) : "transparent")
    Text {
      id: chipText
      anchors.centerIn: parent
      text: chip.label
      color: chip.active || chipArea.containsMouse ? root.fg : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    MouseArea {
      id: chipArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.clicked()
    }
  }

  component TransportButton: Button {
    foreground: root.fg
    horizontalPadding: Style.spacing.controlPaddingX
    verticalPadding: Style.spacing.controlPaddingY
    opacity: enabled ? 1.0 : 0.4
  }

  // Clickable icon in text color, for dense rows.
  component IconLink: Text {
    id: iconLink
    property string tip: ""
    readonly property bool hot: linkArea.containsMouse
    signal clicked()
    color: linkArea.containsMouse ? root.fg : root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    MouseArea {
      id: linkArea
      anchors.fill: parent
      anchors.margins: -Style.space(4)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: iconLink.clicked()
      onContainsMouseChanged: {
        if (!root.bar || iconLink.tip === "") return
        if (containsMouse) root.bar.showTooltip(iconLink, iconLink.tip)
        else root.bar.hideTooltip(iconLink)
      }
    }
  }

  // Sidebar entry: label + count, highlighted when active.
  component SideItem: Rectangle {
    id: side
    property string label: ""
    property int count: -1
    property bool active: false
    signal clicked()
    width: parent ? parent.width : 0
    height: sideText.implicitHeight + Style.space(8)
    radius: Style.cornerRadius
    color: active ? Style.selectedFillFor(root.fg, root.accent, root.badColor)
         : (sideArea.containsMouse ? Style.hoverFillFor(root.fg, root.accent) : "transparent")
    SmallText {
      id: sideText
      anchors.left: parent.left
      anchors.right: sideCount.left
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: side.label
      color: side.active || sideArea.containsMouse ? root.fg : root.dim
      font.bold: side.active
    }
    SmallText {
      id: sideCount
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      visible: side.count >= 0
      text: Model.thousands(side.count)
      color: root.faint
    }
    MouseArea {
      id: sideArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: side.clicked()
    }
  }

  // Spectrum bars from root.vizBars; flat baseline when idle.
  component Spectrum: Item {
    id: spec
    property int count: 32
    property real gapRatio: 0.3
    property color barColor: root.accent
    property real minFraction: 0.04
    readonly property real slot: width / count
    Repeater {
      model: spec.count
      Rectangle {
        required property int index
        readonly property real v: {
          var b = root.vizBars
          if (!b || !b.length) return 0
          return (b[Math.floor(index * b.length / spec.count)] || 0) / 100
        }
        x: index * spec.slot + spec.slot * spec.gapRatio / 2
        width: Math.max(1, spec.slot * (1 - spec.gapRatio))
        height: Math.max(spec.height * spec.minFraction, spec.height * v)
        anchors.bottom: parent.bottom
        radius: Math.min(width / 2, Style.space(2))
        color: spec.barColor
        opacity: 0.35 + 0.65 * v
      }
    }
  }

  // Vertical EQ slider, -max..+max dB. Drag to set, double-click to reset, wheel to nudge.
  component EqSlider: Item {
    id: eqs
    property int band: 0
    property real value: 0
    property real maxDb: 12
    property bool dragging: false
    property real liveValue: value
    onValueChanged: if (!dragging) liveValue = value
    readonly property real shown: dragging ? liveValue : value
    readonly property real mid: track.y + track.height / 2
    width: Style.space(26)
    height: Style.space(104)

    function setFromY(y) {
      var g = (mid - y) / (track.height / 2) * maxDb
      g = Math.round(Math.max(-maxDb, Math.min(maxDb, g)) * 2) / 2
      if (g !== liveValue) { liveValue = g; root.setEqBand(band, g) }
    }

    SmallText {
      id: eqVal
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      font.pixelSize: Style.font.caption
      text: eqs.dragging || eqArea.containsMouse ? (eqs.shown > 0 ? "+" : "") + eqs.shown : ""
      color: root.fg
    }
    Rectangle {
      id: track
      anchors.horizontalCenter: parent.horizontalCenter
      y: eqVal.height + Style.space(2)
      width: Style.space(4)
      height: parent.height - y - eqLabel.height - Style.space(4)
      radius: width / 2
      color: Util.alpha(root.fg, 0.10)
    }
    Rectangle {  // 0 dB tick
      anchors.horizontalCenter: parent.horizontalCenter
      y: eqs.mid - height / 2
      width: Style.space(10)
      height: 1
      color: Util.alpha(root.fg, 0.25)
    }
    Rectangle {  // fill from 0 dB to the value
      anchors.horizontalCenter: parent.horizontalCenter
      width: track.width
      radius: width / 2
      readonly property real off: eqs.shown / eqs.maxDb * track.height / 2
      y: off >= 0 ? eqs.mid - off : eqs.mid
      height: Math.abs(off)
      color: root.accent
    }
    Rectangle {  // knob
      anchors.horizontalCenter: parent.horizontalCenter
      width: Style.space(12)
      height: width
      radius: width / 2
      y: eqs.mid - eqs.shown / eqs.maxDb * track.height / 2 - height / 2
      color: root.fg
      scale: eqArea.containsMouse || eqs.dragging ? 1.15 : 1
    }
    SmallText {
      id: eqLabel
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      font.pixelSize: Style.font.caption
      text: Model.EQ_LABELS[eqs.band]
      color: root.faint
    }
    MouseArea {
      id: eqArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.SizeVerCursor
      onPressed: function(m) { eqs.dragging = true; eqs.setFromY(m.y) }
      onPositionChanged: function(m) { if (eqs.dragging) eqs.setFromY(m.y) }
      onReleased: eqs.dragging = false
      onDoubleClicked: { eqs.liveValue = 0; root.setEqBand(eqs.band, 0) }
      onWheel: function(w) {
        var g = Math.max(-eqs.maxDb, Math.min(eqs.maxDb, eqs.value + (w.angleDelta.y > 0 ? 1 : -1)))
        root.setEqBand(eqs.band, g)
      }
    }
  }

  // ---------------------------------------------------------------- now playing
  // The whole compact dropdown; also the right-hand column of the full player.

  component NowPlaying: Column {
    id: np
    spacing: Style.space(10)

    // ---- Where it plays: here, or on the remote machine with this one as its remote control (t)
    Item {
      visible: root.remoteSet || root.remoteMode
      width: parent.width
      height: playOnRow.implicitHeight
      Row {
        id: playOnRow
        spacing: Style.space(4)
        Caption {
          anchors.verticalCenter: parent.verticalCenter
          text: "PLAY ON"
          rightPadding: Style.space(4)
        }
        Chip { label: "Here"; active: !root.remoteMode; onClicked: root.playOn("here") }
        Chip { label: root.remoteHost; active: root.remoteMode; onClicked: root.playOn("remote") }
      }
      SmallText {
        anchors.left: playOnRow.right
        anchors.leftMargin: Style.space(8)
        anchors.right: parent.right
        anchors.verticalCenter: playOnRow.verticalCenter
        horizontalAlignment: Text.AlignRight
        text: root.playOnStatus
        color: root.playOnError ? root.warnColor : root.faint
      }
    }

    // ---- Daemon down
    Column {
      visible: !root.daemonUp
      width: parent.width
      spacing: Style.space(6)
      Text {
        text: root.remoteMode ? "The remote bridge isn't running" : "sclikes isn't running"
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
      }
      SmallText {
        width: parent.width
        wrapMode: Text.WordWrap
        elide: Text.ElideNone
        text: root.remoteMode ? "sclikes-remote.service relays this panel to " + root.remoteHost + "'s player over ssh."
                           : "The player and archiver live in the sclikes user service."
      }
      Chip { label: root.remoteMode ? "Start sclikes-remote.service" : "Start sclikes.service"; onClicked: root.startDaemon() }
    }

    // ---- Now playing
    Row {
      visible: root.daemonUp
      width: parent.width
      spacing: Style.space(12)

      BorderSurface {
        id: artFrame
        width: Style.space(88)
        height: Style.space(88)
        radius: Style.spacing.labelGap
        color: Style.normalFillFor(root.fg, root.accent)
        borderSpec: Border.controlSpec("normal", root.fg, root.accent)

        Image {
          id: art
          anchors.fill: parent
          anchors.margins: Style.space(2)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: true
          sourceSize.width: 256
          sourceSize.height: 256
          source: root.artSource
          visible: status === Image.Ready
        }
        Text {
          anchors.centerIn: parent
          visible: art.status !== Image.Ready
          text: Model.NOTE
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.displayLarge
        }
      }

      Column {
        width: parent.width - artFrame.width - parent.spacing
        anchors.verticalCenter: artFrame.verticalCenter
        spacing: Style.space(4)

        Item {
          width: parent.width
          height: npCaption.implicitHeight
          Caption {
            id: npCaption
            text: root.pstate === "stopped" ? "STOPPED" : root.pstate === "paused" ? "PAUSED"
                  : root.pstate === "loading" ? "LOADING…" : "NOW PLAYING"
          }
          IconLink {
            anchors.right: parent.right
            anchors.verticalCenter: npCaption.verticalCenter
            text: root.expanded ? Model.COLLAPSE : Model.EXPAND
            tip: root.expanded ? "Compact player" : "Full player: library, search, archive"
            onClicked: root.setExpanded(!root.expanded)
          }
        }
        Text {
          width: parent.width
          text: root.track ? root.track.title : "Nothing queued"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }
        SmallText {
          width: parent.width
          visible: text !== ""
          text: root.track ? root.track.artist : "Press play to start your likes, newest first."
          color: root.track ? root.fg : root.dim
          opacity: root.track ? 0.8 : 1
        }
        Flow {
          width: parent.width
          spacing: Style.space(4)
          Repeater {
            model: Model.badges(root.track)
            Badge {
              required property var modelData
              label: modelData.text
              tone: modelData.tone
            }
          }
        }
      }
    }

    // ---- Spectrum
    Spectrum {
      visible: root.daemonUp && root.vizAvailable
      width: parent.width
      height: Style.space(30)
      count: 32
    }

    // ---- Scrubber
    Column {
      visible: root.daemonUp
      width: parent.width
      spacing: 0

      PanelSlider {
        id: scrub
        width: parent.width
        bar: root.bar
        minimum: 0
        maximum: Math.max(1, root.duration)
        value: root.pos
        step: 5
        enabled: root.pstate !== "stopped"
        opacity: enabled ? 1 : 0.4
        onReleased: function(v) { root.seekTo(v) }
      }
      Item {
        width: parent.width
        height: elapsed.implicitHeight
        SmallText {
          id: elapsed
          text: Model.clock(scrub.dragging ? scrub.liveValue : root.pos)
        }
        SmallText {
          anchors.right: parent.right
          text: root.duration > 0 ? "-" + Model.clock(root.duration - (scrub.dragging ? scrub.liveValue : root.pos)) : ""
        }
      }
    }

    // ---- Transport
    Item {
      visible: root.daemonUp
      width: parent.width
      height: transport.implicitHeight

      Row {
        id: transport
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(6)

        TransportButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: Model.SHUFFLE
          selected: root.pl ? root.pl.shuffle === true : false
          opacity: selected ? 1 : 0.55
          tooltipText: selected ? "Shuffle on (s)" : "Shuffle off (s)"
          onClicked: root.toggleShuffle()
        }
        TransportButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: Model.PREV
          tooltipText: "Previous (p) — restarts after 3 s"
          onClicked: root.prev()
        }
        TransportButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: root.playing ? Model.PAUSE : Model.PLAY
          iconSize: Style.font.iconLarge
          horizontalPadding: Style.spacing.panelGap
          tooltipText: "Play / pause (space)"
          onClicked: root.playPause()
        }
        TransportButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: Model.NEXT
          tooltipText: "Next (n)"
          onClicked: root.next()
        }
        TransportButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: Model.repeatGlyph(root.pl ? root.pl.repeat : "all")
          selected: root.pl ? root.pl.repeat !== "off" : true
          opacity: selected ? 1 : 0.55
          tooltipText: "Repeat " + (root.pl ? root.pl.repeat : "all") + " (r)"
          onClicked: root.cycleRepeat()
        }
        TransportButton {
          visible: root.expanded && root.vizAvailable
          anchors.verticalCenter: parent.verticalCenter
          iconText: Model.GLOW
          selected: root.barGlowMode !== "Off"
          opacity: selected ? 1 : 0.55
          tooltipText: selected ? "Bar glow on (g)" : "Bar glow off (g)"
          onClicked: root.toggleBarGlow()
        }
      }
    }

    // ---- Volume
    Row {
      visible: root.daemonUp
      width: parent.width
      spacing: Style.space(8)
      Text {
        id: volGlyph
        anchors.verticalCenter: parent.verticalCenter
        text: root.sysMuted || root.sysVolume === 0 ? Model.MUTE : Model.VOLUME
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }
      PanelSlider {
        id: vol
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - volGlyph.width - volText.width - eqChip.width - parent.spacing * 3
        bar: root.bar
        minimum: 0
        maximum: 100
        step: 5
        integer: true
        value: Math.min(100, root.sysVolume)
        onMoved: function(v) { root.setVolume(v) }
      }
      SmallText {
        id: volText
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(28)
        horizontalAlignment: Text.AlignRight
        text: String(Math.round(vol.dragging ? vol.liveValue : vol.value))
      }
      Chip {
        id: eqChip
        anchors.verticalCenter: parent.verticalCenter
        label: root.eq && root.eq.preset !== "flat" ? "EQ · " + Model.presetLabel(root.eq.preset) : "EQ"
        active: root.showEq
        onClicked: root.showEq = !root.showEq
      }
    }

    // ---- Equalizer
    Column {
      visible: root.daemonUp && root.showEq && root.eq !== null
      width: parent.width
      spacing: Style.space(6)

      Flow {
        width: parent.width
        spacing: Style.space(3)
        Repeater {
          model: root.eq ? root.eq.presets : []
          Chip {
            required property string modelData
            label: Model.presetLabel(modelData)
            active: root.eq && root.eq.preset === modelData
            onClicked: root.setEqPreset(modelData)
          }
        }
      }
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Math.max(0, (parent.width - 10 * Style.space(26)) / 9)
        Repeater {
          model: 10
          EqSlider {
            required property int index
            band: index
            maxDb: root.eq ? root.eq.max_db : 12
            value: root.eq ? root.eq.gains[index] : 0
          }
        }
      }
      Caption {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        font.letterSpacing: 0
        text: "drag · scroll to nudge · double-click resets a band"
      }
    }

    // ---- Errors
    SmallText {
      visible: text !== ""
      width: parent.width
      wrapMode: Text.WordWrap
      elide: Text.ElideNone
      maximumLineCount: 3
      color: root.warnColor
      text: root.cmdError !== "" ? "⚠ " + root.cmdError
            : (root.daemonUp && root.pl && root.pl.error ? "⚠ " + root.pl.error : "")
    }

    PanelSeparator { visible: root.daemonUp; foreground: root.fg }

    // ---- Up next
    Column {
      visible: root.daemonUp && root.pl !== null && root.pl.queue_len > 0
      width: parent.width
      spacing: Style.space(2)

      Item {
        width: parent.width
        height: upCaption.implicitHeight + Style.space(4)
        Caption { id: upCaption; text: "UP NEXT" }
        Caption {
          anchors.right: parent.right
          width: parent.width - upCaption.width - Style.space(12)
          horizontalAlignment: Text.AlignRight
          font.letterSpacing: 0
          text: root.pl ? Model.filterLabel(root.pl.filter) + " · "
                          + Model.thousands(root.pl.index + 1) + " of " + Model.thousands(root.pl.queue_len) : ""
        }
      }

      Repeater {
        model: root.pl ? root.pl.up_next : []
        Rectangle {
          id: upRow
          required property var modelData
          required property int index
          width: parent.width
          height: upInner.implicitHeight + Style.space(8)
          radius: Style.cornerRadius
          color: upArea.containsMouse ? Style.hoverFillFor(root.fg, root.accent) : "transparent"

          Row {
            id: upInner
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.space(6)
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            SmallText {
              width: Style.space(12)
              text: upArea.containsMouse ? Model.PLAY : String(upRow.index + 1)
              color: root.faint
              horizontalAlignment: Text.AlignRight
            }
            SmallText {
              width: parent.width - Style.space(12) - upSrc.width - upDur.width - parent.spacing * 3
              text: upRow.modelData.title + "  ·  " + upRow.modelData.artist
              color: upArea.containsMouse ? root.fg : root.dim
            }
            SmallText {
              id: upSrc
              width: Style.space(14)
              text: upRow.modelData.source === "local" ? "" : Model.CLOUD
              color: root.faint
            }
            SmallText {
              id: upDur
              width: Style.space(34)
              horizontalAlignment: Text.AlignRight
              text: Model.clock(upRow.modelData.duration)
              color: root.faint
            }
          }
          MouseArea {
            id: upArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.playId(upRow.modelData.sc_id)
          }
        }
      }
    }

    PanelSeparator { visible: root.daemonUp && root.pl !== null && root.pl.queue_len > 0; foreground: root.fg }

    // ---- Archive
    Column {
      visible: root.progress !== null
      width: parent.width
      spacing: Style.space(5)

      Item {
        width: parent.width
        height: Math.max(archCaption.implicitHeight, archChip.height)
        Caption { id: archCaption; anchors.verticalCenter: parent.verticalCenter; text: "ARCHIVE" }
        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)
          SmallText {
            anchors.verticalCenter: parent.verticalCenter
            text: Model.archiveStateLabel(root.archive)
            color: root.archive && root.archive.state === "rate_limited" ? root.warnColor
                 : root.archive && root.archive.state === "downloading" ? root.goodColor : root.dim
          }
          Chip {
            anchors.verticalCenter: parent.verticalCenter
            label: root.syncing ? "Syncing…" : "Sync now"
            active: root.syncing
            onClicked: root.syncNow()
          }
          Chip {
            id: archChip
            anchors.verticalCenter: parent.verticalCenter
            visible: root.daemonUp && !root.archiveOff
            label: root.archive && root.archive.paused ? "Resume" : "Pause"
            onClicked: root.toggleArchive()
          }
          Chip {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.daemonUp && !root.remoteMode
            label: root.archiveOff ? "Turn on" : "Turn off"
            onClicked: root.setArchiving(root.archiveOff)
          }
        }
      }

      Rectangle {
        width: parent.width
        height: Style.space(6)
        radius: height / 2
        color: Util.alpha(root.fg, 0.08)
        Rectangle {
          width: Math.max(height, parent.width * Math.min(1, root.progress ? root.progress.fraction : 0))
          height: parent.height
          radius: parent.radius
          color: root.archive && root.archive.paused ? root.dim : root.accent
        }
      }

      SmallText {
        width: parent.width
        wrapMode: Text.WordWrap
        elide: Text.ElideNone
        color: root.fg
        text: !root.progress ? ""
              : Model.thousands(root.progress.archived) + " / " + Model.thousands(root.progress.archivable)
                + " archived (" + Math.floor(root.progress.fraction * 100) + "%)"
                + (root.progress.queued ? " · " + Model.thousands(root.progress.queued) + " queued"
                                         + (root.progress.eta ? ", ~" + root.progress.eta + " left" : "") : "")
      }
      SmallText {
        width: parent.width
        visible: root.archiveOff
        wrapMode: Text.WordWrap
        elide: Text.ElideNone
        color: root.dim
        text: "Archiving is off: your likes stream from SoundCloud. Turn it on to keep local copies "
              + "(one download at a time; DRM and Go+ tracks are never downloaded)."
      }
      SmallText {
        width: parent.width
        visible: text !== ""
        text: root.archive && root.archive.current
              ? Model.DOWNLOAD + " " + root.archive.current.artist + " – " + root.archive.current.title
              : root.archive && root.archive.last && root.archive.last.title
                ? "last: " + root.archive.last.artist + " – " + root.archive.last.title + " (" + root.archive.last.status + ")"
                : ""
      }
      SmallText {
        width: parent.width
        visible: text !== ""
        color: root.syncInfo && root.syncInfo.state === "error" ? root.warnColor : root.faint
        text: Model.syncLine(root.syncInfo, root.now)
      }
      SmallText {
        width: parent.width
        visible: root.archive && root.archive.priority && root.archive.priority.length > 0
        color: root.accent
        text: visible ? root.archive.priority.length + " requested with “archive now”" : ""
      }
      SmallText {
        width: parent.width
        wrapMode: Text.WordWrap
        elide: Text.ElideNone
        color: root.faint
        text: !root.progress ? ""
              : "SoundCloud-only: " + root.progress.preview + " preview · " + root.progress.drm + " DRM · "
                + root.progress.gone + " gone" + (root.progress.failed ? " · " + root.progress.failed + " failed" : "")
      }
    }

    // ---- Footer: links for the current track
    Flow {
      visible: root.track !== null
      width: parent.width
      spacing: Style.space(4)
      Chip {
        label: "Open on SoundCloud"
        visible: root.track && root.track.permalink
        onClicked: { root.run(["xdg-open", root.track.permalink]); root.close() }
      }
      Chip {
        label: "Buy / download"
        visible: root.track && root.track.purchase_url
        onClicked: { root.run(["xdg-open", root.track.purchase_url]); root.close() }
      }
      Chip {
        label: "Show file"
        visible: root.track && root.track.source === "local" && !!root.track.path
        onClicked: {
          var f = root.track.path
          root.run(["xdg-open", f.substring(0, f.lastIndexOf("/"))])
          root.close()
        }
      }
    }

    // ---- Bar spectrum setting (saved to shell.json via `omarchy bar set`)
    Item {
      visible: root.daemonUp && root.vizAvailable
      width: parent.width
      height: Math.max(vizCaption.implicitHeight, vizModes.height)
      Caption {
        id: vizCaption
        anchors.verticalCenter: parent.verticalCenter
        text: "BAR SPECTRUM"
      }
      Row {
        id: vizModes
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)
        Repeater {
          model: [{ key: "On", label: "All screens" }, { key: "External", label: "External only" }, { key: "Off", label: "Off" }]
          Chip {
            required property var modelData
            label: modelData.label
            active: root.pillVizMode === modelData.key
            onClicked: root.setPillVizMode(modelData.key)
          }
        }
      }
    }

    // ---- Bar pill look (same mechanism)
    Item {
      visible: root.daemonUp
      width: parent.width
      height: Math.max(styleCaption.implicitHeight, styleModes.height)
      Caption {
        id: styleCaption
        anchors.verticalCenter: parent.verticalCenter
        text: "BAR STYLE"
      }
      Row {
        id: styleModes
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)
        Repeater {
          model: [{ key: "Vivid", label: "Vivid" }, { key: "Classic", label: "Classic" }]
          Chip {
            required property var modelData
            label: modelData.label
            active: (root.pillVivid ? "Vivid" : "Classic") === modelData.key
            onClicked: root.setPillStyle(modelData.key)
          }
        }
      }
    }

    // ---- Whole-bar glow (same mechanism)
    Item {
      visible: root.daemonUp && root.vizAvailable
      width: parent.width
      height: Math.max(glowCaption.implicitHeight, glowModes.height)
      Caption {
        id: glowCaption
        anchors.verticalCenter: parent.verticalCenter
        text: "BAR GLOW"
      }
      Row {
        id: glowModes
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)
        Repeater {
          model: [{ key: "On", label: "All screens" }, { key: "External", label: "External only" }, { key: "Off", label: "Off" }]
          Chip {
            required property var modelData
            label: modelData.label
            active: root.barGlowMode === modelData.key
            onClicked: root.setBarGlowMode(modelData.key)
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- views

  Component {
    id: compactView
    Flickable {
      id: compactScroll
      implicitHeight: compactBody.implicitHeight
      contentWidth: width
      contentHeight: compactBody.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height
      NowPlaying { id: compactBody; width: compactScroll.width }
    }
  }

  Component {
    id: fullView
    Item {
      id: full
      implicitHeight: Style.space(700)

      readonly property real sideW: Style.space(180)
      readonly property real npW: Style.space(320)
      readonly property real gap: Style.space(14)

      // ---- Sidebar
      Flickable {
        id: sideScroll
        x: 0
        width: full.sideW
        height: parent.height
        contentWidth: width
        contentHeight: sideCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: sideCol
          width: sideScroll.width
          spacing: Style.space(1)

          Caption { text: "LIBRARY"; bottomPadding: Style.space(4) }
          Repeater {
            model: Model.VIEW_LIST
            SideItem {
              required property var modelData
              readonly property int n: root.facets && root.facets.views ? (root.facets.views[modelData.key] || 0) : -1
              visible: !modelData.hideEmpty || n > 0
              label: modelData.label
              count: n
              active: root.view === modelData.key && root.artistFilter === "" && root.genreFilter === ""
              onClicked: root.setView(modelData.key)
            }
          }

          Item { width: 1; height: Style.space(10) }
          Caption { text: "GENRES"; bottomPadding: Style.space(4) }
          Repeater {
            model: root.facets ? root.facets.genres.slice(0, 14) : []
            SideItem {
              required property var modelData
              label: modelData.name
              count: modelData.n
              active: root.genreFilter.toLowerCase() === String(modelData.name).toLowerCase()
              onClicked: root.genreFilter = active ? "" : modelData.name
            }
          }

          Item { width: 1; height: Style.space(10) }
          Caption { text: "ARTISTS"; bottomPadding: Style.space(4) }
          Repeater {
            model: root.facets ? root.facets.artists : []
            SideItem {
              required property var modelData
              label: modelData.name
              count: modelData.n
              active: root.artistFilter.toLowerCase() === String(modelData.name).toLowerCase()
              onClicked: root.artistFilter = active ? "" : modelData.name
            }
          }
        }
      }

      Rectangle {
        x: full.sideW + full.gap / 2
        width: 1
        height: parent.height
        color: Util.alpha(root.fg, 0.10)
      }

      // ---- Track list
      Item {
        id: listPane
        x: full.sideW + full.gap
        width: full.width - full.sideW - full.npW - full.gap * 2
        height: parent.height

        Column {
          id: listHead
          width: parent.width
          spacing: Style.space(8)

          Row {
            width: parent.width
            spacing: Style.space(6)
            TextField {
              id: search
              width: parent.width - playAll.width - shuffleAll.width - parent.spacing * 2
              foreground: root.fg
              placeholderText: "Search " + Model.thousands(root.facets && root.facets.views ? root.facets.views.all : 0)
                               + " likes (title, artist, genre)"
              text: root.query
              onTextChanged: root.query = text
              onAccepted: root.playRow(root.selIndex)
              Component.onCompleted: { root.searchItem = search; forceActiveFocus() }
            }
            Chip {
              id: playAll
              anchors.verticalCenter: search.verticalCenter
              label: Model.PLAY + " Play"
              onClicked: root.playList(false)
            }
            Chip {
              id: shuffleAll
              anchors.verticalCenter: search.verticalCenter
              label: Model.SHUFFLE + " Shuffle"
              onClicked: root.playList(true)
            }
          }

          Item {
            width: parent.width
            height: sortRow.height
            Row {
              id: sortRow
              spacing: Style.space(2)
              Caption { anchors.verticalCenter: parent.verticalCenter; text: "SORT"; rightPadding: Style.space(4) }
              Repeater {
                model: Model.SORT_LIST
                Chip {
                  required property var modelData
                  label: modelData.label
                  active: root.sortKey === modelData.key
                  onClicked: root.sortKey = modelData.key
                }
              }
            }
            Row {
              anchors.right: parent.right
              anchors.verticalCenter: sortRow.verticalCenter
              spacing: Style.space(4)
              Chip {
                visible: root.artistFilter !== ""
                label: root.artistFilter + "  ×"
                active: true
                onClicked: root.artistFilter = ""
              }
              Chip {
                visible: root.genreFilter !== ""
                label: root.genreFilter + "  ×"
                active: true
                onClicked: root.genreFilter = ""
              }
            }
          }

          Item {
            width: parent.width
            height: countText.implicitHeight
            SmallText {
              id: countText
              text: Model.thousands(root.rowsTotal) + (root.rowsTotal === 1 ? " track" : " tracks")
                    + " · " + Model.viewLabel(root.view)
                    + (root.rowsLoading ? "  …" : "")
            }
            SmallText {
              anchors.right: parent.right
              text: "↑↓ select · ⏎ play · click an artist to filter"
              color: root.faint
            }
          }
          PanelSeparator { foreground: root.fg }
        }

        ListView {
          id: list
          anchors.top: listHead.bottom
          anchors.topMargin: Style.space(4)
          anchors.bottom: parent.bottom
          width: parent.width
          clip: true
          model: trackModel
          boundsBehavior: Flickable.StopAtBounds
          reuseItems: true
          cacheBuffer: 400
          Component.onCompleted: root.listItem = list
          onAtYEndChanged: if (atYEnd) root.loadMore()

          delegate: Rectangle {
            id: rowItem
            required property int index
            required property var model
            readonly property bool isCurrent: root.track !== null && model.sc_id === root.track.sc_id
            readonly property bool unplayable: model.status === "drm" || model.status === "gone"
            width: ListView.view.width
            height: Style.space(26)
            radius: Style.cornerRadius
            color: index === root.selIndex ? Style.selectedFillFor(root.fg, root.accent, root.badColor)
                 : rowArea.containsMouse ? Style.hoverFillFor(root.fg, root.accent) : "transparent"

            MouseArea {
              id: rowArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: { root.selIndex = rowItem.index; root.playRow(rowItem.index) }
            }

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              spacing: Style.space(8)

              Text {
                id: statusIcon
                width: Style.space(16)
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignHCenter
                text: rowItem.isCurrent ? Model.stateGlyph(root.pstate) : Model.statusGlyph(rowItem.model.status, rowItem.model.archiving)
                color: rowItem.isCurrent ? root.accent : Model.statusTone(rowItem.model.status, rowItem.model.archiving) === "good" ? root.goodColor
                     : Model.statusTone(rowItem.model.status, rowItem.model.archiving) === "warn" ? root.warnColor
                     : Model.statusTone(rowItem.model.status, rowItem.model.archiving) === "bad" ? root.badColor
                     : Model.statusTone(rowItem.model.status, rowItem.model.archiving) === "accent" ? root.accent : root.faint
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.NoButton
                  onContainsMouseChanged: {
                    if (!root.bar) return
                    if (containsMouse) root.bar.showTooltip(statusIcon, Model.statusLabel(rowItem.model.status, rowItem.model.archiving))
                    else root.bar.hideTooltip(statusIcon)
                  }
                }
              }
              SmallText {
                width: parent.width - statusIcon.width - artistCell.width - playsCell.width - timeCell.width
                       - actionCell.width - parent.spacing * 5
                anchors.verticalCenter: parent.verticalCenter
                text: rowItem.model.title
                color: rowItem.isCurrent ? root.accent : rowItem.unplayable ? root.faint : root.fg
                font.bold: rowItem.isCurrent
              }
              SmallText {
                id: artistCell
                width: Math.round(listPane.width * 0.26)
                anchors.verticalCenter: parent.verticalCenter
                text: rowItem.model.artist
                color: artistArea.containsMouse ? root.fg : root.dim
                font.underline: artistArea.containsMouse
                MouseArea {
                  id: artistArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.artistFilter = rowItem.model.artist
                }
              }
              SmallText {
                id: playsCell
                width: Style.space(26)
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: rowItem.model.plays > 0 ? String(rowItem.model.plays) : ""
                color: root.faint
              }
              SmallText {
                id: timeCell
                width: Style.space(40)
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: Model.clock(rowItem.model.duration)
                color: root.faint
              }
              Item {
                id: actionCell
                width: Style.space(18)
                height: parent.height
                IconLink {
                  anchors.centerIn: parent
                  opacity: rowArea.containsMouse || hot || rowItem.index === root.selIndex ? 1 : 0
                  readonly property bool canArchive: (rowItem.model.status === "linked" || rowItem.model.status === "failed")
                                                     && !rowItem.model.archiving
                  text: canArchive ? Model.DOWNLOAD : rowItem.model.status === "archived" ? "" : Model.OPEN
                  tip: canArchive ? "Archive now" : "Open on SoundCloud"
                  onClicked: canArchive ? root.archiveNow(rowItem.index) : root.run(["xdg-open", rowItem.model.permalink])
                }
              }
            }
          }

          SmallText {
            anchors.centerIn: parent
            visible: !root.rowsLoading && trackModel.count === 0
            text: root.daemonUp ? "No tracks match" : "sclikes isn't running"
          }
        }
      }

      Rectangle {
        x: full.width - full.npW - full.gap / 2
        width: 1
        height: parent.height
        color: Util.alpha(root.fg, 0.10)
      }

      // ---- Now playing column
      Flickable {
        id: npScroll
        x: full.width - full.npW
        width: full.npW
        height: parent.height
        contentWidth: width
        contentHeight: npBody.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        NowPlaying { id: npBody; width: npScroll.width }
      }
    }
  }

  // ---------------------------------------------------------------- screensaver overlay
  // Above Omarchy's screensaver on this bar's screen while music plays. The input mask is
  // empty, so keys and mouse still reach the screensaver (which exits), and this hides with it.

  // Whole-bar glow: a click-through layer over this bar (and a soft spill just below it) tinted with the
  // cover colour; it brightens on bass hits. Each bar's Panel draws its own screen.
  PanelWindow {
    id: glow
    screen: root.anchorWindow ? root.anchorWindow.screen : null
    visible: glowFx.opacity > 0
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "sclikes-bar-glow"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    readonly property bool atBottom: root.bar && root.bar.position === "bottom"
    anchors { top: !atBottom; bottom: atBottom; left: true; right: true }
    readonly property real barH: root.anchorWindow ? root.anchorWindow.height : Style.bar.sizeHorizontal
    readonly property real spill: Style.space(70)
    implicitHeight: barH + spill
    mask: Region {}

    Item {
      id: glowFx
      anchors.fill: parent
      opacity: root.glowActive && !root.saverActive ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 600 } }
      property real level: root.glowLevel
      readonly property real hit: Math.pow(level, 2)   // heavy beats stand out from the steady wash
      readonly property color c1: root.accent
      readonly property color c2: Qt.hsla((root.accentHue + 0.06) % 1, Math.max(0.6, root.accent.hslSaturation), root.accent.hslLightness, 1)
      readonly property color c3: Qt.hsla((root.accentHue + 0.94) % 1, Math.max(0.6, root.accent.hslSaturation), root.accent.hslLightness, 1)

      // Wash over the bar itself: kept light so the bar's text stays readable.
      Rectangle {
        y: glow.atBottom ? glow.spill : 0
        width: parent.width
        height: glow.barH
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0.0; color: Util.alpha(glowFx.c2, 0.14 + 0.28 * glowFx.hit) }
          GradientStop { position: 0.5; color: Util.alpha(glowFx.c1, 0.09 + 0.20 * glowFx.hit) }
          GradientStop { position: 1.0; color: Util.alpha(glowFx.c3, 0.14 + 0.28 * glowFx.hit) }
        }
      }
      // Edge line where the bar meets the desktop.
      Rectangle {
        y: glow.atBottom ? glow.spill : glow.barH - height
        width: parent.width
        height: Math.max(1, Style.space(glowFx.hit > 0.5 ? 2.5 : 1.5))
        color: Util.alpha(Qt.lighter(glowFx.c1, 1 + 0.4 * glowFx.hit), 0.45 + 0.55 * glowFx.level)
      }
      // Glow radiating out from the bar: always a soft halo, reaching further and brighter on hits.
      // Exponential-ish falloff (several stops) reads as light rather than a flat band.
      Rectangle {
        readonly property real reach: glow.spill * (0.6 + 0.4 * glowFx.level)
        y: glow.atBottom ? glow.spill - reach : glow.barH
        width: parent.width
        height: reach
        opacity: 0.6 + 0.2 * glowFx.level + 0.2 * glowFx.hit
        gradient: Gradient {
          GradientStop { position: glow.atBottom ? 1.0 : 0.0;  color: Util.alpha(glowFx.c1, 0.75) }
          GradientStop { position: glow.atBottom ? 0.85 : 0.15; color: Util.alpha(glowFx.c2, 0.45) }
          GradientStop { position: glow.atBottom ? 0.6 : 0.4;  color: Util.alpha(glowFx.c1, 0.22) }
          GradientStop { position: glow.atBottom ? 0.3 : 0.7;  color: Util.alpha(glowFx.c3, 0.08) }
          GradientStop { position: glow.atBottom ? 0.0 : 1.0;  color: Util.alpha(glowFx.c1, 0) }
        }
      }
    }
  }

  PanelWindow {
    id: saver
    screen: root.anchorWindow ? root.anchorWindow.screen : null
    visible: root.saverActive && root.anchorWindow !== null  // not `screen`: that changes when we map
    color: "black"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "sclikes-screensaver"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    anchors { top: true; bottom: true; left: true; right: true }
    mask: Region {}

    Item {
      id: saverContent
      width: parent.width
      height: parent.height

      // Slow drift so nothing sits still on the panel for long.
      property real driftX: 0
      property real driftY: 0
      SequentialAnimation on driftX {
        running: saver.visible
        loops: Animation.Infinite
        NumberAnimation { to: 40; duration: 47000; easing.type: Easing.InOutSine }
        NumberAnimation { to: -40; duration: 47000; easing.type: Easing.InOutSine }
      }
      SequentialAnimation on driftY {
        running: saver.visible
        loops: Animation.Infinite
        NumberAnimation { to: 24; duration: 31000; easing.type: Easing.InOutSine }
        NumberAnimation { to: -24; duration: 31000; easing.type: Easing.InOutSine }
      }

      Spectrum {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: parent.width * 0.04
        height: parent.height * 0.32   // stays below the text block
        count: 32   // one per cava band
        gapRatio: 0.35
        minFraction: 0.01
        visible: root.vizAvailable
      }

      Column {
        x: (parent.width - width) / 2 + saverContent.driftX
        y: parent.height * 0.10 + saverContent.driftY
        width: Math.min(parent.width * 0.6, Style.space(640))
        spacing: Style.space(14)

        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          width: Math.min(parent.width, saverContent.height * 0.32)
          height: width
          radius: Style.space(10)
          color: Util.alpha(root.fg, 0.06)
          clip: true
          Image {
            id: saverArt
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            sourceSize.width: 600
            sourceSize.height: 600
            source: root.artSource
            visible: status === Image.Ready
          }
          Text {
            anchors.centerIn: parent
            visible: saverArt.status !== Image.Ready
            text: Model.NOTE
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: parent.height * 0.3
          }
        }
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.track ? root.track.title : ""
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.displayLarge
          font.bold: true
          wrapMode: Text.Wrap
          maximumLineCount: 2
          elide: Text.ElideRight
          textFormat: Text.PlainText
        }
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.track ? root.track.artist : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          elide: Text.ElideRight
          textFormat: Text.PlainText
        }
        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          width: parent.width * 0.6
          height: Style.space(3)
          radius: height / 2
          color: Util.alpha(root.fg, 0.12)
          Rectangle {
            width: parent.width * (root.duration > 0 ? Math.min(1, root.pos / root.duration) : 0)
            height: parent.height
            radius: parent.radius
            color: root.accent
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- window

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // theme border, tinted toward the art color (a theme border gradient yields while tinted)
    readonly property var themeBorder: Border.surfaceSpec("popups", "border", Color.popups.border,
                                                          Math.max(1, Style.space(2)))
    borderSpec: root.tintStrength > 0
      ? { color: Qt.tint(themeBorder.color, Util.alpha(root.accent, 0.9 * root.tintStrength)),
          widths: themeBorder.widths, gradient: { colors: [], angle: 0, enabled: false } }
      : themeBorder
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(viewLoader.item ? viewLoader.item.implicitHeight : Style.space(300),
                                             Style.space(720))

    // Cover-art tint over the card background; reaches back over the card padding to its border.
    Rectangle {
      anchors.fill: parent
      anchors.margins: -panel.padding
      radius: Math.max(0, Style.cornerRadius - Border.left(panel.borderSpec))
      visible: root.tintStrength > 0
      gradient: Gradient {
        GradientStop { position: 0.0; color: Util.alpha(root.accent, 0.32 * root.tintStrength) }
        GradientStop { position: 0.55; color: Util.alpha(root.accent, 0.13 * root.tintStrength) }
        GradientStop { position: 1.0; color: Util.alpha(root.accent, 0.06 * root.tintStrength) }
      }
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: root.playPause()
      onMoveRequested: function(dx, dy) {
        if (dx) root.seekBy(dx * 10)
        if (dy) root.volumeBy(-dy * 5)
      }
      onTextKey: function(t) { root.playerKey(t) }

      Loader {
        id: viewLoader
        anchors.fill: parent
        sourceComponent: compactView
        onLoaded: Qt.callLater(function() { keyCatcher.forceActiveFocus() })
      }
    }
  }

  function playerKey(t) {
    if (t === "n" || t === ">") root.next()
    else if (t === "p" || t === "<") root.prev()
    else if (t === "s") root.toggleShuffle()
    else if (t === "r") root.cycleRepeat()
    else if (t === "g" && root.expanded) root.toggleBarGlow()
    else if (t === "f") root.setExpanded(!root.expanded)
    else if (t === "t" && root.remoteSet) root.playOn(root.remoteMode ? "here" : "remote")
    else if (t === "/" && root.searchItem) root.searchItem.forceActiveFocus()
  }

  // Full player: a real toplevel window rather than a popup, so clicking another window
  // doesn't dismiss it. Closed by ⤡ (back to the dropdown), Esc, or the compositor.
  FloatingWindow {
    id: playerWindow
    visible: false
    title: "sclikes player"
    color: Color.popups.background
    implicitWidth: Style.space(1160)
    implicitHeight: Style.space(720)
    minimumSize: Qt.size(Style.space(900), Style.space(520))
    // Bigger UI on the laptop's built-in panel (it floats there, see hypr/sclikes.lua).
    readonly property string screenName: screen ? String(screen.name) : ""
    readonly property real uiScale: /^(eDP|LVDS|DSI)/.test(screenName) ? 1.3 : 1

    onVisibleChanged: {
      if (visible) Qt.callLater(function() { fullKeys.forceActiveFocus() })
      else root.expanded = false
    }

    Rectangle {
      anchors.fill: parent
      visible: root.tintStrength > 0
      gradient: Gradient {
        GradientStop { position: 0.0; color: Util.alpha(root.accent, 0.32 * root.tintStrength) }
        GradientStop { position: 0.55; color: Util.alpha(root.accent, 0.13 * root.tintStrength) }
        GradientStop { position: 1.0; color: Util.alpha(root.accent, 0.06 * root.tintStrength) }
      }
    }

    PanelKeyCatcher {
      id: fullKeys
      anchors.fill: parent
      anchors.margins: Style.spacing.popupPadding
      onCloseRequested: playerWindow.visible = false
      onActivateRequested: root.playPause()
      onReturnRequested: root.playRow(root.selIndex)
      onMoveRequested: function(dx, dy) {
        if (dy) { root.moveSelection(dy); return }
        if (dx) root.seekBy(dx * 10)
      }
      onTextKey: function(t) { root.playerKey(t) }

      // Laid out at 1/uiScale of the window, then scaled up, so every font, row and icon grows together.
      Item {
        width: parent.width / playerWindow.uiScale
        height: parent.height / playerWindow.uiScale
        scale: playerWindow.uiScale
        transformOrigin: Item.TopLeft
        Loader {
          anchors.fill: parent
          active: root.expanded
          sourceComponent: fullView
        }
      }
    }
  }

  onExpandedChanged: {
    playerWindow.visible = expanded
    if (!expanded) { searchItem = null; listItem = null }
  }
}
