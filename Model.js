// Pure state logic for io.github.cahva.rdp-manager.
//
// Everything here is a plain function of its arguments: no QML types, no
// clock read that is not passed in, no file access. That is what makes it
// runnable under `node tests/model.test.js`, and it is why Panel.qml and
// Service.qml can both use it without either one owning it.
//
// QML loads this with `import "Model.js" as Model`; node loads it through the
// `module.exports` at the bottom.

// ------------------------------------------------------------------- lists

// Coerce anything list-shaped into a real JavaScript array.
//
// `Array.isArray` is not safe on values that have crossed a QML property
// boundary: QML hands JavaScript a sequence-backed wrapper that indexes and
// has a `length`, but for which `Array.isArray` reports false. Guarding with
// `Array.isArray(x) ? x : []` therefore silently discards real data. Every
// list-taking function in this file goes through here first.
function asList(value) {
  if (!value) return []
  if (Array.isArray(value)) return value
  // A string is indexable and has a length, so the duck-typing below would
  // turn "home" into ["h","o","m","e"]. Anything scalar is not a list.
  if (typeof value !== "object") return []
  var n = Number(value.length)
  if (!isFinite(n) || n <= 0) return []
  var out = []
  for (var i = 0; i < n; i++) out.push(value[i])
  return out
}

function str(value) {
  if (value === undefined || value === null) return ""
  return String(value)
}

function trim(value) {
  return str(value).replace(/^\s+|\s+$/g, "")
}

// --------------------------------------------------------------------- ids

// Turn a display name into the connection id.
//
// The id is not cosmetic: it is the keyring lookup attribute and the
// `/wm-class` suffix used to find the session's window. It is generated once
// on create and then immutable, because changing it would orphan the stored
// password and break status detection for a running session.
function slugify(name) {
  var base = trim(name).toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
  return base.substring(0, 48).replace(/-+$/g, "")
}

function isValidId(id) {
  return /^[a-z0-9][a-z0-9-]*$/.test(str(id))
}

// Append -2, -3, ... until the slug is free. Returns "" for an unusable name
// so callers surface a validation error rather than writing a blank id.
function uniqueId(name, takenIds) {
  var base = slugify(name)
  if (!base) return ""
  var taken = {}
  var list = asList(takenIds)
  for (var i = 0; i < list.length; i++) taken[str(list[i])] = true
  if (!taken[base]) return base
  for (var n = 2; n < 1000; n++) {
    var candidate = base + "-" + n
    if (!taken[candidate]) return candidate
  }
  return ""
}

// ------------------------------------------------------------ normalization

var DEFAULT_PORT = 3389
var CERT_POLICIES = ["tofu", "ignore", "deny"]

// FreeRDP's /scale: accepts exactly these three values (see `xfreerdp3 --help`).
// "100" is native size and is treated as "off" — buildArgs omits the flag
// entirely rather than emit a no-op /scale:100.
var SCALE_VALUES = ["100", "140", "180"]

// ------------------------------------------------------- display and sizing

// How the remote desktop relates to the client window.
//   fixed    the desktop is created at one size and stays there. Growing the
//            window letterboxes it. Sharpest, and the server does nothing.
//   scaled   /smart-sizing scales the desktop to the window. Resizable, a
//            little soft away from native size, still no server involvement.
//   dynamic  +dynamic-resolution asks the server to resize the desktop to
//            match the window. Best fidelity while resizing, but it drives the
//            server's indirect display driver (RdpIdd.dll on Windows), which
//            is the component that takes the session down when it crashes.
// FreeRDP refuses /smart-sizing and +dynamic-resolution together (it exits 22),
// so this is one choice rather than two independent flags.
var DISPLAY_MODES = ["fixed", "scaled", "dynamic"]

// Offered by the form's resolution dropdown, most common first.
var COMMON_RESOLUTIONS = [
  "1920x1080", "2560x1440", "1600x900", "1366x768", "1280x1024", "3840x2160"
]

