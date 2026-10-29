import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
usage: roster-probe <command>

  list [--all]
      call-capable apps that are running, with their windows (title, pid, bundle id).

  dump --app zoom|chrome|arc|safari|teams|<bundle id> [--window <title part>] [--depth N] [--max-nodes N]
       [--budget SECONDS] [--no-enable] [--fixed-attrs] [--out file.json]
      one accessibility snapshot of the call window, as JSON, and a console summary of the names found.

  watch --app … [--window <title part>] [--interval 0.25] [--seconds 120] [--tiles-only]
        [--depth N] [--max-nodes N] [--no-enable] [--fixed-attrs] [--out file.jsonl]
      samples repeatedly and logs only what changes, with timestamps. also writes <out>.baseline.json.

  analyze file.jsonl [--out report.txt]
      the names found, which attributes toggled per name (a speaking indicator shows up here),
      and the stable paths and identifiers to target.

output defaults to /tmp/roster-probe. it holds names and on-screen text; never commit it.
needs Accessibility permission for the terminal that runs this. see README.md.
"""

var arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else {
    print(usage)
    exit(2)
}
let command = arguments.removeFirst()

do {
    let args = try Args(arguments)
    switch command {
    case "list": try ListCommand.run(args)
    case "dump": try DumpCommand.run(args)
    case "watch": try WatchCommand.run(args)
    case "analyze": try AnalyzeCommand.run(args)
    case "help", "--help", "-h": print(usage)
    default: throw ProbeError("unknown command '\(command)'\n\n\(usage)")
    }
} catch {
    FileHandle.standardError.write(Data("roster-probe: \(error.localizedDescription)\n".utf8))
    exit(2)
}
