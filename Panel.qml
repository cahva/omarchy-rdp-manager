import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar button and its popup, built once per monitor.
//
// This file owns no session state, no timer that matters and no file write: all
// of that lives in Service.qml, which the shell loads exactly once. The popup's
// content — the list, the form, the delete confirmation — is ConnectionsView,
// which the service's window hosts too; this file only decides how the bar
// button behaves and where the popup goes.
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
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------ engine state

  readonly property var connections: svc ? svc.connections : []
  readonly property var summary: svc ? svc.summary : Model.summarize([])
  readonly property int nowSeconds: svc ? svc.nowSeconds : 0

  // Settings live inline on this widget's shell.json entry.
  readonly property bool notifyOnDisconnect: setting("notifyOnDisconnect", true)
  readonly property bool hideWhenIdle: setting("hideWhenIdle", false)

  // The window and IPC connect through the service, which has no widget entry
  // of its own to read this from. Every monitor's widget carries the same
  // value, so it does not matter which copy the binding lands from.
  Binding {
    target: root.svc
    property: "notifyOnDisconnect"
    value: root.notifyOnDisconnect
    when: !!root.svc
  }

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

  // The popup gets out of the way first: the window is the same view, larger,
  // and leaving both up would show the list twice.
  function openWindow() {
    root.close()
    if (svc) svc.showWindow()
  }

  // ------------------------------------------------------------- the bar item

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\u{F08B9}"                                  // nf-md-remote-desktop
    active: root.barState === "connected"
    tooltipText: root.barTooltip
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton && root.svc) root.svc.refresh()
      else if (buttonCode === Qt.MiddleButton) root.openWindow()
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
    focusTarget: view.keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    // No explicit cap: fittedContentHeight already clamps to the space the screen
    // actually has (availableCardHeight). A fixed cap clipped the edit form's
    // Save/Cancel row off the bottom on a display with plenty of room to spare.
    contentHeight: panel.fittedContentHeight(view.contentHeight)

    ConnectionsView {
      id: view
      anchors.fill: parent
      svc: root.svc
      foreground: root.foreground
      urgent: root.urgent
      accent: root.accent
      fontFamily: root.fontFamily
      notifyOnDisconnect: root.notifyOnDisconnect
      surfaceOpen: root.opened
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onOpenWindowRequested: root.openWindow()
    }
  }
}
