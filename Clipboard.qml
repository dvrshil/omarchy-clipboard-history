import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Raycast-style clipboard history for Omarchy.
//
// It reads the history the stock omarchy.clipboard plugin already records
// (every Super+C / Ctrl+C lands there), and layers on top: pins, type filters,
// custom names, inline editing, source app + copy counts, OCR and QR text
// extraction, time-window deletion, retention, and ignored apps.
//
// Summon: omarchy-shell shell toggle dvrshil.clipboard
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var manifest: null
  property var shell: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string actionsScript: pluginDir + "/actions.sh"
  readonly property string historyPath: home + "/.local/state/omarchy/clipboard-history.json"
  readonly property string stateDir: home + "/.local/state/omarchy/dvrshil-clipboard"
  readonly property string statePath: stateDir + "/state.json"
  readonly property string shellConfigPath: home + "/.config/omarchy/shell.json"
  readonly property int historyLimit: 500

  // ---- settings (inline on the bar entry in shell.json) ----
  property var settings: ({})
  function setting(name, fallback) {
    var v = settings ? settings[name] : undefined
    return v === undefined || v === null || v === "" ? fallback : v
  }
  // Empty until the user sets one: the plugin never binds a key on its own.
  readonly property string shortcut: String(setting("shortcut", ""))
  readonly property bool pasteIsPrimary: String(setting("primaryAction", "Paste to active app")) !== "Copy to clipboard"
  readonly property string retention: String(setting("keepHistoryFor", "3 Months"))
  readonly property var ignoredApps: Model.parseList(setting("ignoredApps", "1password, bitwarden, keepassxc, org.keepassxc.KeePassXC"))
  property string appliedShortcut: ""

  // ---- data ----
  property var history: []
  property var historyKeys: []
  property var store: Model.emptyState()
  property bool historyLoaded: false
  property bool stateLoaded: false
  property bool reconciled: false
  property string frontKey: ""
  property real nowMs: Date.now()

  // ---- UI state ----
  property bool opened: false
  property string filterText: ""
  property string typeFilter: "all"
  property int selectedIndex: 0
  property string mode: "list"          // list | actions | rename | edit | confirm
  property string actionFilter: ""
  property int actionIndex: 0
  property var actionList: []
  property int rowsRevision: 0
  readonly property var current: (rowsRevision, selectedIndex >= 0 && selectedIndex < rowsModel.count ? rowsModel.get(selectedIndex) : null)

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ---- theme (shares the menu surface tokens, like the stock clipboard) ----
  readonly property color background: Commons.Color.menu.background
  readonly property color foreground: Commons.Color.menu.text
  readonly property color border: Commons.Color.menu.border
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  readonly property color scrim: Commons.Color.menu.scrim
  readonly property color selectedBackground: Commons.Color.menu.selectedBackground
  readonly property color selectedText: Commons.Color.menu.selectedText
  readonly property color dim: Util.alpha(foreground, 0.6)
  readonly property color faint: Util.alpha(foreground, 0.28)
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int radius: Style.cornerRadius
  readonly property int pad: Style.spacing.panelPadding
  readonly property int rowHeight: Math.max(Style.space(40), Style.font.title + Style.spacing.rowPaddingX * 2)

  // =========================================================================
  // lifecycle
  // =========================================================================

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) {}
    root.nowMs = Date.now()
    root.filterText = ""
    root.typeFilter = Model.typeFilters.indexOf(String(payload.type || "")) >= 0 ? String(payload.type) : "all"
    root.selectedIndex = 0
    root.mode = "list"
    root.opened = true
    root.rebuild(false)
    Qt.callLater(function() { searchInput.forceActiveFocus() })
  }

  function close() {
    root.mode = "list"
    root.opened = false
  }

  function toggle() { root.opened ? root.close() : root.open("{}") }

  // =========================================================================
  // persistence
  // =========================================================================

  FileView {
    id: historyFile
    path: root.historyPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.onHistoryText(text())
    onLoadFailed: root.onHistoryText("[]")
    onFileChanged: reload()
  }

  FileView {
    id: stateFile
    path: root.statePath
    atomicWrites: true
    printErrors: false
    onLoaded: { root.store = Model.parseState(text()); root.stateLoaded = true; root.reconcileNow() }
    onLoadFailed: { root.store = Model.emptyState(); root.stateLoaded = true; root.reconcileNow() }
  }

  FileView {
    id: shellConfigFile
    path: root.shellConfigPath
    watchChanges: true
    printErrors: false
    onLoaded: root.readSettings(text())
    onFileChanged: reload()
  }

  Timer { id: saveStateTimer; interval: 400; onTriggered: root.writeState() }

  Timer {
    interval: 3600000
    running: true
    repeat: true
    onTriggered: root.applyRetention()
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Component.onCompleted: Quickshell.execDetached(["mkdir", "-p", root.stateDir])

  function readSettings(raw) {
    var cfg = {}
    try { cfg = JSON.parse(raw) || {} } catch (e) { return }
    var found = null
    var layout = cfg.bar && cfg.bar.layout ? cfg.bar.layout : {}
    for (var section in layout) {
      var list = Array.isArray(layout[section]) ? layout[section] : []
      for (var i = 0; i < list.length; i++)
        if (list[i] && list[i].id === "dvrshil.clipboard") found = list[i]
    }
    if (!found && Array.isArray(cfg.plugins))
      for (var j = 0; j < cfg.plugins.length; j++)
        if (cfg.plugins[j] && cfg.plugins[j].id === "dvrshil.clipboard") found = cfg.plugins[j]
    root.settings = found || {}
    root.syncShortcut()
  }

  // Write the Hyprland binding only for a Shortcut the user set themselves.
  // Clearing the setting leaves any existing binding alone.
  function syncShortcut() {
    var chord = root.shortcut.trim()
    if (!chord || chord === root.appliedShortcut) return
    root.appliedShortcut = chord
    Quickshell.execDetached([root.actionsScript, "set-shortcut", chord])
  }

  function onHistoryText(raw) {
    var parsed = Model.parseHistory(raw)
    var keys = []
    for (var i = 0; i < parsed.length; i++) keys.push(Model.entryKey(parsed[i]))
    root.history = parsed
    root.historyKeys = keys
    root.historyLoaded = true
    root.reconcileNow()
  }

  function activeApp() {
    var t = ToplevelManager.activeToplevel
    return t ? String(t.appId || "") : ""
  }

  function reconcileNow() {
    if (!root.historyLoaded || !root.stateLoaded) return
    var first = !root.reconciled
    var app = root.activeApp()
    var result = Model.reconcile(root.store, root.history, root.frontKey, Date.now(), app, first)
    root.frontKey = result.frontKey
    root.reconciled = true

    // Raycast's "ignore apps": drop a copy made in an ignored app.
    if (result.newCopy && Model.appIgnored(app, root.ignoredApps) && !Model.isPinned(root.store, result.frontKey)) {
      root.writeHistory(Model.removeKeys(root.history, [result.frontKey]))
      return
    }
    if (first) root.applyRetention()
    root.scheduleStateSave()
    if (root.opened) root.rebuild()
  }

  function writeHistory(next) {
    var trimmed = next.slice(0, root.historyLimit)
    historyFile.setText(JSON.stringify(trimmed, null, 2) + "\n")
    root.onHistoryText(JSON.stringify(trimmed))
  }

  function scheduleStateSave() { saveStateTimer.restart() }

  function writeState() {
    stateFile.setText(JSON.stringify(root.store) + "\n")
  }

  function applyRetention() {
    if (!root.reconciled) return
    var expired = Model.expiredKeys(root.history, root.store, root.retention, Date.now())
    if (expired.length) root.writeHistory(Model.removeKeys(root.history, expired))
  }

  // =========================================================================
  // list
  // =========================================================================

  ListModel { id: rowsModel }

  // keepSelection follows the selected entry when the list changes under an
  // open overlay. Opening passes false so it always starts at the newest copy.
  function rebuild(keepSelection) {
    var keepKey = keepSelection !== false && root.current ? root.current.key : ""
    var rows = Model.displayRows(root.history, root.store, root.filterText, root.typeFilter, 300, root.nowMs, root.historyKeys)
    rowsModel.clear()
    var nextIndex = -1
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i]
      if (r.key === keepKey) nextIndex = i
      rowsModel.append({
        key: r.key, kind: r.kind, title: r.title, customName: r.customName, fileCount: r.fileCount,
        body: r.body, truncated: r.truncated, path: r.path, mime: r.mime,
        previewImage: r.previewImage ? Util.fileUrl(r.previewImage) : "",
        historyIndex: r.historyIndex, pinned: r.pinned, group: r.group, app: r.app,
        first: r.first, last: r.last, count: r.count, approx: r.approx,
        characters: r.stats.characters, words: r.stats.words, lines: r.stats.lines,
        swatch: r.kind === "color" ? Model.qmlColor(r.body) : ""
      })
    }
    if (nextIndex >= 0 && root.filterText === "") root.selectedIndex = nextIndex
    root.selectedIndex = Math.max(0, Math.min(root.selectedIndex, rowsModel.count - 1))
    root.rowsRevision++
    Qt.callLater(root.ensureVisible)
  }

  // Section headers sit outside their row, so index 0 needs the very top.
  function ensureVisible() {
    if (!rowsModel.count) return
    if (root.selectedIndex === 0) list.positionViewAtBeginning()
    else list.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  Connections {
    target: Commons.I18n
    function onStringsChanged() { if (root.opened) root.rebuild() }
  }

  function select(delta) {
    if (!rowsModel.count) return
    root.selectedIndex = Math.max(0, Math.min(rowsModel.count - 1, root.selectedIndex + delta))
    root.ensureVisible()
  }

  function setFilter(text) {
    root.filterText = text
    root.selectedIndex = 0
    root.rebuild()
  }

  function cycleType(delta) {
    root.typeFilter = Model.nextTypeFilter(root.typeFilter, delta)
    root.selectedIndex = 0
    root.rebuild()
  }

  // Full entry for a row: history (authoritative) or the pin's own copy.
  function entryFor(row) {
    if (!row) return null
    if (row.historyIndex >= 0 && row.historyIndex < root.history.length && root.historyKeys[row.historyIndex] === row.key)
      return root.history[row.historyIndex]
    for (var i = 0; i < root.store.pins.length; i++)
      if (root.store.pins[i].key === row.key) return root.store.pins[i].entry
    var idx = root.historyKeys.indexOf(row.key)
    return idx >= 0 ? root.history[idx] : null
  }

  function titleFor(row) {
    if (!row) return ""
    if (row.title) return row.title
    if (row.kind === "file") return strings.tn("files", row.fileCount).arg(Commons.I18n.formatNumber(row.fileCount))
    if (row.kind === "image") {
      var e = root.entryFor(row)
      var at = e && e.capturedAt ? String(e.capturedAt) : ""
      if (!at) return strings.t("image")
      return (row.mime === "image/png" ? strings.t("screenshotFrom") : strings.t("imageFrom")).arg(at)
    }
    return ""
  }

  function kindGlyph(kind) {
    switch (kind) {
    case "image": return "\u{f02e9}"   // nf-md-image
    case "file": return "\u{f0214}"    // nf-md-file
    case "link": return "\u{f0337}"    // nf-md-link_variant
    case "email": return "\u{f01ee}"   // nf-md-email
    case "color": return "\u{f03d8}"   // nf-md-palette
    default: return "\u{f09ed}"        // nf-md-text
    }
  }

  // =========================================================================
  // actions
  // =========================================================================

  Component {
    id: textPipeComponent
    Process {
      property string payload: ""
      stdinEnabled: true
      onStarted: { write(payload); stdinEnabled = false }
      onExited: destroy()
    }
  }

  function pipeText(args, text) {
    var p = textPipeComponent.createObject(root, { payload: String(text), command: [root.actionsScript].concat(args) })
    if (p) p.running = true
  }

  function bumpToTop(row) {
    var m = root.store.meta[row.key]
    if (m) { m.last = Date.now(); m.count = (m.count || 1) + 1; delete m.approx }
    root.scheduleStateSave()
  }

  function deliver(row, paste) {
    var entry = root.entryFor(row)
    if (!entry) return
    root.close()
    if (entry.type === "image") {
      var args = [root.actionsScript, "copy-image", entry.mime, entry.path]
      if (paste) args.push("--paste")
      Quickshell.execDetached(args)
    } else {
      root.pipeText(paste ? ["copy-text", "--paste"] : ["copy-text"], entry.text)
    }
  }

  function primary(row) { root.deliver(row, root.pasteIsPrimary) }
  function secondary(row) { root.deliver(row, !root.pasteIsPrimary) }

  function openRow(row) {
    var entry = root.entryFor(row)
    if (!entry) return
    root.close()
    if (row.kind === "link" || row.kind === "email") {
      var url = Model.linkUrl(entry)
      if (url) Quickshell.execDetached([root.actionsScript, "open-url", url])
    } else if (entry.type === "image") {
      Quickshell.execDetached(["omasnap", "--notify", entry.path])
    } else if (row.kind === "file") {
      Quickshell.execDetached([root.actionsScript, "open-path", Model.filePaths(entry)[0]])
    } else {
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-clipboard-open", "--history-index", String(row.historyIndex)])
    }
  }

  function revealRow(row) {
    var entry = root.entryFor(row)
    if (!entry) return
    var path = entry.type === "image" ? entry.path : (Model.filePaths(entry)[0] || "")
    if (!path) return
    root.close()
    Quickshell.execDetached([root.actionsScript, "reveal", path])
  }

  function imagePathFor(row) {
    var entry = root.entryFor(row)
    if (!entry) return ""
    if (entry.type === "image") return entry.path
    var paths = Model.filePaths(entry)
    return paths.length === 1 && /\.(png|jpe?g|webp|gif|bmp|tiff?)$/i.test(paths[0]) ? paths[0] : ""
  }

  function ocrRow(row) {
    var path = root.imagePathFor(row)
    if (!path) return
    root.close()
    Quickshell.execDetached([root.actionsScript, "ocr", path])
  }

  function qrRow(row) {
    var path = root.imagePathFor(row)
    if (!path) return
    root.close()
    Quickshell.execDetached([root.actionsScript, "qr", path])
  }

  function shareRow(row) {
    var entry = root.entryFor(row)
    if (!entry) return
    root.close()
    if (entry.type === "image") Quickshell.execDetached([root.actionsScript, "share", entry.path])
    else if (row.kind === "file") Quickshell.execDetached([root.actionsScript, "share"].concat(Model.filePaths(entry)))
    else root.pipeText(["share-text"], entry.text)
  }

  function togglePinRow(row) {
    var entry = root.entryFor(row)
    if (!entry) return
    Model.togglePin(root.store, entry, Date.now())
    root.scheduleStateSave()
    root.rebuild()
  }

  function movePinRow(row, delta) {
    if (!row || !row.pinned) return
    Model.movePin(root.store, row.key, delta)
    root.scheduleStateSave()
    root.rebuild()
  }

  function deleteRow(row) {
    if (!row) return
    if (row.pinned) Model.togglePin(root.store, root.entryFor(row), Date.now())
    root.scheduleStateSave()
    if (row.historyIndex >= 0) root.writeHistory(Model.removeKeys(root.history, [row.key]))
    else root.rebuild()
  }

  function deleteRecent(minutes) {
    var keys = Model.keysCopiedSince(root.history, root.store, minutes * 60000, Date.now())
    if (keys.length) root.writeHistory(Model.removeKeys(root.history, keys))
  }

  function deleteAll() {
    // Pinned entries survive, as in Raycast.
    var keep = root.history.filter(function(e) { return Model.isPinned(root.store, Model.entryKey(e)) })
    root.writeHistory(keep)
  }

  function startRename(row) {
    if (!row) return
    renameInput.text = row.customName
    root.mode = "rename"
    Qt.callLater(function() { renameInput.forceActiveFocus(); renameInput.selectAll() })
  }

  function commitRename() {
    var row = root.current
    if (row) {
      Model.setName(root.store, row.key, renameInput.text, Date.now())
      root.scheduleStateSave()
    }
    root.mode = "list"
    root.rebuild()
    searchInput.forceActiveFocus()
  }

  function startEdit(row) {
    var entry = root.entryFor(row)
    if (!entry || entry.type !== "text") return
    editArea.text = String(entry.text).slice(0, Model.maxTextLength)
    root.mode = "edit"
    Qt.callLater(function() { editArea.forceActiveFocus(); editArea.cursorPosition = editArea.length })
  }

  function commitEdit() {
    var row = root.current
    if (row) {
      var r = Model.replaceText(root.history, root.store, row.key, editArea.text, Date.now())
      root.scheduleStateSave()
      root.writeHistory(r.history)
    }
    root.mode = "list"
    searchInput.forceActiveFocus()
  }

  function backToList() {
    root.mode = "list"
    searchInput.forceActiveFocus()
  }

  // ---- action panel (Ctrl+K) ----
  function buildActions() {
    var row = root.current
    if (!row) return []
    var out = []
    function add(id, label, keys) { out.push({ id: id, label: label, keys: keys || "" }) }
    var pasteLabel = strings.t("action.paste"), copyLabel = strings.t("action.copy")
    if (root.pasteIsPrimary) { add("paste", pasteLabel, "Enter"); add("copy", copyLabel, "Ctrl+Enter") }
    else { add("copy", copyLabel, "Enter"); add("paste", pasteLabel, "Ctrl+Enter") }
    if (row.kind === "link" || row.kind === "email") add("open", strings.t("action.openLink"), "Ctrl+O")
    else add("open", strings.t("action.open"), "Ctrl+O")
    if (row.kind === "image" || row.kind === "file") add("reveal", strings.t("action.reveal"), "Ctrl+Shift+O")
    if (root.imagePathFor(row)) { add("ocr", strings.t("action.ocr"), "Ctrl+T"); add("qr", strings.t("action.qr"), "") }
    add("share", strings.t("action.share"), "Ctrl+Shift+S")
    add("rename", strings.t("action.rename"), "Ctrl+E")
    if (row.kind !== "image" && row.kind !== "file") add("edit", strings.t("action.edit"), "Ctrl+Shift+E")
    add("pin", row.pinned ? strings.t("action.unpin") : strings.t("action.pin"), "Ctrl+.")
    if (row.pinned) { add("pinUp", strings.t("action.pinUp"), "Ctrl+Shift+↑"); add("pinDown", strings.t("action.pinDown"), "Ctrl+Shift+↓") }
    add("delete", strings.t("action.delete"), "Ctrl+X")
    add("delete5", strings.t("action.delete5"), "")
    add("delete15", strings.t("action.delete15"), "")
    add("delete30", strings.t("action.delete30"), "")
    add("delete60", strings.t("action.delete60"), "")
    add("delete1440", strings.t("action.delete1440"), "")
    add("deleteAll", strings.t("action.deleteAll"), "Ctrl+Shift+X")
    return out
  }

  function filteredActions() {
    var needle = root.actionFilter.trim().toLowerCase()
    var all = root.buildActions()
    return needle ? all.filter(function(a) { return a.label.toLowerCase().indexOf(needle) >= 0 }) : all
  }

  function openActions() {
    if (!root.current) return
    root.actionFilter = ""
    root.actionIndex = 0
    root.actionList = root.filteredActions()
    root.mode = "actions"
    Qt.callLater(function() { actionInput.forceActiveFocus() })
  }

  function runAction(id) {
    var row = root.current
    root.mode = "list"
    searchInput.forceActiveFocus()
    if (!row && id !== "deleteAll") return
    switch (id) {
    case "paste": root.deliver(row, true); break
    case "copy": root.deliver(row, false); break
    case "open": root.openRow(row); break
    case "reveal": root.revealRow(row); break
    case "ocr": root.ocrRow(row); break
    case "qr": root.qrRow(row); break
    case "share": root.shareRow(row); break
    case "rename": root.startRename(row); break
    case "edit": root.startEdit(row); break
    case "pin": root.togglePinRow(row); break
    case "pinUp": root.movePinRow(row, -1); break
    case "pinDown": root.movePinRow(row, 1); break
    case "delete": root.deleteRow(row); break
    case "delete5": root.deleteRecent(5); break
    case "delete15": root.deleteRecent(15); break
    case "delete30": root.deleteRecent(30); break
    case "delete60": root.deleteRecent(60); break
    case "delete1440": root.deleteRecent(1440); break
    case "deleteAll": root.requestDeleteAll(); break
    }
  }

  function requestDeleteAll() {
    confirmDialog.selectedIndex = 1
    root.mode = "confirm"
    keyCatcher.forceActiveFocus()
  }

  // Shortcuts shared by the search field. Returns true when handled.
  function handleListKey(event) {
    var ctrl = event.modifiers & Qt.ControlModifier
    var shift = event.modifiers & Qt.ShiftModifier
    var row = root.current

    if (event.key === Qt.Key_Escape) {
      if (root.filterText) root.setFilter("")
      else if (root.typeFilter !== "all") { root.typeFilter = "all"; root.rebuild() }
      else root.close()
      return true
    }
    if (event.key === Qt.Key_Up) {
      if (ctrl && shift) root.movePinRow(row, -1); else root.select(-1)
      return true
    }
    if (event.key === Qt.Key_Down) {
      if (ctrl && shift) root.movePinRow(row, 1); else root.select(1)
      return true
    }
    if (ctrl && !shift && (event.key === Qt.Key_N || event.key === Qt.Key_J)) { root.select(1); return true }
    if (ctrl && !shift && event.key === Qt.Key_K) { root.openActions(); return true }
    if (event.key === Qt.Key_PageUp) { root.select(-8); return true }
    if (event.key === Qt.Key_PageDown) { root.select(8); return true }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (!row) return true
      if (ctrl) root.secondary(row)
      else if (event.modifiers & Qt.AltModifier) root.openRow(row)
      else root.primary(row)
      return true
    }
    if (ctrl && event.key === Qt.Key_P) {
      if (shift) root.togglePinRow(row)        // Raycast's legacy ⌘⇧P
      else root.cycleType(1)
      return true
    }
    if (ctrl && event.key === Qt.Key_Tab) { root.cycleType(shift ? -1 : 1); return true }
    if (ctrl && event.key === Qt.Key_Period) { root.togglePinRow(row); return true }
    if (ctrl && event.key === Qt.Key_X) {
      if (shift) root.requestDeleteAll(); else root.deleteRow(row)
      return true
    }
    if (ctrl && event.key === Qt.Key_E) { if (shift) root.startEdit(row); else root.startRename(row); return true }
    if (ctrl && event.key === Qt.Key_O) { if (shift) root.revealRow(row); else root.openRow(row); return true }
    if (ctrl && event.key === Qt.Key_T) { root.ocrRow(row); return true }
    if (ctrl && shift && event.key === Qt.Key_S) { root.shareRow(row); return true }
    if (ctrl && !shift && event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
      var n = event.key - Qt.Key_1
      if (n < rowsModel.count) root.primary(rowsModel.get(n))
      return true
    }
    return false
  }

  // =========================================================================
  // formatting
  // =========================================================================

  function agoText(ms) {
    var diff = Math.max(0, root.nowMs - ms)
    var minutes = Math.floor(diff / 60000)
    if (minutes < 1) return strings.t("ago.now")
    if (minutes < 60) return strings.tn("ago.minutes", minutes).arg(Commons.I18n.formatNumber(minutes))
    var hours = Math.floor(minutes / 60)
    if (hours < 24) return strings.tn("ago.hours", hours).arg(Commons.I18n.formatNumber(hours))
    return new Date(ms).toLocaleString(Qt.locale(Commons.I18n.formatLocale), Locale.ShortFormat)
  }

  function whenText(row, ms) {
    if (!row || row.approx || !ms) return strings.t("meta.beforeTracking")
    return root.agoText(ms)
  }

  // =========================================================================
  // UI
  // =========================================================================

  component Label: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  component KeyHint: Row {
    property string label: ""
    property string keys: ""
    spacing: Style.space(6)
    Label { text: parent.label; color: root.dim; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      radius: Math.max(2, root.radius / 2)
      color: Util.alpha(root.foreground, 0.08)
      width: keyText.implicitWidth + Style.space(10)
      height: keyText.implicitHeight + Style.space(4)
      Label { id: keyText; anchors.centerIn: parent; text: parent.parent.keys; color: root.dim; font.pixelSize: Style.font.caption }
    }
  }

  component MetaRow: Item {
    property string label: ""
    property string value: ""
    width: parent ? parent.width : 0
    height: Math.max(Style.space(24), valueText.implicitHeight + Style.space(6))
    visible: value !== ""
    Label { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: parent.label; color: root.dim; width: parent.width * 0.42 }
    Label { id: valueText; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; width: parent.width * 0.56; horizontalAlignment: Text.AlignRight; text: parent.value }
    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: Style.normalBorderWidth; color: Util.alpha(root.foreground, 0.08) }
  }

  OverlayWindow {
    id: window
    shown: root.opened
    WlrLayershell.namespace: "dvrshil-clipboard"

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.close() }

    BorderSurface {
      id: card
      width: Math.min(Style.space(940), window.width - Style.gapsOut * 2)
      height: Math.min(Style.space(620), window.height - Style.gapsOut * 2)
      anchors.centerIn: parent
      radius: root.radius
      color: root.background
      borderSpec: root.borderSpec
      padding: 0

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: content
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        // ---------------- header: search + type filter ----------------
        Item {
          id: header
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: Math.max(Style.space(52), Style.font.heading + Style.spacing.controlPaddingY * 4)

          TextInput {
            id: searchInput
            anchors.left: parent.left
            anchors.right: typeButton.left
            anchors.leftMargin: root.pad
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            color: root.foreground
            selectionColor: Style.selectionFillFor(root.foreground, Commons.Color.accent)
            selectedTextColor: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            clip: true
            focus: root.mode === "list"
            onTextChanged: if (text !== root.filterText) root.setFilter(text)
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) {
              if (root.mode !== "list") return
              if (root.handleListKey(event)) event.accepted = true
            }

            Label {
              anchors.fill: parent
              verticalAlignment: Text.AlignVCenter
              text: strings.t("search")
              color: root.foreground
              opacity: 0.45
              font.pixelSize: Style.font.heading
              visible: !searchInput.text
            }
          }

          Connections {
            target: root
            function onFilterTextChanged() { if (searchInput.text !== root.filterText) searchInput.text = root.filterText }
          }

          Rectangle {
            id: typeButton
            anchors.right: parent.right
            anchors.rightMargin: root.pad
            anchors.verticalCenter: parent.verticalCenter
            radius: root.radius
            color: typeMouse.containsMouse ? root.selectedBackground : Util.alpha(root.foreground, 0.05)
            width: typeRow.implicitWidth + Style.space(20)
            height: typeRow.implicitHeight + Style.space(10)

            Row {
              id: typeRow
              anchors.centerIn: parent
              spacing: Style.space(6)
              Label { text: strings.t("type." + root.typeFilter); color: root.typeFilter === "all" ? root.dim : root.selectedText }
              Label { text: "\u{f0140}"; color: root.dim }   // nf-md-chevron_down
            }

            MouseArea {
              id: typeMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              onClicked: function(mouse) { root.cycleType(mouse.button === Qt.RightButton ? -1 : 1); searchInput.forceActiveFocus() }
            }
          }

          Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: Style.normalBorderWidth; color: Util.alpha(root.border, 0.22) }
        }

        // ---------------- footer ----------------
        Item {
          id: footer
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          height: Math.max(Style.space(38), Style.font.caption + Style.space(20))

          Rectangle { anchors.top: parent.top; width: parent.width; height: Style.normalBorderWidth; color: Util.alpha(root.border, 0.22) }

          Row {
            anchors.left: parent.left
            anchors.leftMargin: root.pad
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)
            Label { text: "\u{f0147}"; color: root.dim; font.pixelSize: Style.font.title }   // clipboard glyph
            Label {
              text: root.mode === "edit" ? strings.t("edit.hint")
                : root.mode === "rename" ? strings.t("rename.hint")
                : strings.tn("items", rowsModel.count).arg(Commons.I18n.formatNumber(rowsModel.count))
              color: root.dim
              font.pixelSize: Style.font.caption
            }
          }

          Row {
            anchors.right: parent.right
            anchors.rightMargin: root.pad
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(16)
            visible: root.mode === "list" || root.mode === "actions"
            KeyHint { label: strings.t("footer.filter"); keys: "Ctrl+P" }
            KeyHint { label: root.pasteIsPrimary ? strings.t("action.paste") : strings.t("action.copy"); keys: "↵" }
            KeyHint { label: strings.t("footer.actions"); keys: "Ctrl+K" }
          }
        }

        // ---------------- body ----------------
        Item {
          id: body
          anchors.top: header.bottom
          anchors.bottom: footer.top
          anchors.left: parent.left
          anchors.right: parent.right

          // list
          ListView {
            id: list
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            width: Math.round(parent.width * 0.42)
            anchors.topMargin: Style.space(6)
            anchors.bottomMargin: Style.space(6)
            leftMargin: Style.space(8)
            rightMargin: Style.space(8)
            clip: true
            model: rowsModel
            spacing: Style.space(2)
            boundsBehavior: Flickable.StopAtBounds
            currentIndex: root.selectedIndex
            highlightFollowsCurrentItem: false
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            section.property: "group"
            section.criteria: ViewSection.FullString
            section.delegate: Item {
              required property string section
              width: ListView.view.width - Style.space(16)
              height: Style.space(28)
              Label {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Style.space(4)
                text: strings.t("group." + parent.section)
                color: root.dim
                font.pixelSize: Style.font.caption
                font.weight: Font.DemiBold
              }
            }

            delegate: Rectangle {
              id: rowItem
              required property int index
              required property string kind
              required property string title
              required property string previewImage
              required property string swatch
              required property bool pinned
              required property string customName
              readonly property bool selected: index === root.selectedIndex

              width: ListView.view.width - Style.space(16)
              height: root.rowHeight
              radius: root.radius
              color: selected ? root.selectedBackground : (rowMouse.containsMouse ? Util.alpha(root.foreground, 0.04) : "transparent")

              Item {
                id: icon
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(22)
                height: Style.space(22)

                Rectangle {
                  anchors.fill: parent
                  anchors.margins: Style.space(3)
                  radius: Style.space(4)
                  visible: rowItem.swatch !== ""
                  color: rowItem.swatch || "transparent"
                  border.width: Style.normalBorderWidth
                  border.color: Util.alpha(root.foreground, 0.3)
                }
                SizedImage {
                  anchors.fill: parent
                  visible: rowItem.swatch === "" && rowItem.previewImage !== ""
                  url: rowItem.previewImage
                  crop: true
                  asynchronous: true
                }
                Label {
                  anchors.centerIn: parent
                  visible: rowItem.swatch === "" && rowItem.previewImage === ""
                  text: root.kindGlyph(rowItem.kind)
                  color: rowItem.selected ? root.selectedText : root.dim
                  font.pixelSize: Style.font.iconLarge
                }
              }

              Label {
                anchors.left: icon.right
                anchors.leftMargin: Style.space(10)
                anchors.right: badges.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                text: root.titleFor(rowsModel.get(rowItem.index)) || " "
                color: rowItem.selected ? root.selectedText : root.foreground
                font.pixelSize: Style.font.title
                font.italic: rowItem.customName !== ""
                wrapMode: Text.NoWrap
              }

              Row {
                id: badges
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)
                Label {
                  visible: rowItem.index < 9 && rowItem.selected
                  text: "Ctrl+" + (rowItem.index + 1)
                  color: root.faint
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
                Label {
                  visible: rowItem.pinned
                  text: "\u{f0403}"   // nf-md-pin
                  color: rowItem.selected ? root.selectedText : root.dim
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: function(mouse) {
                  root.selectedIndex = rowItem.index
                  if (mouse.button === Qt.RightButton) root.openActions()
                  else searchInput.forceActiveFocus()
                }
                onDoubleClicked: root.primary(rowsModel.get(rowItem.index))
              }
            }
          }

          Rectangle {
            id: divider
            anchors.left: list.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Style.normalBorderWidth
            color: Util.alpha(root.border, 0.22)
          }

          // detail pane
          Item {
            id: detail
            anchors.left: divider.right
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.margins: root.pad
            visible: root.current !== null && root.mode !== "edit"

            readonly property var row: root.current

            Item {
              id: preview
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: meta.top
              anchors.bottomMargin: Style.space(12)
              clip: true

              // colour swatch
              Rectangle {
                visible: detail.row && detail.row.swatch !== ""
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(parent.width, Style.space(220))
                height: Math.min(parent.height * 0.6, Style.space(120))
                radius: root.radius
                color: detail.row && detail.row.swatch ? detail.row.swatch : "transparent"
                border.width: Style.normalBorderWidth
                border.color: Util.alpha(root.foreground, 0.3)
              }

              // image
              Image {
                id: previewImage
                anchors.fill: parent
                visible: detail.row && detail.row.previewImage !== ""
                source: detail.row && detail.row.previewImage ? detail.row.previewImage : ""
                fillMode: Image.PreserveAspectFit
                horizontalAlignment: Image.AlignHCenter
                verticalAlignment: Image.AlignTop
                asynchronous: true
                smooth: true
                mipmap: true
              }

              // text
              Flickable {
                id: textFlick
                anchors.fill: parent
                anchors.topMargin: detail.row && detail.row.swatch !== "" ? Math.min(parent.height * 0.6, Style.space(120)) + Style.space(12) : 0
                visible: detail.row && detail.row.previewImage === ""
                contentHeight: bodyText.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                Text {
                  id: bodyText
                  width: textFlick.width
                  textFormat: Text.PlainText
                  text: detail.row ? detail.row.body : ""
                  color: root.foreground
                  font.family: detail.row && (detail.row.kind === "text") ? "monospace" : root.fontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WrapAnywhere
                }
              }
              Connections {
                target: root
                function onSelectedIndexChanged() { textFlick.contentY = 0 }
              }
            }

            Column {
              id: meta
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              spacing: 0

              Label {
                visible: detail.row && detail.row.truncated
                width: parent.width
                text: strings.t("meta.truncated")
                color: root.dim
                font.pixelSize: Style.font.caption
                bottomPadding: Style.space(6)
              }
              MetaRow { label: strings.t("meta.application"); value: detail.row ? (detail.row.app || strings.t("meta.unknown")) : "" }
              MetaRow { label: strings.t("meta.contentType"); value: detail.row ? strings.t("kind." + detail.row.kind) : "" }
              MetaRow {
                label: strings.t("meta.dimensions")
                value: previewImage.visible && previewImage.status === Image.Ready
                  ? Commons.I18n.formatNumber(previewImage.implicitWidth) + " × " + Commons.I18n.formatNumber(previewImage.implicitHeight) : ""
              }
              MetaRow { label: strings.t("meta.path"); value: detail.row && detail.row.path ? detail.row.path : "" }
              MetaRow { label: strings.t("meta.characters"); value: detail.row && detail.row.characters ? Commons.I18n.formatNumber(detail.row.characters) : "" }
              MetaRow { label: strings.t("meta.words"); value: detail.row && detail.row.words ? Commons.I18n.formatNumber(detail.row.words) : "" }
              MetaRow { label: strings.t("meta.lines"); value: detail.row && detail.row.lines > 1 ? Commons.I18n.formatNumber(detail.row.lines) : "" }
              MetaRow { label: strings.t("meta.timesCopied"); value: detail.row && !detail.row.approx ? Commons.I18n.formatNumber(detail.row.count) : "" }
              MetaRow { label: strings.t("meta.lastCopied"); value: detail.row ? (root.nowMs, root.whenText(detail.row, detail.row.last)) : "" }
              MetaRow {
                label: strings.t("meta.firstCopied")
                value: detail.row && !detail.row.approx && detail.row.count > 1 ? (root.nowMs, root.whenText(detail.row, detail.row.first)) : ""
              }
            }
          }

          // inline editor (Edit Content)
          Item {
            anchors.left: divider.right
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.margins: root.pad
            visible: root.mode === "edit"

            Rectangle {
              anchors.fill: parent
              radius: root.radius
              color: Util.alpha(root.foreground, 0.04)
              border.width: Style.normalBorderWidth
              border.color: Util.alpha(Commons.Color.accent, 0.6)
            }

            ScrollView {
              anchors.fill: parent
              anchors.margins: Style.space(8)
              TextArea {
                id: editArea
                textFormat: TextEdit.PlainText
                wrapMode: TextEdit.WrapAnywhere
                color: root.foreground
                selectionColor: Style.selectionFillFor(root.foreground, Commons.Color.accent)
                font.family: "monospace"
                font.pixelSize: Style.font.body
                background: null
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) { root.backToList(); event.accepted = true }
                  else if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_S || event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                    root.commitEdit(); event.accepted = true
                  }
                }
              }
            }
          }

          // empty state
          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: rowsModel.count === 0
            Label {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "\u{f0147}"
              color: root.selectedText
              opacity: 0.8
              font.pixelSize: Style.font.displayLarge
            }
            Label {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.history.length === 0 && root.store.pins.length === 0 ? strings.t("empty") : strings.t("noMatches").arg(root.filterText || strings.t("type." + root.typeFilter))
              color: root.foreground
              opacity: 0.7
              font.pixelSize: Style.font.title
            }
          }
        }

        // ---------------- rename bar ----------------
        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: footer.top
          height: Style.space(48)
          visible: root.mode === "rename"
          color: root.background
          Rectangle { anchors.top: parent.top; width: parent.width; height: Style.normalBorderWidth; color: Util.alpha(root.border, 0.22) }

          TextField {
            id: renameInput
            anchors.fill: parent
            anchors.margins: Style.space(8)
            anchors.leftMargin: root.pad
            anchors.rightMargin: root.pad
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            placeholderText: strings.t("renamePlaceholder")
            maximumLength: 200
            onAccepted: root.commitRename()
            Keys.onEscapePressed: root.backToList()
          }
        }

        // ---------------- action panel ----------------
        Rectangle {
          id: actionPanel
          visible: root.mode === "actions"
          anchors.right: parent.right
          anchors.bottom: footer.top
          anchors.rightMargin: Style.space(10)
          anchors.bottomMargin: Style.space(6)
          width: Math.min(Style.space(360), parent.width - Style.space(20))
          height: Math.min(body.height - Style.space(12), actionHeader.height + actionListView.contentHeight + Style.space(14))
          radius: root.radius
          color: root.background
          border.width: Math.max(1, Style.normalBorderWidth)
          border.color: Util.alpha(root.border, 0.5)
          z: 5

          MouseArea { anchors.fill: parent; onClicked: {} }

          ListView {
            id: actionListView
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: actionHeader.top
            anchors.margins: Style.space(6)
            clip: true
            model: root.actionList
            currentIndex: root.actionIndex
            boundsBehavior: Flickable.StopAtBounds
            delegate: Rectangle {
              required property int index
              required property var modelData
              readonly property bool selected: index === root.actionIndex
              width: ListView.view.width
              height: Style.space(32)
              radius: root.radius
              color: selected ? root.selectedBackground : (am.containsMouse ? Util.alpha(root.foreground, 0.04) : "transparent")
              Label {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.right: hint.left
                anchors.verticalCenter: parent.verticalCenter
                text: parent.modelData.label
                color: parent.selected ? root.selectedText : (String(parent.modelData.id).indexOf("delete") === 0 ? Commons.Color.urgent : root.foreground)
              }
              Label {
                id: hint
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: parent.modelData.keys
                color: root.faint
                font.pixelSize: Style.font.caption
              }
              MouseArea {
                id: am
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.runAction(parent.modelData.id)
              }
            }
          }

          Item {
            id: actionHeader
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Style.space(38)
            Rectangle { anchors.top: parent.top; width: parent.width; height: Style.normalBorderWidth; color: Util.alpha(root.border, 0.22) }

            TextInput {
              id: actionInput
              anchors.fill: parent
              anchors.leftMargin: Style.space(14)
              anchors.rightMargin: Style.space(14)
              verticalAlignment: TextInput.AlignVCenter
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              onTextChanged: {
                root.actionFilter = text
                root.actionIndex = 0
                root.actionList = root.filteredActions()
              }
              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                var n = root.actionList.length
                if (event.key === Qt.Key_Escape || ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_K)) {
                  text = ""
                  root.backToList()
                } else if (event.key === Qt.Key_Up) {
                  root.actionIndex = n ? (root.actionIndex - 1 + n) % n : 0
                  actionListView.positionViewAtIndex(root.actionIndex, ListView.Contain)
                } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab) {
                  root.actionIndex = n ? (root.actionIndex + 1) % n : 0
                  actionListView.positionViewAtIndex(root.actionIndex, ListView.Contain)
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  var a = root.actionList[root.actionIndex]
                  text = ""
                  if (a) root.runAction(a.id); else root.backToList()
                } else return
                event.accepted = true
              }
              Label {
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                text: strings.t("searchActions")
                opacity: 0.45
                visible: !actionInput.text
              }
            }
          }
        }
      }

      // ---------------- delete-all confirmation ----------------
      Item {
        id: keyCatcher
        anchors.fill: parent
        visible: root.mode === "confirm"
        z: 20
        focus: root.mode === "confirm"
        Keys.onPressed: function(event) { if (confirmDialog.handleKey(event)) event.accepted = true }

        ConfirmDialog {
          id: confirmDialog
          anchors.fill: parent
          opened: root.mode === "confirm"
          message: strings.t("confirm.deleteAll")
          confirmText: strings.t("confirm.delete")
          background: root.background
          foreground: root.foreground
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.radius
          onCanceled: root.backToList()
          onConfirmed: { root.deleteAll(); root.backToList() }
        }
      }
    }
  }
}