// "auto" resolves against the monitor the session opens on. The cap stops a
// large or very wide display from becoming a desktop that is slow to push over
// a WAN: a 5120x1440 ultrawide asks for 2560x1440 rather than seven megapixels
// of framebuffer per update.
var AUTO_MAX_WIDTH = 2560
var AUTO_MAX_HEIGHT = 1440
var MIN_WIDTH = 640
var MIN_HEIGHT = 480
var MAX_WIDTH = 7680
var MAX_HEIGHT = 4320

// Used when "auto" is asked for but the caller could not supply a monitor
// size. The launcher and the panel both pass a real one.
var FALLBACK_AUTO = { width: 1920, height: 1080 }

// Clamp a monitor size into something sensible to ask a remote desktop for.
// Each axis is clamped independently: fitting an ultrawide inside the cap
// while preserving its aspect ratio would give 2560x720, which is a letterbox
// slot nobody wants to work in.
function autoResolution(monitorWidth, monitorHeight) {
  var w = Number(monitorWidth)
  var h = Number(monitorHeight)
  if (!isFinite(w) || w <= 0) w = FALLBACK_AUTO.width
  if (!isFinite(h) || h <= 0) h = FALLBACK_AUTO.height
  w = Math.min(Math.floor(w), AUTO_MAX_WIDTH)
  h = Math.min(Math.floor(h), AUTO_MAX_HEIGHT)
  // RDP wants a width that is a multiple of 4; an odd height is no better.
  w = Math.max(Math.floor(w / 4) * 4, MIN_WIDTH)
  h = Math.max(Math.floor(h / 2) * 2, MIN_HEIGHT)
  return { width: w, height: h }
}

// Accepts "1920x1080", tolerating stray spaces or a pasted multiplication
// sign. Returns null for anything else, "auto" included, so callers can tell
// a real size from the keyword.
function parseResolution(value) {
  var m = /^\s*(\d{3,5})\s*[x\u00d7]\s*(\d{3,5})\s*$/.exec(str(value))
  if (!m) return null
  var w = Number(m[1])
  var h = Number(m[2])
  if (w < MIN_WIDTH || w > MAX_WIDTH || h < MIN_HEIGHT || h > MAX_HEIGHT) return null
  return { width: w, height: h }
}

function normalizeResolution(value) {
  var v = trim(value).toLowerCase()
  if (!v || v === "auto") return "auto"
  var parsed = parseResolution(v)
  return parsed ? parsed.width + "x" + parsed.height : "auto"
}

// displayMode replaced an older dynamicResolution boolean. A file written
// before this option existed still carries the boolean, so it is read as the
// mode it used to mean; absent entirely keeps the old default, which was
// dynamic resolution on.
function normalizeDisplayMode(options) {
  var o = options && typeof options === "object" ? options : {}
  var mode = trim(o.displayMode).toLowerCase()
  if (DISPLAY_MODES.indexOf(mode) !== -1) return mode
  if (o.dynamicResolution === false) return "fixed"
  return "dynamic"
}

// The size to actually ask FreeRDP for. `autoSize` is the monitor the session
// will open on, passed in because this file cannot see a display: the launcher
// reads it from hyprctl, the panel from its own screen.
function resolveResolution(conn, autoSize) {
  var c = normalizeConnection(conn)
  // Honoured in every mode. Under "dynamic" the desktop is renegotiated on the
  // first resize, so this only decides where the window opens, but that is
  // exactly the size that matters most: without it FreeRDP starts at 1024x768.
  if (c.options.resolution !== "auto") {
    var explicit = parseResolution(c.options.resolution)
    if (explicit) return explicit
  }
  var a = autoSize && typeof autoSize === "object" ? autoSize : FALLBACK_AUTO
  return autoResolution(a.width, a.height)
}

function normalizeDrive(drive) {
  var d = drive && typeof drive === "object" ? drive : {}
  return { name: trim(d.name), path: trim(d.path) }
}

function normalizeDrives(drives) {
  var list = asList(drives)
  var out = []
  for (var i = 0; i < list.length; i++) {
    var d = normalizeDrive(list[i])
    // A half-filled row is what an unfinished form looks like; drop it rather
    // than emitting a /drive: flag FreeRDP would reject.
    if (d.name && d.path) out.push(d)
  }
  return out
}

