.pragma library

// The bar's LLM pill: what `shinobi provider readiness --json` says, in a few words.
//
// The bar used to have one word for the AI ("offline") and an operator reading it
// could not act on it: no default chosen, no engagement, an engagement that has not
// cleared cloud egress, a session below operator and a missing key are five
// different fixes. The readiness report already separates them, per provider and
// for the default, so this only has to say the first one that matters.
//
// It decides nothing. It reads a report that the gate's own clearance reader
// produced (see providerctl._readiness) and shortens it; it never reads a key, a
// scope or a setting itself, and a report it cannot make sense of is shown as
// unknown rather than guessed at. This file is plain JavaScript so the logic can
// be tested without a compositor (tests/test-bar-provider.sh).

var UNKNOWN = { label: "LLM ?", tone: "muted" }

// A provider id comes from a manifest and ends up on screen: keep it to the
// characters an id can have and to a length the bar has room for.
function shown(id) {
  var text = String(id).replace(/[^A-Za-z0-9._-]/g, "_")
  return text.length > 24 ? text.slice(0, 23) + "…" : text
}

// The first blocker is the one to fix first: the report lists them in the order the
// gate checks them (engagement, what it permits, cloud clearance, session profile,
// key), and a later one cannot be fixed to any effect while an earlier one stands.
function reason(blocker) {
  var text = String(blocker).toLowerCase()
  if (text.indexOf("no usable engagement") >= 0) return "no engagement"
  if (text.indexOf("(llm.providers)") >= 0) return "not allowed here"
  if (text.indexOf("(llm.models)") >= 0) return "model not allowed"
  if (text.indexOf("not cleared cloud egress") >= 0) return "not cleared"
  if (text.indexOf("operator-or-above") >= 0) return "needs operator"
  if (text.indexOf("no api key") >= 0) return "no key"
  // A default of the operator's own that names a provider no longer installed.
  if (text.indexOf("no provider manifest") >= 0) return "unknown provider"
  return "blocked"
}

// summarize(text): the output of `shinobi provider readiness --json` (empty when the
// command failed). Returns { label, tone }, tone being "good" (the default could be
// used right now), "warn" (something can be done about it) or "muted" (nothing is set
// up, or the report cannot be read).
function parse(text) {
  try {
    var report = JSON.parse(String(text))
    return report && typeof report === "object" ? report : null
  } catch (error) {
    return null
  }
}

function summarize(text) {
  var report = parse(text)
  if (report === null) return UNKNOWN
  var chosen = report["default"]
  if (!chosen || typeof chosen !== "object") return UNKNOWN

  var id = typeof chosen.id === "string" && chosen.id.length > 0 ? chosen.id : null
  if (id === null) {
    // A default that is set but cannot be read comes with a problem and no id.
    if (typeof chosen.problem === "string" && chosen.problem.length > 0)
      return { label: "LLM bad default", tone: "warn" }
    // Nothing chosen. If something could be used, say that a choice is all that is
    // missing; if nothing could, there is nothing to nudge.
    return { label: "LLM none set", tone: report.any_usable === true ? "warn" : "muted" }
  }

  var name = shown(id)
  if (chosen.usable === true && !chosen.problem) return { label: "LLM " + name, tone: "good" }

  var blockers = Array.isArray(chosen.blockers) ? chosen.blockers : []
  var first = blockers.length > 0 ? blockers[0] : (chosen.problem || "")
  return { label: "LLM " + name + " · " + reason(first), tone: "warn" }
}

// rows(text): one row per provider for the panel, or null when the report cannot be read.
// The default comes first (it is the one the agent would use), then what could be used,
// then the rest by name. `right` says where the model runs and, when it cannot be used, the
// first thing in the way -- the same short reasons as the pill.
function rows(text) {
  var report = parse(text)
  if (report === null || !Array.isArray(report.providers)) return null
  var chosen = report["default"] && typeof report["default"].id === "string" ? report["default"].id : null
  var list = report.providers.filter(function (p) { return p && typeof p === "object" && typeof p.id === "string" })
  function rank(p) { return p.id === chosen ? 0 : (p.usable === true ? 1 : 2) }
  list.sort(function (a, b) { return rank(a) - rank(b) || (a.id < b.id ? -1 : (a.id > b.id ? 1 : 0)) })
  return list.map(function (p) {
    var blockers = Array.isArray(p.blockers) ? p.blockers : []
    var where = p.egress === "cloud" ? "cloud" : (p.egress === "local" ? "local" : "?")
    var usable = p.usable === true
    return {
      left: (p.id === chosen ? "● " : "○ ") + shown(p.id),
      right: where + " · " + (usable ? "ready" : reason(blockers.length > 0 ? blockers[0] : "")),
      tone: usable ? "good" : (p.id === chosen ? "warn" : "muted")
    }
  })
}
