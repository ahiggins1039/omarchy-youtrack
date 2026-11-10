// Run with: node --test tests/model.test.js
// Model.js is a QML JavaScript library, so it is loaded into a plain context
// with its `.pragma library` line stripped.
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const Model = vm.createContext({})
vm.runInContext(source, Model)

const issue = (priority, updated = 0, extra = {}) => ({ id: `T-${priority}-${updated}`, priority, updated, ...extra })
const plain = value => JSON.parse(JSON.stringify(value))
const order = groups => groups.map(g => g.priority)

test("P0-P4 work unconfigured", () => {
  const groups = Model.groupByPriority([issue("P2"), issue("P0"), issue("P4"), issue("P1")])
  assert.deepEqual(plain(order(groups)), ["P0", "P1", "P2", "P4"])
  assert.deepEqual(plain(Model.barSegments(groups, "YT:0", false)), [
    { text: "P0:1", colorKey: "red" },
    { text: "P1:1", colorKey: "yellow" },
    { text: "P2:1", colorKey: "green" },
    { text: "P4:1", colorKey: "gray" }
  ])
  assert.equal(Model.hasTopPriority(groups), true)
})

test("YouTrack's default priorities work unconfigured, with short bar labels", () => {
  const groups = Model.groupByPriority([issue("Minor"), issue("Major"), issue("Show-stopper"), issue("Normal"), issue("Critical")])
  assert.deepEqual(plain(order(groups)), ["Show-stopper", "Critical", "Major", "Normal", "Minor"])
  assert.deepEqual(plain(Model.barSegments(groups, "YT:0", false)).map(s => s.text), ["Stop:1", "Crit:1", "Maj:1", "Norm:1", "Min:1"])
  assert.deepEqual(plain(Model.barSegments(groups, "YT:0", false)).map(s => s.colorKey), ["red", "yellow", "green", "blue", "gray"])
  assert.equal(Model.hasTopPriority(groups), true)
  // The tooltip keeps the full names.
  assert.equal(Model.barLabel(groups, "YT:0"), "Show-stopper:1 Critical:1 Major:1 Normal:1 Minor:1")
})

test("no top priority, no blocker", () => {
  assert.equal(Model.hasTopPriority(Model.groupByPriority([issue("Critical"), issue("P1")])), false)
})

test("matching ignores case and surrounding spaces", () => {
  assert.equal(Model.colorKeyFor("show-stopper"), "red")
  assert.equal(Model.shortLabel(" MAJOR "), "Maj")
})

test("unknown names and None come after known ones, alphabetically, uncolored", () => {
  const groups = Model.groupByPriority([issue("Zebra"), issue("None"), issue("Major"), issue("Alpha")])
  assert.deepEqual(plain(order(groups)), ["Major", "Alpha", "None", "Zebra"])
  assert.equal(Model.colorKeyFor("Alpha"), "")
  assert.equal(Model.shortLabel("Alpha"), "Alpha")
})

test("a custom scale replaces the built-ins", () => {
  const scale = Model.makeScale(" Urgent=U, High , Low=L, Later, Someday, Never ")
  const groups = Model.groupByPriority([issue("Low"), issue("High"), issue("Urgent"), issue("P0"), issue("Never")], scale)
  assert.deepEqual(plain(order(groups)), ["Urgent", "High", "Low", "Never", "P0"])
  assert.deepEqual(plain(Model.barSegments(groups, "YT:0", false, scale)), [
    { text: "U:1", colorKey: "red" },
    { text: "High:1", colorKey: "yellow" },
    { text: "L:1", colorKey: "green" },
    { text: "Never:1", colorKey: "gray" },
    { text: "P0:1", colorKey: "" }
  ])
  assert.equal(Model.hasTopPriority(groups, scale), true)
  assert.equal(Model.hasTopPriority(Model.groupByPriority([issue("P0")], scale), scale), false)
})

test("a blank or junk spec falls back to the built-ins; duplicates keep the first", () => {
  assert.equal(Model.colorKeyFor("Critical", Model.makeScale(" , ,")), "yellow")
  const scale = Model.makeScale("A, B, a=X")
  assert.equal(Model.priorityRank("a", scale), 0)
  assert.equal(Model.shortLabel("A", scale), "A")
})

test("within a priority, newest update first", () => {
  const [group] = Model.groupByPriority([issue("P1", 1), issue("P1", 3), issue("P1", 2)])
  assert.deepEqual(plain(group.issues.map(i => i.updated)), [3, 2, 1])
})

test("errors and empty queues", () => {
  assert.deepEqual(plain(Model.barSegments([], "YT:0", true)), [{ text: "YT!", colorKey: "red" }])
  assert.deepEqual(plain(Model.barSegments([], "YT:0", false)), [{ text: "YT:0", colorKey: "" }])
})

test("search filters on every term", () => {
  const issues = [issue("P1", 0, { summary: "Login bug", type: "Bug" }), issue("P2", 0, { summary: "Login copy", type: "Task" })]
  assert.equal(Model.filterIssues(issues, "login bug").length, 1)
  assert.equal(Model.filterIssues(issues, "").length, 2)
})
