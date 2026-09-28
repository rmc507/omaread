// Run with: node --test tests/*.test.js
// Loads ReaderModel.js (a QML JS library) by dropping its `.pragma library` line.
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")

const source = fs.readFileSync(path.join(__dirname, "..", "ReaderModel.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "")
const M = new Function(source + "\nreturn { DEFAULTS, START_DELAY, normalizeConfig, normalizeWpm, findEntry, parseFetchOutput, tokenize, focusIndex, splitWord, delayMs, averageDelayMs, previousSentence, nextSentence, formatDuration }")()

test("normalizeConfig keeps only wpm, source and fontSize", () => {
  const cfg = M.normalizeConfig({ wpm: 5000, source: "bogus", fontSize: 4, focusPosition: 0.1 })
  assert.deepEqual(cfg, { wpm: 1500, source: "auto", fontSize: 12 })
  assert.deepEqual(M.normalizeConfig(null), { wpm: 400, source: "auto", fontSize: 0 })
  assert.equal(M.normalizeConfig({ wpm: "450" }).wpm, 450)
  assert.equal(M.normalizeWpm(10), 60)
  assert.equal(M.normalizeWpm(undefined), 400)
})

test("findEntry reads our plugins[] entry and tolerates bad JSON", () => {
  const json = JSON.stringify({ plugins: [{ id: "other" }, { id: "io.github.rmc507.speed-reader", wpm: 420 }] })
  assert.equal(M.findEntry(json, "io.github.rmc507.speed-reader").wpm, 420)
  assert.deepEqual(M.findEntry("{not json", "io.github.rmc507.speed-reader"), {})
  assert.deepEqual(M.findEntry(JSON.stringify({ bar: {} }), "io.github.rmc507.speed-reader"), {})
})

test("parseFetchOutput splits title from body", () => {
  assert.deepEqual(M.parseFetchOutput("Title\n\nOne two.\n\nThree.\n"), { title: "Title", text: "One two.\n\nThree." })
  assert.deepEqual(M.parseFetchOutput("just text"), { title: "", text: "just text" })
})

test("tokenize marks clause, sentence and paragraph ends", () => {
  const t = M.tokenize("Hello, world. \"Quoted!\" end\n\nNext para")
  assert.deepEqual(t.map(x => x.text), ["Hello,", "world.", "\"Quoted!\"", "end", "Next", "para"])
  assert.deepEqual(t.map(x => x.end), ["clause", "sentence", "sentence", "paragraph", "", "paragraph"])
  assert.deepEqual(M.tokenize("   \n\n  "), [])
})

test("focus letter is left of centre and skips leading punctuation", () => {
  assert.equal(M.focusIndex("a"), 0)
  assert.equal(M.focusIndex("Hello"), 1)
  assert.equal(M.focusIndex("demonstrate"), 3)
  assert.equal(M.focusIndex("(Hello"), 2)
  assert.deepEqual(M.splitWord("Hello"), { pre: "H", focus: "e", post: "llo" })
  assert.deepEqual(M.splitWord("—"), { pre: "", focus: "—", post: "" })
  assert.deepEqual(M.splitWord(""), { pre: "", focus: "", post: "" })
})

test("delays scale with wpm, punctuation and word length", () => {
  assert.equal(M.delayMs({ text: "word", end: "" }, 300), 200)
  assert.equal(M.delayMs({ text: "word,", end: "clause" }, 300), 250)
  assert.equal(M.delayMs({ text: "word.", end: "sentence" }, 300), 300)
  assert.equal(M.delayMs({ text: "word", end: "paragraph" }, 300), 400)
  assert.equal(M.delayMs({ text: "extraordinary", end: "" }, 300), 230)
  assert.equal(M.delayMs({ text: "word", end: "" }, 600), 100)
  assert.equal(M.averageDelayMs([], 300), 0)
  assert.ok(M.START_DELAY <= 400)
})

test("sentence navigation", () => {
  const t = M.tokenize("One two three. Four five six. Seven eight.")
  // indices: One0 two1 three2 | Four3 five4 six5 | Seven6 eight7
  assert.equal(M.previousSentence(t, 5), 3)   // mid-sentence -> its start
  assert.equal(M.previousSentence(t, 3), 0)   // at start -> previous sentence
  assert.equal(M.previousSentence(t, 4), 0)   // one word in still counts as the start
  assert.equal(M.previousSentence(t, 0), 0)
  assert.equal(M.nextSentence(t, 1), 3)
  assert.equal(M.nextSentence(t, 3), 6)
  assert.equal(M.nextSentence(t, 7), 7)       // last sentence stays put
  assert.equal(M.nextSentence([], 0), 0)
})

test("formatDuration", () => {
  assert.equal(M.formatDuration(0), "0:00")
  assert.equal(M.formatDuration(65000), "1:05")
  assert.equal(M.formatDuration(3723000), "1:02:03")
})
