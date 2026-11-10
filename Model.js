.pragma library

// ---------------------------------------------------------------- priorities
//
// A "scale" says how priorities rank, which color each takes, and what the bar
// calls them. Rank 0 is the most urgent: it takes red and turns the pill
// urgent. Ranks 1-3 are yellow, green and blue; rank 4 and below are gray.
// Names the scale doesn't know are still counted and listed, after the known
// ones in alphabetical order, in the surrounding foreground color.
//
// With no `priorities` setting the widget recognises both of these, so the
// P0-P4 convention and YouTrack's out-of-the-box priorities work unconfigured.
var BUILTIN_SCALES = [
  [["P0", "P0"], ["P1", "P1"], ["P2", "P2"], ["P3", "P3"], ["P4", "P4"]],
  [["Show-stopper", "Stop"], ["Critical", "Crit"], ["Major", "Maj"], ["Normal", "Norm"], ["Minor", "Min"]]
]

var RANK_COLOR_KEYS = ["red", "yellow", "green", "blue", "gray"]

function scaleKey(name) {
  return String(name || "").trim().toLowerCase()
}

// "Urgent=U, High, Low=L" -> a custom scale in that order. Each entry is a
// priority name, optionally followed by "=" and its bar label. An empty or
// blank spec gives the built-in scale.
function makeScale(spec) {
  var scale = { ranks: {}, shorts: {} }
  var entries = String(spec || "").split(",").map(function(e) { return e.trim() }).filter(function(e) { return e !== "" })

  if (entries.length === 0) {
    for (var s = 0; s < BUILTIN_SCALES.length; s++)
      for (var i = 0; i < BUILTIN_SCALES[s].length; i++) {
        scale.ranks[scaleKey(BUILTIN_SCALES[s][i][0])] = i
        scale.shorts[scaleKey(BUILTIN_SCALES[s][i][0])] = BUILTIN_SCALES[s][i][1]
      }
    return scale
  }

  for (var j = 0; j < entries.length; j++) {
    var eq = entries[j].indexOf("=")
    var name = (eq === -1 ? entries[j] : entries[j].slice(0, eq)).trim()
    var short = eq === -1 ? "" : entries[j].slice(eq + 1).trim()
    if (name === "" || scaleKey(name) in scale.ranks) continue
    scale.ranks[scaleKey(name)] = Object.keys(scale.ranks).length
    if (short !== "") scale.shorts[scaleKey(name)] = short
  }
  return scale
}

var DEFAULT_SCALE = makeScale("")

function priorityRank(priority, scale) {
  var rank = (scale || DEFAULT_SCALE).ranks[scaleKey(priority)]
  return rank === undefined ? Infinity : rank
}

function shortLabel(priority, scale) {
  return (scale || DEFAULT_SCALE).shorts[scaleKey(priority)] || String(priority)
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
function groupByPriority(issues, scale) {
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
    var rankA = priorityRank(a.priority, scale)
    var rankB = priorityRank(b.priority, scale)
    if (rankA !== rankB) return rankA < rankB ? -1 : 1
    return a.priority < b.priority ? -1 : (a.priority > b.priority ? 1 : 0)
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

// Which palette role paints a priority: "" for names outside the scale, which
// means "leave it the surrounding foreground color".
function colorKeyFor(priority, scale) {
  var rank = priorityRank(priority, scale)
  if (rank === Infinity) return ""
  return RANK_COLOR_KEYS[Math.min(rank, RANK_COLOR_KEYS.length - 1)]
}

// The bar pill, one segment per priority so each pair takes its own color,
// using the scale's short labels: [{ text: "Crit:1", colorKey: "yellow" }, ...]
function barSegments(groups, emptyLabel, error, scale) {
  if (error) return [{ text: "YT!", colorKey: "red" }]
  if (groups.length === 0) return [{ text: emptyLabel, colorKey: "" }]
  var segments = []
  for (var i = 0; i < groups.length; i++)
    segments.push({
      text: shortLabel(groups[i].priority, scale) + ":" + groups[i].count,
      colorKey: colorKeyFor(groups[i].priority, scale)
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

// Whether anything of the most urgent rank (P0, Show-stopper, or the first
// entry of a custom list) is open.
function hasTopPriority(groups, scale) {
  for (var i = 0; i < groups.length; i++)
    if (groups[i].count > 0 && priorityRank(groups[i].priority, scale) === 0) return true
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