// Coerces to a string first: a hand-edited file might have 140 as a JSON
// number rather than "140", and SCALE_VALUES compares strings.
function normalizeScale(scale) {
  var s = trim(String(scale == null ? "" : scale))
  return SCALE_VALUES.indexOf(s) === -1 ? "100" : s
}

function normalizeOptions(options) {
  var o = options && typeof options === "object" ? options : {}
  var cert = trim(o.cert).toLowerCase()
  return {
    displayMode: normalizeDisplayMode(o),
    resolution: normalizeResolution(o.resolution),
    clipboard: o.clipboard !== false,
    cert: CERT_POLICIES.indexOf(cert) === -1 ? "tofu" : cert,
    scale: normalizeScale(o.scale)
  }
}

function normalizePort(port) {
  var n = Number(port)
  if (!isFinite(n) || n < 1 || n > 65535) return DEFAULT_PORT
  return Math.floor(n)
}

// The form has one Host field and no Port field, so "host:port" typed there
// is the only way to set a port through the UI. Splits it out on save.
//
// Split on the *last* colon, not the first: a bracketed IPv6 literal with a
// port — "[::1]:3389" — only works if the colon after "]" is the one used, and
// splitting on the first colon inside an unbracketed IPv6 address would tear
// the address itself apart. A bare IPv6 host with no port ("2001:db8::1") is
// genuinely ambiguous with "host:port" once brackets are gone, so it is left
// untouched unless bracketed — better to do nothing than guess wrong on an
// address, not a hostname.
function splitHostPort(rawHost) {
  var host = trim(rawHost)

  var bracketed = host.match(/^\[([^\]]+)\](?::(\d{1,5}))?$/)
  if (bracketed) {
    if (!bracketed[2]) return { host: host, port: null }
    var bracketedPort = Number(bracketed[2])
    if (bracketedPort < 1 || bracketedPort > 65535) return { host: host, port: null }
    return { host: "[" + bracketed[1] + "]", port: bracketedPort }
  }

  var lastColon = host.lastIndexOf(":")
  // Exactly one colon: safe to treat as host:port. Two or more with no
  // brackets reads as an unbracketed IPv6 literal — leave it alone.
  if (lastColon <= 0 || host.indexOf(":") !== lastColon) return { host: host, port: null }

  var portPart = host.slice(lastColon + 1)
  if (!/^\d{1,5}$/.test(portPart)) return { host: host, port: null }
  var port = Number(portPart)
  if (port < 1 || port > 65535) return { host: host, port: null }

  return { host: host.slice(0, lastColon), port: port }
}

// Bring a connection read from disk (or built by the form) into the exact
// shape the rest of the code assumes. Missing keys get defaults; unknown keys
// are dropped so a hand-edited file cannot smuggle anything into buildArgs.
function normalizeConnection(conn) {
  var c = conn && typeof conn === "object" ? conn : {}
  var name = trim(c.name)
  return {
    id: trim(c.id),
    name: name,
    host: trim(c.host),
    port: normalizePort(c.port),
    user: trim(c.user),
    domain: trim(c.domain),
    secret: trim(c.secret) === "prompt" ? "prompt" : "keyring",
    drives: normalizeDrives(c.drives),
    options: normalizeOptions(c.options)
  }
}

// Parse the whole connections.json document. Never throws: a corrupt file
// degrades to an empty list plus an error string the panel can show, which is
// better than an exception that takes the bar widget down with it.
function parseConfig(raw) {
  var text = trim(raw)
  if (!text) return { version: 1, connections: [], error: "" }
  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return { version: 1, connections: [], error: "connections.json is not valid JSON: " + e.message }
  }
  if (!parsed || typeof parsed !== "object") {
    return { version: 1, connections: [], error: "connections.json must contain a JSON object" }
  }
  var list = asList(parsed.connections)
  var out = []
  var seen = {}
  for (var i = 0; i < list.length; i++) {
    var c = normalizeConnection(list[i])
    // Drop entries that cannot be acted on. A duplicate id would make two
    // rows share a keyring secret and a wm-class, so the later one loses.
    if (!isValidId(c.id) || !c.host || seen[c.id]) continue
    seen[c.id] = true
    if (!c.name) c.name = c.id
    out.push(c)
  }
  return { version: 1, connections: out, error: "" }
}

