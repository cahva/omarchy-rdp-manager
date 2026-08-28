// Unit tests for Model.js. Run with: node tests/model.test.js
//
// Model.js is deliberately free of QML types so this can run under plain node.
// Anything that needs a running Omarchy session (the bar, the popup, real
// FreeRDP, the keyring) is out of scope here and is listed in README.md under
// manual verification instead.

var assert = require("assert")
var M = require("../Model.js")

var passed = 0
function test(name, fn) {
  try {
    fn()
    passed++
  } catch (e) {
    console.error("FAIL: " + name)
    console.error("  " + (e && e.message ? e.message : e))
    process.exitCode = 1
  }
}

// --------------------------------------------------------------------- asList

test("asList unwraps a QML sequence wrapper", function () {
  // This is the shape a list takes after crossing a QML property boundary: it
  // indexes and has a length, but Array.isArray reports false. Guarding with
  // `Array.isArray(x) ? x : []` therefore throws real data away silently.
  var wrapper = { 0: { name: "home" }, 1: { name: "work" }, length: 2 }
  assert.strictEqual(Array.isArray(wrapper), false, "fixture must not be a real array")
  assert.deepStrictEqual(M.asList(wrapper), [{ name: "home" }, { name: "work" }])
})

test("asList refuses to shred a string into characters", function () {
  assert.deepStrictEqual(M.asList("home"), [])
})

test("asList tolerates null, undefined and scalars", function () {
  assert.deepStrictEqual(M.asList(null), [])
  assert.deepStrictEqual(M.asList(undefined), [])
  assert.deepStrictEqual(M.asList(7), [])
  assert.deepStrictEqual(M.asList({ length: 0 }), [])
})

test("normalizeDrives accepts a sequence wrapper", function () {
  var wrapper = { 0: { name: "home", path: "/tmp" }, length: 1 }
  assert.deepStrictEqual(M.normalizeDrives(wrapper), [{ name: "home", path: "/tmp" }])
})

// ------------------------------------------------------------------------ ids

test("slugify makes a filesystem- and keyring-safe id", function () {
  assert.strictEqual(M.slugify("Windows Build Server"), "windows-build-server")
  assert.strictEqual(M.slugify("  Prod DC01 (eu-west-1)  "), "prod-dc01-eu-west-1")
  assert.strictEqual(M.slugify("!!!"), "")
  assert.strictEqual(M.slugify("Ä Ö"), "")
})

test("slugify never emits a trailing dash, even when truncating", function () {
  var long = M.slugify("a".repeat(47) + " tail")
  assert.ok(long.length <= 48)
  assert.ok(!/-$/.test(long), "got trailing dash: " + long)
})

test("isValidId matches what the shell scripts accept", function () {
  // The same regex guards every bin/ script; a divergence here would let the
  // panel write an id the launcher then refuses.
  var re = /^[a-z0-9][a-z0-9-]*$/
  var samples = ["a", "windows-build-server", "dc01", "-lead", "Upper", "has_underscore", ""]
  samples.forEach(function (sample) {
    assert.strictEqual(M.isValidId(sample), re.test(sample), "disagreement on: " + sample)
  })
})

test("uniqueId appends a suffix rather than colliding", function () {
  assert.strictEqual(M.uniqueId("Server", []), "server")
  assert.strictEqual(M.uniqueId("Server", ["server"]), "server-2")
  assert.strictEqual(M.uniqueId("Server", ["server", "server-2"]), "server-3")
  assert.strictEqual(M.uniqueId("!!!", []), "")
})

test("uniqueId reads a sequence wrapper of taken ids", function () {
  assert.strictEqual(M.uniqueId("Server", { 0: "server", length: 1 }), "server-2")
})

// ------------------------------------------------------------- normalization

test("normalizeOptions defaults on, and honours an explicit false", function () {
  assert.deepStrictEqual(M.normalizeOptions(undefined),
    { displayMode: "dynamic", resolution: "auto", clipboard: true, cert: "tofu", scale: "100" })
  assert.deepStrictEqual(M.normalizeOptions({ clipboard: false, dynamicResolution: false, cert: "ignore", scale: 180 }),
    { displayMode: "fixed", resolution: "auto", clipboard: false, cert: "ignore", scale: "180" })
})

