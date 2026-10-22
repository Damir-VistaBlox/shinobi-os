import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

// The panel: a drop-down under the bar with the things an operator glances at during an
// engagement -- the engagement and whether its scope can be used, which LLM the agent would
// use, the approvals waiting for a human, and what the tools last did. It only shows. What
// it shows is built in PanelModel.js; this file lays it out.
//
// Every Text here is PlainText. The strings come from a log and from files an agent can
// influence (a target it was refused, an approval's reason), and Qt's default format treats a
// string that looks like markup as rich text: an <img> in a refused target made the shell
// fetch the URL when the panel was opened, which is network traffic outside the gate.
//
// It floats over the windows instead of making room for itself (exclusionMode Ignore), so
// opening it never reflows the engagement's terminals, and it asks for the keyboard only when
// clicked (OnDemand), so it never takes keys from the window being worked in.
PanelWindow {
  id: panel

  // The colours. Named `colors`, not `theme`: `theme: theme` in the parent would bind the
  // property to itself, since a scope object's own properties come before ids.
  required property QtObject colors
  // { sections: [{ title, command, rows: [{ left, right, tone }] }], footer }
  property var content: ({ sections: [], footer: "" })

  signal closeRequested()
  signal commandRequested(string command)

  anchors { top: true; right: true }
  margins { top: 46; right: 8 }
  implicitWidth: 440
  // As tall as the content, up to what the screen leaves under the bar; past that it scrolls.
  implicitHeight: Math.min(body.implicitHeight + 24, (screen ? screen.height : 800) - 70)
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "shinobi-panel"
  WlrLayershell.layer: WlrLayer.Top
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

  function toneColor(tone) {
    if (tone === "good") return panel.colors.good
    if (tone === "warn") return panel.colors.warn
    if (tone === "muted") return panel.colors.muted
    return panel.colors.foreground
  }

  Shortcut {
    sequence: "Escape"
    onActivated: panel.closeRequested()
  }

  Rectangle {
    anchors.fill: parent
    color: panel.colors.background
    border.color: panel.colors.border
    border.width: 1

    Flickable {
      id: scroller
      anchors.fill: parent
      anchors.margins: 12
      contentWidth: width
      contentHeight: body.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

    ColumnLayout {
      id: body
      width: scroller.width
      spacing: 10

      Repeater {
        model: panel.content.sections
        delegate: ColumnLayout {
          required property var modelData
          Layout.fillWidth: true
          spacing: 2

          Text {
            text: modelData.title
            textFormat: Text.PlainText
            color: panel.colors.accent
            font.family: "JetBrainsMono Nerd Font Mono"
            font.pixelSize: 11
            font.bold: true
            font.letterSpacing: 1.5
          }

          Repeater {
            model: modelData.rows
            delegate: RowLayout {
              required property var modelData
              Layout.fillWidth: true
              spacing: 8

              Text {
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                text: modelData.left
                textFormat: Text.PlainText
                color: panel.toneColor(modelData.tone)
                wrapMode: Text.WrapAnywhere
                font.family: "JetBrainsMono Nerd Font Mono"
                font.pixelSize: 12
              }
              Text {
                visible: modelData.right.length > 0
                text: modelData.right
                textFormat: Text.PlainText
                color: panel.toneColor(modelData.tone)
                font.family: "JetBrainsMono Nerd Font Mono"
                font.pixelSize: 12
              }
            }
          }

          // A section with something to do runs it when clicked anywhere in it.
          TapHandler {
            enabled: modelData.command.length > 0
            onTapped: panel.commandRequested(modelData.command)
          }
        }
      }

      Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: panel.colors.border
      }

      Text {
        Layout.fillWidth: true
        text: panel.content.footer
        color: panel.colors.muted
        font.family: "JetBrainsMono Nerd Font Mono"
        font.pixelSize: 11
        textFormat: Text.PlainText
      }
    }
    }
  }
}
