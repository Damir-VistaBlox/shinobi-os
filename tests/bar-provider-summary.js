// Runs the status bar's ProviderStatus.js outside Quickshell: reads a readiness report
// (or whatever the probe printed) on stdin and prints "<label><TAB><tone>".
//
//   shinobi provider readiness --json | node tests/bar-provider-summary.js <ProviderStatus.js>
//
// QML's `.pragma library` line is not JavaScript, so it is dropped before the file is
// evaluated; the test checks separately that the line is there.
const fs = require("fs")

const source = fs.readFileSync(process.argv[2], "utf8").replace(/^\.pragma library[ \t]*$/m, "")
const library = new Function(source + "\nreturn { summarize: summarize };")()
const summary = library.summarize(fs.readFileSync(0, "utf8"))
process.stdout.write(summary.label + "\t" + summary.tone + "\n")