test("normalizeScale accepts only FreeRDP's three /scale: values", function () {
  assert.strictEqual(M.normalizeScale(undefined), "100")
  assert.strictEqual(M.normalizeScale(""), "100")
  assert.strictEqual(M.normalizeScale(140), "140")
  assert.strictEqual(M.normalizeScale("180"), "180")
  assert.strictEqual(M.normalizeScale("200"), "100")   // not one of FreeRDP's allowed values
  assert.strictEqual(M.normalizeScale("nonsense"), "100")
})

test("buildArgs omits /scale: at 100 (native) and emits it otherwise", function () {
  var base = M.blankConnection()
  base.id = "scaletest"; base.host = "h"; base.user = "u"
  assert.ok(M.buildArgs(base).indexOf("/scale:100") === -1)
  base.options.scale = "180"
  assert.ok(M.buildArgs(base).indexOf("/scale:180") !== -1)
})

// ------------------------------------------------------- display and sizing

test("normalizeDisplayMode reads the legacy dynamicResolution boolean", function () {
  // Files written before displayMode existed carry only the boolean. Absent
  // entirely has to keep meaning what it used to mean, which was dynamic on,
  // or upgrading would silently change how every saved connection behaves.
  assert.strictEqual(M.normalizeDisplayMode({}), "dynamic")
  assert.strictEqual(M.normalizeDisplayMode({ dynamicResolution: true }), "dynamic")
  assert.strictEqual(M.normalizeDisplayMode({ dynamicResolution: false }), "fixed")
  // An explicit mode wins over the legacy key.
  assert.strictEqual(M.normalizeDisplayMode({ displayMode: "scaled", dynamicResolution: true }), "scaled")
  assert.strictEqual(M.normalizeDisplayMode({ displayMode: "SCALED" }), "scaled")
  assert.strictEqual(M.normalizeDisplayMode({ displayMode: "nonsense" }), "dynamic")
})

test("autoResolution clamps each axis independently", function () {
  // Preserving the aspect ratio would turn a 5120x1440 ultrawide into
  // 2560x720, a letterbox slot nobody wants to work in. Clamping per axis
  // keeps the full height.
  assert.deepStrictEqual(M.autoResolution(5120, 1440), { width: 2560, height: 1440 })
  assert.deepStrictEqual(M.autoResolution(3840, 2160), { width: 2560, height: 1440 })
  assert.deepStrictEqual(M.autoResolution(1920, 1080), { width: 1920, height: 1080 })
})

test("autoResolution rounds width to a multiple of 4", function () {
  assert.deepStrictEqual(M.autoResolution(1366, 768), { width: 1364, height: 768 })
})

test("autoResolution falls back when the monitor size is unusable", function () {
  assert.deepStrictEqual(M.autoResolution(0, 0), { width: 1920, height: 1080 })
  assert.deepStrictEqual(M.autoResolution(NaN, undefined), { width: 1920, height: 1080 })
})

test("autoResolution never goes below the floor", function () {
  assert.deepStrictEqual(M.autoResolution(320, 200), { width: 640, height: 480 })
})

test("parseResolution accepts WxH and rejects everything else", function () {
  assert.deepStrictEqual(M.parseResolution("1920x1080"), { width: 1920, height: 1080 })
  assert.deepStrictEqual(M.parseResolution("  2560 x 1440 "), { width: 2560, height: 1440 })
  // A resolution pasted from a spec sheet often carries a multiplication sign.
  assert.deepStrictEqual(M.parseResolution("1600\u00d7900"), { width: 1600, height: 900 })
  assert.strictEqual(M.parseResolution("auto"), null)
  assert.strictEqual(M.parseResolution("99x99"), null)
  assert.strictEqual(M.parseResolution("99999x1080"), null)
  assert.strictEqual(M.parseResolution(""), null)
  assert.strictEqual(M.parseResolution("1920"), null)
})

test("normalizeResolution falls back to auto rather than passing junk on", function () {
  assert.strictEqual(M.normalizeResolution(undefined), "auto")
  assert.strictEqual(M.normalizeResolution("AUTO"), "auto")
  assert.strictEqual(M.normalizeResolution("garbage"), "auto")
  assert.strictEqual(M.normalizeResolution("1600 \u00d7 900"), "1600x900")
})