function serializeConfig(connections) {
  var list = asList(connections)
  var out = []
  for (var i = 0; i < list.length; i++) out.push(normalizeConnection(list[i]))
  return JSON.stringify({ version: 1, connections: out }, null, 2) + "\n"
}

// -------------------------------------------------------------- validation

// Returns { ok, errors: { field: message } }. Field keys match the form's
// input ids so the panel can mark the offending row.
function validateConnection(conn, takenIds) {
  var c = normalizeConnection(conn)
  var errors = {}

  if (!c.name) errors.name = "Give the connection a name"
  if (!c.host) errors.host = "Host is required"
  else if (/\s/.test(c.host)) errors.host = "Host cannot contain spaces"

  if (!c.user) errors.user = "Username is required"

  // The form has no port field in this version, so a bad port can only come
  // from a hand-edited file — report it rather than silently defaulting.
  var rawPort = conn && conn.port !== undefined && conn.port !== null ? Number(conn.port) : DEFAULT_PORT
  if (!isFinite(rawPort) || rawPort < 1 || rawPort > 65535) errors.port = "Port must be between 1 and 65535"

  // Only a typed or hand-edited value can be wrong here; the dropdown can only
  // produce "auto" or a preset. normalizeResolution() would quietly fall back
  // to "auto", which would hide the mistake instead of reporting it.
  var rawRes = trim(conn && conn.options ? conn.options.resolution : "")
  if (rawRes && rawRes.toLowerCase() !== "auto" && !parseResolution(rawRes)) {
    errors.resolution = "Use WIDTHxHEIGHT, for example 1920x1080"
  }

  var drives = asList(conn ? conn.drives : [])
  for (var i = 0; i < drives.length; i++) {
    var d = normalizeDrive(drives[i])
    // A wholly blank row is just an unfilled slot in the form.
    if (!d.name && !d.path) continue
    if (!d.name) { errors["drive." + i + ".name"] = "Share name is required"; continue }
    if (!/^[A-Za-z0-9_-]+$/.test(d.name)) {
      errors["drive." + i + ".name"] = "Use only letters, numbers, - and _"
      continue
    }
    if (!d.path) errors["drive." + i + ".path"] = "Path is required"
    else if (d.path.charAt(0) !== "/") errors["drive." + i + ".path"] = "Use an absolute path"
  }

  var names = {}
  for (var j = 0; j < drives.length; j++) {
    var dn = normalizeDrive(drives[j]).name.toLowerCase()
    if (!dn) continue
    if (names[dn]) errors["drive." + j + ".name"] = "Duplicate share name"
    names[dn] = true
  }

  var taken = asList(takenIds)
  for (var k = 0; k < taken.length; k++) {
    if (str(taken[k]) === c.id && c.id) { errors.name = "A connection with this id already exists"; break }
  }

  var ok = true
  for (var key in errors) { ok = false; break }
  return { ok: ok, errors: errors }
}

// --------------------------------------------------------- argument building

function wmClassFor(id) {
  return "omarchy-rdp-" + str(id)
}

// Build the FreeRDP argument list for a connection, one element per line of
// the /args-from: list.
//
// The password is deliberately NOT included here. It is appended as its own
// line by the launcher, which is the only place it exists, so nothing that
// renders or logs this list can leak it. `buildArgs` is what the dry-run
// preview shows, and the launcher builds the same list, so they cannot drift.
function buildArgs(conn, autoSize) {
  var c = normalizeConnection(conn)
  var args = []

  args.push("/v:" + formatHostPort(c.host, c.port))
  args.push("/u:" + c.user)
  if (c.domain) args.push("/d:" + c.domain)

  args.push("/cert:" + c.options.cert)
  // FreeRDP 3 enables clipboard by default, so the meaningful action is the
  // negative one. Emitting +clipboard as well keeps the intent readable in a
  // dry run and matches what a user would type by hand.
  args.push(c.options.clipboard ? "+clipboard" : "-clipboard")
  // "100" is native size; omit the flag rather than pass a no-op /scale:100.
  if (c.options.scale !== "100") args.push("/scale:" + c.options.scale)

  // Without a size FreeRDP picks 1024x768, which is a postage stamp on a
  // modern display. The size is emitted for every mode: under "dynamic" it is
  // the size the desktop starts at before the first resize.
  var size = resolveResolution(c, autoSize)
  args.push("/size:" + size.width + "x" + size.height)
  if (c.options.displayMode === "scaled") args.push("/smart-sizing")
  else if (c.options.displayMode === "dynamic") args.push("+dynamic-resolution")

  for (var i = 0; i < c.drives.length; i++) {
    args.push("/drive:" + c.drives[i].name + "," + c.drives[i].path)
  }

  // The class is how status detection finds this session's window, and how a
  // user can write Hyprland rules against it.
  args.push("/wm-class:" + wmClassFor(c.id))
  // parseConfig() backfills an empty name from the id, and the form requires
  // one, so this fallback only matters for a directly-constructed object.
  args.push("/t:" + (c.name || c.id || c.host))

  return args
}

