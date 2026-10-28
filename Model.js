// Pure helpers for the Raycast-style clipboard history. No QML, no I/O, so
// the Node tests in tests/ can exercise every rule here directly.
//
// The history itself is Omarchy's (~/.local/state/omarchy/clipboard-history.json,
// written by the stock omarchy.clipboard capture watchers). This plugin keeps a
// sidecar of per-entry metadata keyed by a short content hash: when it was
// copied, from which app, how often, a custom name, and pins.

var maxTextLength = 200000       // longest text kept in a pin or edit
var displayTextLimit = 8192      // longest text searched/rendered per row
var maxNameLength = 200
var maxMetaEntries = 2000
var maxPins = 200

// ---- hashing --------------------------------------------------------------

// cyrb53: small, fast, well-distributed 53-bit string hash.
function hash53(str) {
  var h1 = 0xdeadbeef, h2 = 0x41c6ce57
  for (var i = 0; i < str.length; i++) {
    var ch = str.charCodeAt(i)
    h1 = Math.imul(h1 ^ ch, 2654435761)
    h2 = Math.imul(h2 ^ ch, 1597334677)
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909)
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909)
  return (4294967296 * (2097151 & h2) + (h1 >>> 0)).toString(36)
}

// ---- entries --------------------------------------------------------------

function normalizeEntry(value) {
  if (typeof value === "string")
    return value.trim().length > 0 ? { type: "text", text: value } : null
  if (!value || typeof value !== "object") return null

  var type = String(value.type || "")
  if (type === "text") {
    var text = String(value.text || "")
    return text.trim().length > 0 ? { type: "text", text: text } : null
  }
  if (type === "image") {
    var path = String(value.path || "")
    if (!path || path.charAt(0) !== "/") return null
    var entry = { type: "image", path: path, mime: String(value.mime || "image/png") }
    if (!/^image\/[a-z0-9.+-]+$/i.test(entry.mime)) entry.mime = "image/png"
    if (value.capturedAt !== undefined && value.capturedAt !== null) entry.capturedAt = String(value.capturedAt).slice(0, 80)
    return entry
  }
  return null
}

function entryKey(entry) {
  if (!entry) return ""
  if (entry.type === "image") return "i" + hash53(String(entry.path || ""))
  var text = String(entry.text || "")
  return "t" + hash53(text) + text.length.toString(36)
}

function parseHistory(raw) {
  try {
    var parsed = JSON.parse(String(raw || "[]"))
    if (!Array.isArray(parsed)) return []
    var out = []
    for (var i = 0; i < parsed.length; i++) {
      var entry = normalizeEntry(parsed[i])
      if (entry) out.push(entry)
    }
    return out
  } catch (e) {
    return []
  }
}

// ---- classification -------------------------------------------------------

var colorPattern = /^(#(?:[0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})|(?:rgb|rgba|hsl|hsla)\(\s*[-0-9.%]+\s*(?:,|\s)\s*[-0-9.%]+\s*(?:,|\s)\s*[-0-9.%]+\s*(?:(?:,|\/)\s*[-0-9.%]+\s*)?\))$/i
var emailPattern = /^[^\s@<>()",;:]+@[^\s@<>()",;:]+\.[a-z]{2,}$/i
var urlPattern = /^(?:https?|ftp):\/\/[^\s<>"']+$/i
var bareDomainPattern = /^(?:www\.)?[a-z0-9][a-z0-9-]*(?:\.[a-z0-9-]+)*\.[a-z]{2,}(?:\/[^\s]*)?$/i

function decodeFileUri(uri) {
  var value = String(uri || "").trim()
  if (value.indexOf("file://") !== 0) return ""
  var path = value.substring(7)
  if (path.indexOf("localhost/") === 0) path = path.substring(9)
  if (path.charAt(0) !== "/") return ""
  try { return decodeURIComponent(path) } catch (e) { return path }
}

function filePaths(entry) {
  if (!entry || entry.type !== "text") return []
  var lines = String(entry.text || "").slice(0, displayTextLimit).split(/\r?\n/)
  var paths = []
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].trim()) continue
    var path = decodeFileUri(lines[i])
    if (!path) return []           // a file list is file URIs only
    paths.push(path)
  }
  return paths
}

