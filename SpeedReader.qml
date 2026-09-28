import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "ReaderModel.js" as ReaderModel

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) || "io.github.rmc507.speed-reader"
  readonly property string fetchScript: decodeURIComponent(String(Qt.resolvedUrl("bin/fetch-text")).replace(/^file:\/\//, ""))
  readonly property string shellConfigPath: Quickshell.env("HOME") + "/.config/omarchy/shell.json"

  // Settings come from this plugin's entry in shell.json's plugins[] array.
  property var config: ReaderModel.normalizeConfig({})

  property bool opened: false
  property string status: "idle"   // idle | loading | reading | done | error
  property string loadingText: ""
  property string errorText: ""
  property string title: ""
  property var tokens: []
  property int index: 0
  property bool playing: false
  property int wpm: config.wpm
  property real averageDelay: 0

  // Fetch bookkeeping: the process result is used once stdout, stderr and the
  // exit code have all arrived, in whatever order Quickshell delivers them.
  property var pendingCommand: null
  property int fetchExitCode: -1
  property bool fetchStdoutDone: false
  property bool fetchStderrDone: false

  readonly property var parts: ReaderModel.splitWord(tokens.length > 0 ? tokens[Math.min(index, tokens.length - 1)].text : "")
  readonly property real progress: tokens.length > 1 ? index / (tokens.length - 1) : (status === "done" ? 1 : 0)
  readonly property string remainingText: ReaderModel.formatDuration(Math.max(0, tokens.length - index - 1) * averageDelay)

  property string fontFamily: Style.font.menuFamily
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color accent: Color.accent
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  readonly property int wordSize: config.fontSize > 0 ? config.fontSize : Math.round(Style.font.heading * 2.75)
  property int cardWidth: Math.min(Style.space(560), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(layout.implicitHeight + card.contentTopInset + card.contentBottomInset, panel.height - Style.gapsOut * 2)

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }

    root.stop()
    root.opened = true
    root.tokens = []
    root.index = 0
    root.title = ""
    root.errorText = ""
    root.wpm = payload.wpm ? ReaderModel.normalizeWpm(payload.wpm) : root.config.wpm
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })

    if (typeof payload.text === "string" && payload.text.trim()) {
      root.load(payload.title || "Text", payload.text)
      return
    }

    var args = [root.fetchScript]
    if (payload.url) {
      args.push("url", String(payload.url))
      root.loadingText = "Fetching page…"
    } else if (payload.file) {
      args.push("file", String(payload.file))
      root.loadingText = "Opening file…"
    } else {
      var source = ReaderModel.normalizeConfig({ source: payload.source || root.config.source }).source
      args.push(source)
      root.loadingText = source === "selection" ? "Reading selection…" : "Reading clipboard…"
    }
    root.fetch(args)
  }

  function close() {
    root.opened = false
    root.stop()
    root.tokens = []
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function stop() {
    tick.stop()
    root.playing = false
    root.status = "idle"
    root.pendingCommand = null
    if (fetchProc.running) fetchProc.running = false
  }

  function fetch(args) {
    root.status = "loading"
    if (fetchProc.running) {
      // Let the old run exit first; onExited starts this one.
      root.pendingCommand = args
      fetchProc.running = false
      return
    }
    root.startFetch(args)
  }

  function startFetch(args) {
    root.fetchExitCode = -1
    root.fetchStdoutDone = false
    root.fetchStderrDone = false
    fetchProc.command = args
    fetchProc.running = true
  }

  function finishFetch() {
    if (root.fetchExitCode === -1 || !root.fetchStdoutDone || !root.fetchStderrDone) return
    if (root.status !== "loading") return
    if (root.fetchExitCode === 0) {
      var result = ReaderModel.parseFetchOutput(fetchStdout.text)
      root.load(result.title, result.text)
    } else {
      root.fail(fetchStderr.text.trim().split("\n").pop() || "Could not read any text")
    }
  }

  function load(title, text) {
    var tokens = ReaderModel.tokenize(text)
    if (tokens.length === 0) {
      root.fail("Nothing to read")
      return
    }
    root.title = title || ""
    root.tokens = tokens
    root.index = 0
    root.averageDelay = ReaderModel.averageDelayMs(tokens, root.wpm)
    root.status = "reading"
    root.play(ReaderModel.START_DELAY)
  }

  function fail(message) {
    root.status = "error"
    root.errorText = message
  }

  function play(extraHold) {
    root.playing = true
    tick.interval = (extraHold || 0) + ReaderModel.delayMs(root.tokens[root.index], root.wpm)
    tick.restart()
  }

  function pause() {
    root.playing = false
    tick.stop()
  }

  function togglePlay() {
    if (root.status === "done") {
      root.index = 0
      root.status = "reading"
      root.play(ReaderModel.START_DELAY)
    } else if (root.status === "reading") {
      if (root.playing) root.pause()
      else root.play(0)
    }
  }

  function advance() {
    if (root.index < root.tokens.length - 1) {
      root.index += 1
      root.play(0)
    } else {
      root.playing = false
      root.status = "done"
    }
  }

  function seek(nextIndex) {
    if (root.tokens.length === 0 || (root.status !== "reading" && root.status !== "done")) return
    root.index = Math.max(0, Math.min(nextIndex, root.tokens.length - 1))
    root.status = "reading"
    // Hold a jumped-to word a little longer so the eye can land on it.
    if (root.playing) root.play(Math.round(ReaderModel.START_DELAY / 2))
  }

  function setWpm(next) {
    root.wpm = ReaderModel.normalizeWpm(next)
    root.averageDelay = ReaderModel.averageDelayMs(root.tokens, root.wpm)
  }

  function applyConfig(text) {
    var previousWpm = root.config.wpm
    root.config = ReaderModel.normalizeConfig(ReaderModel.findEntry(text, root.pluginId))
    // shell.json also changes for unrelated reasons; keep a speed adjusted
    // with the arrow keys unless wpm itself was edited.
    root.setWpm(root.config.wpm !== previousWpm ? root.config.wpm : root.wpm)
  }

  FileView {
    id: configFile
    path: root.shellConfigPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyConfig(text())
    onLoadFailed: root.applyConfig("{}")
    onFileChanged: reload()
  }

  Process {
    id: fetchProc
    onExited: function(exitCode) {
      if (root.pendingCommand) {
        var next = root.pendingCommand
        root.pendingCommand = null
        root.startFetch(next)
        return
      }
      root.fetchExitCode = exitCode
      root.finishFetch()
    }
    stdout: StdioCollector {
      id: fetchStdout
      waitForEnd: true
      onStreamFinished: { root.fetchStdoutDone = true; root.finishFetch() }
    }
    stderr: StdioCollector {
      id: fetchStderr
      waitForEnd: true
      onStreamFinished: { root.fetchStderrDone = true; root.finishFetch() }
    }
  }

  Timer {
    id: tick
    repeat: false
    onTriggered: root.advance()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "io.github.rmc507.speed-reader"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea {
        anchors.fill: parent
        onClicked: root.togglePlay()
      }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          var key = event.key
          if (key === Qt.Key_Escape || key === Qt.Key_Q) {
            root.dismiss()
          } else if (key === Qt.Key_Space || key === Qt.Key_Return || key === Qt.Key_Enter) {
            root.togglePlay()
          } else if (key === Qt.Key_Left || key === Qt.Key_H) {
            root.seek(ReaderModel.previousSentence(root.tokens, root.index))
          } else if (key === Qt.Key_Right || key === Qt.Key_L) {
            root.seek(ReaderModel.nextSentence(root.tokens, root.index))
          } else if (key === Qt.Key_Up || key === Qt.Key_K) {
            root.setWpm(root.wpm + ReaderModel.WPM_STEP)
          } else if (key === Qt.Key_Down || key === Qt.Key_J) {
            root.setWpm(root.wpm - ReaderModel.WPM_STEP)
          } else if (key === Qt.Key_Home) {
            root.seek(0)
          } else {
            return
          }
          event.accepted = true
        }
      }

      Column {
        id: layout
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.space(10)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.title || " "
          color: root.foreground
          opacity: 0.58
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Item {
          id: stage
          width: parent.width
          height: Math.round(root.wordSize * 2.2)

          readonly property real focalX: Math.round(width / 2)
          readonly property bool showWord: root.status === "reading" || (root.status === "done" && root.tokens.length > 0)
          // Shrink words that would not fit on one side of the focal column.
          readonly property real wordScale: {
            var half = focusMetrics.advanceWidth / 2
            var left = preMetrics.advanceWidth + half
            var right = postMetrics.advanceWidth + half
            var scale = 1
            if (left > 0) scale = Math.min(scale, focalX / left)
            if (right > 0) scale = Math.min(scale, (width - focalX) / right)
            return Math.max(0.3, scale)
          }
          readonly property int pixelSize: Math.max(8, Math.floor(root.wordSize * wordScale))

          TextMetrics { id: preMetrics; font.family: root.fontFamily; font.pixelSize: root.wordSize; text: root.parts.pre }
          TextMetrics { id: focusMetrics; font.family: root.fontFamily; font.pixelSize: root.wordSize; text: root.parts.focus }
          TextMetrics { id: postMetrics; font.family: root.fontFamily; font.pixelSize: root.wordSize; text: root.parts.post }

          // Guide ticks mark the focal column above and below the word.
          Rectangle {
            visible: stage.showWord
            x: stage.focalX - width / 2
            anchors.top: parent.top
            width: Math.max(1, Style.space(2))
            height: Style.space(8)
            color: root.accent
            opacity: 0.6
          }

          Rectangle {
            visible: stage.showWord
            x: stage.focalX - width / 2
            anchors.bottom: parent.bottom
            width: Math.max(1, Style.space(2))
            height: Style.space(8)
            color: root.accent
            opacity: 0.6
          }

          Text {
            id: focusText
            visible: stage.showWord
            x: stage.focalX - width / 2
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.parts.focus
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: stage.pixelSize
            font.bold: true
            opacity: root.status === "done" ? 0.4 : 1
          }

          Text {
            visible: stage.showWord
            anchors.right: focusText.left
            anchors.baseline: focusText.baseline
            textFormat: Text.PlainText
            text: root.parts.pre
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: stage.pixelSize
            opacity: focusText.opacity
          }

          Text {
            visible: stage.showWord
            anchors.left: focusText.right
            anchors.baseline: focusText.baseline
            textFormat: Text.PlainText
            text: root.parts.post
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: stage.pixelSize
            opacity: focusText.opacity
          }

          Text {
            visible: !stage.showWord
            anchors.centerIn: parent
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: root.status === "error" ? root.errorText : root.loadingText
            color: root.status === "error" ? Color.urgent : root.foreground
            opacity: root.status === "error" ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }
        }

        Rectangle {
          width: parent.width
          height: Math.max(1, Style.space(2))
          radius: height / 2
          color: Util.alpha(root.foreground, 0.12)

          Rectangle {
            width: parent.width * root.progress
            height: parent.height
            radius: parent.radius
            color: root.accent
          }
        }

        Item {
          width: parent.width
          height: statusLine.implicitHeight

          Text {
            id: statusLine
            anchors.left: parent.left
            textFormat: Text.PlainText
            text: root.wpm + " wpm" + (root.tokens.length > 0 ? "  ·  " + root.remainingText + " left" : "")
            color: root.foreground
            opacity: 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            anchors.right: parent.right
            textFormat: Text.PlainText
            text: root.status === "done" ? "Done  ·  Space to restart  ·  Esc"
              : root.status === "reading" && !root.playing ? "Paused  ·  Space  ←→ sentence  ↑↓ speed"
              : root.status === "reading" ? "Space pause  ·  Esc"
              : "Esc to close"
            color: root.foreground
            opacity: 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }
}