// What the user sees in a dry run: the real list plus a redacted stand-in for
// the line the launcher adds.
function previewArgs(conn, autoSize) {
  return buildArgs(conn, autoSize).concat(["/p:<redacted>"])
}

function previewCommand(conn, autoSize) {
  return "xfreerdp3 /args-from:fd:3   # " + previewArgs(conn, autoSize).length + " arguments on fd 3"
}

// ---------------------------------------------------------------- exit codes

// Transcribed from `enum XF_EXIT_CODE` in FreeRDP's client/X11/xfreerdp.h,
// which is the authority: there is no EXIT STATUS section in the manpage.
//
// An earlier version of this table said the codes were `135 + low byte of
// ERRCONNECT_*`. They are not. The enum is bespoke and has a gap at 146, so
// that formula was right up to 143 and silently wrong above it, which put the
// wrong message on eight codes. Verified against the real enum, and spot
// checked against a live FreeRDP: 0x01 PRE_CONNECT_FAILED does exit 136, and
// 0x0D CONNECT_TRANSPORT_FAILED exits 147 rather than the 148 the formula
// predicts.
//
// The ranges, per the enum's own comments:
//   0-15     protocol-independent, mostly how a *live* session ended
//   16-31    licensing
//   32-127   RDP protocol errors
//   128-254  xfreerdp's own, nearly all connection-time
var EXIT_MESSAGES = {
  0: "Session ended",

  // These describe a session that was up and then stopped. Several are not
  // failures at all, which is what isFailureExit() below keys on.
  1: "Disconnected",
  2: "Signed out on the remote machine",
  3: "Disconnected after being idle",
  4: "Logon timed out",
  5: "Replaced by another connection",
  6: "The server ran out of memory",
  7: "The server refused the connection",
  8: "The server refused the connection (FIPS policy)",
  9: "Insufficient user privileges",
  10: "Fresh credentials are required",
  11: "Disconnected by the user",

  128: "Bad FreeRDP arguments (plugin bug, please report)",
  129: "FreeRDP ran out of memory",
  130: "Protocol error",
  131: "Could not connect to the host",
  132: "Authentication failed",
  133: "Security negotiation failed",
  134: "Logon failure, check the username and domain",
  135: "Account locked out",
  136: "Pre-connect failed",
  137: "Connection failed for an unspecified reason",
  138: "Post-connect failed",
  139: "DNS error",
  140: "Host not found",
  141: "Could not connect, host unreachable or RDP not listening",
  142: "MCS connect failed",
  143: "TLS handshake failed",
  144: "Insufficient privileges",
  145: "Connection cancelled",
  // 146 is deliberately absent: the enum skips it.
  147: "Transport failed, is that port really RDP?",
  148: "Password expired",
  149: "Password must be changed before signing in",
  150: "Kerberos KDC unreachable",
  151: "Account disabled",
  152: "Password expired",
  153: "Client revoked",
  154: "Wrong password",
  155: "Access denied",
  156: "Account restriction",
  157: "Account expired",
  158: "Logon type not granted to this account",
  159: "No credentials were supplied",
  160: "The remote machine is still booting",
  161: "The server requires NLA",
  255: "Unknown FreeRDP error"
}

// Codes 1-11 report how a live session ended. Anything at 128 or above is
// xfreerdp failing to get a session at all.
function isSessionEndCode(code) {
  var n = Number(code)
  return isFinite(n) && n >= 1 && n <= 11
}

