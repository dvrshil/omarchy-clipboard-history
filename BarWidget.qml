import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bar icon for dvrshil.clipboard. Left click opens the history; right click
// opens it filtered to images.
BarWidget {
  id: root
  moduleName: "dvrshil.clipboard"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\u{f0147}"   // nf-md-clipboard_text_outline
    tooltipText: strings.t("bar.tooltip") + (String(root.setting("shortcut", "")) ? "  ·  " + String(root.setting("shortcut", "")) : "")
    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton) root.bar.run("omarchy-shell shell toggle dvrshil.clipboard '{\"type\":\"image\"}'")
      else root.bar.run("omarchy-shell shell toggle dvrshil.clipboard")
    }
  }
}