// One of: image, file, link, email, color, text.
function classify(entry) {
  if (!entry) return "text"
  if (entry.type === "image") return "image"
  if (filePaths(entry).length > 0) return "file"
  var t = String(entry.text || "").trim()
  if (t.length > 2048) return "text"
  if (colorPattern.test(t)) return "color"
  if (/\s/.test(t)) return "text"
  if (emailPattern.test(t) || /^mailto:/i.test(t)) return "email"
  if (urlPattern.test(t) || bareDomainPattern.test(t)) return "link"
  return "text"
}

var typeFilters = ["all", "text", "image", "file", "link", "email", "color"]

function nextTypeFilter(current, delta) {
  var i = typeFilters.indexOf(String(current || "all"))
  if (i < 0) i = 0
  var n = typeFilters.length
  return typeFilters[((i + (delta || 1)) % n + n) % n]
}

// A CSS colour as a QML "#aarrggbb" string, or "" if it can't be shown.
function qmlColor(text) {
  var t = String(text || "").trim().toLowerCase()
  if (!colorPattern.test(t)) return ""
  function hex2(n) { var s = Math.max(0, Math.min(255, Math.round(n))).toString(16); return s.length < 2 ? "0" + s : s }
  var r, g, b, a = 1
  var m = /^#([0-9a-f]+)$/.exec(t)
  if (m) {
    var h = m[1]
    if (h.length === 3 || h.length === 4) h = h.split("").map(function(c) { return c + c }).join("")
    r = parseInt(h.slice(0, 2), 16); g = parseInt(h.slice(2, 4), 16); b = parseInt(h.slice(4, 6), 16)
    if (h.length === 8) a = parseInt(h.slice(6, 8), 16) / 255
    return "#" + hex2(a * 255) + hex2(r) + hex2(g) + hex2(b)
  }
  var parts = t.replace(/^[a-z]+\(|\)$/g, "").split(/[\s,\/]+/).filter(function(s) { return s.length })
  if (parts.length < 3) return ""
  function num(s, scale) { return s.indexOf("%") >= 0 ? parseFloat(s) / 100 * scale : parseFloat(s) }
  if (parts.length > 3) a = Math.max(0, Math.min(1, num(parts[3], 1)))
  if (t.indexOf("rgb") === 0) {
    r = num(parts[0], 255); g = num(parts[1], 255); b = num(parts[2], 255)
  } else {
    var hue = ((parseFloat(parts[0]) % 360) + 360) % 360 / 360
    var sat = Math.max(0, Math.min(1, num(parts[1], 1)))
    var lig = Math.max(0, Math.min(1, num(parts[2], 1)))
    function hue2rgb(p, q, x) {
      if (x < 0) x += 1
      if (x > 1) x -= 1
      if (x < 1 / 6) return p + (q - p) * 6 * x
      if (x < 1 / 2) return q
      if (x < 2 / 3) return p + (q - p) * (2 / 3 - x) * 6
      return p
    }
    if (sat === 0) { r = g = b = lig * 255 }
    else {
      var q = lig < 0.5 ? lig * (1 + sat) : lig + sat - lig * sat
      var p = 2 * lig - q
      r = hue2rgb(p, q, hue + 1 / 3) * 255; g = hue2rgb(p, q, hue) * 255; b = hue2rgb(p, q, hue - 1 / 3) * 255
    }
  }
  if ([r, g, b, a].some(function(v) { return isNaN(v) })) return ""
  return "#" + hex2(a * 255) + hex2(r) + hex2(g) + hex2(b)
}