// The subset of those that are an ordinary way for a session to finish, rather
// than something the user has to go and fix. Deliberately not all of 1-11:
// a logon timeout (4) or a server refusal (7) ended the session too, but they
// are failures. In order: disconnect, remote logoff, idle timeout, replaced by
// another connection, disconnected by the user.
var NORMAL_END_CODES = [1, 2, 3, 5, 11]

function describeExit(code) {
  var n = Number(code)
  if (!isFinite(n)) return "Session ended"
  if (EXIT_MESSAGES[n]) return EXIT_MESSAGES[n]
  // Unmapped codes still fall in a range with a known meaning, so say which
  // rather than using one message for all of them.
  if (n >= 128) return "Connection failed (FreeRDP exit " + n + ")"
  if (n >= 32) return "RDP protocol error (FreeRDP exit " + n + ")"
  // 16-31 is the licensing set, but FreeRDP also returns codes in this range
  // when it rejects its own command line: an argument mistake here exits 22.
  // Both mean no session, so the wording covers them without picking one.
  if (n >= 16) return "Could not start FreeRDP (exit " + n + ")"
  return "Session ended (FreeRDP exit " + n + ")"
}

// Whether an exit code is worth painting red and raising a notification for.
//
// 130 used to be excluded here as SIGINT, on the shell's 128+signal
// convention. It is not any more: the launcher already records a deliberate
// stop as phase "stopped" with exit 0, so by the time a code reaches this
// function a 130 can only be XF_EXIT_PROTOCOL, a real failure. The same
// applies to 143, which collides with TLS_CONNECT_FAILED. Leaving those
// exceptions in only ever hid genuine errors.
function isFailureExit(code) {
  var n = Number(code)
  if (!isFinite(n)) return false
  if (n === 0) return false
  return NORMAL_END_CODES.indexOf(n) === -1
}

// A session that was up and then ended badly is a different event from one
// that never connected, even though FreeRDP reports both with the same code.
// 147 is the case that prompted this: at connect time it genuinely does suggest
// the port is not RDP, and mid-session it only means the link died.
function isDroppedSession(session) {
  var s = normalizeSession(session)
  return s.established && isFailureExit(s.exitCode) && !isSessionEndCode(s.exitCode)
}

// What to show for a finished session. The launcher's own message wins when it
// set one, because it knew whether the session had established.
function describeEnd(session) {
  var s = normalizeSession(session)
  if (s.message) return s.message
  if (isDroppedSession(s)) return "Connection lost"
  return describeExit(s.exitCode)
}

// -------------------------------------------------------------- session view

function normalizeSession(session) {
  var s = session && typeof session === "object" ? session : {}
  var phase = trim(s.phase)
  if (["connecting", "connected", "exited", "stopped"].indexOf(phase) === -1) phase = "exited"
  var exitCode = s.exitCode === undefined || s.exitCode === null ? null : Number(s.exitCode)
  return {
    id: trim(s.id),
    pid: Number(s.pid) || 0,
    phase: phase,
    startedAt: Number(s.startedAt) || 0,
    exitCode: exitCode === null || !isFinite(exitCode) ? null : exitCode,
    // Whether this session ever had a window. FreeRDP maps nothing until the
    // connection succeeds, so this is what separates "the link died" from
    // "we never got in", which the exit code alone cannot say.
    established: s.established === true,
    message: trim(s.message)
  }
}

function parseStatus(raw) {
  var text = trim(raw)
  if (!text) return { sessions: [], error: "" }
  // The status helper prints one JSON object per invocation, but a shelled-out
  // tool can be preceded by a version-manager banner on stdout, so take the
  // last non-empty line rather than trimming the whole stream.
  var lines = text.split("\n")
  var last = ""
  for (var i = lines.length - 1; i >= 0; i--) {
    if (trim(lines[i])) { last = trim(lines[i]); break }
  }
  var parsed
  try {
    parsed = JSON.parse(last)
  } catch (e) {
    return { sessions: [], error: "status helper returned unparseable output" }
  }
  var list = asList(parsed ? parsed.sessions : [])
  var out = []
  for (var j = 0; j < list.length; j++) {
    var s = normalizeSession(list[j])
    if (s.id) out.push(s)
  }
  return { sessions: out, error: trim(parsed ? parsed.error : "") }
}

