// Runs the desktop panel's JavaScript (PanelModel.js, ProviderStatus.js) outside Quickshell and
// prints what the panel would show as JSON: build() applied to a status report and the provider
// rows made from a readiness report, as shell.qml does.
//
//   node tests/panel-model-summary.js <PanelModel.js> <ProviderStatus.js> <status-file> <readiness-file> <now-ms>
//
// The files may hold anything (a failed probe prints nothing): what the panel does with a report
// it cannot read is what is being tested. QML's `.pragma library` line is not JavaScript, so it is
// dropped before a file is evaluated; the tests check separately that it is there.
const fs = require("fs")

function load(file, names) {
  const source = fs.readFileSync(file, "utf8").replace(/^\.pragma library[ \t]*$/m, "")
  return new Function(source + "\nreturn {" + names.map((n) => n + ": " + n).join(",") + "};")()
}

const [, , panelFile, providerFile, statusFile, readinessFile, now] = process.argv
const panel = load(panelFile, ["build"])
const providers = load(providerFile, ["rows"])
const read = (file) => fs.readFileSync(file, "utf8")
// A status file named "null" stands for a probe that has not answered yet (loading).
const status = statusFile === "null" ? null : read(statusFile)
process.stdout.write(JSON.stringify(panel.build(status, providers.rows(read(readinessFile)), Number(now))) + "\n")
