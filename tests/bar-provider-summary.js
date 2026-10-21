// Runs the status bar's ProviderStatus.js outside Quickshell: reads a readiness report
// (or whatever the probe printed) on stdin and prints "<label><TAB><tone>", or with the
// argument `rows`, one "<left><TAB><right><TAB><tone>" line per provider row (`null` when
// the panel would have none).
//
//   shinobi provider readiness --json | node tests/bar-provider-summary.js <ProviderStatus.js> [rows]
//
// QML's `.pragma library` line is not JavaScript, so it is dropped before the file is
// evaluated; the test checks separately that the line is there.
const fs = require("fs")

const source = fs.readFileSync(process.argv[2], "utf8").replace(/^\.pragma library[ \t]*$/m, "")
const library = new Function(source + "\nreturn { summarize: summarize, rows: rows };")()
const input = fs.readFileSync(0, "utf8")
if (process.argv[3] === "rows") {
  const rows = library.rows(input)
  process.stdout.write(rows === null ? "null\n" : rows.map((r) => [r.left, r.right, r.tone].join("\t")).join("\n") + "\n")
} else {
  const summary = library.summarize(input)
  process.stdout.write(summary.label + "\t" + summary.tone + "\n")
}
