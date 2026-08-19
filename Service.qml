import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The engine for cahva.rdp-manager, loaded exactly once per shell session
// (manifest kind: "service").
//
// Everything there can only be one of lives here: the connection list, the
// status poll, every write to connections.json and every process launch.
// Panel.qml is built once *per monitor*, so anything stateful placed there gets
// duplicated on a multi-monitor setup — two poll timers, two writers racing the
// same file. Panels reach this singleton through
// `bar.shell.serviceFor("cahva.rdp-manager")`.
Item {
  id: service

  // Injected by omarchy-shell for kind: "service".
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: ({})
  property var barWidgetRegistry: null
  property var pluginRegistry: null

  readonly property string pluginId: "cahva.rdp-manager"
  readonly property string home: Quickshell.env("HOME")

  // The registry stamps __sourceDir onto the manifest at scan time. Fall back to
  // the conventional install path so a hand-dropped copy still works.
  readonly property string sourceDir: manifest && manifest.__sourceDir
    ? String(manifest.__sourceDir)
    : home + "/.config/omarchy/plugins/" + pluginId

  readonly property string launchScript: sourceDir + "/bin/omarchy-rdp-launch"
  readonly property string statusScript: sourceDir + "/bin/omarchy-rdp-status"
  readonly property string disconnectScript: sourceDir + "/bin/omarchy-rdp-disconnect"
  readonly property string secretScript: sourceDir + "/bin/omarchy-rdp-secret"

  readonly property string configDir: home + "/.config/omarchy-rdp"
  readonly property string configPath: configDir + "/connections.json"

  // ------------------------------------------------------------------- state

  property var connections: []
  property var sessions: []
  readonly property var sessionsById: Model.sessionMap(sessions)
  readonly property var summary: Model.summarize(sessions)

  // Wall clock in seconds. Ticked only while something is on screen that needs
  // it, so an idle bar costs nothing. Passed *into* Model.js rather than read
  // there, which is what keeps Model.js testable under node.
  property int nowSeconds: 0

  property string errorText: ""
  property string configError: ""
  property bool configLoaded: false

  // id -> true for connections with a password in the keyring. Probed lazily,
  // because the answer only matters while the edit form is open.
  property var secretKnown: ({})

  signal connectionSaved(string id)
  signal connectionRemoved(string id)
  signal secretProbed(string id, bool present)
  signal actionFailed(string id, string message)

  function connectionFor(id) { return Model.findConnection(connections, id) }
  function sessionFor(id) { return sessionsById[String(id)] || null }
  function isLive(id) { return Model.isLive(sessionFor(id)) }

  // ------------------------------------------------------------- config file

  // True once the file exists on disk. Distinct from configLoaded, which is also
  // set by the first-run miss.
  property bool configExists: false

  function applyConfig(raw) {
    var parsed = Model.parseConfig(raw)
    service.connections = parsed.connections
    service.configError = parsed.error
    service.configLoaded = true
  }

  // FileView cannot watch a file that does not exist, so on a first run the
  // watcher has nothing to attach to and a config created afterwards — by hand,
  // or by another monitor's panel — stays invisible until something forces a
  // reload. Writing an empty document immediately gives the watcher a real file
  // to follow, and leaves the user something to hand-edit that documents the
  // shape. Guarded so a later read error cannot clobber real data.
  function seedConfig() {
    if (service.configExists) return
    service.configExists = true
    persist([])
  }

  // Persist the list. mkdir first because FileView will not create the
  // directory; 0700 keeps hostnames and usernames to this user, even though no
  // secret is ever written here.
  function persist(nextConnections) {
    service.connections = Model.asList(nextConnections)
    mkdirProc.running = true
    configFile.setText(Model.serializeConfig(service.connections))
    return true
  }

  function saveConnection(conn) {
    var taken = []
    for (var i = 0; i < service.connections.length; i++) {
      if (service.connections[i].id !== String(conn.id)) taken.push(service.connections[i].id)
    }
    var verdict = Model.validateConnection(conn, taken)
    if (!verdict.ok) return verdict
    persist(Model.upsertConnection(service.connections, conn))
    service.connectionSaved(String(conn.id))
    return verdict
  }

  function removeConnection(id) {
    persist(Model.removeConnection(service.connections, id))
    // Otherwise the password outlives the connection and a later connection
    // that happened to slug to the same id would silently inherit it.
    deleteSecret(id)
    service.connectionRemoved(String(id))
  }

  function newIdFor(name) {
    var taken = []
    for (var i = 0; i < service.connections.length; i++) taken.push(service.connections[i].id)
    return Model.uniqueId(name, taken)
  }

  // watchChanges is why this is a plain JSON file rather than a database: a
  // hand-edit shows up in the panel with no reload. Our own setText() also
  // trips the watcher, which is harmless — re-parsing is idempotent, and
  // nothing here saves in response to a load.
  FileView {
    id: configFile
    path: service.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      service.configExists = true
      service.applyConfig(text())
    }

    // `watchChanges` only *notifies* — it does not re-read. Verified: editing the
    // file externally emits fileChanged but never a second `loaded`, so without
    // this reload() a hand-edit is detected and then ignored, and the panel keeps
    // showing the connections it read at startup. (Nothing in omarchy's own shell
    // sets watchChanges, so there was no idiom to copy here.)
    onFileChanged: reload()
    // First run: the file does not exist yet. Seed it so the change watcher has
    // something to attach to; without this the widget stays blind to a config
    // created later in the session.
    onLoadFailed: {
      service.applyConfig("")
      service.seedConfig()
    }
    onSaveFailed: service.errorText = "Could not write " + service.configPath
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", "-m", "700", service.configDir]
    // FileView will not create the directory, and mkdir is asynchronous, so the
    // first read is deferred until this has actually finished rather than racing
    // it and reporting a spurious first-run miss.
    onExited: if (!service.configLoaded) configFile.reload()
  }

  // ----------------------------------------------------------------- secrets

  // The password only ever travels over a pipe: written to this helper's stdin,
  // which hands it to secret-tool's stdin. It is never an argv element, so it
  // cannot show up in `ps`.
  function storeSecret(id, password, label) {
    if (!password) return
    secretStoreProc.pendingId = String(id)
    secretStoreProc.pendingPassword = String(password)
    secretStoreProc.command = [service.secretScript, "store", String(id),
                               String(label || ("Omarchy RDP: " + id))]
    secretStoreProc.launched = false
    secretStoreProc.running = true
  }

  Process {
    id: secretStoreProc
    property string pendingId: ""
    property string pendingPassword: ""
    property bool launched: false
    stdinEnabled: true
    onRunningChanged: {
      if (running || launched) return
      // Never silently swallow this: the user typed a password and needs to
      // know it did not get stored.
      pendingPassword = ""
      service.actionFailed(pendingId, "Cannot run the keyring helper — check bin/ is executable")
    }
    onStarted: {
      launched = true
      write(pendingPassword)
      // Closing stdin is what tells secret-tool the secret is complete.
      stdinEnabled = false
      pendingPassword = ""
    }
    onExited: function(exitCode) {
      pendingPassword = ""
      var next = service.secretKnown
      if (exitCode === 0) {
        next[pendingId] = true
        service.secretKnown = next
        service.secretProbed(pendingId, true)
      } else {
        service.actionFailed(pendingId, exitCode === 124
          ? "The keyring did not respond — is it unlocked?"
          : "Could not save the password to the keyring")
      }
    }
  }

  function deleteSecret(id) {
    Quickshell.execDetached([service.secretScript, "delete", String(id)])
    var next = service.secretKnown
    delete next[String(id)]
    service.secretKnown = next
  }

  // Ask whether a password is already stored, so the edit form can say so and
  // treat a blank field as "keep what is there".
  function probeSecret(id) {
    if (!id) return
    secretProbeProc.pendingId = String(id)
    secretProbeProc.command = [service.secretScript, "has", String(id)]
    secretProbeProc.launched = false
    secretProbeProc.running = true
  }

  Process {
    id: secretProbeProc
    property string pendingId: ""
    property bool launched: false
    onStarted: launched = true
    // A spawn failure must leave the answer as "not stored" rather than
    // claiming a password exists that the launcher will not find.
    onRunningChanged: {
      if (running || launched) return
      var next = service.secretKnown
      delete next[pendingId]
      service.secretKnown = next
      service.secretProbed(pendingId, false)
    }
    onExited: function(exitCode) {
      var present = exitCode === 0
      var next = service.secretKnown
      if (present) next[pendingId] = true
      else delete next[pendingId]
      service.secretKnown = next
      service.secretProbed(pendingId, present)
    }
  }

  function hasSecret(id) { return service.secretKnown[String(id)] === true }

  // ----------------------------------------------------------------- actions

  // Detached on purpose. Saving any file under ~/.config/omarchy/plugins
  // hot-reloads this plugin, and `omarchy-restart-shell` replaces the shell
  // outright — a child process would die with us and take the RDP session with
  // it. `setsid -f` cuts the session loose, and the state files the launcher
  // writes are how we find it again afterwards.
  function connect(id, options) {
    var conn = connectionFor(id)
    if (!conn) return
    if (isLive(id)) { focusSession(id); return }
    var argv = ["setsid", "-f", service.launchScript, String(id)]
    if (!options || options.notify !== false) argv.push("--notify")
    Quickshell.execDetached(argv)
    markPending(String(id))
    schedulePoll(500)
  }

  function disconnect(id) {
    Quickshell.execDetached([service.disconnectScript, String(id)])
    schedulePoll(500)
  }

  function focusSession(id) {
    Quickshell.execDetached(["hyprctl", "dispatch", "focuswindow",
                             "class:" + Model.wmClassFor(id)])
  }

  // ------------------------------------------------------------ pending merge

  // A click has to show something immediately, but the launcher needs a moment
  // to write its first state file. Until it does, the status helper reports
  // nothing for that id — so without this the row would flick back to "Not
  // connected" before turning "Connecting…". Pending ids are merged into the
  // session list as synthetic connecting rows, and expire if the launcher never
  // appears (a missing script, a keyring that would not open).
  property var pendingSince: ({})
  readonly property int pendingTimeoutMs: 12000

  function markPending(id) {
    var next = service.pendingSince
    next[id] = Date.now()
    service.pendingSince = next
    service.sessions = mergePending(service.sessions)
  }

  function mergePending(parsed) {
    var list = Model.asList(parsed)
    var byId = {}
    for (var i = 0; i < list.length; i++) byId[String(list[i].id)] = true

    var now = Date.now()
    var nextPending = {}
    var out = list.slice()
    var changed = false

    for (var id in service.pendingSince) {
      var startedMs = Number(service.pendingSince[id])
      // The launcher got far enough to write a state file: it owns the truth now.
      if (byId[id]) { changed = true; continue }
      if (now - startedMs > service.pendingTimeoutMs) {
        changed = true
        out.push({ id: id, pid: 0, phase: "exited", startedAt: 0, exitCode: 1,
                   message: "The launcher never started — check that bin/ is executable" })
        continue
      }
      nextPending[id] = startedMs
      out.push({ id: id, pid: 0, phase: "connecting", startedAt: 0, exitCode: null, message: "" })
    }
    if (changed) service.pendingSince = nextPending
    return out
  }

  // --------------------------------------------------------------- test probe

  // `--test` runs FreeRDP with +auth-only, which authenticates and stops before
  // opening a window. Only ever from the explicit Test button: it hits the
  // network, and a stale stored password on a timer could contribute to an
  // account lockout.
  property string testingId: ""
  property string testResultId: ""
  property string testResult: ""
  property bool testOk: false

  function testConnection(id) {
    if (service.testingId) return
    service.testingId = String(id)
    service.testResultId = ""
    service.testResult = ""
    testProc.command = [service.launchScript, String(id), "--test"]
    testProc.launched = false
    testProc.running = true
  }

  Process {
    id: testProc
    // Same spawn-failure case as statusProc. Left unhandled it would strand
    // testingId, which disables the Test button on every row for good.
    property bool launched: false
    onStarted: launched = true
    onRunningChanged: {
      if (running || launched) return
      var strandedId = service.testingId
      service.testingId = ""
      service.testResultId = strandedId
      service.testOk = false
      service.testResult = "Cannot run the launcher — check bin/ is executable"
    }
    onExited: function(exitCode) {
      var id = service.testingId
      service.testingId = ""
      service.testResultId = id
      service.testOk = exitCode === 0
      // Exit 1 with no FreeRDP involvement is the launcher's own "no password
      // stored" path; anything >= 23 came from FreeRDP.
      if (exitCode === 1) service.testResult = "No password stored yet"
      else service.testResult = exitCode === 0
        ? "Reachable, credentials accepted"
        : Model.describeExit(exitCode)
    }
  }

  // ----------------------------------------------------------------- polling

  Process {
    id: statusProc
    command: [service.statusScript]
    stdout: StdioCollector { id: statusOut; waitForEnd: true }

    // A binary that cannot be spawned at all — missing, or not executable —
    // never emits `exited`. It only drops `running` back to false without ever
    // having emitted `started`, and no exit code arrives because nothing ran a
    // shell on our behalf. Tracking `launched` is the only way to tell that
    // case apart from a helper that ran and failed. Getting this wrong leaves
    // the poll timer un-armed and the widget frozen with nothing on screen to
    // explain why.
    // Cleared by the caller immediately before `running = true`, never in
    // onExited: QProcess emits `finished` before `running` drops, so clearing it
    // there made every successful run look like a failed spawn.
    property bool launched: false
    onStarted: launched = true

    onRunningChanged: {
      if (running || launched) return
      service.errorText = "Cannot run " + service.statusScript
        + " — check that it exists and is executable"
      pollTimer.interval = 30000
      pollTimer.restart()
    }

    onExited: function(exitCode) {
      if (exitCode !== 0) {
        service.errorText = "Status helper failed (exit " + exitCode + ")"
        pollTimer.interval = 10000
        pollTimer.restart()
        return
      }
      var parsed = Model.parseStatus(statusOut.text)
      service.errorText = parsed.error
      service.sessions = service.mergePending(parsed.sessions)
      // Re-arm at the cadence the new state deserves.
      pollTimer.interval = Model.pollInterval(service.summary)
      pollTimer.restart()
    }
  }

  function refresh() {
    if (statusProc.running) return
    statusProc.launched = false
    statusProc.running = true
  }

  // Bring the next poll forward after a user action without disturbing the
  // steady-state cadence.
  function schedulePoll(delayMs) {
    pollTimer.interval = delayMs
    pollTimer.restart()
  }

  Timer {
    id: pollTimer
    interval: 10000
    running: true
    repeat: false
    onTriggered: service.refresh()
  }

  Timer {
    interval: 5000
    repeat: true
    // Only tick while there is a duration on screen to keep current.
    running: service.summary.connected > 0 || service.summary.connecting > 0
    triggeredOnStart: true
    onTriggered: service.nowSeconds = Math.floor(Date.now() / 1000)
  }

  // --------------------------------------------------------------------- IPC

  // Registered here rather than in the panel: an IPC target routes to a single
  // handler, and the panel exists once per monitor.
  IpcHandler {
    target: "cahva.rdp-manager"

    function connect(id: string): string {
      if (!service.connectionFor(id)) return "unknown connection: " + id
      service.connect(id, {})
      return "ok"
    }

    function disconnect(id: string): string {
      service.disconnect(id)
      return "ok"
    }

    function list(): string {
      var out = []
      for (var i = 0; i < service.connections.length; i++) {
        var c = service.connections[i]
        var s = service.sessionFor(c.id)
        out.push(c.id + "\t" + Model.endpointFor(c) + "\t" + (s ? s.phase : "idle"))
      }
      return out.join("\n")
    }

    function status(): string { return JSON.stringify(service.summary) }

    function refresh(): string {
      service.refresh()
      return "ok"
    }
  }

  Component.onCompleted: {
    service.nowSeconds = Math.floor(Date.now() / 1000)
    // mkdirProc.onExited drives the first read once the directory is guaranteed
    // to exist.
    mkdirProc.running = true
    service.refresh()
  }
}
