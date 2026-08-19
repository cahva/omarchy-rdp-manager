// Validates manifest.json against the rules omarchy-shell actually enforces, so
// a typo is caught here rather than by the plugin silently failing to load.
//
// Sources: shell/services/PluginRegistry.qml validateManifest(), and
// /usr/bin/omarchy-plugin-validate. Run with: node tests/manifest.test.js

var assert = require("assert")
var fs = require("fs")
var path = require("path")

var root = path.join(__dirname, "..")
var manifest = JSON.parse(fs.readFileSync(path.join(root, "manifest.json"), "utf8"))

var passed = 0
function test(name, fn) {
  try { fn(); passed++ } catch (e) {
    console.error("FAIL: " + name + "\n  " + (e && e.message ? e.message : e))
    process.exitCode = 1
  }
}

test("schemaVersion is the number 1, not a string", function () {
  // PluginRegistry compares with !==, so "1" is rejected outright.
  assert.strictEqual(manifest.schemaVersion, 1)
})

test("every required field is present", function () {
  ;["id", "name", "version", "kinds", "entryPoints"].forEach(function (key) {
    assert.notStrictEqual(manifest[key], undefined, "missing " + key)
  })
})

test("the id is well formed and not in the reserved namespace", function () {
  assert.ok(/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(manifest.id), "bad id: " + manifest.id)
  assert.ok(manifest.id.indexOf("/") === -1)
  assert.ok(manifest.id.indexOf("..") === -1)
  // Ids beginning omarchy. are rejected as first-party at merge time.
  assert.ok(manifest.id.indexOf("omarchy.") !== 0, "omarchy.* is reserved")
})

test("kinds is a non-empty array of known kinds", function () {
  var known = ["bar-widget", "panel", "overlay", "menu", "service", "bar"]
  assert.ok(Array.isArray(manifest.kinds) && manifest.kinds.length > 0)
  manifest.kinds.forEach(function (k) {
    assert.ok(known.indexOf(k) !== -1, "unknown kind: " + k)
  })
})

test("every declared kind has an entry point, and it exists on disk", function () {
  var keyFor = { "bar": "bar", "bar-widget": "barWidget", "menu": "menu",
                 "overlay": "overlay", "panel": "panel", "service": "service" }
  manifest.kinds.forEach(function (kind) {
    var key = keyFor[kind]
    var target = manifest.entryPoints[key]
    assert.ok(target, "no entryPoints." + key + " for kind " + kind)
    assert.ok(fs.existsSync(path.join(root, target)), "missing file: " + target)
  })
})

test("entry-point paths are relative and cannot escape the plugin directory", function () {
  Object.keys(manifest.entryPoints).forEach(function (key) {
    var target = String(manifest.entryPoints[key])
    assert.ok(target.charAt(0) !== "/", "absolute entry point: " + target)
    assert.ok(target.indexOf("..") === -1, "traversal in entry point: " + target)
  })
})

test("defaultSection is one of left, center, right", function () {
  if (!manifest.barWidget || manifest.barWidget.defaultSection === undefined) return
  assert.ok(["left", "center", "right"].indexOf(manifest.barWidget.defaultSection) !== -1)
})

test("every schema key has a matching default", function () {
  var defaults = manifest.barWidget.defaults || {}
  ;(manifest.barWidget.schema || []).forEach(function (entry) {
    assert.notStrictEqual(defaults[entry.key], undefined,
      "schema key '" + entry.key + "' has no entry in barWidget.defaults")
    assert.strictEqual(defaults[entry.key], entry.defaultValue,
      "defaults and schema disagree on '" + entry.key + "'")
  })
})

