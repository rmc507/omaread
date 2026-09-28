.pragma library

// Pure helpers for the speed reader overlay: config, tokenizing, timing.
// Kept free of QML types so tests/reader-model.test.js can run it in node.

var SOURCES = ["auto", "clipboard", "selection"]
var EXTRACTORS = ["auto", "defuddle", "builtin"]

var DEFAULTS = {
  wpm: 300,
  wpmStep: 25,
  source: "auto",
  extractor: "auto",
  fontSize: 0,            // 0 = derive from the theme's font scale
  width: 0,               // 0 = derive from the theme's spacing scale
  focusPosition: 0.5,     // where the focus letter sits across the card, 0..1
  punctuationPause: 2.0,  // delay multiplier at sentence ends
  longWordPause: 1.4,     // delay multiplier for long words
  longWordLength: 8,
  startDelay: 800         // ms the first word is held before reading starts
}

function num(value, fallback, min, max) {
  var n = Number(value)
  if (value === null || value === undefined || value === "" || !isFinite(n)) return fallback
  return Math.min(max, Math.max(min, n))
}

function oneOf(value, list, fallback) {
  return list.indexOf(String(value)) !== -1 ? String(value) : fallback
}

function normalizeConfig(raw) {
  var c = raw && typeof raw === "object" ? raw : {}
  var fontSize = num(c.fontSize, 0, 0, 240)
  var width = num(c.width, 0, 0, 4000)
  return {
    wpm: Math.round(num(c.wpm, DEFAULTS.wpm, 60, 1500)),
    wpmStep: Math.round(num(c.wpmStep, DEFAULTS.wpmStep, 5, 200)),
    source: oneOf(c.source, SOURCES, DEFAULTS.source),
    extractor: oneOf(c.extractor, EXTRACTORS, DEFAULTS.extractor),
    fontSize: fontSize > 0 ? Math.max(12, fontSize) : 0,
    width: width > 0 ? Math.max(240, width) : 0,
    focusPosition: num(c.focusPosition, DEFAULTS.focusPosition, 0.2, 0.8),
    punctuationPause: num(c.punctuationPause, DEFAULTS.punctuationPause, 1, 5),
    longWordPause: num(c.longWordPause, DEFAULTS.longWordPause, 1, 3),
    longWordLength: Math.round(num(c.longWordLength, DEFAULTS.longWordLength, 3, 30)),
    startDelay: Math.round(num(c.startDelay, DEFAULTS.startDelay, 0, 5000))
  }
}

// Our settings are the plugin's own entry in shell.json's plugins[] array.
function findEntry(shellJsonText, id) {
  var config
  try { config = JSON.parse(shellJsonText || "{}") } catch (e) { return {} }
  var plugins = config && Array.isArray(config.plugins) ? config.plugins : []
  for (var i = 0; i < plugins.length; i++)
    if (plugins[i] && plugins[i].id === id) return plugins[i]
  return {}
}

// fetch-text prints "<title>\n\n<text>".
function parseFetchOutput(out) {
  var text = String(out || "")
  var split = text.indexOf("\n\n")
  if (split === -1) return { title: "", text: text.trim() }
  return { title: text.slice(0, split).trim(), text: text.slice(split + 2).trim() }
}

var CLOSERS = "[\"'”’)\\]]*$"
var SENTENCE_END = new RegExp("[.!?…]" + CLOSERS)
var CLAUSE_END = new RegExp("[,;:—–]" + CLOSERS)
var WORD_CHAR = /[A-Za-z0-9À-￿]/

// Each token is { text, end } with end one of "", "clause", "sentence",
// "paragraph"; paragraph wins over sentence so breaks get the longest pause.
function tokenize(text) {
  var tokens = []
  var paragraphs = String(text || "").split(/\n\s*\n/)
  for (var p = 0; p < paragraphs.length; p++) {
    var words = paragraphs[p].split(/\s+/).filter(function(w) { return w.length > 0 })
    for (var i = 0; i < words.length; i++) {
      var word = words[i]
      var end = ""
      if (i === words.length - 1) end = "paragraph"
      else if (SENTENCE_END.test(word)) end = "sentence"
      else if (CLAUSE_END.test(word)) end = "clause"
      tokens.push({ text: word, end: end })
    }
  }
  return tokens
}

function coreBounds(word) {
  var first = -1
  var last = -1
  for (var i = 0; i < word.length; i++) {
    if (WORD_CHAR.test(word.charAt(i))) {
      if (first === -1) first = i
      last = i
    }
  }
  if (first === -1) return { first: 0, length: word.length }
  return { first: first, length: last - first + 1 }
}

// Optimal recognition point: a letter a little left of the word's middle,
// ignoring leading quotes/brackets so "(hello" focuses the same as "hello".
function focusIndex(word) {
  if (!word) return 0
  var core = coreBounds(word)
  var n = core.length
  var offset = n <= 1 ? 0 : n <= 5 ? 1 : n <= 9 ? 2 : n <= 13 ? 3 : 4
  return Math.min(word.length - 1, core.first + offset)
}

function splitWord(word) {
  var text = String(word || "")
  if (!text) return { pre: "", focus: "", post: "" }
  var i = focusIndex(text)
  return { pre: text.slice(0, i), focus: text.charAt(i), post: text.slice(i + 1) }
}

function isSentenceEnd(token) {
  return !!token && (token.end === "sentence" || token.end === "paragraph")
}

function delayMs(token, cfg, wpm) {
  var delay = 60000 / Math.max(1, wpm)
  if (!token) return delay
  if (coreBounds(token.text).length > cfg.longWordLength) delay *= cfg.longWordPause
  if (token.end === "paragraph") delay *= cfg.punctuationPause * 1.5
  else if (token.end === "sentence") delay *= cfg.punctuationPause
  else if (token.end === "clause") delay *= 1 + (cfg.punctuationPause - 1) / 2
  return Math.round(delay)
}

function averageDelayMs(tokens, cfg, wpm) {
  if (!tokens || tokens.length === 0) return 0
  var total = 0
  for (var i = 0; i < tokens.length; i++) total += delayMs(tokens[i], cfg, wpm)
  return total / tokens.length
}

function sentenceStart(tokens, index) {
  var i = Math.max(0, Math.min(index, tokens.length - 1))
  while (i > 0 && !isSentenceEnd(tokens[i - 1])) i--
  return i
}

// Back jumps to the start of the current sentence, or to the previous
// sentence when already at (or one word into) the start.
function previousSentence(tokens, index) {
  if (tokens.length === 0) return 0
  var start = sentenceStart(tokens, index)
  if (index - start <= 1 && start > 0) return sentenceStart(tokens, start - 1)
  return start
}

function nextSentence(tokens, index) {
  if (tokens.length === 0) return 0
  var i = Math.max(0, index)
  while (i < tokens.length - 1 && !isSentenceEnd(tokens[i])) i++
  return Math.min(i + 1, tokens.length - 1)
}

function formatDuration(ms) {
  var total = Math.max(0, Math.round(ms / 1000))
  var h = Math.floor(total / 3600)
  var m = Math.floor((total % 3600) / 60)
  var s = total % 60
  var ss = (s < 10 ? "0" : "") + s
  if (h > 0) return h + ":" + (m < 10 ? "0" : "") + m + ":" + ss
  return m + ":" + ss
}