test("resolveResolution honours an explicit size in every mode", function () {
  // Under dynamic this only decides where the window opens, but dropping it
  // would put every dynamic session back at FreeRDP's 1024x768 default. It
  // also matters for legacy files: those have no displayMode, so they read as
  // dynamic, and ignoring the size there would make hand-editing it a no-op.
  ;["fixed", "scaled", "dynamic"].forEach(function (mode) {
    var conn = { options: { displayMode: mode, resolution: "1280x1024" } }
    assert.deepStrictEqual(M.resolveResolution(conn, { width: 5120, height: 1440 }),
      { width: 1280, height: 1024 }, mode)
  })
  var legacy = { options: { resolution: "1280x1024" } }
  assert.strictEqual(M.normalizeConnection(legacy).options.displayMode, "dynamic")
  assert.deepStrictEqual(M.resolveResolution(legacy, { width: 5120, height: 1440 }),
    { width: 1280, height: 1024 })
})

test("resolveResolution prefers an explicit size over the monitor", function () {
  var explicit = { options: { resolution: "1280x1024" } }
  assert.deepStrictEqual(M.resolveResolution(explicit, { width: 5120, height: 1440 }),
    { width: 1280, height: 1024 })
  var auto = { options: { resolution: "auto" } }
  assert.deepStrictEqual(M.resolveResolution(auto, { width: 5120, height: 1440 }),
    { width: 2560, height: 1440 })
})

test("normalizeOptions rejects an unknown cert policy", function () {
  assert.strictEqual(M.normalizeOptions({ cert: "whatever" }).cert, "tofu")
  assert.strictEqual(M.normalizeOptions({ cert: "DENY" }).cert, "deny")
})

test("normalizePort clamps nonsense to the default", function () {
  assert.strictEqual(M.normalizePort(undefined), 3389)
  assert.strictEqual(M.normalizePort(0), 3389)
  assert.strictEqual(M.normalizePort(70000), 3389)
  assert.strictEqual(M.normalizePort("4489"), 4489)
})

test("normalizeDrives drops half-filled rows", function () {
  var drives = [{ name: "home", path: "/tmp" }, { name: "", path: "/tmp" }, { name: "x", path: "" }]
  assert.deepStrictEqual(M.normalizeDrives(drives), [{ name: "home", path: "/tmp" }])
})

test("normalizeConnection drops unknown keys", function () {
  var c = M.normalizeConnection({ id: "a", host: "h", user: "u", evil: "/p:leak" })
  assert.strictEqual(c.evil, undefined)
})

// ------------------------------------------------------------- config parsing

test("parseConfig reports bad JSON instead of throwing", function () {
  var r = M.parseConfig("{ not json")
  assert.deepStrictEqual(r.connections, [])
  assert.ok(/not valid JSON/.test(r.error), r.error)
})

test("parseConfig treats a missing file as empty, not an error", function () {
  var r = M.parseConfig("")
  assert.deepStrictEqual(r.connections, [])
  assert.strictEqual(r.error, "")
})

test("parseConfig drops entries that cannot be acted on", function () {
  var raw = JSON.stringify({ version: 1, connections: [
    { id: "good", host: "h", user: "u" },
    { id: "nohost", user: "u" },
    { id: "Bad Id", host: "h" },
    { id: "good", host: "other" }
  ]})
  var r = M.parseConfig(raw)
  assert.deepStrictEqual(r.connections.map(function (c) { return c.id }), ["good"])
  assert.strictEqual(r.connections[0].host, "h", "the first of a duplicate id must win")
})

test("parseConfig backfills an empty name from the id", function () {
  var r = M.parseConfig(JSON.stringify({ version: 1, connections: [{ id: "dc01", host: "h", user: "u" }] }))
  assert.strictEqual(r.connections[0].name, "dc01")
})

test("serializeConfig round-trips through parseConfig", function () {
  var conn = { id: "a", name: "A", host: "h", port: 4489, user: "u", domain: "D",
               secret: "keyring", drives: [{ name: "home", path: "/tmp" }],
               options: { dynamicResolution: false, clipboard: false, cert: "deny" } }
  var again = M.parseConfig(M.serializeConfig([conn])).connections[0]
  assert.deepStrictEqual(again, M.normalizeConnection(conn))
})

test("serializeConfig never writes a password, whatever is handed to it", function () {
  var text = M.serializeConfig([{ id: "a", name: "A", host: "h", user: "u",
                                  password: "hunter2", secret: "hunter2" }])
  assert.ok(!/hunter2/.test(text), "secret leaked into connections.json: " + text)
})

// ------------------------------------------------------------------ validation

test("validateConnection requires the fields the launcher needs", function () {
  var r = M.validateConnection({ id: "a", name: "", host: "", user: "" }, [])
  assert.strictEqual(r.ok, false)
  assert.ok(r.errors.name && r.errors.host && r.errors.user)
})

