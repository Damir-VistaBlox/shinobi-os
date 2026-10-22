.pragma library

// What the desktop panel says, built from two reports: `shinobi panel status --json` (the
// engagement, the approvals waiting for a human, what the agent's tools last did) and the
// provider rows ProviderStatus.rows() makes from the readiness report.
//
// The panel is somewhere to look, not somewhere to decide: nothing here approves, clears or
// changes anything, and every row is text the operator can act on with a command they can
// read. It is plain JavaScript so it can be tested without a compositor
// (tests/test-panel.sh). A report it cannot make sense of is shown as unavailable, never
// as the last good state and never as an empty (and so reassuring) section; a section the
// report marks unavailable (null) is shown as unavailable on its own, and a report that has
// been asked for and has not come yet is shown as loading.
//
// A row is { left, right, tone }: tone is "good", "warn", "muted" or "plain".

function parse(text) {
  var report
  try {
    report = JSON.parse(String(text))
  } catch (error) {
    return null
  }
  if (!report || typeof report !== "object" || report.version !== 1) return null
  if (!report.engagement || typeof report.engagement !== "object") return null
  // A section that could not be read is null: unavailable, which is not the same as empty.
  if (report.approvals !== null && (typeof report.approvals !== "object" || !Array.isArray(report.approvals.pending))) return null
  if (report.activity !== null && !Array.isArray(report.activity)) return null
  return report
}

function span(ms) {
  var seconds = Math.floor(ms / 1000)
  if (seconds < 60) return seconds + "s"
  if (seconds < 3600) return Math.floor(seconds / 60) + "m"
  if (seconds < 86400) return Math.floor(seconds / 3600) + "h"
  return Math.floor(seconds / 86400) + "d"
}

function ago(iso, nowMs) {
  var then = Date.parse(iso)
  if (isNaN(then)) return ""
  var elapsed = Math.max(0, nowMs - then)
  return elapsed < 5000 ? "just now" : span(elapsed) + " ago"
}

function remaining(iso, nowMs) {
  var then = Date.parse(iso)
  if (isNaN(then)) return ""
  return then <= nowMs ? "expired" : span(then - nowMs) + " left"
}

function unavailable(what) {
  return [{ left: what + " unavailable", right: "", tone: "warn" }]
}

function loading() {
  return [{ left: "loading…", right: "", tone: "muted" }]
}

function engagementRows(report) {
  var e = report.engagement
  if (e.state === "none")
    return [
      { left: "none active", right: "profile " + report.profile, tone: "muted" },
      { left: "shinobi engagement use <name>", right: "", tone: "muted" }
    ]
  if (e.state === "problem")
    return [
      { left: e.name || "engagement", right: "cannot be used", tone: "warn" },
      { left: e.problem || "", right: "", tone: "muted" }
    ]
  var w = e.window || {}
  var window = w.state === "active" ? { text: "active · ends " + w.end, tone: "good" }
    : w.state === "upcoming" ? { text: "starts " + w.start, tone: "warn" }
    : w.state === "expired" ? { text: "expired " + w.end, tone: "warn" }
    : { text: "not set (edit window.start and window.end)", tone: "warn" }
  var out = [
    { left: e.name, right: "profile " + report.profile, tone: "good" },
    { left: "window", right: window.text, tone: window.tone },
    { left: "targets", right: String(e.target_count), tone: e.target_count > 0 ? "plain" : "warn" }
  ]
  var targets = Array.isArray(e.targets) ? e.targets : []
  targets.forEach(function (target) { out.push({ left: "  " + target, right: "", tone: "muted" }) })
  if (e.target_count > targets.length)
    out.push({ left: "  +" + (e.target_count - targets.length) + " more", right: "", tone: "muted" })
  return out
}

function approvalRows(report, nowMs) {
  var a = report.approvals
  if (a === null) return unavailable("approvals")
  var pending = a.pending
  var out = []
  // A record that could not be read might be the pending one: say so, never skip it quietly.
  if (a.unreadable > 0)
    out.push({ left: a.unreadable + " approval record" + (a.unreadable === 1 ? "" : "s") + " could not be read", right: "", tone: "warn" })
  if (a.pending_count === 0 || pending.length === 0)
    return out.length > 0 ? out : [{ left: "none waiting", right: "", tone: "muted" }]
  pending.forEach(function (item) {
    out.push({ left: item.capability, right: remaining(item.expires_at, nowMs), tone: "warn" })
    out.push({ left: "  " + item.reason + " (" + String(item.approval_id).slice(0, 8) + ")", right: "", tone: "muted" })
  })
  if (a.pending_count > pending.length)
    out.push({ left: "  +" + (a.pending_count - pending.length) + " more", right: "", tone: "muted" })
  out.push({ left: "  shinobi approval show <id> / approve / deny", right: "", tone: "muted" })
  return out
}

function activityRows(report, nowMs) {
  if (report.activity === null) return unavailable("activity")
  if (report.activity.length === 0) return [{ left: "nothing yet", right: "", tone: "muted" }]
  return report.activity.map(function (row) {
    var tone = row.verdict === "allowed" ? "good" : (row.verdict === "started" ? "muted" : "warn")
    var when = ago(row.time, nowMs)
    return {
      left: row.tool + (row.target ? " " + row.target : ""),
      right: row.verdict + (when ? " · " + when : ""),
      tone: tone
    }
  })
}

// build(statusText, providerRows, nowMs): { sections: [{ title, command, rows }], footer }.
// `command` is what a click on that section runs ("" for none). statusText is the probe's
// answer, "" when it gave none, or null while it has not been asked yet (loading).
function build(statusText, providerRows, nowMs) {
  var report = statusText === null || statusText === undefined ? null : parse(statusText)
  if (statusText === null || statusText === undefined) {
    var wait = providerRows === null || providerRows === undefined ? unavailable("provider report") : providerRows
    return {
      sections: [
        { title: "ENGAGEMENT", command: "", rows: loading() },
        { title: "LLM", command: "shinobi-menu provider", rows: wait.length > 0 ? wait : loading() },
        { title: "APPROVALS", command: "", rows: loading() },
        { title: "ACTIVITY", command: "", rows: loading() }
      ],
      footer: "click LLM to manage providers · SUPER+A closes"
    }
  }
  var providers = providerRows === null || providerRows === undefined
    ? unavailable("provider report")
    : (providerRows.length > 0 ? providerRows : [{ left: "no providers installed", right: "", tone: "warn" }])
  var sections = []
  if (report === null) {
    sections.push({ title: "ENGAGEMENT", command: "", rows: unavailable("status") })
  } else {
    sections.push({ title: "ENGAGEMENT", command: "", rows: engagementRows(report) })
  }
  sections.push({ title: "LLM", command: "shinobi-menu provider", rows: providers })
  if (report !== null) {
    sections.push({ title: "APPROVALS", command: "", rows: approvalRows(report, nowMs) })
    sections.push({ title: "ACTIVITY", command: "", rows: activityRows(report, nowMs) })
  }
  return { sections: sections, footer: "click LLM to manage providers · SUPER+A closes" }
}