test("every settings key the panel reads is declared", function () {
  // Keeps the manifest honest about what the widget actually consumes.
  var panel = fs.readFileSync(path.join(root, "Panel.qml"), "utf8")
  var declared = Object.keys(manifest.barWidget.defaults || {})
  var re = /setting\("([A-Za-z0-9_]+)"/g
  var match
  while ((match = re.exec(panel)) !== null) {
    assert.ok(declared.indexOf(match[1]) !== -1,
      "Panel.qml reads setting('" + match[1] + "') but the manifest does not declare it")
  }
})

test("the plugin directory contains no symlinks", function () {
  // omarchy-plugin-validate rejects the whole plugin if it finds one.
  function walk(dir) {
    fs.readdirSync(dir, { withFileTypes: true }).forEach(function (entry) {
      if (entry.name === ".git" || entry.name === "node_modules") return
      var full = path.join(dir, entry.name)
      assert.ok(!entry.isSymbolicLink(), "symlink found: " + full)
      if (entry.isDirectory()) walk(full)
    })
  }
  walk(root)
})

test("every bin/ command is executable and has a shebang", function () {
  fs.readdirSync(path.join(root, "bin")).forEach(function (name) {
    var full = path.join(root, "bin", name)
    // lib-*.sh files are sourced, never executed.
    if (/^lib-/.test(name)) {
      assert.ok((fs.statSync(full).mode & 0o111) === 0,
        name + " is sourced, so it should not be executable")
      assert.notStrictEqual(fs.readFileSync(full, "utf8").slice(0, 2), "#!",
        name + " is sourced, so it should not carry a shebang")
      return
    }
    // Commands are spawned directly by Quickshell, not through a shell, so a
    // missing +x bit means the process never starts and never reports an exit code.
    assert.ok((fs.statSync(full).mode & 0o111) !== 0, name + " is not executable")
    assert.strictEqual(fs.readFileSync(full, "utf8").slice(0, 2), "#!", name + " has no shebang")
  })
})

test("every hardcoded plugin id matches manifest.json", function () {
  // The id appears in the QML, the dev installer and the docs, and renaming it
  // means editing all of them together. A missed one is silent: the widget loads
  // but the panel cannot find its service, or the installer writes to the wrong
  // directory.
  var id = manifest.id
  var sites = [
    ["Service.qml", /readonly property string pluginId: "([^"]+)"/],
    ["Service.qml", /IpcHandler\s*\{[\s\S]*?target: "([^"]+)"/],
    ["Panel.qml", /moduleName: "([^"]+)"/],
    ["Panel.qml", /readonly property string manifestPluginId: "([^"]+)"/],
    ["dev-install.sh", /PLUGIN_ID=(\S+)/]
  ]
  sites.forEach(function (site) {
    var text = fs.readFileSync(path.join(root, site[0]), "utf8")
    var match = text.match(site[1])
    assert.ok(match, "could not find the plugin id in " + site[0] + " via " + site[1])
    assert.strictEqual(match[1], id,
      site[0] + " declares plugin id '" + match[1] + "' but manifest.json says '" + id + "'")
  })
})

test("the plugin id is namespaced and lowercase", function () {
  // Marketplace ids are permanent and unique across every repository, so a
  // reverse-DNS namespace is what keeps this one from colliding.
  assert.strictEqual(manifest.id, manifest.id.toLowerCase())
  assert.ok(manifest.id.indexOf(".") !== -1, "expected a namespaced id")
})

test("no helper uses the pre-0.56 hyprctl dispatch form", function () {
  // Hyprland 0.56 moved `hyprctl dispatch` to a Lua interface, so
  // `dispatch focuswindow class:foo` became a Lua syntax error that fails
  // silently — the Focus button did nothing at all. The Lua form must come first
  // and any legacy call must only ever be a fallback behind it.
  fs.readdirSync(path.join(root, "bin")).forEach(function (name) {
    var text = fs.readFileSync(path.join(root, "bin", name), "utf8")
    if (text.indexOf("focuswindow") === -1) return
    assert.ok(text.indexOf("hl.dsp.focus") !== -1,
      name + " calls focuswindow without trying the Lua hl.dsp.focus form first")
  })
  // The QML must not dispatch directly; it goes through the helper.
  ;["Service.qml", "Panel.qml"].forEach(function (file) {
    var text = fs.readFileSync(path.join(root, file), "utf8")
    var line = text.split("\n").find(function (l) {
      return l.indexOf("\"focuswindow\"") !== -1
    })
    assert.strictEqual(line, undefined,
      file + " dispatches focuswindow directly instead of using bin/omarchy-rdp-focus")
  })
})