test("validateConnection accepts a complete connection", function () {
  var r = M.validateConnection({ id: "a", name: "A", host: "10.0.0.5", user: "Administrator",
                                 drives: [{ name: "home", path: "/home/you" }] }, [])
  assert.deepStrictEqual(r.errors, {})
  assert.strictEqual(r.ok, true)
})

test("validateConnection rejects a host with whitespace", function () {
  var r = M.validateConnection({ id: "a", name: "A", host: "10.0.0.5 /p:oops", user: "u" }, [])
  assert.ok(r.errors.host)
})

test("validateConnection enforces drive share-name and path rules", function () {
  var r = M.validateConnection({ id: "a", name: "A", host: "h", user: "u", drives: [
    { name: "bad name", path: "/tmp" },
    { name: "rel", path: "relative/path" },
    { name: "", path: "" }
  ]}, [])
  assert.ok(r.errors["drive.0.name"], "space in share name must be rejected")
  assert.ok(r.errors["drive.1.path"], "relative path must be rejected")
  assert.strictEqual(r.errors["drive.2.name"], undefined, "a blank row is just unfilled")
})

test("validateConnection catches duplicate share names", function () {
  var r = M.validateConnection({ id: "a", name: "A", host: "h", user: "u", drives: [
    { name: "home", path: "/a" }, { name: "HOME", path: "/b" }
  ]}, [])
  assert.ok(r.errors["drive.1.name"])
})

test("validateConnection rejects an id already in use", function () {
  var r = M.validateConnection({ id: "taken", name: "A", host: "h", user: "u" }, ["taken"])
  assert.ok(r.errors.name)
})

test("validateConnection reports an out-of-range port from a hand-edited file", function () {
  var r = M.validateConnection({ id: "a", name: "A", host: "h", user: "u", port: 99999 }, [])
  assert.ok(r.errors.port)
})

// ------------------------------------------------------------ argument building

test("buildArgs reproduces the documented baseline command", function () {
  var conn = { id: "windows-build-server", name: "Windows Build Server", host: "10.0.0.5",
               user: "Administrator",
               drives: [{ name: "home", path: "/home/you/projects/shared" }] }
  assert.deepStrictEqual(M.buildArgs(conn), [
    "/v:10.0.0.5",
    "/u:Administrator",
    "/cert:tofu",
    "+clipboard",
    // No autoSize was passed, so "auto" lands on the documented fallback.
    "/size:1920x1080",
    "+dynamic-resolution",
    "/drive:home,/home/you/projects/shared",
    "/wm-class:omarchy-rdp-windows-build-server",
    "/t:Windows Build Server"
  ])
})

test("buildArgs honours clipboard:false and dynamicResolution:false", function () {
  // Regression: the shell launcher read these with jq's `//`, which substitutes
  // for false as well as null — so switching either off was silently ignored.
  var args = M.buildArgs({ id: "a", name: "A", host: "h", user: "u",
                           options: { clipboard: false, dynamicResolution: false, cert: "tofu" } })
  assert.ok(args.indexOf("-clipboard") !== -1, "expected -clipboard in " + args.join(" "))
  assert.ok(args.indexOf("+clipboard") === -1)
  assert.ok(args.indexOf("+dynamic-resolution") === -1)
})

test("buildArgs emits exactly one of /smart-sizing and +dynamic-resolution", function () {
  // FreeRDP exits 22 when both are present, so this is an invariant rather
  // than a matter of taste.
  var base = { id: "a", name: "A", host: "h", user: "u" }
  function argsFor(mode) {
    return M.buildArgs({ id: base.id, name: base.name, host: base.host, user: base.user,
                         options: { displayMode: mode, resolution: "1920x1080" } })
  }
  var fixed = argsFor("fixed")
  assert.ok(fixed.indexOf("/smart-sizing") === -1)
  assert.ok(fixed.indexOf("+dynamic-resolution") === -1)

  var scaled = argsFor("scaled")
  assert.ok(scaled.indexOf("/smart-sizing") !== -1, "expected /smart-sizing in " + scaled.join(" "))
  assert.ok(scaled.indexOf("+dynamic-resolution") === -1)

  var dynamic = argsFor("dynamic")
  assert.ok(dynamic.indexOf("+dynamic-resolution") !== -1)
  assert.ok(dynamic.indexOf("/smart-sizing") === -1)
})

