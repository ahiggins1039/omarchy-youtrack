.pragma library

// Priorities are rendered and counted in this order; anything the project
// defines outside the list (a renamed level, an unset field) is appended
// alphabetically after them rather than dropped.
var PRIORITY_ORDER = ["P0", "P1", "P2", "P3", "P4"]

function priorityRank(priority) {
  var index = PRIORITY_ORDER.indexOf(priority)
  return index === -1 ? PRIORITY_ORDER.length : index
}

function parse(text) {
  var raw = String(text || "").trim()
  if (raw === "") return { ok: false, error: "No response from youtrack-fetch", issues: [] }

  var payload
  try {
    payload = JSON.parse(raw)
  } catch (e) {
    return { ok: false, error: "Malformed response from youtrack-fetch", issues: [] }
  }

  if (!payload || payload.ok !== true)
    return { ok: false, error: String((payload && payload.error) || "YouTrack lookup failed"), issues: [] }

  var issues = Array.isArray(payload.issues) ? payload.issues : []
  return {
    ok: true,
    error: "",
    query: String(payload.query || ""),
    base: String(payload.base || ""),
    issues: issues
  }
}

// [{ priority, count, issues }] — one entry per priority that has tickets,
// highest first, with each group's tickets sorted most-recently-updated first.
function groupByPriority(issues) {
  var buckets = {}
  for (var i = 0; i < issues.length; i++) {
    var priority = String(issues[i].priority || "None")
    if (!buckets[priority]) buckets[priority] = []
    buckets[priority].push(issues[i])
  }

  var groups = []
  for (var key in buckets) {
    buckets[key].sort(function(a, b) { return (b.updated || 0) - (a.updated || 0) })
    groups.push({ priority: key, count: buckets[key].length, issues: buckets[key] })
  }

  groups.sort(function(a, b) {
    var byRank = priorityRank(a.priority) - priorityRank(b.priority)
    return byRank !== 0 ? byRank : (a.priority < b.priority ? -1 : 1)
  })
  return groups
}

// The bar's collapsed state: "P0:1 P1:4 P2:7". Only priorities with tickets
// appear, so an empty queue collapses to the empty-state label.
function barLabel(groups, emptyLabel) {
  if (groups.length === 0) return emptyLabel
  var parts = []
  for (var i = 0; i < groups.length; i++) parts.push(groups[i].priority + ":" + groups[i].count)
  return parts.join(" ")
}

// Which palette role paints each priority. Anything outside the list — an
// unset Priority field, a project that renamed its levels — gets "", which
// means "leave it the surrounding foreground color".
var PRIORITY_COLOR_KEYS = { "P0": "red", "P1": "yellow", "P2": "green", "P3": "blue", "P4": "gray" }

function colorKeyFor(priority) {
  return PRIORITY_COLOR_KEYS[priority] || ""
}

// The bar pill, one segment per priority so each pair takes its own color:
// [{ text: "P0:1", colorKey: "red" }, { text: "P1:4", colorKey: "yellow" }, ...]
function barSegments(groups, emptyLabel, error) {
  if (error) return [{ text: "YT!", colorKey: "red" }]
  if (groups.length === 0) return [{ text: emptyLabel, colorKey: "" }]
  var segments = []
  for (var i = 0; i < groups.length; i++)
    segments.push({
      text: groups[i].priority + ":" + groups[i].count,
      colorKey: colorKeyFor(groups[i].priority)
    })
  return segments
}

// ------------------------------------------------------------------ palette
//
// The shell's Color singleton only carries foreground/background/accent/
// urgent/muted, so the priority colors are read straight out of the active
// theme's colors.toml — the same file the terminal palette comes from.

// "red = \"#fc293a\"" -> { red: "#fc293a" }. Same shape of line the shell's
// own loader matches, so quoted and bare values both work.
function parseThemeColors(raw) {
  var values = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var match = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
    if (match) values[match[1]] = match[2]
  }
  return values
}

// Themes name their palette either in words or as color0-15, and not every
// theme defines every word, so each role walks a chain of candidates and
// returns "" when the theme offers none of them.
var COLOR_CHAINS = {
  "red":    ["red", "color1", "bright_red", "color9"],
  "yellow": ["yellow", "color3", "bright_yellow", "color11", "orange"],
  "green":  ["green", "color2", "bright_green", "color10"],
  "blue":   ["blue", "color4", "bright_blue", "color12", "cyan", "color6"],
  "gray":   ["muted", "color8", "dark_foreground", "bright_black"]
}

function themeColor(values, key) {
  var chain = COLOR_CHAINS[key]
  if (!chain) return ""
  for (var i = 0; i < chain.length; i++) {
    var candidate = values[chain[i]]
    if (candidate) return candidate
  }
  return ""
}

function totalCount(groups) {
  var total = 0
  for (var i = 0; i < groups.length; i++) total += groups[i].count
  return total
}

function hasPriority(groups, priority) {
  for (var i = 0; i < groups.length; i++)
    if (groups[i].priority === priority && groups[i].count > 0) return true
  return false
}

// The popup's search box. Every whitespace-separated term has to appear,
// case-insensitively, somewhere in the ticket's id, summary, priority, state,
// type, or project, so "p1 bug" narrows to P1 bugs and "sys-12" finds a ticket
// by id. An empty search keeps everything.
function filterIssues(issues, search) {
  var terms = String(search || "").toLowerCase().split(/\s+/).filter(function(t) { return t !== "" })
  if (terms.length === 0) return issues

  return issues.filter(function(issue) {
    var haystack = [issue.id, issue.summary, issue.priority, issue.state, issue.type, issue.project]
      .map(function(v) { return String(v || "") })
      .join(" ")
      .toLowerCase()
    for (var i = 0; i < terms.length; i++)
      if (haystack.indexOf(terms[i]) === -1) return false
    return true
  })
}

// Every ticket in display order, so keyboard navigation can walk one flat
// index across the grouped list.
function flatten(groups) {
  var rows = []
  for (var i = 0; i < groups.length; i++)
    for (var j = 0; j < groups[i].issues.length; j++) rows.push(groups[i].issues[j])
  return rows
}

function indexOfIssue(rows, issue) {
  if (!issue) return -1
  for (var i = 0; i < rows.length; i++) if (rows[i].id === issue.id) return i
  return -1
}

function issueMeta(issue) {
  if (!issue) return ""
  var parts = []
  if (issue.state) parts.push(String(issue.state))
  if (issue.type) parts.push(String(issue.type))
  return parts.join(" · ")
}

function relativeTime(millis, now) {
  var value = Number(millis) || 0
  if (value <= 0) return ""
  var seconds = Math.max(0, Math.round(((now || Date.now()) - value) / 1000))
  if (seconds < 60) return "just now"
  var minutes = Math.round(seconds / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.round(minutes / 60)
  if (hours < 24) return hours + "h ago"
  var days = Math.round(hours / 24)
  if (days < 30) return days + "d ago"
  var months = Math.round(days / 30)
  if (months < 12) return months + "mo ago"
  return Math.round(months / 12) + "y ago"
}
