import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// YouTrack tickets assigned to you, counted by priority.
//
// The bar shows the collapsed state only — "P0:1 P1:4 P2:7" — and the pill
// takes the urgent color while any P0 is open. Clicking opens the popup with
// the same tickets listed under a heading per priority.
Panel {
  id: root
  moduleName: "al.youtrack"
  ipcTarget: "al.youtrack"
  manageIpc: false

  // Trailing slash included, so the script name appends directly.
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
  readonly property string fetchScript: pluginDir + "youtrack-fetch"

  readonly property string query: String(setting("query", "for: me #Unresolved"))
  readonly property int refreshIntervalSec: Math.max(30, Number(setting("refreshIntervalSec", 300)) || 300)
  readonly property string emptyLabel: String(setting("emptyLabel", "YT:0"))

  property var issues: []
  property string baseUrl: ""
  property string lastError: ""
  property bool loading: false
  property int cursorIndex: -1
  property bool cursorActive: false
  property string searchText: ""

  // A YouTrack-side search: the search box text sent as the query itself, so
  // it reaches tickets beyond `query` and takes YouTrack syntax as well as
  // plain words. `remoteQuery` is the text the held results answer;
  // `remotePending` is the latest text asked for, which can run ahead of the
  // one in flight when the search is re-run before the last one returns.
  property string remoteQuery: ""
  property var remoteIssues: []
  property string remoteError: ""
  property bool remoteLoading: false
  property string remotePending: ""
  property string remoteInFlight: ""

  readonly property string searchTerm: searchText.trim()
  readonly property bool searching: searchTerm !== ""
  // Results only stand while the box still says what was searched for; any
  // edit falls back to filtering the assigned tickets until the next search.
  readonly property bool showingRemote: searching && remoteQuery === searchTerm
  readonly property bool remoteBusy: remoteLoading && remotePending === searchTerm

  // `groups` always covers the whole query and drives the bar; the popup lists
  // `shownGroups`, which the search box narrows or YouTrack's results replace.
  readonly property var groups: Model.groupByPriority(issues)
  readonly property var shownGroups: Model.groupByPriority(showingRemote ? remoteIssues : Model.filterIssues(issues, searchText))
  readonly property var rows: Model.flatten(shownGroups)
  readonly property int total: Model.totalCount(groups)
  readonly property bool hasBlocker: Model.hasPriority(groups, "P0")

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Priority colors, read from the active theme's colors.toml: P0 red,
  // P1 yellow, P2 green, P3 blue, P4 gray. A theme missing one of those roles
  // falls back to a shell color that always exists.
  property var themeColors: ({})

  readonly property color redColor: colorOr("red", urgent)
  readonly property color yellowColor: colorOr("yellow", Color.accent)
  readonly property color greenColor: colorOr("green", Color.accent)
  readonly property color blueColor: colorOr("blue", Color.accent)
  readonly property color grayColor: colorOr("gray", Color.muted)

  function colorOr(key, fallback) {
    var value = Model.themeColor(themeColors, key)
    return value === "" ? fallback : value
  }

  // `fallback` is the surrounding foreground, which differs between the bar
  // pill and the popup, so each caller passes its own.
  function priorityColor(priority, fallback) {
    return colorForKey(Model.colorKeyFor(priority), fallback)
  }

  function colorForKey(key, fallback) {
    if (key === "red") return redColor
    if (key === "yellow") return yellowColor
    if (key === "green") return greenColor
    if (key === "blue") return blueColor
    if (key === "gray") return grayColor
    return fallback
  }

  readonly property bool vertical: bar ? bar.vertical : false

  // A vertical bar has no room for the breakdown, so it shows the total and
  // keeps the per-priority counts in the tooltip.
  readonly property string barLabel: lastError !== "" ? "YT!" : (total > 0 ? String(total) : emptyLabel)
  readonly property var barSegments: Model.barSegments(groups, emptyLabel, lastError !== "")

  readonly property string tooltipText: {
    if (lastError !== "") return "YouTrack: " + lastError
    if (total === 0) return "No tickets match " + query
    return Model.barLabel(groups, emptyLabel) + " — " + total + (total === 1 ? " ticket" : " tickets")
  }

  function refresh() {
    if (loading) return
    loading = true
    fetchProcess.command = ["bash", root.fetchScript, root.query]
    fetchProcess.running = true
  }

  function applyResult(text) {
    var result = Model.parse(text)
    if (!result.ok) {
      root.lastError = result.error
      return
    }
    root.lastError = ""
    root.issues = result.issues
    if (result.base !== "") root.baseUrl = result.base
    if (root.cursorIndex >= root.rows.length) root.cursorIndex = root.rows.length - 1
  }

  function searchYouTrack() {
    if (!searching) return
    remotePending = searchTerm
    // A search already in flight picks the newer text up when it exits.
    if (!remoteProcess.running) startRemoteSearch()
  }

  function startRemoteSearch() {
    remoteInFlight = remotePending
    remoteLoading = true
    remoteProcess.command = ["bash", root.fetchScript, remoteInFlight]
    remoteProcess.running = true
  }

  function applyRemoteResult(text) {
    var result = Model.parse(text)
    remoteQuery = remoteInFlight
    remoteError = result.ok ? "" : result.error
    remoteIssues = result.ok ? result.issues : []
    if (result.ok && result.base !== "") baseUrl = result.base
    if (showingRemote) {
      cursorActive = rows.length > 0
      cursorIndex = cursorActive ? 0 : -1
      if (panelFlick) panelFlick.contentY = 0
    }
  }

  function clearRemoteSearch() {
    remoteQuery = ""
    remoteIssues = []
    remoteError = ""
    remotePending = ""
  }

  // Shift+Enter, and the footer row: search YouTrack for the box's text, or
  // once its results are showing, open that same search in the browser.
  function searchOrOpenYouTrack() {
    if (showingRemote) openUrl(searchUrl(searchTerm))
    else searchYouTrack()
  }

  function searchUrl(q) {
    return baseUrl === "" ? "" : baseUrl + "/issues?q=" + encodeURIComponent(q)
  }

  // The saved-search URL behind a middle click. Empty until the first
  // successful fetch reports which YouTrack instance the token points at.
  readonly property string issuesUrl: searchUrl(root.query)

  function openIssue(issue) {
    if (!issue || !issue.url) return
    openUrl(String(issue.url))
    root.close()
  }

  // execArgv, not bar.run: the URL is API data, and argv never gets re-split
  // by a shell. (bar.shellQuote, which the bar README mentions, does not
  // exist — shellQuote lives on Util.)
  function openUrl(url) {
    if (!url) return
    Util.execArgv(["xdg-open", url])
  }

  function moveCursor(dy) {
    cursorActive = true
    if (rows.length === 0) { cursorIndex = -1; return }
    if (cursorIndex < 0) cursorIndex = 0
    else cursorIndex = Math.max(0, Math.min(rows.length - 1, cursorIndex + dy))
    scrollCursorIntoView()
  }

  function scrollCursorIntoView() {
    Qt.callLater(function() {
      var item = rowRegistry[root.cursorIndex]
      if (!item || !panelFlick) return
      var margin = Style.space(6)
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin)
        panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  // Rows live inside nested Repeaters, so they register themselves here by
  // flat index rather than being reachable through a single children list.
  property var rowRegistry: ({})

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Typing lights up the top match, so Enter opens it without an arrow key
  // first; clearing the search puts the cursor away again.
  onSearchTextChanged: {
    cursorActive = searching && rows.length > 0
    cursorIndex = cursorActive ? 0 : -1
    if (panelFlick) panelFlick.contentY = 0
  }

  function focusSearch() {
    if (searchField.visible) searchField.forceActiveFocus()
  }

  onOpenedChanged: if (opened) {
    searchField.text = ""
    clearRemoteSearch()
    cursorActive = false
    cursorIndex = -1
    if (panelFlick) panelFlick.contentY = 0
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Component.onCompleted: refresh()

  Process {
    id: fetchProcess
    running: false
    command: []
    stdout: StdioCollector { id: fetchStdout; waitForEnd: true }
    stderr: StdioCollector { id: fetchStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.loading = false
      if (exitCode === 0) root.applyResult(fetchStdout.text)
      else root.lastError = String(fetchStderr.text || "youtrack-fetch failed").split("\n")[0]
    }
  }

  Process {
    id: remoteProcess
    running: false
    command: []
    stdout: StdioCollector { id: remoteStdout; waitForEnd: true }
    stderr: StdioCollector { id: remoteStderr; waitForEnd: true }
    onExited: function(exitCode) {
      // The popup reopened (which clears the search) while this one ran, so
      // nobody is waiting on the answer.
      if (root.remotePending === "") {
        root.remoteLoading = false
        return
      }
      // The text changed and was searched again while this one ran, so this
      // answer is already stale: run the newer one instead of showing it.
      if (root.remotePending !== root.remoteInFlight) {
        Qt.callLater(root.startRemoteSearch)
        return
      }
      root.remoteLoading = false
      if (exitCode === 0) root.applyRemoteResult(remoteStdout.text)
      else root.applyRemoteResult(JSON.stringify({
        ok: false,
        error: String(remoteStderr.text || "youtrack-fetch failed").split("\n")[0]
      }))
    }
  }

  FileView {
    id: themeColorsFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.themeColors = Model.parseThemeColors(text())
    onFileChanged: reload()
    onLoadFailed: root.themeColors = ({})
  }

  // `current/theme` is a symlink the theme switcher repoints, which a file
  // watch on the old target does not see. The switch does reach the Color
  // singleton over shell IPC, so treat that as the cue to re-read the palette.
  Connections {
    target: Color
    function onForegroundChanged() { themeColorsFile.reload() }
    function onAccentChanged() { themeColorsFile.reload() }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function counts(): string { return root.lastError !== "" ? root.lastError : Model.barLabel(root.groups, root.emptyLabel) }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Horizontally the pill is the segment row below, which colors the P0 pair
    // on its own; the built-in single-color label only serves a vertical bar.
    text: root.vertical ? root.barLabel : ""
    labelVisible: root.vertical
    hasVisualContent: true
    active: root.vertical && (root.hasBlocker || root.lastError !== "")
    fixedWidth: root.vertical ? -1 : segmentRow.implicitWidth + button.scaledHorizontalMargin * 2
    tooltipText: root.tooltipText
    dimmed: root.total === 0 && root.lastError === ""

    Row {
      id: segmentRow
      visible: !root.vertical
      anchors.centerIn: parent
      spacing: Style.space(6)

      Repeater {
        model: root.barSegments

        Text {
          required property var modelData
          text: modelData.text
          color: root.colorForKey(modelData.colorKey, button.foreground)
          font.family: button.fontFamily
          font.pixelSize: button.fontSize
          renderType: Text.NativeRendering
          verticalAlignment: Text.AlignVCenter
        }
      }
    }

    onPressed: function(b) {
      if (b === Qt.RightButton) root.refresh()
      else if (b === Qt.MiddleButton) root.openUrl(root.issuesUrl)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(header.implicitHeight + Style.space(12) + column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The search box handles its own keys while it has focus.
      blocked: searchField.activeFocus
      onMoveRequested: function(dx, dy) {
        if (dy === 0) return
        // The first arrow key only lights the cursor up on the top row; from
        // there it steps, so nothing is skipped past on the way in.
        if (!root.cursorActive) root.moveCursor(0)
        else root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive && root.cursorIndex >= 0) root.openIssue(root.rows[root.cursorIndex])
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "/") root.focusSearch()
      }

      // The heading and search box stay put while the ticket list scrolls.
      Column {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(12)

        PanelHero {
          id: hero
          width: parent.width
          title: "YouTrack"
          meta: {
            if (root.remoteBusy) return "Searching YouTrack…"
            if (root.showingRemote)
              return root.remoteError !== ""
                ? "YouTrack search failed"
                : root.rows.length + (root.rows.length === 1 ? " result" : " results") + " in YouTrack"
            if (root.loading) return "Refreshing…"
            if (root.lastError !== "") return "Lookup failed"
            if (root.searching) return root.rows.length + " of " + root.total + (root.total === 1 ? " ticket" : " tickets")
            return root.total + (root.total === 1 ? " ticket assigned" : " tickets assigned")
          }
          foreground: root.foreground
          fontFamily: root.fontFamily

          iconComponent: Component {
            Text {
              text: "󰄗"
              color: root.hasBlocker ? root.redColor : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }

          trailingControl: Component {
            PanelActionButton {
              iconText: "󰑐"
              tooltipText: "Refresh"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.loading
              onClicked: root.refresh()
            }
          }
        }

        Text {
          visible: root.lastError !== ""
          width: parent.width
          text: root.lastError
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        TextField {
          id: searchField
          width: parent.width
          placeholderText: "Search tickets  /"
          foreground: root.foreground
          font.family: root.fontFamily

          onTextChanged: root.searchText = text

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              if (text !== "") text = ""
              else root.close()
              event.accepted = true
            } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
              var dy = event.key === Qt.Key_Down ? 1 : -1
              if (!root.cursorActive) root.moveCursor(0)
              else root.moveCursor(dy)
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              // Shift+Enter always goes to YouTrack; plain Enter opens the
              // highlighted ticket, or searches YouTrack when nothing matched.
              if (event.modifiers & Qt.ShiftModifier) root.searchOrOpenYouTrack()
              else if (root.cursorActive && root.cursorIndex >= 0) root.openIssue(root.rows[root.cursorIndex])
              else if (!root.showingRemote) root.searchYouTrack()
              event.accepted = true
            } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
              // Hand the keys back to the list, so j/k and r work again.
              keyCatcher.forceActiveFocus()
              event.accepted = true
            }
          }
        }
      }

      Flickable {
        id: panelFlick
        anchors.top: header.bottom
        anchors.topMargin: Style.space(12)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
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

          Text {
            visible: root.lastError === "" && root.total === 0 && !root.loading && !root.searching
            width: parent.width
            text: "Nothing assigned to you."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            visible: root.showingRemote && root.remoteError !== ""
            width: parent.width
            text: root.remoteError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.searching && !root.remoteBusy && root.rows.length === 0
              && !(root.showingRemote && root.remoteError !== "")
            width: parent.width
            text: root.showingRemote
              ? "YouTrack found nothing for “" + root.searchTerm + "”."
              : "No assigned tickets match “" + root.searchTerm + "”. Enter searches YouTrack."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.shownGroups

            Column {
              id: group
              required property var modelData
              required property int index

              // Flat index of this group's first ticket, so each row can work
              // out its own position in the keyboard-navigable list.
              readonly property int rowOffset: {
                var offset = 0
                for (var i = 0; i < index; i++) offset += root.shownGroups[i].count
                return offset
              }

              width: column.width
              spacing: Style.space(8)

              PanelSeparator {
                width: parent.width
                visible: group.index > 0
                foreground: root.foreground
              }

              PanelSectionHeader {
                text: group.modelData.priority + " · " + group.modelData.count
                // PanelSectionHeader darkens what it is given, which is what
                // keeps these headings subdued against the ticket rows.
                foreground: root.priorityColor(group.modelData.priority, root.foreground)
                fontFamily: root.fontFamily
              }

              Column {
                width: parent.width
                spacing: Style.space(4)

                Repeater {
                  model: group.modelData.issues

                  IssueRow {
                    required property var modelData
                    required property int index
                    width: group.width
                    issue: modelData
                    rowIndex: group.rowOffset + index
                  }
                }
              }
            }
          }

          // The way out to YouTrack: searches it from the box's text, then,
          // with its results showing, opens the same search in the browser.
          CursorSurface {
            id: youtrackRow
            visible: root.searching
            width: parent.width
            hasCursor: youtrackMouse.containsMouse
            foreground: root.foreground
            implicitHeight: youtrackLabel.implicitHeight + Style.spacing.rowPaddingX

            MouseArea {
              id: youtrackMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              enabled: !root.remoteBusy
              onClicked: root.searchOrOpenYouTrack()
            }

            RowLayout {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(8)

              Text {
                id: youtrackLabel
                Layout.fillWidth: true
                text: root.remoteBusy
                  ? "Searching YouTrack for “" + root.searchTerm + "”…"
                  : (root.showingRemote
                     ? "Open this search in YouTrack"
                     : "Search all of YouTrack for “" + root.searchTerm + "”")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Text {
                text: "Shift+Enter"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }
    }
  }

  component IssueRow: CursorSurface {
    id: issueRow
    property var issue: null
    property int rowIndex: 0

    hasCursor: root.cursorActive && root.cursorIndex === rowIndex
    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    Component.onCompleted: root.rowRegistry[rowIndex] = issueRow
    // Searching rebuilds the rows, and the replacement for an index can
    // register before the old row is destroyed, so only clear our own entry.
    Component.onDestruction: if (root.rowRegistry[rowIndex] === issueRow) delete root.rowRegistry[rowIndex]

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: {
        root.cursorActive = true
        root.cursorIndex = issueRow.rowIndex
      }
      onClicked: root.openIssue(issueRow.issue)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: issueRow.issue ? String(issueRow.issue.summary || issueRow.issue.id) : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: issueRow.issue
            ? String(issueRow.issue.id) + "  ·  " + Model.issueMeta(issueRow.issue)
            : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        text: issueRow.issue ? Model.relativeTime(issueRow.issue.updated, Date.now()) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }
}