test("buildArgs always emits a size, so FreeRDP never falls back to 1024x768", function () {
  ;["fixed", "scaled", "dynamic"].forEach(function (mode) {
    var args = M.buildArgs({ id: "a", name: "A", host: "h", user: "u",
                             options: { displayMode: mode } }, { width: 2560, height: 1440 })
    var sizes = args.filter(function (a) { return a.indexOf("/size:") === 0 })
    assert.deepStrictEqual(sizes, ["/size:2560x1440"], mode + " -> " + args.join(" "))
  })
})

test("buildArgs uses the monitor passed in for an auto resolution", function () {
  var conn = { id: "a", name: "A", host: "h", user: "u",
               options: { displayMode: "fixed", resolution: "auto" } }
  assert.ok(M.buildArgs(conn, { width: 5120, height: 1440 }).indexOf("/size:2560x1440") !== -1)
  assert.ok(M.buildArgs(conn, { width: 1600, height: 900 }).indexOf("/size:1600x900") !== -1)
})

test("validateConnection rejects an unusable resolution", function () {
  var base = { name: "A", host: "h", user: "u" }
  function check(res) {
    return M.validateConnection({ name: base.name, host: base.host, user: base.user,
                                  options: { resolution: res } }, [])
  }
  assert.strictEqual(check("auto").ok, true)
  assert.strictEqual(check("1920x1080").ok, true)
  assert.strictEqual(check("").ok, true)
  // normalizeResolution would quietly turn these into "auto", which hides the
  // mistake from someone who hand-edited the file.
  assert.strictEqual(check("garbage").ok, false)
  assert.ok(check("garbage").errors.resolution)
  assert.strictEqual(check("99x99").ok, false)
})

test("buildArgs omits the port when it is the default and includes it otherwise", function () {
  assert.ok(M.buildArgs({ id: "a", name: "A", host: "h", user: "u" }).indexOf("/v:h") !== -1)
  assert.ok(M.buildArgs({ id: "a", name: "A", host: "h", user: "u", port: 4489 }).indexOf("/v:h:4489") !== -1)
})

test("buildArgs omits /d: when there is no domain", function () {
  var args = M.buildArgs({ id: "a", name: "A", host: "h", user: "u" })
  assert.ok(!args.some(function (a) { return a.indexOf("/d:") === 0 }))
  var withDomain = M.buildArgs({ id: "a", name: "A", host: "h", user: "u", domain: "CORP" })
  assert.ok(withDomain.indexOf("/d:CORP") !== -1)
})

test("buildArgs emits one /drive: per mapping", function () {
  var args = M.buildArgs({ id: "a", name: "A", host: "h", user: "u", drives: [
    { name: "home", path: "/a" }, { name: "work", path: "/b" }
  ]})
  assert.deepStrictEqual(args.filter(function (x) { return x.indexOf("/drive:") === 0 }),
    ["/drive:home,/a", "/drive:work,/b"])
})

test("buildArgs sets the wm-class status detection depends on", function () {
  assert.strictEqual(M.wmClassFor("dc01"), "omarchy-rdp-dc01")
  assert.ok(M.buildArgs({ id: "dc01", name: "A", host: "h", user: "u" })
    .indexOf("/wm-class:omarchy-rdp-dc01") !== -1)
})

test("buildArgs NEVER contains a password", function () {
  // The password is appended by the launcher alone, so nothing that renders or
  // logs this list can leak it. This is the invariant the whole design rests on.
  var conn = { id: "a", name: "A", host: "h", user: "u", password: "hunter2",
               secret: "hunter2", options: { cert: "tofu" } }
  var args = M.buildArgs(conn)
  args.forEach(function (a) {
    assert.ok(a.indexOf("/p:") !== 0, "buildArgs emitted a password argument: " + a)
    assert.ok(a.indexOf("hunter2") === -1, "password leaked into: " + a)
  })
})

test("previewArgs redacts the password line and adds exactly one", function () {
  var conn = { id: "a", name: "A", host: "h", user: "u" }
  var preview = M.previewArgs(conn)
  assert.deepStrictEqual(preview.slice(0, -1), M.buildArgs(conn))
  assert.strictEqual(preview[preview.length - 1], "/p:<redacted>")
  assert.strictEqual(preview.filter(function (a) { return a.indexOf("/p:") === 0 }).length, 1)
})

// ------------------------------------------------------------------ exit codes

test("describeExit matches FreeRDP's own enum", function () {
  // This test used to claim these were "measured against FreeRDP 3.30". They
  // were not: they came from a formula, and it put "Wrong password" on 156,
  // which is really ACCOUNT_RESTRICTION. Checked against enum XF_EXIT_CODE in
  // client/X11/xfreerdp.h at tag 3.30.0, the version developed against.
  assert.strictEqual(M.describeExit(0), "Session ended")
  assert.strictEqual(M.describeExit(140), "Host not found")
  assert.strictEqual(M.describeExit(154), "Wrong password")
  assert.strictEqual(M.describeExit(156), "Account restriction")
})

