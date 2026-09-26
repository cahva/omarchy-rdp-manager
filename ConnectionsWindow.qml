import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// The popup's content as an ordinary window: resizable, tileable, and free to
// stay open while the bar's popup comes and goes. Hosted inside the shell
// process (the way Omarchy's own dev gallery is), so it reads the same service
// the popup does rather than running a second poll.
//
// Service.qml creates this on first use and keeps it; showWindow() and
// hideWindow() there flip `visible`.
FloatingWindow {
  id: win

  property var svc: null

  title: "RDP Manager"
  color: Color.background
  implicitWidth: 720
  implicitHeight: 640
  minimumSize: Qt.size(480, 400)
  visible: false

  // Keyboard-first, like the popup: the key catcher must own focus once the
  // surface is mapped, or j/k/Enter go nowhere until something is clicked.
  onVisibleChanged: if (visible) Qt.callLater(function() { view.keyCatcher.forceActiveFocus() })

  ConnectionsView {
    id: view
    anchors.fill: parent
    // Inset from the edge: Hyprland rounds the corners, and text flush to the
    // border is clipped by the radius.
    anchors.margins: Style.space(12)
    svc: win.svc
    inWindow: true
    surfaceOpen: win.visible
    notifyOnDisconnect: win.svc ? win.svc.notifyOnDisconnect : true
    // The bar animates its colours for transparency modes; a window has no bar,
    // so the theme singletons are the right source here.
    foreground: Color.foreground
    urgent: Color.urgent
    accent: Color.accent
    fontFamily: Style.font.family
    // Esc with nothing left to unwind closes the window, as it closes the popup.
    onCloseRequested: win.visible = false
  }
}