function linkUrl(entry) {
  var t = String(entry && entry.text || "").trim()
  if (/^(?:https?|ftp):\/\//i.test(t)) return t
  if (/^mailto:/i.test(t)) return t
  if (emailPattern.test(t)) return "mailto:" + t
  if (bareDomainPattern.test(t)) return "https://" + t
  return ""
}

// ---- text stats -------------------------------------------------------------

function fileName(path) {
  var parts = String(path || "").split("/")
  return parts[parts.length - 1] || String(path || "")
}

function isImagePath(path) {
  return /\.(png|jpe?g|webp|gif|bmp|tiff?)$/i.test(String(path || ""))
}

function textStats(text) {
  var s = String(text || "")
  var trimmed = s.trim()
  return {
    characters: s.length,
    words: trimmed ? trimmed.split(/\s+/).length : 0,
    lines: s.length ? s.split(/\r\n|\r|\n/).length : 0
  }
}

function capText(text, limit) {
  var s = String(text || "")
  var max = limit || displayTextLimit
  if (s.length <= max) return s
  var cut = s.lastIndexOf("\n", max)
  return s.slice(0, cut > max / 2 ? cut : max)
}

function oneLine(text) {
  return String(text || "").slice(0, 600).replace(/\s+/g, " ").trim()
}

// ---- metadata ---------------------------------------------------------------

function emptyState() {
  return { version: 1, meta: {}, pins: [] }
}

function parseState(raw) {
  var state = emptyState()
  try {
    var parsed = JSON.parse(String(raw || "{}"))
    if (!parsed || typeof parsed !== "object") return state
    var meta = parsed.meta && typeof parsed.meta === "object" ? parsed.meta : {}
    var keys = Object.keys(meta).slice(0, maxMetaEntries)
    for (var i = 0; i < keys.length; i++) {
      var k = keys[i]
      if (!/^[ti][0-9a-z]{1,24}$/.test(k)) continue
      var m = meta[k] || {}
      var clean = {
        first: finiteTime(m.first),
        last: finiteTime(m.last),
        count: Math.max(1, Math.min(1e6, Math.floor(Number(m.count) || 1)))
      }
      if (m.app) clean.app = String(m.app).slice(0, 120)
      if (m.name) clean.name = String(m.name).slice(0, maxNameLength)
      if (m.approx) clean.approx = true
      state.meta[k] = clean
    }
    var pins = Array.isArray(parsed.pins) ? parsed.pins.slice(0, maxPins) : []
    for (var j = 0; j < pins.length; j++) {
      var entry = normalizeEntry(pins[j] && pins[j].entry)
      if (!entry) continue
      if (entry.type === "text" && entry.text.length > maxTextLength) entry.text = entry.text.slice(0, maxTextLength)
      state.pins.push({ key: entryKey(entry), entry: entry, pinnedAt: finiteTime(pins[j].pinnedAt) })
    }
  } catch (e) {}
  return state
}

function finiteTime(value) {
  var n = Number(value)
  return isFinite(n) && n > 0 && n < 1e14 ? Math.floor(n) : 0
}

function pruneMeta(state, liveKeys) {
  var keep = {}
  for (var i = 0; i < state.pins.length; i++) keep[state.pins[i].key] = true
  for (var k in liveKeys) keep[k] = true
  var meta = {}
  for (var key in state.meta) if (keep[key]) meta[key] = state.meta[key]
  state.meta = meta
  return state
}

// Reconcile a freshly loaded history with the metadata store.
//   prevFront: key that was at index 0 on the previous load ("" on first load)
//   now: ms timestamp; app: active window app id at the time of the change
// Returns { state, newCopy: bool, frontKey }.
function reconcile(state, history, prevFront, now, app, firstLoad) {
  var frontKey = history.length ? entryKey(history[0]) : ""
  var live = {}
  var newCopy = false

  for (var i = 0; i < history.length; i++) {
    var key = entryKey(history[i])
    live[key] = true
    if (!state.meta[key]) {
      // Seen for the first time. Only the front entry of a live change is a
      // real copy we can stamp precisely; anything else predates the plugin.
      var fresh = !firstLoad && i === 0 && key !== prevFront
      state.meta[key] = { first: now, last: now, count: 1 }
      if (fresh && app) state.meta[key].app = String(app).slice(0, 120)
      if (!fresh) state.meta[key].approx = true
      if (fresh) newCopy = true
    } else if (!firstLoad && i === 0 && key !== prevFront && prevFront !== "") {
      // An older entry came back to the top: copied again.
      var m = state.meta[key]
      m.last = now
      m.count = (m.count || 1) + 1
      if (app) m.app = String(app).slice(0, 120)
      delete m.approx
      newCopy = true
    }
  }

  pruneMeta(state, live)
  return { state: state, newCopy: newCopy, frontKey: frontKey }
}

function isPinned(state, key) {
  for (var i = 0; i < state.pins.length; i++) if (state.pins[i].key === key) return true
  return false
}

function togglePin(state, entry, now) {
  var normalized = normalizeEntry(entry)
  if (!normalized) return state
  var key = entryKey(normalized)
  for (var i = 0; i < state.pins.length; i++) {
    if (state.pins[i].key === key) {
      state.pins.splice(i, 1)
      return state
    }
  }
  if (normalized.type === "text" && normalized.text.length > maxTextLength)
    normalized.text = normalized.text.slice(0, maxTextLength)
  state.pins.unshift({ key: key, entry: normalized, pinnedAt: now })
  state.pins = state.pins.slice(0, maxPins)
  return state
}

function movePin(state, key, delta) {
  for (var i = 0; i < state.pins.length; i++) {
    if (state.pins[i].key !== key) continue
    var j = i + delta
    if (j < 0 || j >= state.pins.length) return state
    var tmp = state.pins[i]
    state.pins[i] = state.pins[j]
    state.pins[j] = tmp
    return state
  }
  return state
}

function setName(state, key, name, now) {
  var clean = String(name || "").replace(/[\r\n\t]+/g, " ").trim().slice(0, maxNameLength)
  if (!state.meta[key]) state.meta[key] = { first: now, last: now, count: 1, approx: true }
  if (clean) state.meta[key].name = clean
  else delete state.meta[key].name
  return state
}

// Replace an entry's text everywhere (history + pins), keeping its metadata.
function replaceText(history, state, oldKey, newText, now) {
  var text = String(newText || "").slice(0, maxTextLength)
  if (!text.trim()) return { history: history, state: state, key: oldKey }
  var newEntry = { type: "text", text: text }
  var newKey = entryKey(newEntry)
  var next = []
  for (var i = 0; i < history.length; i++) {
    var k = entryKey(history[i])
    if (k === newKey && k !== oldKey) continue
    next.push(k === oldKey ? newEntry : history[i])
  }
  for (var j = 0; j < state.pins.length; j++)
    if (state.pins[j].key === oldKey) state.pins[j] = { key: newKey, entry: newEntry, pinnedAt: state.pins[j].pinnedAt }
  if (state.meta[oldKey] && newKey !== oldKey) {
    state.meta[newKey] = state.meta[oldKey]
    delete state.meta[oldKey]
  }
  if (state.meta[newKey]) state.meta[newKey].last = now
  return { history: next, state: state, key: newKey }
}

// ---- deletion & retention ---------------------------------------------------

function removeKeys(history, keys) {
  var drop = {}
  for (var i = 0; i < keys.length; i++) drop[keys[i]] = true
  return history.filter(function(entry) { return !drop[entryKey(entry)] })
}

// Unpinned keys whose last copy is within the last `windowMs`.
function keysCopiedSince(history, state, windowMs, now) {
  var out = []
  for (var i = 0; i < history.length; i++) {
    var key = entryKey(history[i])
    if (isPinned(state, key)) continue
    var m = state.meta[key]
    if (m && !m.approx && now - (m.last || 0) <= windowMs) out.push(key)
  }
  return out
}

var retentionDays = { "1 Day": 1, "1 Week": 7, "1 Month": 30, "3 Months": 90, "6 Months": 182, "1 Year": 365, "Unlimited": 0 }

function retentionMs(label) {
  var days = retentionDays[String(label || "")]
  return days === undefined ? 90 * 86400000 : days * 86400000
}

// Unpinned keys older than the retention window.
function expiredKeys(history, state, retentionLabel, now) {
  var window = retentionMs(retentionLabel)
  if (!window) return []
  var out = []
  for (var i = 0; i < history.length; i++) {
    var key = entryKey(history[i])
    if (isPinned(state, key)) continue
    var m = state.meta[key]
    if (m && now - (m.last || m.first || now) > window) out.push(key)
  }
  return out
}

function parseList(value) {
  return String(value || "").split(/[,\n]/).map(function(s) { return s.trim().toLowerCase() }).filter(function(s) { return s.length > 0 })
}

function appIgnored(app, ignoredList) {
  var id = String(app || "").toLowerCase()
  if (!id) return false
  var list = Array.isArray(ignoredList) ? ignoredList : parseList(ignoredList)
  for (var i = 0; i < list.length; i++) if (id === list[i] || id.indexOf(list[i]) >= 0) return true
  return false
}

// ---- grouping & rows --------------------------------------------------------

function dayGroup(ms, now) {
  if (!ms) return "earlier"
  var d = new Date(ms), n = new Date(now)
  var startToday = new Date(n.getFullYear(), n.getMonth(), n.getDate()).getTime()
  if (ms >= startToday) return "today"
  if (ms >= startToday - 86400000) return "yesterday"
  if (ms >= startToday - 6 * 86400000) return "week"
  return "earlier"
}

function searchable(entry, kind, name) {
  var base = name ? name + " " : ""
  if (entry.type === "image") return base + "image screenshot " + (entry.mime || "") + " " + (entry.capturedAt || "")
  if (kind === "file") return base + filePaths(entry).join(" ")
  return base + String(entry.text || "").slice(0, displayTextLimit)
}

function buildRow(entry, key, historyIndex, pinned, state, now) {
  var kind = classify(entry)
  var m = state.meta[key] || {}
  var paths = kind === "file" ? filePaths(entry) : []
  var previewImage = kind === "image" ? entry.path : (paths.length === 1 && isImagePath(paths[0]) ? paths[0] : "")
  var title
  if (m.name) title = m.name
  else if (kind === "image") title = ""      // QML fills in a translated label
  else if (kind === "file") title = paths.length === 1 ? fileName(paths[0]) : ""
  else title = oneLine(entry.text)
  return {
    key: key,
    kind: kind,
    title: title,
    customName: m.name || "",
    fileCount: paths.length,
    body: entry.type === "text" ? capText(kind === "file" ? paths.join("\n") : entry.text) : "",
    truncated: entry.type === "text" && String(entry.text).length > displayTextLimit,
    path: entry.type === "image" ? entry.path : (paths.length === 1 ? paths[0] : ""),
    mime: entry.type === "image" ? entry.mime : "text/plain",
    previewImage: previewImage,
    historyIndex: historyIndex,
    pinned: pinned,
    group: pinned ? "pinned" : dayGroup(m.approx ? 0 : (m.last || 0), now),
    app: m.app || "",
    first: m.first || 0,
    last: m.last || 0,
    count: m.count || 1,
    approx: !!m.approx,
    stats: entry.type === "text" ? textStats(entry.text) : { characters: 0, words: 0, lines: 0 }
  }
}

// Rows for the list: pins first (in pin order), then history newest-first.
// keys (optional) are the precomputed entryKey()s of history, same order.
function displayRows(history, state, query, typeFilter, limit, now, keys) {
  var needle = String(query || "").trim().toLowerCase()
  var filter = String(typeFilter || "all")
  var max = limit || 300
  var rows = []
  var historyKeys = Array.isArray(keys) && keys.length === history.length ? keys : history.map(entryKey)
  var historyIndexByKey = {}
  for (var h = 0; h < history.length; h++) {
    var hk = historyKeys[h]
    if (historyIndexByKey[hk] === undefined) historyIndexByKey[hk] = h
  }

  function consider(entry, key, index, pinned) {
    var kind = classify(entry)
    if (filter !== "all" && kind !== filter) return
    var m = state.meta[key] || {}
    if (needle && searchable(entry, kind, m.name).toLowerCase().indexOf(needle) < 0) return
    rows.push(buildRow(entry, key, index, pinned, state, now))
  }

  var pinnedKeys = {}
  var groupRanks = { today: 0, yesterday: 1, week: 2, earlier: 3 }
  var groupNames = ["today", "yesterday", "week", "earlier"]
  var lastRank = 0
  for (var p = 0; p < state.pins.length && rows.length < max; p++) {
    var pin = state.pins[p]
    pinnedKeys[pin.key] = true
    var idx = historyIndexByKey[pin.key]
    consider(idx !== undefined ? history[idx] : pin.entry, pin.key, idx !== undefined ? idx : -1, true)
  }
  for (var i = 0; i < history.length && rows.length < max; i++) {
    var key = historyKeys[i]
    if (pinnedKeys[key]) continue
    var before = rows.length
    consider(history[i], key, i, false)
    // History is newest-first, but an edited entry keeps its place with a
    // fresh time. Keep groups monotonic so each heading appears once.
    if (rows.length > before) {
      var row = rows[rows.length - 1]
      lastRank = Math.max(lastRank, groupRanks[row.group] || 0)
      row.group = groupNames[lastRank]
    }
  }
  return rows
}

if (typeof module !== "undefined") {
  module.exports = {
    hash53: hash53, normalizeEntry: normalizeEntry, entryKey: entryKey, parseHistory: parseHistory,
    classify: classify, qmlColor: qmlColor, typeFilters: typeFilters, nextTypeFilter: nextTypeFilter, linkUrl: linkUrl,
    filePaths: filePaths, fileName: fileName, textStats: textStats, capText: capText, oneLine: oneLine,
    emptyState: emptyState, parseState: parseState, reconcile: reconcile, isPinned: isPinned,
    togglePin: togglePin, movePin: movePin, setName: setName, replaceText: replaceText,
    removeKeys: removeKeys, keysCopiedSince: keysCopiedSince, retentionMs: retentionMs,
    expiredKeys: expiredKeys, parseList: parseList, appIgnored: appIgnored, dayGroup: dayGroup,
    displayRows: displayRows, displayTextLimit: displayTextLimit, maxTextLength: maxTextLength
  }
}
