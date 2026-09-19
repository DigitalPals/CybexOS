import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// markbusking.pomodoro — Pomodoro focus timer for the Omarchy shell.
//
// Cycles through work / short break / long break phases. A timer in the bar
// shows the remaining time, clicking opens a popup controller, and phase
// completion fires a desktop notification. Durations and cycle length are
// configurable per-widget via shell.json settings:
//   workMinutes (25), shortBreakMinutes (5), longBreakMinutes (15),
//   pomodorosPerCycle (4)
//
// Bar: stopwatch glyph (coffee during breaks) plus the remaining time. Dimmed
// when no session is active so the entry point stays discoverable. Middle
// click toggles start/pause without opening the popup.
//
// Popup: phase label with pomodoro count dots, a large remaining-time readout,
// progress bar, and transport buttons. Keyboard: Space start/pause, R reset,
// S skip, Esc close.

Panel {
  id: root
  moduleName: "markbusking.pomodoro"
  ipcTarget: "markbusking.pomodoro"

  // ------------------------------------------------------------- settings

  readonly property int workMinutes: root.setting("workMinutes", 25)
  readonly property int shortBreakMinutes: root.setting("shortBreakMinutes", 5)
  readonly property int longBreakMinutes: root.setting("longBreakMinutes", 15)
  readonly property int pomodorosPerCycle: root.setting("pomodorosPerCycle", 4)
  readonly property bool soundEnabled: root.setting("sound", true)
  readonly property color breakColor: root.setting("breakColor", "#a6e3a1") // catppuccin green

  // ---------------------------------------------------------------- state

  property string phase: "idle"          // idle | work | shortBreak | longBreak
  property bool running: false
  property int remainingSeconds: 0       // seconds left in the current phase
  property int completedPomodoros: 0     // completed work sessions this cycle

  readonly property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int workSeconds: root.workMinutes * 60
  readonly property int shortBreakSeconds: root.shortBreakMinutes * 60
  readonly property int longBreakSeconds: root.longBreakMinutes * 60

  readonly property bool isBreak: root.phase === "shortBreak" || root.phase === "longBreak"
  readonly property bool hasSession: root.phase !== "idle"
  readonly property bool playing: root.running && root.hasSession

  // Phase theming: work uses the theme accent, breaks use a distinct green so
  // the bar pill reads at a glance. Idle stays neutral/dimmed.
  readonly property color phaseColor: root.isBreak ? root.breakColor : Color.accent
  readonly property color pillTextColor: {
    if (!root.hasSession) return root.contentForeground
    if (root.playing) return root.phaseColor
    return root.contentForeground
  }
  readonly property color pillBackground: {
    if (!root.hasSession) return Qt.rgba(0, 0, 0, 0)
    if (root.playing) return Util.alpha(root.phaseColor, 0.18)
    return Util.alpha(root.contentForeground, 0.10)
  }
  readonly property real pillOpacity: root.hasSession ? 1.0 : 0.7

  readonly property string phaseGlyph: root.isBreak ? "󰅶" : "\uf2f2" // md-coffee / fa-stopwatch
  readonly property string phaseLabel: {
    if (root.phase === "work") return "Work"
    if (root.phase === "shortBreak") return "Short break"
    if (root.phase === "longBreak") return "Long break"
    return "Pomodoro"
  }

  readonly property int phaseSeconds: {
    if (root.phase === "shortBreak") return root.shortBreakSeconds
    if (root.phase === "longBreak") return root.longBreakSeconds
    return root.workSeconds
  }

  readonly property real progress: root.phaseSeconds > 0
      ? Math.max(0, Math.min(1, 1 - (root.remainingSeconds / root.phaseSeconds)))
      : 0

  readonly property string tooltipText: {
    if (!root.hasSession) return "Pomodoro — click to start"
    if (root.running) return root.phaseLabel + " — " + root.formatTime(root.remainingSeconds)
    return root.phaseLabel + " — paused"
  }

  readonly property string playIcon: root.playing ? "\uf04c" : "\uf04b" // fa-pause / fa-play
  readonly property string playTooltip: {
    if (root.playing) return "Pause (Space)"
    return root.hasSession ? "Start (Space)" : "Start pomodoro (Space)"
  }

  readonly property int displaySeconds: root.hasSession ? root.remainingSeconds : root.workSeconds

  // --------------------------------------------------------------- ticking

  Timer {
    interval: 1000
    running: root.running
    repeat: true
    onTriggered: root.tick()
  }

  function tick() {
    root.remainingSeconds -= 1
    if (root.remainingSeconds <= 0) root.completePhase()
  }

  function startPhase(nextPhase, autoRun) {
    root.phase = nextPhase
    root.remainingSeconds = root.phaseSeconds
    root.running = autoRun
  }

  // Start/pause the current session. From idle, begins a work phase.
  function toggleTimer() {
    if (!root.hasSession) {
      root.startPhase("work", true)
      return
    }
    root.running = !root.running
  }

  function resetPhase() {
    root.remainingSeconds = root.phaseSeconds
    root.running = false
  }

  // Move to the next phase without counting a completed pomodoro.
  function skipPhase() {
    if (root.phase === "work") {
      root.startPhase("shortBreak", true)
    } else if (root.isBreak) {
      root.startPhase("work", false)
    }
  }

  function completePhase() {
    root.running = false
    if (root.phase === "work") {
      root.completedPomodoros += 1
      var long = root.completedPomodoros % root.pomodorosPerCycle === 0
      root.startPhase(long ? "longBreak" : "shortBreak", true)
      root.notify("Pomodoro complete", long ? "Long break — you earned it." : "Work session done. Take a short break.")
      root.playSound("/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga")
    } else {
      if (root.phase === "longBreak") root.completedPomodoros = 0
      root.startPhase("work", false)
      root.notify("Break over", "Ready for the next focus session?")
      root.playSound("/usr/share/sounds/freedesktop/stereo/complete.oga")
    }
  }

  function notify(title, body) {
    Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-notification-send",
                             title, body, "-g", root.phaseGlyph, "-u", "normal"])
  }

  // Play a phase-end sound via PipeWire. Disable with `"sound": false` in the
  // widget's shell.json entry.
  function playSound(file) {
    if (!root.soundEnabled) return
    Quickshell.execDetached(["/usr/bin/pw-play", file])
  }

  function formatTime(secs) {
    var total = Math.max(0, Math.floor(secs))
    var h = Math.floor(total / 3600)
    var m = Math.floor((total % 3600) / 60)
    var s = total % 60
    var ss = (s < 10 ? "0" : "") + s
    if (h > 0) return h + ":" + ((m < 10 ? "0" : "") + m) + ":" + ss
    return m + ":" + ss
  }

  // --------------------------------------------------------------- bar widget

  implicitWidth: Style.space(56)
  implicitHeight: bar ? bar.barSize : Style.bar.sizeHorizontal
  opacity: root.pillOpacity

  Item {
    id: barItem
    anchors.fill: parent

    // Pill container: subtle rounded background that tints per phase so the
    // widget reads as a discrete pill instead of floating text.
    Rectangle {
      anchors.fill: parent
      anchors.margins: Style.space(2)
      radius: Math.round(height / 2)
      color: root.pillBackground

      Behavior on color {
        ColorAnimation { duration: 200; easing.type: Easing.OutCubic }
      }
    }

    Row {
      anchors.centerIn: parent
      spacing: Style.space(4)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.phaseGlyph
        color: root.pillTextColor
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.icon
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.formatTime(root.displaySeconds)
        color: root.pillTextColor
        opacity: root.hasSession ? 1.0 : 0.55
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton

      onClicked: function(mouse) {
        if (mouse.button === Qt.MiddleButton) root.toggleTimer()
        else root.toggle()
      }

      onEntered: if (root.bar) root.bar.showTooltip(root, root.tooltipText)
      onExited: if (root.bar) root.bar.hideTooltip(root)
    }
  }

  // ------------------------------------------------------------------- popup

  KeyboardPanel {
    id: panel
    anchorItem: barItem
    owner: root
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(300))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight + Style.space(24))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onActivateRequested: root.toggleTimer()
      onCloseRequested: root.close()

      onTabRequested: function(direction) {
        root.switchPanel(direction)
      }

      onTextKey: function(t) {
        if (t === "r") root.resetPhase()
        else if (t === "s") root.skipPhase()
      }

      Column {
        id: contentColumn
        width: parent.width - Style.space(24)
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(12)

        // ------------------------------------------------- phase + count

        RowLayout {
          width: parent.width
          spacing: Style.space(6)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.phaseGlyph
            color: root.playing ? root.phaseColor : root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.phaseLabel
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Item { Layout.fillWidth: true }

          Repeater {
            model: root.pomodorosPerCycle

            Rectangle {
              width: Style.space(6)
              height: Style.space(6)
              radius: Math.round(width / 2)
              color: index < root.completedPomodoros
                  ? Color.accent
                  : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.25)
            }
          }
        }

        // -------------------------------------------------- remaining time

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.formatTime(root.remainingSeconds)
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.displayLarge
          font.bold: true
        }

        // ---------------------------------------------------- progress bar

        Rectangle {
          width: parent.width
          height: 5
          radius: Math.round(height / 2)
          color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

          Rectangle {
            width: parent.width * root.progress
            height: parent.height
            radius: parent.radius
            color: root.playing ? root.phaseColor : root.contentForeground

            Behavior on width {
              NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
            }
          }
        }

        // ------------------------------------------------------ transport

        RowLayout {
          width: parent.width
          spacing: Style.space(16)

          Item { Layout.fillWidth: true }

          PanelActionButton {
            iconText: "\uf051" // fa-step-forward
            tooltipText: "Skip phase (S)"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            enabled: root.hasSession
            opacity: root.hasSession ? 1.0 : 0.7
            onClicked: root.skipPhase()
          }

          PanelActionButton {
            iconText: root.playIcon
            tooltipText: root.playTooltip
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            fontSize: Style.font.iconLarge
            onClicked: root.toggleTimer()
          }

          PanelActionButton {
            iconText: "\uf0e2" // fa-undo
            tooltipText: "Reset phase (R)"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            enabled: root.hasSession
            opacity: root.hasSession ? 1.0 : 0.7
            onClicked: root.resetPhase()
          }

          Item { Layout.fillWidth: true }
        }

        // ------------------------------------------------------- shortcuts

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "Space start · R reset · S skip"
          color: root.contentForeground
          opacity: 0.45
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}