// node --test tests/
const test = require("node:test")
const assert = require("node:assert/strict")
const M = require("../Model.js")

const T = (text) => ({ type: "text", text })
const NOW = Date.UTC(2026, 9, 28, 18, 0, 0)

test("classify recognises Raycast's content types", () => {
  assert.equal(M.classify(T("hello world")), "text")
  assert.equal(M.classify(T("https://example.com/a?b=1")), "link")
  assert.equal(M.classify(T("example.com/path")), "link")
  assert.equal(M.classify(T("me@example.com")), "email")
  assert.equal(M.classify(T("#ff8800")), "color")
  assert.equal(M.classify(T("rgb(10, 20, 30)")), "color")
  assert.equal(M.classify(T("hsl(120 50% 50%)")), "color")
  assert.equal(M.classify(T("file:///home/a/b.txt\nfile:///home/a/c.png")), "file")
  assert.equal(M.classify({ type: "image", path: "/tmp/x.png", mime: "image/png" }), "image")
  // A sentence containing a URL is text, not a link.
  assert.equal(M.classify(T("see https://example.com")), "text")
  // Mixed lines are not a file list.
  assert.equal(M.classify(T("file:///a\nnot a uri")), "text")
})

test("qmlColor converts css colours to #aarrggbb", () => {
  assert.equal(M.qmlColor("#f80"), "#ffff8800")
  assert.equal(M.qmlColor("#11223344"), "#44112233")
  assert.equal(M.qmlColor("rgb(255, 0, 0)"), "#ffff0000")
  assert.equal(M.qmlColor("hsl(120, 100%, 50%)"), "#ff00ff00")
  assert.equal(M.qmlColor("not a colour"), "")
})

test("linkUrl only produces safe schemes", () => {
  assert.equal(M.linkUrl(T("example.com")), "https://example.com")
  assert.equal(M.linkUrl(T("a@b.io")), "mailto:a@b.io")
  assert.equal(M.linkUrl(T("javascript:alert(1)")), "")
  assert.equal(M.linkUrl(T("hello")), "")
})

test("type filter cycles both ways", () => {
  assert.equal(M.nextTypeFilter("all", 1), "text")
  assert.equal(M.nextTypeFilter("all", -1), "color")
  assert.equal(M.nextTypeFilter("color", 1), "all")
})

test("entry keys differ by content and type", () => {
  assert.notEqual(M.entryKey(T("a")), M.entryKey(T("b")))
  assert.equal(M.entryKey(T("a")), M.entryKey(T("a")))
  assert.match(M.entryKey({ type: "image", path: "/x.png" }), /^i/)
  assert.match(M.entryKey(T("x")), /^t/)
})

test("reconcile stamps new copies and recopies, not the initial backlog", () => {
  let state = M.emptyState()
  const h1 = [T("b"), T("a")]
  let r = M.reconcile(state, h1, "", NOW, "firefox", true)
  assert.equal(r.newCopy, false)
  assert.equal(state.meta[M.entryKey(T("b"))].approx, true)

  const h2 = [T("c"), T("b"), T("a")]
  r = M.reconcile(state, h2, r.frontKey, NOW + 1000, "foot", false)
  assert.equal(r.newCopy, true)
  const c = state.meta[M.entryKey(T("c"))]
  assert.equal(c.app, "foot")
  assert.equal(c.count, 1)
  assert.ok(!c.approx)

  // "a" copied again moves to the front.
  const h3 = [T("a"), T("c"), T("b")]
  r = M.reconcile(state, h3, r.frontKey, NOW + 2000, "code", false)
  const a = state.meta[M.entryKey(T("a"))]
  assert.equal(a.count, 2)
  assert.equal(a.last, NOW + 2000)
  assert.equal(a.app, "code")
  assert.ok(!a.approx)

  // A reload with an unchanged front is not a copy.
  r = M.reconcile(state, h3, r.frontKey, NOW + 3000, "code", false)
  assert.equal(r.newCopy, false)
  assert.equal(a.count, 2)
})

test("metadata for entries that left history is pruned unless pinned", () => {
  let state = M.emptyState()
  M.reconcile(state, [T("a"), T("b")], "", NOW, "", true)
  M.togglePin(state, T("b"), NOW)
  M.reconcile(state, [T("c")], M.entryKey(T("a")), NOW, "", false)
  assert.equal(state.meta[M.entryKey(T("a"))], undefined)
  assert.ok(state.meta[M.entryKey(T("b"))])
})

test("pins come first, survive leaving history, and can be reordered", () => {
  let state = M.emptyState()
  const history = [T("one"), T("two"), T("three")]
  M.reconcile(state, history, "", NOW, "", true)
  M.togglePin(state, T("three"), NOW)
  M.togglePin(state, T("gone"), NOW)   // pinned but not in history
  let rows = M.displayRows(history, state, "", "all", 50, NOW)
  assert.deepEqual(rows.map(r => r.title), ["gone", "three", "one", "two"])
  assert.equal(rows[0].historyIndex, -1)
  assert.equal(rows[0].group, "pinned")

  M.movePin(state, M.entryKey(T("three")), -1)
  rows = M.displayRows(history, state, "", "all", 50, NOW)
  assert.deepEqual(rows.map(r => r.title).slice(0, 2), ["three", "gone"])

  M.togglePin(state, T("three"), NOW)
  assert.equal(M.isPinned(state, M.entryKey(T("three"))), false)
})