test("describeExit names the range when a code has no entry", function () {
  assert.ok(/Connection failed/.test(M.describeExit(199)))
  assert.ok(/RDP protocol error/.test(M.describeExit(99)))
  assert.ok(/Could not start FreeRDP/.test(M.describeExit(22)))
  // 5 is a real mapping now, not a fallback.
  assert.strictEqual(M.describeExit(5), "Replaced by another connection")
  assert.strictEqual(M.describeExit(undefined), "Session ended")
  assert.strictEqual(M.describeExit("nonsense"), "Session ended")
})

test("isFailureExit separates ordinary endings from real failures", function () {
  assert.strictEqual(M.isFailureExit(0), false)
  assert.strictEqual(M.isFailureExit(null), false)
  // The ordinary ways a live session finishes.
  ;[1, 2, 3, 5, 11].forEach(function (c) {
    assert.strictEqual(M.isFailureExit(c), false, "code " + c + " should not be a failure")
  })
  // Session-end codes that are still failures: a logon timeout or a refused
  // connection ended the session too, but the user has something to fix.
  ;[4, 6, 7, 8, 9, 10].forEach(function (c) {
    assert.strictEqual(M.isFailureExit(c), true, "code " + c + " should be a failure")
  })
  assert.strictEqual(M.isFailureExit(141), true)
  // 130 was excluded here as SIGINT, on the shell's 128+signal convention. The
  // launcher records a deliberate stop as phase "stopped" with exit 0, so a 130
  // arriving here can only be XF_EXIT_PROTOCOL, and the exception hid it.
  assert.strictEqual(M.isFailureExit(130), true)
})

test("the exit table matches FreeRDP's enum where it used to be wrong", function () {
  // Transcribed from enum XF_EXIT_CODE. The old table was derived from
  // "135 + low byte of ERRCONNECT_*", which holds to 143 and then breaks,
  // because the enum has a gap at 146. These are the codes it got wrong.
  assert.strictEqual(M.EXIT_MESSAGES[132], "Authentication failed")
  assert.strictEqual(M.EXIT_MESSAGES[144], "Insufficient privileges")
  assert.strictEqual(M.EXIT_MESSAGES[145], "Connection cancelled")
  assert.strictEqual(M.EXIT_MESSAGES[154], "Wrong password")
  assert.strictEqual(M.EXIT_MESSAGES[155], "Access denied")
  // 146 is not an exit code FreeRDP can produce; the old table gave it a
  // meaning that belonged to 145.
  assert.strictEqual(M.EXIT_MESSAGES[146], undefined)
  // Still correct, and the case that started all of this.
  assert.strictEqual(M.EXIT_MESSAGES[147], "Transport failed, is that port really RDP?")
})

test("a dropped session is not reported as a connect-time failure", function () {
  // The bug this fixes: an hour-old session was reset by the peer, FreeRDP
  // exited 147, and the panel told the user to check whether the port was
  // really RDP. Same code, opposite meaning, decided by whether a window ever
  // appeared.
  var dropped = { id: "a", phase: "exited", exitCode: 147, established: true }
  var never = { id: "a", phase: "exited", exitCode: 147, established: false }

  assert.strictEqual(M.isDroppedSession(dropped), true)
  assert.strictEqual(M.isDroppedSession(never), false)

  assert.strictEqual(M.describeEnd(dropped), "Connection lost")
  assert.strictEqual(M.describeEnd(never), "Transport failed, is that port really RDP?")

  // A drop is information, not something to paint red.
  assert.strictEqual(M.rowStatus(dropped, 0).tone, "dim")
  assert.strictEqual(M.rowStatus(never, 0).tone, "urgent")

  // Nor should it tint the bar icon, which means "go and fix this".
  assert.strictEqual(M.summarize([dropped]).state, "idle")
  assert.strictEqual(M.summarize([never]).state, "failed")
})

test("the launcher's own message wins over the generic one", function () {
  // The launcher knew whether the session had established, so what it wrote is
  // better than anything reconstructed from the code alone.
  var s = { id: "a", phase: "exited", exitCode: 147, established: true, message: "Connection lost" }
  assert.strictEqual(M.describeEnd(s), "Connection lost")
})

