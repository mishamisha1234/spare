import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpareCore

/// Generates a batch of lessons through the real pipeline and the real prompts,
/// writes each one to markdown, and reports words against budget, quality
/// findings, and actual cost.
///
/// The point is to judge the prompts, so it uses `ProxyProvider` and therefore
/// `Prompts.swift` — the same two-pass draft-and-revision pipeline, the same
/// editorial system prompt, the same word budgets, the same chaptered path for a
/// 30-minute course. A PowerShell script sending its own prompt measures cost
/// and speed honestly and says nothing at all about the writing.
///
/// Lives in the SpareCore package rather than beside the server for the same
/// reason: anything that reimplements the prompts elsewhere will drift from them.

// MARK: - Arguments

struct Options {
    var baseURL: URL
    var token: String
    var outputDirectory: URL
    var only: TimeWindow?
    var deviceID: String

    static func parse() throws -> Options {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var values: [String: String] = [:]

        while let flag = arguments.first {
            arguments.removeFirst()
            guard flag.hasPrefix("--") else {
                throw Failure("unexpected argument \"\(flag)\"")
            }
            guard let value = arguments.first, !value.hasPrefix("--") else {
                throw Failure("\(flag) needs a value")
            }
            arguments.removeFirst()
            values[String(flag.dropFirst(2))] = value
        }

        let environment = ProcessInfo.processInfo.environment
        let rawURL = values["base-url"] ?? environment["SPARE_PROXY_URL"] ?? ""
        let token = values["token"] ?? environment["SPARE_ADMIN_TOKEN"] ?? ""

        guard let url = URL(string: rawURL), url.scheme == "https" else {
            throw Failure("--base-url must be an https URL (or set SPARE_PROXY_URL)")
        }
        guard !token.isEmpty else {
            throw Failure("--token is required (or set SPARE_ADMIN_TOKEN)")
        }

        var only: TimeWindow?
        if let raw = values["only"] {
            guard let window = TimeWindow(rawValue: raw) else {
                throw Failure("--only must be three, ten, fifteen, or thirty")
            }
            only = window
        }

        let out = values["out"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("lessons-\(Self.stamp())")

        return Options(
            baseURL: url,
            token: token,
            outputDirectory: out,
            only: only,
            // A fresh identity per run. The operator token means the daily limit
            // does not apply, but a stable id would still accumulate a "seen"
            // history that could suppress cache reads in a later, non-operator
            // test from the same id.
            deviceID: "batch-\(UUID().uuidString)"
        )
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - What to generate

/// Eight subjects, two per length, spread across domains so the batch shows
/// what the prompts do with different kinds of material rather than two
/// variations on one.
///
/// Deliberately fresh: none of these appeared in the first batch, and none is
/// adjacent to one that did. A rewritten prompt judged on the same subjects
/// would be judged partly on how well the model already knew them.
///
/// Chosen against the specific rules that changed, too. Several carry a second
/// argument that wants to become a section (the Aral Sea is an irrigation story
/// and a fisheries collapse; decipherment is four separate scripts), which is
/// what "one argument per lesson" now has to hold back. Several have a named
/// person whose fate is load-bearing, which is what "give people room" has to
/// spend words on. And two are quantitative enough to tempt a displayed sum.
let topics: [TimeWindow: [(title: String, hook: String, domain: String)]] = [
    .three: [
        ("Why paper cuts hurt so much", "A shallow wound the body treats as an emergency.", "Biology"),
        ("Why tunnels are dug from both ends", "Meeting in the middle is a surveying problem, not a digging one.", "Engineering"),
    ],
    .ten: [
        ("How standard time was imposed", "Railways needed one clock, and towns fought back.", "History"),
        ("Why insulin stayed cheap for decades", "A patent sold for a dollar, and what happened after.", "Medicine"),
    ],
    .fifteen: [
        ("How double-entry bookkeeping spread", "A merchant's habit that made the modern firm possible.", "Economics"),
        ("Why the Aral Sea drained", "Every decision along the way was locally rational.", "Environment"),
    ],
    .thirty: [
        ("How lost writing systems were deciphered", "Linear B, Maya glyphs, and the ones still unread.", "Linguistics"),
        ("How electricity grids stay balanced", "Supply has to equal demand every second, forever.", "Engineering"),
    ],
]

/// A plausible post-onboarding reader, not an empty one.
///
/// The prompts tailor to this, so generating against `.empty` would judge the
/// prompts in a state almost no real user is in. Printed in the summary so the
/// output is read knowing what conditioned it.
let profile = ProfileSnapshot(
    interests: ["History", "Engineering", "Biology"],
    work: "Product manager at a logistics company",
    curiosityGaps: ["How supply chains actually clear", "Why antibiotics stopped working"],
    complexity: .standard
)

// MARK: - Table formatting

/// Column padding, written out rather than using `String(format:)`.
///
/// Foundation's `%@` is a Darwin ObjC bridge. On Linux it does not do what it
/// does on a Mac, and the failure is silent — a misaligned or empty column, not
/// a compile error. This whole tool runs on Linux in CI, so none of the
/// reporting uses it.
func pad(_ value: String, _ width: Int) -> String {
    value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
}

func padLeft(_ value: String, _ width: Int) -> String {
    value.count >= width ? value : String(repeating: " ", count: width - value.count) + value
}

func money(_ dollars: Double) -> String {
    "$" + String(format: "%.4f", dollars)
}

// MARK: - Result rows

struct Row {
    let window: TimeWindow
    let title: String
    let words: Int
    let budget: ClosedRange<Int>
    let seconds: Double
    let costUSD: Double
    let calls: Int
    let findings: [LessonQualityCheck.Finding]
    let file: String

    var verdict: String {
        if words < budget.lowerBound { return "under" }
        if words > budget.upperBound { return "over" }
        return "in budget"
    }
}

// MARK: - Run

func run() async throws {
    let options = try Options.parse()
    let plan = options.only.map { [$0] } ?? TimeWindow.allCases
    let total = plan.reduce(0) { $0 + (topics[$1]?.count ?? 0) }

    try FileManager.default.createDirectory(
        at: options.outputDirectory, withIntermediateDirectories: true
    )

    print("")
    print("Spare lesson batch — real prompts, real pipeline")
    print("  proxy:  \(options.baseURL.absoluteString)")
    print("  output: \(options.outputDirectory.path)")
    print("  \(total) lessons, two passes each; a 30-minute course is an outline plus 4 chapters x 2")
    print("  reader: \(profile.work)")
    print("")

    var rows: [Row] = []
    var runningCost = 0.0
    var index = 0

    for window in plan {
        for topic in topics[window] ?? [] {
            index += 1
            // One complete line per lesson, printed when it finishes. The
            // original wrote a partial line first and flushed, which reads
            // better in a terminal but does not compile under Swift 6: `stdout`
            // is a Glibc global var, and touching it from an async context is
            // shared mutable state. In a CI log, where this actually runs, a
            // line appearing every minute or two is the progress indicator.
            let counter = "[" + padLeft("\(index)", 2) + "/\(total)]"
            let prefix = counter + " " + pad(window.label, 7) + " " + pad(topic.title, 40)

            // A ledger per lesson, so the cost reported is this lesson's and not
            // a share of the run. Every call the pipeline makes lands here,
            // which is also how the call count is honest for chaptered formats.
            let ledger = InMemoryUsageLedger()
            let provider = ProxyProvider(
                transport: FoundationHTTPTransport(),
                baseURL: options.baseURL,
                deviceID: options.deviceID,
                ledger: ledger,
                operatorToken: options.token
            )

            let suggestion = TopicSuggestion(
                title: topic.title, hook: topic.hook, domainTag: topic.domain
            )

            let started = Date()
            do {
                let lesson = try await provider.generateLesson(
                    topic: suggestion, window: window, profile: profile
                )
                let seconds = Date().timeIntervalSince(started)
                let events = await ledger.events
                let cost = events.reduce(0) { $0 + $1.estimatedCostUSD }
                runningCost += cost

                let findings = LessonQualityCheck.findings(for: lesson, window: window)
                let file = try write(
                    lesson: lesson, window: window, index: index, seconds: seconds,
                    cost: cost, events: events, findings: findings,
                    directory: options.outputDirectory
                )

                let row = Row(
                    window: window, title: lesson.title, words: lesson.wordCount,
                    budget: window.wordBudget, seconds: seconds, costUSD: cost,
                    calls: events.count, findings: findings, file: file
                )
                rows.append(row)

                print(prefix + "  " + padLeft("\(row.words)", 5) + " words  "
                      + pad(row.verdict, 9) + "  " + padLeft(money(cost), 9)
                      + "  " + padLeft(String(format: "%.0f", seconds), 4) + "s"
                      + "  " + padLeft("\(events.count)", 2) + " calls"
                      + (findings.isEmpty ? "" : "  \(findings.count) findings"))
                for finding in findings {
                    print("        - \(finding.description)")
                }
            } catch {
                print(prefix + "  FAILED  " + describe(error))
                if isFatal(error) {
                    print("")
                    print("Stopping: nothing further will succeed.")
                    printSummary(rows: rows, plan: plan, cost: runningCost, directory: options.outputDirectory)
                    return
                }
            }
        }
    }

    printSummary(rows: rows, plan: plan, cost: runningCost, directory: options.outputDirectory)
}

/// A refusal that means the rest of the run is pointless, rather than one lesson
/// that happened not to work.
func isFatal(_ error: Error) -> Bool {
    guard let providerError = error as? LessonProviderError else { return false }
    switch providerError {
    case .limited(let limit, _):
        // dailyLimitReached or lockedWindow here means the operator token was
        // not accepted, so every remaining request will be refused too.
        return limit == .dailyLesson || limit == .lockedWindow || limit == .spendCeiling
    case .missingAPIKey:
        return true
    default:
        return false
    }
}

/// The reader-facing copy is the wrong thing to print here.
///
/// The first batch lost five lessons to "Anthropic is having trouble", which is
/// what `ProviderErrorCopy` says for any status at or above 500 — and the proxy
/// answers 502 both when Anthropic is down and when Anthropic refused what the
/// proxy sent. One of those is worth retrying and the other is a bug, and the
/// log could not tell them apart. It took reading the routing table to find out
/// which it had been.
func describe(_ error: Error) -> String {
    guard let providerError = error as? LessonProviderError else { return "\(error)" }
    switch providerError {
    case .limited(.dailyLesson, _), .limited(.lockedWindow, _):
        return "the operator token was not accepted — check ADMIN_TOKEN on the Worker matches --token, and that it has been redeployed"
    case .limited(.spendCeiling, let message):
        return "spend ceiling reached — \(message)"
    case .limited(let limit, let message):
        return "refused: \(limit.rawValue) — \(message)"
    case .httpStatus(let code, let message):
        let detail = message.isEmpty ? ProviderErrorCopy.presentation(for: providerError).title : message
        return "HTTP \(code) — \(detail)"
    case .network(let message):
        return "network — \(message)"
    case .decoding(let message):
        return "could not decode the response — \(message)"
    case .malformedStream(let message):
        return "malformed stream — \(message)"
    default:
        return ProviderErrorCopy.presentation(for: providerError).title
            + " — " + ProviderErrorCopy.presentation(for: providerError).message
    }
}

// MARK: - Output

func write(
    lesson: Lesson,
    window: TimeWindow,
    index: Int,
    seconds: Double,
    cost: Double,
    events: [UsageEvent],
    findings: [LessonQualityCheck.Finding],
    directory: URL
) throws -> String {
    let slug = lesson.title.lowercased()
        .map { $0.isLetter || $0.isNumber ? $0 : "-" }
        .reduce(into: "") { result, character in
            if character == "-" && result.hasSuffix("-") { return }
            result.append(character)
        }
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

    // Not String(format:) with %@ — that is a Darwin ObjC bridge and this runs
    // on Linux, where it fails silently rather than failing to compile. The
    // rest of the reporting was already converted; this one was missed, and it
    // would have named every file after whatever %@ happened to produce.
    let number = index < 10 ? "0\(index)" : "\(index)"
    let name = "\(number)-\(window.rawValue)-\(slug).md"
    let url = directory.appendingPathComponent(name)

    let budget = window.wordBudget
    let verdict: String
    if lesson.wordCount < budget.lowerBound { verdict = "under" }
    else if lesson.wordCount > budget.upperBound { verdict = "over" }
    else { verdict = "in budget" }

    var header = """
    # \(lesson.title)

    \(lesson.subtitle)

    - **Length:** \(window.label) (\(window.format.displayName))
    - **Domain:** \(lesson.domainTag)
    - **Words:** \(lesson.wordCount) — budget \(budget.lowerBound)–\(budget.upperBound), \(verdict)
    - **Cost:** \(CostEstimator.formatted(cost)) across \(events.count) API calls
    - **Time:** \(String(format: "%.0f", seconds))s

    """

    if !events.isEmpty {
        header += "\n<details>\n<summary>Calls</summary>\n\n"
        for event in events {
            header += "- \(event.kind.label): \(event.usage.inputTokens) in"
                + " (\(event.usage.cacheReadInputTokens) cached) / \(event.usage.outputTokens) out"
                + " — \(CostEstimator.formatted(event.estimatedCostUSD))\n"
        }
        header += "\n</details>\n"
    }

    if findings.isEmpty {
        header += "\n**Quality check:** clean.\n"
    } else {
        header += "\n**Quality check:** \(findings.count) finding\(findings.count == 1 ? "" : "s").\n\n"
        for finding in findings {
            header += "- \(finding.description)\n"
        }
    }

    header += """

    **Surprising claim:** \(lesson.surprisingClaim)

    **Deeper angles:**
    \(lesson.deeperAngles.map { "- \($0)" }.joined(separator: "\n"))

    ---

    """

    try (header + lesson.bodyMarkdown + "\n").write(to: url, atomically: true, encoding: .utf8)
    return name
}

func printSummary(rows: [Row], plan: [TimeWindow], cost: Double, directory: URL) {
    print("")
    print(String(repeating: "=", count: 94))
    print("Per lesson")
    print("")
    print(pad("Length", 8) + pad("Title", 44) + padLeft("Words", 6) + "  "
          + pad("Budget", 11) + padLeft("Cost", 9) + padLeft("Secs", 7)
          + padLeft("Findings", 10))
    for row in rows {
        let title = row.title.count > 42 ? String(row.title.prefix(41)) + "\u{2026}" : row.title
        print(pad(row.window.label, 8) + pad(title, 44) + padLeft("\(row.words)", 6) + "  "
              + pad(row.verdict, 11) + padLeft(money(row.costUSD), 9)
              + padLeft(String(format: "%.0f", row.seconds), 7)
              + padLeft("\(row.findings.count)", 10))
    }

    print("")
    print("By length")
    print("")
    print(pad("Length", 8) + padLeft("N", 3) + padLeft("Avg words", 11)
          + padLeft("Budget", 13) + padLeft("In budget", 12) + padLeft("Clean", 8)
          + padLeft("Avg cost", 11))
    for window in plan {
        let group = rows.filter { $0.window == window }
        guard !group.isEmpty else { continue }
        let averageWords = group.reduce(0) { $0 + $1.words } / group.count
        let averageCost = group.reduce(0.0) { $0 + $1.costUSD } / Double(group.count)
        let inBudget = group.filter { $0.verdict == "in budget" }.count
        let clean = group.filter { $0.findings.isEmpty }.count
        print(pad(window.label, 8) + padLeft("\(group.count)", 3)
              + padLeft("\(averageWords)", 11)
              + padLeft("\(window.wordBudget.lowerBound)-\(window.wordBudget.upperBound)", 13)
              + padLeft("\(inBudget)/\(group.count)", 12)
              + padLeft("\(clean)/\(group.count)", 8)
              + padLeft(money(averageCost), 11))
    }

    // Every distinct finding, counted. This is the part that says something
    // about the prompts rather than about one lesson.
    var tally: [String: Int] = [:]
    for row in rows {
        for finding in row.findings {
            let key = String(finding.description.prefix(while: { $0 != ":" }))
            tally[key, default: 0] += 1
        }
    }
    if !tally.isEmpty {
        print("")
        print("Findings across the batch")
        print("")
        for (key, count) in tally.sorted(by: { $0.value > $1.value }) {
            print("  " + padLeft("\(count)", 3) + "  " + key)
        }
    }

    let clean = rows.filter { $0.findings.isEmpty }.count
    let inBudget = rows.filter { $0.verdict == "in budget" }.count
    print("")
    print("\(rows.count) lessons — \(inBudget) in budget, \(clean) with no quality findings"
          + " — total \(CostEstimator.formatted(cost))")
    print("Saved to \(directory.path)")
    print("")

    writeCSV(rows: rows, directory: directory)
}

func writeCSV(rows: [Row], directory: URL) {
    var csv = "window,title,words,budget_min,budget_max,verdict,cost_usd,seconds,api_calls,findings,file\n"
    for row in rows {
        let findings = row.findings.map(\.description).joined(separator: "; ")
        csv += "\(row.window.rawValue),\"\(row.title)\",\(row.words),"
            + "\(row.budget.lowerBound),\(row.budget.upperBound),\(row.verdict),"
            + String(format: "%.6f", row.costUSD) + ",\(Int(row.seconds)),\(row.calls),"
            + "\"\(findings)\",\(row.file)\n"
    }
    try? csv.write(
        to: directory.appendingPathComponent("summary.csv"), atomically: true, encoding: .utf8
    )
}

// MARK: - Entry point

do {
    try await run()
} catch let failure as Failure {
    FileHandle.standardError.write(Data("error: \(failure.description)\n".utf8))
    FileHandle.standardError.write(Data("""

    usage: spare-batch --base-url <https://...> --token <admin token> [--only three|ten|fifteen|thirty] [--out <dir>]

    Environment fallbacks: SPARE_PROXY_URL, SPARE_ADMIN_TOKEN

    """.utf8))
    exit(2)
}
