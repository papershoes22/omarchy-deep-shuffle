import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar pill: play state glyph + scrolling "Artist – Title", with a thin track-progress
// line along the bottom. The popup (Panel.qml) owns the data; this pill reads it back.
//   left: dropdown · middle: play/pause · right: next · scroll: volume
BarWidget {
  id: root
  moduleName: "io.github.papershoes22.sclikes"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item) panelLoader.item.openFromHotkey() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  readonly property var panel: panelLoader.item
  // Narrow screens (under 1600 logical px, e.g. a 2560-wide monitor at 2x) get a shorter title so
  // the right section doesn't run into the centered clock; longer titles scroll.
  readonly property var barScreen: button.QsWindow.window ? button.QsWindow.window.screen : null
  readonly property bool narrowScreen: barScreen !== null && barScreen.width < 1600
  readonly property real maxLabelWidth: Style.space(narrowScreen
      ? Math.min(Number(setting("maxWidth", 200)), Number(setting("narrowMaxWidth", 80)))
      : Number(setting("maxWidth", 200)))
  readonly property bool showTitle: String(setting("showTitle", "On")) !== "Off"
  readonly property string label: panel && showTitle ? panel.pillText : ""
  // Vivid look: only while a track is loaded (playing or paused).
  readonly property bool vivid: panel !== null && panel.pillVivid && panel.pillText !== "" && !vertical
  readonly property bool playing: panel !== null && panel.pillActive
  readonly property color accent: panel ? panel.accent : button.foreground
  // Bass level from the spectrum frames the pill already receives (0 when the mini spectrum is off).
  property real bass: vivid && playing && panel.pillViz ? Math.min(1, 1.5 * Math.sqrt(Math.max(panel.pillBars[0] || 0, panel.pillBars[1] || 0))) : 0
  // Stay near the cover's hue: bars fan out ±2 steps around it instead of drifting into another colour.
  function barHue(i) { return ((panel ? panel.accentHue : 0.6) + (i - 2) * 0.025 + 1) % 1 }

  visible: panelLoader.item !== null
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  readonly property real openPanelIndicatorWidth: pillRow.implicitWidth

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    tooltipText: root.panel ? root.panel.tooltip : ""
    fixedWidth: pillRow.implicitWidth + Style.spaceReal(17)

    onPressed: function (b) {
      if (!root.bar || !root.panel) return
      if (b === Qt.MiddleButton) root.panel.playPause()
      else if (b === Qt.RightButton) root.panel.next()
      else root.togglePanel()
    }
    onWheelMoved: function (delta) {
      if (root.panel) root.panel.volumeBy(delta > 0 ? 5 : -5)
    }

    // Vivid capsule: cover colour fading right, border in the accent, glows with the bass.
    Rectangle {
      id: capsule
      visible: opacity > 0
      opacity: !root.vivid ? 0 : root.playing ? 1 : 0.55
      Behavior on opacity { NumberAnimation { duration: 400 } }
      anchors.verticalCenter: parent.verticalCenter
      x: pillRow.x - Style.space(6)
      width: pillRow.width + Style.space(12)
      height: Math.min(parent.height - Style.space(4), pillRow.height + Style.space(8))
      radius: height / 2
      border.width: root.bass > 0.6 ? 2 : 1
      border.color: Util.alpha(Qt.lighter(root.accent, 1 + 0.35 * root.bass), 0.6 + 0.4 * root.bass)
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0.0; color: Util.alpha(root.accent, 0.62 + 0.3 * root.bass) }
        GradientStop { position: 0.5; color: Util.alpha(Qt.hsla(root.barHue(0), Math.max(0.6, root.accent.hslSaturation), root.accent.hslLightness, 1), 0.34 + 0.3 * root.bass) }
        GradientStop { position: 1.0; color: Util.alpha(root.accent, 0.14 + 0.12 * root.bass) }
      }
    }

    Row {
      id: pillRow
      anchors.centerIn: parent
      spacing: Style.space(6)

      // Cover thumbnail (vivid only).
      Image {
        visible: root.vivid && status === Image.Ready
        anchors.verticalCenter: parent.verticalCenter
        width: visible ? button.fontSize + Style.space(4) : 0
        height: width
        source: root.vivid && root.panel ? root.panel.artSource : ""
        sourceSize.width: 64
        sourceSize.height: 64
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        smooth: true
        Rectangle {
          anchors.fill: parent
          color: "transparent"
          radius: Style.space(2)
          border.width: 1
          border.color: Util.alpha(root.accent, 0.8)
        }
      }

      // Mini spectrum while playing (when cava is available); otherwise the state glyph.
      Item {
        id: miniViz
        readonly property bool on: root.panel !== null && root.panel.pillActive && root.panel.vizAvailable
                                   && root.panel.pillViz
        visible: on
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(17)
        height: button.fontSize + Style.space(2)
        Repeater {
          model: 5
          Rectangle {
            required property int index
            readonly property real v: root.panel ? (root.panel.pillBars[index] || 0) : 0
            x: index * Style.space(3.5)
            width: Style.space(2.5)
            // sqrt lifts the typical 10-40% levels so they read at bar size
            height: Math.max(Style.space(2), miniViz.height * Math.min(1, Math.sqrt(v) * 1.15))
            anchors.bottom: parent.bottom
            radius: width / 2
            color: root.vivid ? Qt.hsla(root.barHue(index), Math.max(0.7, root.accent.hslSaturation),
                                        Math.min(0.85, root.accent.hslLightness + 0.1 + 0.25 * v), 1)
                              : button.foreground
          }
        }
      }

      Text {
        id: glyph
        visible: !miniViz.on
        anchors.verticalCenter: parent.verticalCenter
        text: root.panel ? root.panel.pillGlyph : Model.NOTE
        color: root.vivid ? root.accent
             : root.panel && root.panel.pillActive ? button.foreground : Qt.darker(button.foreground, 1.5)
        font.family: button.fontFamily
        font.pixelSize: button.fontSize + 1
        renderType: Text.NativeRendering
      }

      // Scrolls when the title is wider than maxWidth; pauses while the dropdown is open.
      Item {
        id: clipBox
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.vertical && root.label !== ""
        width: Math.min(root.maxLabelWidth, labelText.implicitWidth)
        height: labelText.implicitHeight
        clip: true

        Text {
          id: labelText
          anchors.verticalCenter: parent.verticalCenter
          text: root.label
          textFormat: Text.PlainText
          color: root.panel && root.panel.pillActive ? button.foreground : Qt.darker(button.foreground, 1.5)
          font.family: button.fontFamily
          font.pixelSize: button.fontSize
          renderType: Text.NativeRendering
          readonly property bool needsScroll: implicitWidth > clipBox.width
          onTextChanged: x = 0

          SequentialAnimation on x {
            running: labelText.needsScroll && !root.opened && root.panel && root.panel.pillActive
            loops: Animation.Infinite
            PauseAnimation { duration: 2500 }
            NumberAnimation {
              from: 0
              to: -(labelText.implicitWidth - clipBox.width)
              duration: Math.max(2000, (labelText.implicitWidth - clipBox.width) * 30)
              easing.type: Easing.InOutQuad
            }
            PauseAnimation { duration: 2000 }
            NumberAnimation {
              to: 0
              duration: 600
              easing.type: Easing.OutCubic
            }
          }
        }
      }
    }

    // Track progress along the bottom of the pill.
    Rectangle {
      visible: !root.vertical && root.panel && root.panel.pillProgress > 0
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(3)
      x: pillRow.x
      width: pillRow.width * Math.min(1, root.panel ? root.panel.pillProgress : 0)
      height: Math.max(1, Style.space(root.vivid ? 2.5 : 2))
      radius: height / 2
      color: root.vivid ? Util.alpha(root.accent, root.playing ? 0.95 : 0.5)
                        : Util.alpha(button.foreground, root.panel && root.panel.pillActive ? 0.55 : 0.25)
    }
  }
}