test("search matches content and custom names; type filter narrows", () => {
  let state = M.emptyState()
  const history = [T("https://x.io"), T("alpha beta"), T("#fff")]
  M.reconcile(state, history, "", NOW, "", true)
  M.setName(state, M.entryKey(T("alpha beta")), "Greek letters", NOW)
  assert.deepEqual(M.displayRows(history, state, "greek", "all", 50, NOW).map(r => r.title), ["Greek letters"])
  assert.deepEqual(M.displayRows(history, state, "", "link", 50, NOW).map(r => r.kind), ["link"])
  assert.deepEqual(M.displayRows(history, state, "", "color", 50, NOW).map(r => r.kind), ["color"])
  M.setName(state, M.entryKey(T("alpha beta")), "  ", NOW)
  assert.equal(state.meta[M.entryKey(T("alpha beta"))].name, undefined)
})

test("replaceText edits in place and carries metadata and pins", () => {
  let state = M.emptyState()
  const history = [T("old"), T("other")]
  M.reconcile(state, history, "", NOW, "", true)
  const oldKey = M.entryKey(T("old"))
  M.setName(state, oldKey, "Mine", NOW)
  M.togglePin(state, T("old"), NOW)
  const r = M.replaceText(history, state, oldKey, "new", NOW)
  assert.equal(r.history[0].text, "new")
  assert.equal(state.meta[r.key].name, "Mine")
  assert.equal(state.pins[0].entry.text, "new")
  assert.equal(state.meta[oldKey], undefined)
})

test("time-window and retention deletion skip pins and backlog", () => {
  let state = M.emptyState()
  const h = [T("new"), T("old"), T("pinned")]
  M.reconcile(state, h, "", NOW - 10 * 86400000, "", true)    // backlog
  M.reconcile(state, [T("new"), ...h.slice(1)], "", NOW, "", false)
  state.meta[M.entryKey(T("new"))] = { first: NOW - 60000, last: NOW - 60000, count: 1 }
  M.togglePin(state, T("pinned"), NOW)
  assert.deepEqual(M.keysCopiedSince(h, state, 5 * 60000, NOW), [M.entryKey(T("new"))])
  const expired = M.expiredKeys(h, state, "1 Week", NOW)
  assert.deepEqual(expired, [M.entryKey(T("old"))])
  assert.deepEqual(M.expiredKeys(h, state, "Unlimited", NOW), [])
  assert.deepEqual(M.removeKeys(h, expired).map(e => e.text), ["new", "pinned"])
})

test("ignored apps match by id substring", () => {
  assert.equal(M.appIgnored("org.keepassxc.KeePassXC", "1password, keepassxc"), true)
  assert.equal(M.appIgnored("firefox", "1password, keepassxc"), false)
  assert.equal(M.appIgnored("", "x"), false)
})

test("parseState rejects junk and bounds sizes", () => {
  const s = M.parseState(JSON.stringify({
    meta: { "../evil": { count: 3 }, t1: { count: "9e99", name: "x".repeat(500), first: -1 } },
    pins: [{ entry: { type: "image", path: "relative.png" } }, { entry: { type: "text", text: "ok" } }]
  }))
  assert.equal(s.meta["../evil"], undefined)
  assert.equal(s.meta.t1.count, 1e6)
  assert.equal(s.meta.t1.name.length, 200)
  assert.equal(s.meta.t1.first, 0)
  assert.equal(s.pins.length, 1)
  assert.deepEqual(M.parseState("not json"), M.emptyState())
})

test("markup-shaped clipboard text stays verbatim in rows", () => {
  const evil = '<img src="https://example.invalid/tracker">'
  let state = M.emptyState()
  M.reconcile(state, [T(evil)], "", NOW, "", true)
  const row = M.displayRows([T(evil)], state, "", "all", 5, NOW)[0]
  assert.equal(row.title, evil)
  assert.equal(row.body, evil)
})

test("huge entries are capped for display but stats use the full text", () => {
  const big = ("line\n").repeat(5000)
  let state = M.emptyState()
  M.reconcile(state, [T(big)], "", NOW, "", true)
  const row = M.displayRows([T(big)], state, "", "all", 5, NOW)[0]
  assert.ok(row.body.length <= M.displayTextLimit)
  assert.equal(row.truncated, true)
  assert.equal(row.stats.characters, big.length)
  assert.equal(row.stats.lines, 5001)
})

test("day groups", () => {
  const now = new Date(2026, 9, 28, 12).getTime()
  assert.equal(M.dayGroup(now - 3600000, now), "today")
  assert.equal(M.dayGroup(now - 86400000, now), "yesterday")
  assert.equal(M.dayGroup(now - 3 * 86400000, now), "week")
  assert.equal(M.dayGroup(now - 30 * 86400000, now), "earlier")
  assert.equal(M.dayGroup(0, now), "earlier")
})