// Index sessions by connection id so a row can look its own state up in O(1).
function sessionMap(sessions) {
  var list = asList(sessions)
  var map = {}
  for (var i = 0; i < list.length; i++) {
    var s = normalizeSession(list[i])
    if (s.id) map[s.id] = s
  }
  return map
}

function isLive(session) {
  if (!session) return false
  return session.phase === "connecting" || session.phase === "connected"
}

// Roll the session list up into what the bar icon needs to render itself.
function summarize(sessions) {
  var list = asList(sessions)
  var connected = 0
  var connecting = 0
  var failed = 0
  for (var i = 0; i < list.length; i++) {
    var s = normalizeSession(list[i])
    if (s.phase === "connected") connected++
    else if (s.phase === "connecting") connecting++
    // A dropped session is deliberately not counted. The icon's failed tint
    // says "this is misconfigured, go and fix it", which is wrong for a link
    // that died; the desktop notification is what reports that.
    else if (s.phase === "exited" && isFailureExit(s.exitCode) && !isDroppedSession(s)) failed++
  }
  var state = "idle"
  if (connected > 0) state = "connected"
  else if (connecting > 0) state = "connecting"
  else if (failed > 0) state = "failed"
  return { state: state, connected: connected, connecting: connecting, failed: failed, total: list.length }
}

// How long the poll timer should wait before asking again. A connecting
// session is the only state where the user is actively waiting on us, so it
// gets the tight cadence; idle backs right off to keep the fork rate low.
function pollInterval(summary) {
  var s = summary && typeof summary === "object" ? summary : {}
  if (Number(s.connecting) > 0) return 2000
  if (Number(s.connected) > 0) return 3000
  return 10000
}

// ------------------------------------------------------------------ display

function formatDuration(seconds) {
  var n = Math.floor(Number(seconds))
  if (!isFinite(n) || n < 0) n = 0
  if (n < 60) return n + "s"
  var m = Math.floor(n / 60)
  if (m < 60) return m + "m"
  var h = Math.floor(m / 60)
  var rem = m % 60
  if (h < 24) return rem ? h + "h " + rem + "m" : h + "h"
  var d = Math.floor(h / 24)
  return d + "d " + (h % 24) + "h"
}

// The one spot the default port is worth hiding: 3389 is what a reader
// assumes anyway, so only a non-default port earns the extra characters.
function formatHostPort(host, port) {
  return port === DEFAULT_PORT ? host : host + ":" + port
}

function endpointFor(conn) {
  var c = normalizeConnection(conn)
  var host = formatHostPort(c.host, c.port)
  var user = c.domain ? c.domain + "\\" + c.user : c.user
  return user ? user + "@" + host : host
}

function driveSummary(conn) {
  var c = normalizeConnection(conn)
  if (!c.drives.length) return ""
  if (c.drives.length === 1) return c.drives[0].name + " → " + c.drives[0].path
  return c.drives.length + " drives mapped"
}

// One line of state per row, given the session (may be absent) and the
// current wall clock passed in from the caller.
function rowStatus(session, nowSeconds) {
  var s = session ? normalizeSession(session) : null
  if (!s) return { label: "Not connected", tone: "dim" }
  if (s.phase === "connecting") return { label: "Connecting…", tone: "accent" }
  if (s.phase === "connected") {
    var since = Number(nowSeconds) - s.startedAt
    var age = s.startedAt > 0 && since >= 0 ? " · " + formatDuration(since) : ""
    return { label: "Connected" + age, tone: "active" }
  }
  if (s.phase === "stopped") return { label: "Disconnected", tone: "dim" }
  // A drop gets the same neutral tone as a deliberate disconnect. It is worth
  // reporting, not worth painting as something the user broke.
  if (isDroppedSession(s)) return { label: describeEnd(s), tone: "dim" }
  if (isFailureExit(s.exitCode)) {
    return { label: describeEnd(s), tone: "urgent" }
  }
  // Checked after the failure case on purpose: 4 and 7 are session-end codes
  // too, but a logon timeout or a refused connection is a failure. What is
  // left here is the ordinary endings, which are worth naming. "Signed out on
  // the remote machine" tells the user more than a flat "Not connected".
  if (isSessionEndCode(s.exitCode)) return { label: describeEnd(s), tone: "dim" }
  return { label: "Not connected", tone: "dim" }
}