test("normalizeSession defaults established to false", function () {
  // State files written before this field existed must not read as established,
  // or every old failure would be relabelled a drop.
  assert.strictEqual(M.normalizeSession({ id: "a" }).established, false)
  assert.strictEqual(M.normalizeSession({ id: "a", established: "yes" }).established, false)
  assert.strictEqual(M.normalizeSession({ id: "a", established: true }).established, true)
})

test("an ordinary session ending keeps its specific reason", function () {
  ;[[2, "Signed out on the remote machine"], [3, "Disconnected after being idle"],
    [5, "Replaced by another connection"]].forEach(function (pair) {
    var s = { id: "a", phase: "exited", exitCode: pair[0], established: true }
    var row = M.rowStatus(s, 0)
    assert.strictEqual(row.label, pair[1], "code " + pair[0])
    assert.strictEqual(row.tone, "dim", "code " + pair[0])
  })
})

// --------------------------------------------------------------- status parsing

var STATUS = JSON.stringify({ sessions: [
  { id: "a", pid: 1, phase: "connected", startedAt: 1000, exitCode: null, message: "" },
  { id: "b", pid: 2, phase: "connecting", startedAt: 1000, exitCode: null, message: "" },
  { id: "c", pid: 0, phase: "exited", startedAt: 1000, exitCode: 140, message: "Host not found" }
], error: "" })

test("parseStatus reads the helper's output", function () {
  var r = M.parseStatus(STATUS)
  assert.strictEqual(r.sessions.length, 3)
  assert.strictEqual(r.error, "")
})

test("parseStatus takes the LAST line, tolerating a version-manager banner", function () {
  // `mise` prints its banner on stdout ahead of the real output, so trimming the
  // whole stream would yield a banner glued to the JSON.
  var r = M.parseStatus("mise WARN  missing: node@latest\n" + STATUS + "\n")
  assert.strictEqual(r.sessions.length, 3)
})

test("parseStatus degrades instead of throwing on garbage", function () {
  var r = M.parseStatus("not json at all")
  assert.deepStrictEqual(r.sessions, [])
  assert.ok(/unparseable/.test(r.error))
  assert.deepStrictEqual(M.parseStatus("").sessions, [])
})

test("normalizeSession rejects an unknown phase", function () {
  assert.strictEqual(M.normalizeSession({ id: "a", phase: "hallucinating" }).phase, "exited")
})

test("sessionMap and isLive classify phases correctly", function () {
  var map = M.sessionMap(M.parseStatus(STATUS).sessions)
  assert.strictEqual(M.isLive(map.a), true)
  assert.strictEqual(M.isLive(map.b), true)
  assert.strictEqual(M.isLive(map.c), false)
  assert.strictEqual(M.isLive(null), false)
})

test("summarize gives the bar icon its state", function () {
  var s = M.summarize(M.parseStatus(STATUS).sessions)
  assert.deepStrictEqual(s, { state: "connected", connected: 1, connecting: 1, failed: 1, total: 3 })
  assert.strictEqual(M.summarize([]).state, "idle")
  assert.strictEqual(M.summarize([{ id: "x", phase: "connecting" }]).state, "connecting")
  assert.strictEqual(M.summarize([{ id: "x", phase: "exited", exitCode: 141 }]).state, "failed")
  assert.strictEqual(M.summarize([{ id: "x", phase: "stopped", exitCode: 0 }]).state, "idle")
})

test("pollInterval tightens while connecting and backs off when idle", function () {
  assert.strictEqual(M.pollInterval({ connecting: 1, connected: 0 }), 2000)
  assert.strictEqual(M.pollInterval({ connecting: 0, connected: 1 }), 3000)
  assert.strictEqual(M.pollInterval({ connecting: 0, connected: 0 }), 10000)
  assert.strictEqual(M.pollInterval(undefined), 10000)
})

// --------------------------------------------------------------------- display

test("formatDuration reads naturally at every scale", function () {
  assert.strictEqual(M.formatDuration(0), "0s")
  assert.strictEqual(M.formatDuration(45), "45s")
  assert.strictEqual(M.formatDuration(90), "1m")
  assert.strictEqual(M.formatDuration(3600), "1h")
  assert.strictEqual(M.formatDuration(3660), "1h 1m")
  assert.strictEqual(M.formatDuration(90000), "1d 1h")
  assert.strictEqual(M.formatDuration(-5), "0s")
})

