import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar button and its popup, built once per monitor.
//
// This file owns no session state, no timer that matters and no file write: all
// of that lives in Service.qml, which the shell loads exactly once. Everything
// here is a view onto that engine plus this popup's own cursor, scroll position
// and form fields — the things that genuinely differ per screen.
Panel {
  id: root
  moduleName: "io.github.cahva.rdp-manager"

  // Service.qml owns the `io.github.cahva.rdp-manager` IPC target. A widget registering it
  // would register it once per monitor, and only the first registration is used.
  manageIpc: false

  // The host may replace moduleName with an instance id; keep the manifest id
  // stable for registry lookups.
  readonly property string manifestPluginId: "io.github.cahva.rdp-manager"

  readonly property var svc: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(manifestPluginId)
    : null

  // ------------------------------------------------------------------ styling

  // Read through `bar` where possible: it animates its colours and handles
  // transparency-mode contrast, which the raw Color singleton does not.
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string glyphIdle: "\u{F08B9}"      // nf-md-remote-desktop
  readonly property string glyphConnect: "\u{F0318}"   // nf-md-lan-connect
  readonly property string glyphDisconnect: "\u{F0319}" // nf-md-lan-disconnect
  readonly property string glyphFocus: "\u{F03CC}"     // nf-md-open-in-new
  readonly property string glyphEdit: "\u{F03EB}"      // nf-md-pencil
  readonly property string glyphDelete: "\u{F01B4}"    // nf-md-delete
  readonly property string glyphTest: "\u{F0450}"      // nf-md-refresh
  readonly property string glyphAdd: "\u{F0415}"       // nf-md-plus

  function toneColor(tone) {
    if (tone === "urgent") return root.urgent
    if (tone === "active") return root.foreground
    if (tone === "accent") return root.accent
    return root.dim
  }

  // ------------------------------------------------------------ engine state

  readonly property var connections: svc ? svc.connections : []
  readonly property var summary: svc ? svc.summary : Model.summarize([])
  readonly property int nowSeconds: svc ? svc.nowSeconds : 0
  readonly property string engineError: svc
    ? (svc.configError || svc.errorText)
    : "The RDP manager service is not loaded."

  function sessionFor(id) { return svc ? svc.sessionFor(id) : null }

  // Settings live inline on this widget's shell.json entry.
  readonly property bool notifyOnDisconnect: setting("notifyOnDisconnect", true)
  readonly property bool hideWhenIdle: setting("hideWhenIdle", false)

  // ---------------------------------------------------------- per-view state

  // "list" | "form"
  property string view: "list"
  property int selectedIndex: -1
  property bool cursorActive: false
  property string confirmDeleteId: ""

  // Form state. Held here rather than in the service because two monitors can
  // have the form open on different connections at the same time.
  property bool formIsNew: true
  property string formId: ""
  property string formName: ""
  property string formHost: ""
  property string formUser: ""
  property string formPassword: ""
  property string formCert: "tofu"
  // One of Model.SCALE_VALUES — the only three FreeRDP's /scale: accepts.
  property string formScale: "100"
  // "auto", one of Model.COMMON_RESOLUTIONS, or "custom". The literal size a
  // custom choice stands for lives in formResolutionCustom.
  property string formDisplayMode: "fixed"
  property string formResolution: "auto"
  property string formResolutionCustom: ""
  property bool formClipboard: true
  property var formErrors: ({})
  property string formNotice: ""

  readonly property bool editingSecretExists: svc && root.formId ? svc.hasSecret(root.formId) : false

  // ---------------------------------------------------------- bar appearance

  readonly property string barState: summary.state
  readonly property bool anyActive: barState === "connected" || barState === "connecting"
  readonly property string barTooltip: Model.tooltipFor(connections, svc ? svc.sessions : [], nowSeconds)

  // hideWhenIdle keeps the icon out of the way, but never while the popup is
  // open — the button is the popup's anchor, so hiding it would strand it.
  readonly property bool iconVisible: !hideWhenIdle || anyActive || opened

  implicitWidth: iconVisible ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight
  visible: iconVisible

  // -------------------------------------------------------------- navigation

  function rowCount() { return Model.asList(root.connections).length }

  function ensureCursor() {
    var n = rowCount()
    if (n === 0) { selectedIndex = -1; return }
    if (selectedIndex >= n) selectedIndex = n - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (root.view !== "list") return
    ensureCursor()
    if (dy === 0 || rowCount() === 0) return
    selectedIndex = Math.max(0, Math.min(rowCount() - 1, selectedIndex + dy))
  }

  function selectedConnection() {
    var list = Model.asList(root.connections)
    if (selectedIndex < 0 || selectedIndex >= list.length) return null
    return list[selectedIndex]
  }

  function activateCursor() {
    if (root.view !== "list") return
    var conn = selectedConnection()
    if (conn) root.activate(conn.id)
  }

  // Enter on a row does the obvious thing for its current state.
  function activate(id) {
    if (!svc) return
    var s = root.sessionFor(id)
    if (s && s.phase === "connected") svc.focusSession(id)
    else if (s && s.phase === "connecting") svc.disconnect(id)
    else svc.connect(id, { notify: root.notifyOnDisconnect })
  }

  function onTextKey(t) {
    if (root.view !== "list") return
    var key = String(t).toLowerCase()
    if (key === "n") { root.openForm(null); return }
    var conn = selectedConnection()
    if (!conn) return
    if (key === "e") root.openForm(conn)
    else if (key === "d") root.confirmDeleteId = conn.id
    else if (key === "t" && svc) svc.testConnection(conn.id)
    else if (key === "x" && svc) svc.disconnect(conn.id)
    else if (key === "c" && svc) svc.connect(conn.id, { notify: root.notifyOnDisconnect })
  }

  // ------------------------------------------------------------------- forms

  // The dropdown offers auto, a few common sizes and "custom". A saved value
  // that is neither auto nor on the list has to land in the custom field, or
  // opening a hand-edited connection would silently reset its resolution to
  // whatever the dropdown happened to show.
  function loadResolution(resolution) {
    var value = String(resolution || "auto")
    if (value === "auto" || Model.COMMON_RESOLUTIONS.indexOf(value) !== -1) {
      root.formResolution = value
      root.formResolutionCustom = ""
    } else {
      root.formResolution = "custom"
      root.formResolutionCustom = value
    }
  }

  function currentResolution() {
    return root.formResolution === "custom" ? root.formResolutionCustom : root.formResolution
  }

  // Built once: the list is static, and a binding whose body is a statement
  // block reads ambiguously in QML.
  function buildResolutionOptions() {
    var out = [{ value: "auto", label: "auto: match this screen, capped at 2560x1440" }]
    for (var i = 0; i < Model.COMMON_RESOLUTIONS.length; i++) {
      out.push({ value: Model.COMMON_RESOLUTIONS[i], label: Model.COMMON_RESOLUTIONS[i] })
    }
    out.push({ value: "custom", label: "custom size..." })
    return out
  }

  readonly property var resolutionOptions: root.buildResolutionOptions()

  function openForm(conn) {
    root.formErrors = ({})
    root.formNotice = ""
    root.formPassword = ""
    if (conn) {
      root.formIsNew = false
      root.formId = conn.id
      root.formName = conn.name
      root.formHost = conn.host
      root.formUser = conn.user
      root.formCert = conn.options.cert
      root.formScale = conn.options.scale
      root.formDisplayMode = conn.options.displayMode
      root.loadResolution(conn.options.resolution)
      root.formClipboard = conn.options.clipboard
      loadDrives(conn.drives)
      if (svc) svc.probeSecret(conn.id)
    } else {
      var blank = Model.blankConnection()
      root.formIsNew = true
      root.formId = ""
      root.formName = ""
      root.formHost = ""
      root.formUser = ""
      root.formCert = blank.options.cert
      root.formScale = blank.options.scale
      root.formDisplayMode = blank.options.displayMode
      root.loadResolution(blank.options.resolution)
      root.formClipboard = blank.options.clipboard
      loadDrives([])
    }
    root.view = "form"
  }

  function closeForm() {
    root.view = "list"
    root.formPassword = ""
    root.formErrors = ({})
    root.formNotice = ""
  }

  // Drives live in a ListModel rather than a plain array because reassigning an
  // array rebuilds the Repeater's delegates, which would drop focus and the
  // caret position out of whichever field is being typed into.
  function loadDrives(drives) {
    driveModel.clear()
    var list = Model.asList(drives)
    for (var i = 0; i < list.length; i++) {
      driveModel.append({ driveName: String(list[i].name || ""), drivePath: String(list[i].path || "") })
    }
  }

  function drivesFromModel() {
    var out = []
    for (var i = 0; i < driveModel.count; i++) {
      var row = driveModel.get(i)
      out.push({ name: row.driveName, path: row.drivePath })
    }
    return out
  }

  function formConnection() {
    var id = root.formIsNew && svc ? svc.newIdFor(root.formName) : root.formId
    return {
      id: id,
      name: root.formName,
      host: root.formHost,
      // No port field in this version; preserve whatever is on disk.
      port: root.formIsNew ? Model.DEFAULT_PORT : (svc && svc.connectionFor(root.formId)
        ? svc.connectionFor(root.formId).port : Model.DEFAULT_PORT),
      user: root.formUser,
      domain: root.formIsNew ? "" : (svc && svc.connectionFor(root.formId)
        ? svc.connectionFor(root.formId).domain : ""),
      secret: "keyring",
      drives: root.drivesFromModel(),
      options: {
        displayMode: root.formDisplayMode,
        resolution: root.currentResolution(),
        clipboard: root.formClipboard,
        cert: root.formCert,
        scale: root.formScale
      }
    }
  }

  function saveForm() {
    if (!svc) return
    var conn = root.formConnection()
    if (!conn.id) {
      root.formErrors = { name: "Give the connection a name" }
      return
    }
    var verdict = svc.saveConnection(conn)
    root.formErrors = verdict.errors
    if (!verdict.ok) return
    // A blank password on an edit means "keep the stored one".
    if (root.formPassword) svc.storeSecret(conn.id, root.formPassword, "Omarchy RDP: " + conn.name)
    root.formPassword = ""
    root.closeForm()
  }

  function deleteConfirmed() {
    if (svc && root.confirmDeleteId) svc.removeConnection(root.confirmDeleteId)
    root.confirmDeleteId = ""
    root.ensureCursor()
  }

  // Reset transient view state whenever the popup closes, so reopening never
  // shows a half-filled form or a stale error from last time.
  onOpenedChanged: {
    if (opened) {
      if (svc) svc.refresh()
      root.cursorActive = false
      root.ensureCursor()
    } else {
      root.view = "list"
      root.formPassword = ""
      root.confirmDeleteId = ""
      root.formNotice = ""
    }
  }

  ListModel { id: driveModel }

  Connections {
    target: root.svc
    ignoreUnknownSignals: true
    function onActionFailed(id, message) { root.formNotice = message }
  }

  // ------------------------------------------------------------- the bar item

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyphIdle
    active: root.barState === "connected"
    tooltipText: root.barTooltip
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton && root.svc) root.svc.refresh()
      else root.toggle()
    }

    // Session count, once a single glyph stops being unambiguous. A corner badge
    // rather than labelVisible, which would re-draw `text` — the glyph itself —
    // centred on top of the icon.
    Text {
      visible: root.summary.connected > 1
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: Style.space(1)
      anchors.topMargin: Style.space(1)
      text: String(root.summary.connected)
      color: root.bar ? root.bar.urgent : root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      renderType: Text.NativeRendering
    }

    // A connecting session is the one state worth animating: it says "working"
    // without needing a second glyph.
    SequentialAnimation on opacity {
      running: root.barState === "connecting"
      loops: Animation.Infinite
      alwaysRunToEnd: true
      NumberAnimation { to: 0.45; duration: 700; easing.type: Easing.InOutQuad }
      NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
    }
  }

  // A failed last attempt tints the glyph without stealing the `active` slot a
  // live session uses.
  Binding {
    target: button
    property: "foreground"
    value: root.urgent
    when: root.barState === "failed" && !!root.bar
  }

  // ---------------------------------------------------------------- the popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    // No explicit cap: fittedContentHeight already clamps to the space the screen
    // actually has (availableCardHeight). A fixed cap clipped the edit form's
    // Save/Cancel row off the bottom on a display with plenty of room to spare.
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The form's text fields own the keyboard while they are up; only events
      // the focused subtree ignores should reach the list's state machine. The
      // confirm dialog is NOT blocked here — it has no focus item of its own, so
      // the catcher has to drive it, otherwise Esc/Enter/Tab are dead and it can
      // only be answered with the mouse.
      blocked: root.view === "form"

      // While the confirm dialog is up it owns every key: left/right pick a
      // button, Enter commits the highlighted one, Esc backs out. Nothing may
      // fall through to the list underneath.
      readonly property bool confirming: root.confirmDeleteId !== ""

      onMoveRequested: function(dx, dy) {
        if (confirming) {
          if (dx !== 0) deleteConfirm.selectedIndex = deleteConfirm.selectedIndex === 0 ? 1 : 0
          return
        }
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: {
        if (confirming) {
          if (deleteConfirm.selectedIndex === 0) root.confirmDeleteId = ""
          else root.deleteConfirmed()
          return
        }
        if (root.cursorActive) root.activateCursor()
      }
      onReturnRequested: {
        if (!confirming) return
        if (deleteConfirm.selectedIndex === 0) root.confirmDeleteId = ""
        else root.deleteConfirmed()
      }
      onCloseRequested: {
        if (confirming) { root.confirmDeleteId = ""; return }
        root.close()
      }
      onTabRequested: function(direction) {
        if (confirming) {
          deleteConfirm.selectedIndex = deleteConfirm.selectedIndex === 0 ? 1 : 0
          return
        }
        root.switchPanel(direction)
      }
      onDeleteRequested: {
        if (confirming) return
        var conn = root.selectedConnection()
        if (conn) root.confirmDeleteId = conn.id
      }
      onTextKey: function(t) { if (!confirming) root.onTextKey(t) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: root.view === "form"
              ? (root.formIsNew ? "New connection" : "Edit connection")
              : "RDP Manager"
            meta: root.view === "form"
              ? (root.formIsNew ? "Saved to connections.json" : root.formId)
              : Model.heroMeta(root.connections, root.svc ? root.svc.sessions : [])
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: root.glyphIdle
                color: root.anyActive ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // Engine-level problems: an unparseable config, a status helper that
          // will not run. Shown above everything because nothing below it can be
          // trusted while one is true.
          Text {
            visible: root.engineError !== ""
            width: parent.width
            text: root.engineError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.formNotice !== ""
            width: parent.width
            text: root.formNotice
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // -------------------------------------------------------- list view

          Column {
            visible: root.view === "list"
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "CONNECTIONS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: root.rowCount() === 0
              width: parent.width
              text: "No connections yet. Press n to add one."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }

            Column {
              id: rowColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.connections
                ConnectionRow {
                  required property var modelData
                  required property int index
                  width: rowColumn.width
                  conn: modelData
                  rowIndex: index
                }
              }
            }

            PanelSeparator {
              visible: root.rowCount() > 0
              foreground: root.foreground
            }

            Button {
              width: parent.width
              text: "New connection"
              iconText: root.glyphAdd
              leftAlign: true
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              tooltipText: "Add a saved RDP connection  (n)"
              onClicked: root.openForm(null)
            }

            Text {
              visible: root.rowCount() > 0
              width: parent.width
              text: "enter connect / focus · c connect · x disconnect · e edit · t test · d delete · n new"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // -------------------------------------------------------- form view

          // Rebuilt on every open. Typing into a TextField replaces its `text`
          // binding with an imperative value, so a form that merely toggled
          // `visible` would still be showing the previous connection's fields.
          // Loader takes its width from us and its height from the item.
          Loader {
            id: formLoader
            width: column.width
            // Bind the height explicitly. A deactivated Loader keeps reporting the
            // implicit height of the item it just destroyed, so after the form had
            // been open once the popup card stayed form-tall on the list view,
            // leaving a large empty area below the rows. Verified in both
            // directions: the form grows the card, closing it shrinks it back.
            height: active && item ? item.implicitHeight : 0
            active: root.view === "form"
            sourceComponent: formComponent
          }
        }
      }

      // Delete is the one destructive action here, and the keyboard path (d) is
      // a single keystroke — so it gets a confirmation rather than an undo.
      ConfirmDialog {
        id: deleteConfirm
        anchors.fill: parent
        z: 10
        opened: root.confirmDeleteId !== ""
        // Reset the highlight to Delete each time, so a dialog answered with
        // "Keep" last time does not open pre-armed on the destructive button in a
        // different position than the user expects.
        onOpenedChanged: if (opened) selectedIndex = 1
        message: root.confirmDeleteId === "" ? "" :
          "Delete \"" + (root.svc && root.svc.connectionFor(root.confirmDeleteId)
            ? root.svc.connectionFor(root.confirmDeleteId).name : root.confirmDeleteId)
          + "\"?\nIts stored password is removed too."
        confirmText: "Delete"
        cancelText: "Keep"
        foreground: root.foreground
        onConfirmed: root.deleteConfirmed()
        onCanceled: root.confirmDeleteId = ""
      }
    }
  }


  // The edit/create form, instantiated fresh by the Loader above each time the
  // view switches to "form".
  Component {
    id: formComponent

    Column {
      width: parent.width
      spacing: Style.space(10)

            FormField {
              width: parent.width
              label: "Name"
              text: root.formName
              placeholder: "Windows build server"
              errorText: root.formErrors.name || ""
              autoFocus: true
              onEdited: function(t) { root.formName = t }
              onSubmitted: root.saveForm()
            }

            FormField {
              width: parent.width
              label: "Host"
              text: root.formHost
              placeholder: "rdp.example.com"
              errorText: root.formErrors.host || ""
              onEdited: function(t) { root.formHost = t }
              onSubmitted: root.saveForm()
            }

            FormField {
              width: parent.width
              label: "Username"
              text: root.formUser
              placeholder: "Administrator"
              errorText: root.formErrors.user || ""
              onEdited: function(t) { root.formUser = t }
              onSubmitted: root.saveForm()
            }

            FormField {
              width: parent.width
              label: "Password"
              text: root.formPassword
              isPassword: true
              // On an edit, an empty field means "keep the stored password" —
              // say so, rather than letting it read as "no password set".
              placeholder: root.formIsNew
                ? "Stored in the system keyring"
                : (root.editingSecretExists ? "Stored — leave blank to keep it" : "No password stored yet")
              hint: root.formIsNew
                ? "Saved to gnome-keyring, never to connections.json"
                : ""
              onEdited: function(t) { root.formPassword = t }
              onSubmitted: root.saveForm()
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "DRIVE REDIRECTION"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: driveModel.count === 0
              width: parent.width
              text: "No folders shared with the remote machine."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Column {
              id: driveColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: driveModel
                DriveRow {
                  required property int index
                  width: driveColumn.width
                  rowIndex: index
                }
              }
            }

            Button {
              width: parent.width
              text: "Add drive"
              iconText: root.glyphAdd
              leftAlign: true
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: driveModel.append({ driveName: "", drivePath: "" })
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "OPTIONS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Dropdown {
              width: parent.width
              label: "Display mode"
              value: root.formDisplayMode
              fontFamily: root.fontFamily
              // One choice rather than two toggles: FreeRDP exits 22 if
              // /smart-sizing and +dynamic-resolution are both passed.
              options: [
                { value: "fixed", label: "fixed: one size, resizing letterboxes" },
                { value: "scaled", label: "scaled: desktop scales to the window" },
                { value: "dynamic", label: "dynamic: server resizes the desktop" }
              ]
              onChanged: function(v) { root.formDisplayMode = v }
            }

            // Under "dynamic" the desktop is renegotiated on the first resize,
            // so this is only the size the window opens at. Calling it a
            // resolution there would be a lie, but hiding it would take away
            // the one thing that stops the window opening tiny.
            Dropdown {
              width: parent.width
              label: root.formDisplayMode === "dynamic" ? "Starting size" : "Resolution"
              value: root.formResolution
              fontFamily: root.fontFamily
              options: root.resolutionOptions
              onChanged: function(v) { root.formResolution = v }
            }

            Text {
              visible: root.formDisplayMode === "dynamic"
              width: parent.width
              text: "The desktop follows the window after that."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            FormField {
              visible: root.formResolution === "custom"
              width: parent.width
              label: "Custom resolution"
              text: root.formResolutionCustom
              placeholder: "1920x1080"
              errorText: root.formErrors.resolution || ""
              onEdited: function(t) { root.formResolutionCustom = t }
              onSubmitted: root.saveForm()
            }

            // FreeRDP's /scale: only accepts these three values (xfreerdp3
            // --help) — this is DPI scaling of the remote desktop's own UI,
            // not the window-resize behavior above, and the two combine.
            Dropdown {
              width: parent.width
              label: "Display scale"
              value: root.formScale
              fontFamily: root.fontFamily
              options: [
                { value: "100", label: "100% — normal" },
                { value: "140", label: "140% — medium" },
                { value: "180", label: "180% — large" }
              ]
              onChanged: function(v) { root.formScale = v }
            }

            OptionToggle {
              width: parent.width
              label: "Share clipboard"
              detail: "Copy and paste between this machine and the remote"
              checked: root.formClipboard
              onToggledOption: root.formClipboard = !root.formClipboard
            }

            Dropdown {
              width: parent.width
              label: "Certificate policy"
              value: root.formCert
              fontFamily: root.fontFamily
              options: [
                { value: "tofu", label: "tofu — trust on first use, warn if it changes" },
                { value: "ignore", label: "ignore — accept any certificate" },
                { value: "deny", label: "deny — refuse anything unknown" }
              ]
              onChanged: function(v) { root.formCert = v }
            }

            PanelSeparator { foreground: root.foreground }

            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              Button {
                Layout.fillWidth: true
                text: "Cancel"
                bordered: true
                foreground: root.dim
                fontFamily: root.fontFamily
                onClicked: root.closeForm()
              }

              Button {
                Layout.fillWidth: true
                text: root.formIsNew ? "Create" : "Save"
                bordered: true
                active: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.saveForm()
              }
            }
    }
  }

  // ------------------------------------------------------------- row delegate

  component ConnectionRow: CursorSurface {
    id: row
    required property var conn
    required property int rowIndex

    readonly property var session: root.sessionFor(row.conn.id)
    readonly property var status: Model.rowStatus(row.session, root.nowSeconds)
    readonly property bool live: Model.isLive(row.session)
    readonly property bool connected: !!row.session && row.session.phase === "connected"
    readonly property bool testing: !!root.svc && root.svc.testingId === row.conn.id
    readonly property bool showTestResult: !!root.svc && root.svc.testResultId === row.conn.id
      && root.svc.testResult !== ""

    hasCursor: root.cursorActive && root.selectedIndex === row.rowIndex
    foreground: root.foreground
    implicitHeight: rowBody.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.selectedIndex = row.rowIndex }
      onClicked: root.activate(row.conn.id)
    }

    Item {
      id: rowBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      implicitHeight: textCol.implicitHeight

      Column {
        id: textCol
        anchors.left: parent.left
        anchors.right: actions.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.hairline

        Text {
          width: parent.width
          text: row.conn.name
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: Model.endpointFor(row.conn)
            + (Model.driveSummary(row.conn) ? "  ·  " + Model.driveSummary(row.conn) : "")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: row.testing
            ? "Testing…"
            : (row.showTestResult ? root.svc.testResult : row.status.label)
          color: row.testing
            ? root.accent
            : (row.showTestResult
                ? (root.svc.testOk ? root.foreground : root.urgent)
                : root.toneColor(row.status.tone))
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Row {
        id: actions
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        PanelActionButton {
          visible: row.connected
          iconText: root.glyphFocus
          tooltipText: "Focus the session window"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: if (root.svc) root.svc.focusSession(row.conn.id)
        }

        PanelActionButton {
          visible: !row.live
          iconText: root.glyphConnect
          tooltipText: "Connect  (c)"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: if (root.svc) root.svc.connect(row.conn.id, { notify: root.notifyOnDisconnect })
        }

        PanelActionButton {
          visible: row.live
          iconText: root.glyphDisconnect
          tooltipText: row.connected ? "Disconnect  (x)" : "Cancel  (x)"
          foreground: root.urgent
          fontFamily: root.fontFamily
          onClicked: if (root.svc) root.svc.disconnect(row.conn.id)
        }

        PanelActionButton {
          visible: !row.live
          iconText: root.glyphTest
          tooltipText: "Test the connection without opening a window  (t)"
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: !!root.svc && root.svc.testingId === ""
          onClicked: if (root.svc) root.svc.testConnection(row.conn.id)
        }

        PanelActionButton {
          iconText: root.glyphEdit
          tooltipText: "Edit  (e)"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.openForm(row.conn)
        }

        PanelActionButton {
          iconText: root.glyphDelete
          tooltipText: "Delete  (d)"
          foreground: root.urgent
          fontFamily: root.fontFamily
          onClicked: root.confirmDeleteId = row.conn.id
        }
      }
    }
  }

  // ----------------------------------------------------------- form controls

  component FormField: Column {
    id: field
    property string label: ""
    property string text: ""
    property string placeholder: ""
    property string errorText: ""
    property string hint: ""
    property bool isPassword: false
    // The panel is keyboard-first, so the form has to arrive with a field ready
    // to type into. KeyboardPanel primes focus on the key catcher, which the
    // form blocks — without claiming focus here, keystrokes went nowhere and the
    // form could only be filled in with the mouse.
    property bool autoFocus: false
    signal edited(string value)
    signal submitted()

    spacing: Style.spacing.labelGap

    Text {
      text: field.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    TextField {
      id: input
      width: field.width
      text: field.text
      password: field.isPassword
      placeholderText: field.placeholder
      foreground: root.foreground
      // Bind one way only: writing back into `text` on every keystroke would
      // reset the caret to the end mid-word.
      onTextChanged: if (text !== field.text) field.edited(text)
      onAccepted: field.submitted()
      Component.onCompleted: if (field.autoFocus) input.forceActiveFocus()
      // Esc backs out of the form rather than closing the whole popup, which is
      // what a half-filled form makes you want.
      Keys.onEscapePressed: root.closeForm()
    }

    Text {
      visible: field.errorText !== "" || field.hint !== ""
      width: field.width
      text: field.errorText !== "" ? field.errorText : field.hint
      color: field.errorText !== "" ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  component DriveRow: Item {
    id: driveRow
    required property int rowIndex

    readonly property string nameError: root.formErrors["drive." + driveRow.rowIndex + ".name"] || ""
    readonly property string pathError: root.formErrors["drive." + driveRow.rowIndex + ".path"] || ""

    implicitHeight: driveBody.implicitHeight

    Column {
      id: driveBody
      width: parent.width
      spacing: Style.spacing.labelGap

      RowLayout {
        width: parent.width
        spacing: Style.space(6)

        TextField {
          Layout.preferredWidth: Style.space(96)
          text: driveModel.count > driveRow.rowIndex ? driveModel.get(driveRow.rowIndex).driveName : ""
          placeholderText: "share"
          foreground: root.foreground
          Keys.onEscapePressed: root.closeForm()
          onAccepted: root.saveForm()
          onTextChanged: if (driveModel.count > driveRow.rowIndex
              && text !== driveModel.get(driveRow.rowIndex).driveName) {
            driveModel.setProperty(driveRow.rowIndex, "driveName", text)
          }
        }

        TextField {
          Layout.fillWidth: true
          text: driveModel.count > driveRow.rowIndex ? driveModel.get(driveRow.rowIndex).drivePath : ""
          placeholderText: "/home/you/folder"
          foreground: root.foreground
          Keys.onEscapePressed: root.closeForm()
          onAccepted: root.saveForm()
          onTextChanged: if (driveModel.count > driveRow.rowIndex
              && text !== driveModel.get(driveRow.rowIndex).drivePath) {
            driveModel.setProperty(driveRow.rowIndex, "drivePath", text)
          }
        }

        PanelActionButton {
          iconText: root.glyphDelete
          tooltipText: "Remove this drive"
          foreground: root.urgent
          fontFamily: root.fontFamily
          onClicked: driveModel.remove(driveRow.rowIndex)
        }
      }

      Text {
        visible: driveRow.nameError !== "" || driveRow.pathError !== ""
        width: parent.width
        text: driveRow.nameError !== "" ? driveRow.nameError : driveRow.pathError
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  component OptionToggle: Item {
    id: option
    property string label: ""
    property string detail: ""
    property bool checked: false
    signal toggledOption()

    implicitHeight: Math.max(optionText.implicitHeight, optionSwitch.implicitHeight)

    Column {
      id: optionText
      anchors.left: parent.left
      anchors.right: optionSwitch.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.hairline

      Text {
        width: parent.width
        text: option.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        visible: option.detail !== ""
        width: parent.width
        text: option.detail
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    ToggleSwitch {
      id: optionSwitch
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: option.checked
      foreground: root.foreground
      onToggled: option.toggledOption()
    }
  }
}