function tooltipFor(connections, sessions, nowSeconds) {
  var conns = asList(connections)
  var map = sessionMap(sessions)
  var live = []
  for (var i = 0; i < conns.length; i++) {
    var c = normalizeConnection(conns[i])
    var s = map[c.id]
    if (!isLive(s)) continue
    var status = rowStatus(s, nowSeconds)
    live.push(c.name + " — " + status.label.toLowerCase())
  }
  if (live.length) return "RDP: " + live.join(", ")

  var summary = summarize(sessions)
  if (summary.failed > 0) {
    for (var j = 0; j < conns.length; j++) {
      var cc = normalizeConnection(conns[j])
      var ss = map[cc.id]
      if (ss && ss.phase === "exited" && isFailureExit(ss.exitCode)) {
        return "RDP: " + cc.name + " — " + (ss.message || describeExit(ss.exitCode))
      }
    }
  }
  if (!conns.length) return "RDP: no connections saved yet"
  return "RDP: " + conns.length + (conns.length === 1 ? " connection" : " connections") + ", none active"
}

function heroMeta(connections, sessions) {
  var n = asList(connections).length
  var summary = summarize(sessions)
  var parts = [n + (n === 1 ? " connection" : " connections")]
  if (summary.connected > 0) parts.push(summary.connected + " connected")
  if (summary.connecting > 0) parts.push(summary.connecting + " connecting")
  return parts.join(" · ")
}

// ------------------------------------------------------------- list mutation

function upsertConnection(connections, conn) {
  var list = asList(connections)
  var next = []
  var replaced = false
  var incoming = normalizeConnection(conn)
  for (var i = 0; i < list.length; i++) {
    var existing = normalizeConnection(list[i])
    if (existing.id === incoming.id) { next.push(incoming); replaced = true }
    else next.push(existing)
  }
  if (!replaced) next.push(incoming)
  return next
}

function removeConnection(connections, id) {
  var list = asList(connections)
  var next = []
  for (var i = 0; i < list.length; i++) {
    var c = normalizeConnection(list[i])
    if (c.id !== str(id)) next.push(c)
  }
  return next
}

function findConnection(connections, id) {
  var list = asList(connections)
  for (var i = 0; i < list.length; i++) {
    var c = normalizeConnection(list[i])
    if (c.id === str(id)) return c
  }
  return null
}

// A blank connection for the create form. Seeded with the defaults that make
// the common case one field of typing.
function blankConnection() {
  return {
    id: "",
    name: "",
    host: "",
    port: DEFAULT_PORT,
    user: "",
    domain: "",
    secret: "keyring",
    drives: [],
    options: { displayMode: "fixed", resolution: "auto", clipboard: true, cert: "tofu", scale: "100" }
  }
}

if (typeof module !== "undefined") module.exports = {
  asList, slugify, isValidId, uniqueId,
  normalizeDrive, normalizeDrives, normalizeOptions, normalizeScale, normalizePort,
  splitHostPort, normalizeConnection,
  parseConfig, serializeConfig, validateConnection,
  wmClassFor, buildArgs, previewArgs, previewCommand,
  describeExit, describeEnd, isFailureExit, isSessionEndCode, isDroppedSession,
  EXIT_MESSAGES, NORMAL_END_CODES,
  normalizeSession, parseStatus, sessionMap, isLive, summarize, pollInterval,
  formatDuration, endpointFor, formatHostPort, driveSummary, rowStatus, tooltipFor, heroMeta,
  upsertConnection, removeConnection, findConnection, blankConnection,
  autoResolution, parseResolution, normalizeResolution, normalizeDisplayMode, resolveResolution,
  DEFAULT_PORT, CERT_POLICIES, DISPLAY_MODES, COMMON_RESOLUTIONS, SCALE_VALUES,
  AUTO_MAX_WIDTH, AUTO_MAX_HEIGHT
}