test("endpointFor renders the connection target", function () {
  assert.strictEqual(M.endpointFor({ id: "a", host: "h", user: "u" }), "u@h")
  assert.strictEqual(M.endpointFor({ id: "a", host: "h", user: "u", port: 4489 }), "u@h:4489")
  assert.strictEqual(M.endpointFor({ id: "a", host: "h", user: "u", domain: "CORP" }), "CORP\\u@h")
})

test("driveSummary shows the mapping, then just a count", function () {
  assert.strictEqual(M.driveSummary({ id: "a", host: "h", user: "u" }), "")
  assert.strictEqual(M.driveSummary({ id: "a", host: "h", user: "u",
    drives: [{ name: "home", path: "/tmp" }] }), "home → /tmp")
  assert.strictEqual(M.driveSummary({ id: "a", host: "h", user: "u",
    drives: [{ name: "a", path: "/a" }, { name: "b", path: "/b" }] }), "2 drives mapped")
})

test("rowStatus tones each phase", function () {
  assert.strictEqual(M.rowStatus(null, 0).tone, "dim")
  assert.strictEqual(M.rowStatus({ id: "a", phase: "connecting" }, 0).tone, "accent")
  assert.strictEqual(M.rowStatus({ id: "a", phase: "connected", startedAt: 100 }, 700).label,
    "Connected · 10m")
  assert.strictEqual(M.rowStatus({ id: "a", phase: "exited", exitCode: 156 }, 0).tone, "urgent")
  assert.strictEqual(M.rowStatus({ id: "a", phase: "stopped", exitCode: 0 }, 0).label, "Disconnected")
})

test("rowStatus does not invent an age from a missing startedAt", function () {
  assert.strictEqual(M.rowStatus({ id: "a", phase: "connected", startedAt: 0 }, 700).label, "Connected")
})

test("tooltipFor names live sessions, then failures, then falls back", function () {
  var conns = M.parseConfig(JSON.stringify({ version: 1, connections: [
    { id: "a", name: "Alpha", host: "h", user: "u" },
    { id: "c", name: "Gamma", host: "h", user: "u" }
  ]})).connections
  var sessions = M.parseStatus(STATUS).sessions
  assert.ok(/Alpha/.test(M.tooltipFor(conns, sessions, 2000)))
  var onlyFailed = [{ id: "c", phase: "exited", exitCode: 140, message: "Host not found" }]
  assert.strictEqual(M.tooltipFor(conns, onlyFailed, 0), "RDP: Gamma — Host not found")
  assert.strictEqual(M.tooltipFor(conns, [], 0), "RDP: 2 connections, none active")
  assert.strictEqual(M.tooltipFor([], [], 0), "RDP: no connections saved yet")
})

test("heroMeta counts connections and live sessions", function () {
  var conns = [{ id: "a", host: "h", user: "u" }]
  assert.strictEqual(M.heroMeta(conns, []), "1 connection")
  assert.strictEqual(M.heroMeta(conns, [{ id: "a", phase: "connected" }]),
    "1 connection · 1 connected")
})

// -------------------------------------------------------------- list mutation

test("upsertConnection replaces by id and appends otherwise", function () {
  var list = [M.normalizeConnection({ id: "a", name: "A", host: "h", user: "u" })]
  var replaced = M.upsertConnection(list, { id: "a", name: "A2", host: "h2", user: "u" })
  assert.strictEqual(replaced.length, 1)
  assert.strictEqual(replaced[0].host, "h2")
  assert.strictEqual(M.upsertConnection(list, { id: "b", name: "B", host: "h", user: "u" }).length, 2)
})

test("removeConnection and findConnection work on a sequence wrapper", function () {
  var wrapper = { 0: { id: "a", host: "h", user: "u" }, 1: { id: "b", host: "h", user: "u" }, length: 2 }
  assert.deepStrictEqual(M.removeConnection(wrapper, "a").map(function (c) { return c.id }), ["b"])
  assert.strictEqual(M.findConnection(wrapper, "b").id, "b")
  assert.strictEqual(M.findConnection(wrapper, "nope"), null)
})

test("blankConnection is a valid starting point once named", function () {
  var blank = M.blankConnection()
  assert.strictEqual(blank.options.cert, "tofu")
  assert.strictEqual(blank.port, M.DEFAULT_PORT)
  blank.id = "x"; blank.name = "X"; blank.host = "h"; blank.user = "u"
  assert.strictEqual(M.validateConnection(blank, []).ok, true)
})

console.log("model.test.js: " + passed + " passed" +
  (process.exitCode ? " (with failures above)" : ""))