test("no helper falls back to a world-writable state directory", function () {
  // omarchy-rdp-disconnect turns a file's contents into a SIGTERM, so a state
  // directory another local user can write to would let them pick the target.
  // /tmp was the original fallback; it must not come back.
  fs.readdirSync(path.join(root, "bin")).forEach(function (name) {
    var text = fs.readFileSync(path.join(root, "bin", name), "utf8")
    assert.ok(text.indexOf("XDG_RUNTIME_DIR:-/tmp") === -1,
      name + " falls back to /tmp for state")
  })
})

test("the version in manifest.json matches the CHANGELOG heading", function () {
  var changelog = fs.readFileSync(path.join(root, "CHANGELOG.md"), "utf8")
  assert.ok(changelog.indexOf("## " + manifest.version) !== -1,
    "CHANGELOG.md has no '## " + manifest.version + "' heading")
})

test("no real hostname or IP has leaked into the repo", function () {
  // This repo is public. Documentation and tests must use example.com or
  // RFC1918/documentation ranges only.
  var allowedPrefixes = ["10.", "127.", "192.168.", "172.16.", "0.0.0.0", "255.255"]
  var files = []
  function walk(dir) {
    fs.readdirSync(dir, { withFileTypes: true }).forEach(function (entry) {
      if (entry.name === ".git" || entry.name === "node_modules") return
      // Untracked and gitignored: it exists precisely to hold strings that must
      // not be committed, so scanning it would fail on its own contents.
      if (entry.name === ".private-denylist") return
      var full = path.join(dir, entry.name)
      if (entry.isDirectory()) walk(full)
      else files.push(full)
    })
  }
  walk(root)
  var re = /\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b/g
  files.forEach(function (file) {
    var text
    try { text = fs.readFileSync(file, "utf8") } catch (e) { return }
    var match
    while ((match = re.exec(text)) !== null) {
      var ip = match[0]
      var octets = ip.split(".").map(Number)
      if (octets.some(function (o) { return o > 255 })) continue  // a version string
      var allowed = allowedPrefixes.some(function (p) { return ip.indexOf(p) === 0 })
      assert.ok(allowed, "public IP address '" + ip + "' in " + path.relative(root, file))
    }
  })
})

test("no term from the local private denylist appears in the repo", function () {
  // This repo is public, but the machine it was written on is not. Personal or
  // client-specific words (project names, internal hostnames) are easy to leave
  // behind in a placeholder or a usage example.
  //
  // The denylist deliberately lives in an untracked file — putting the words in a
  // committed test would publish exactly what it is meant to keep private. Create
  // `.private-denylist` with one case-insensitive term per line (# comments
  // allowed); the check is skipped when the file is absent, so CI and other
  // contributors are unaffected.
  var listPath = path.join(root, ".private-denylist")
  if (!fs.existsSync(listPath)) return

  var terms = fs.readFileSync(listPath, "utf8").split("\n")
    .map(function (line) { return line.replace(/^\s+|\s+$/g, "") })
    .filter(function (line) { return line && line.charAt(0) !== "#" })
    .map(function (line) { return line.toLowerCase() })
  if (!terms.length) return

  function walk(dir, files) {
    fs.readdirSync(dir, { withFileTypes: true }).forEach(function (entry) {
      if (entry.name === ".git" || entry.name === "node_modules") return
      if (entry.name === ".private-denylist") return
      var full = path.join(dir, entry.name)
      if (entry.isDirectory()) walk(full, files)
      else files.push(full)
    })
    return files
  }

  walk(root, []).forEach(function (file) {
    var text
    try { text = fs.readFileSync(file, "utf8").toLowerCase() } catch (e) { return }
    terms.forEach(function (term) {
      // Report the file and the term's length only — never the term itself, so a
      // CI log cannot publish what the denylist is protecting.
      assert.ok(text.indexOf(term) === -1,
        "a private denylist term (" + term.length + " chars) appears in "
        + path.relative(root, file))
    })
  })
})

console.log("manifest.test.js: " + passed + " passed" +
  (process.exitCode ? " (with failures above)" : ""))
