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
    /// One or more models, in the order given on the command line.
    var models: [String]
    /// How many of each length's topics to use. Nil means all of them.
    var perWindow: Int?
    /// A file of topics to use instead of the built-in comparison table.
    ///
    /// The table holds two topics per window, chosen to stress the editorial
    /// rules — right for judging prompts, useless for filling a pool. Seeding
    /// needs a hundred and fifty subjects spread across the interest
    /// categories, and they want to be reviewable before anybody spends money
    /// on them, which a file is and a hardcoded array is not.
    var topicsFile: URL?
    /// Skip a topic whose lesson file is already in the output directory.
    ///
    /// The operator path bypasses the server's cache *read*, so a re-run
    /// regenerates and re-pays for everything. On a two-hour, 150-lesson run
    /// that is the difference between resuming and starting again.
    var resume: Bool
    /// Print the plan and stop. Costs nothing, and is the only way to find a
    /// malformed topics file before paying for the lessons it describes.
    var isDryRun: Bool

    /// More than one model means this is a comparison, and a comparison you can
    /// see the answers to is not one.
    ///
    /// Blinding is derived rather than a flag of its own: naming several models
    /// has no other purpose, and a `--blind` that could be forgotten would make
    /// the failure silent — twelve files with the model in the header, noticed
    /// after reading them.
    var isBlind: Bool { models.count > 1 }

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
                throw Failure("--only must be one, three, seven, fifteen, or thirty")
            }
            only = window
        }

        let models = (values["model"] ?? AnthropicAPI.model)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !models.isEmpty else {
            throw Failure("--model needs at least one model")
        }
        guard Set(models).count == models.count else {
            throw Failure("--model lists the same model twice")
        }
        // Priced, not merely allowed. An unpriced model still generates, but its
        // cost column would silently be another model's, which is worse than no
        // comparison at all.
        for model in models where CostEstimator.modelPricing[model] == nil {
            throw Failure(
                "no published price for \"\(model)\" — add it to CostEstimator.modelPricing,"
                + " otherwise its cost would be reported at \(AnthropicAPI.model) rates"
            )
        }

        let topicsFile = values["topics"].map { URL(fileURLWithPath: $0) }
        let resume = values["resume"] != "false"
        let isDryRun = values["dry-run"] != nil

        var perWindow: Int?
        if let raw = values["per-window"] {
            guard let count = Int(raw), count > 0 else {
                throw Failure("--per-window must be a positive whole number")
            }
            perWindow = count
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
            deviceID: "batch-\(UUID().uuidString)",
            models: models,
            perWindow: perWindow,
            topicsFile: topicsFile,
            resume: resume,
            isDryRun: isDryRun
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
    .one: [
        ("Why ships are measured in tons of water", "A tonnage figure that is a volume, not a weight.", "History"),
        ("Why airport runways are renumbered", "Magnetic north drifts, and the paint has to follow it.", "Engineering"),
    ],
    .three: [
        ("Why paper cuts hurt so much", "A shallow wound the body treats as an emergency.", "Biology"),
        ("Why tunnels are dug from both ends", "Meeting in the middle is a surveying problem, not a digging one.", "Engineering"),
    ],
    .seven: [
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

// MARK: - What a single run is

/// One topic, at one length, through one model.
struct PlannedRun {
    /// Six hex characters. The only name a blinded lesson has.
    let id: String
    let window: TimeWindow
    let title: String
    let hook: String
    let domain: String
    let model: String

    var suggestion: TopicSuggestion {
        TopicSuggestion(title: title, hook: hook, domainTag: domain)
    }
}

func newIdentifier() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6).lowercased()
}

/// One line of a topics file.
///
/// Tab-separated, three fields: window, title, hook. Not JSON, because the
/// point of the file is that a person reads it before a hundred and fifty
/// lessons are paid for, and a hundred and fifty JSON objects is not a thing
/// anybody reads. Blank lines and `#` comments are skipped so the file can be
/// organised by category.
func loadTopics(from url: URL) throws -> [TimeWindow: [(title: String, hook: String, domain: String)]] {
    let text: String
    do {
        text = try String(contentsOf: url, encoding: .utf8)
    } catch {
        throw Failure("could not read --topics file at \(url.path): \(error)")
    }

    var loaded: [TimeWindow: [(title: String, hook: String, domain: String)]] = [:]
    var domain = "General"

    for (number, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if line.hasPrefix("#") {
            // A comment line names the category the topics under it belong to,
            // which is what the premium pool keys its interest tag on. Free
            // pool ignores it, but the file is the same file either way.
            let named = line.dropFirst().trimmingCharacters(in: .whitespaces)
            if !named.isEmpty { domain = named }
            continue
        }

        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 3 else {
            throw Failure(
                "line \(number + 1) of the topics file has \(fields.count) tab-separated "
                + "fields, expected 3 (window, title, hook): \(line)"
            )
        }
        guard let window = TimeWindow(rawValue: fields[0]) else {
            throw Failure("line \(number + 1): \(fields[0]) is not a window")
        }
        loaded[window, default: []].append((title: fields[1], hook: fields[2], domain: domain))
    }

    guard !loaded.isEmpty else { throw Failure("the topics file has no topics in it") }
    return loaded
}

/// A stable filename for a seeded lesson.
///
/// Keyed on what was *asked for*, not on the title the model wrote — that is
/// what makes `--resume` able to tell an already-generated topic from a new
/// one. The default naming uses the lesson's own title, which is not known
/// until after it has been paid for.
func seedFilename(window: TimeWindow, title: String) -> String {
    let slug = title.lowercased()
        .map { $0.isLetter || $0.isNumber ? $0 : "-" }
        .reduce(into: "") { output, character in
            if character == "-" && output.hasSuffix("-") { return }
            output.append(character)
        }
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return "\(window.rawValue)-\(slug.prefix(60)).md"
}

/// Expands the topic table into one run per (topic, model) pair.
///
/// Shuffled when blinded. The identifiers are random already, so the order does
/// not name anything — but a log that lists four Opus lessons, then four
/// Sonnet, then four Haiku hands the answer to anyone who watches the run, and
/// watching the run is the normal way to use this.
func plannedRuns(
    plan: [TimeWindow],
    models: [String],
    perWindow: Int?,
    blind: Bool,
    table: [TimeWindow: [(title: String, hook: String, domain: String)]] = topics,
    skip: (TimeWindow, String) -> Bool = { _, _ in false }
) -> [PlannedRun] {
    var runs: [PlannedRun] = []
    var used: Set<String> = []

    for window in plan {
        let available = (table[window] ?? []).filter { !skip(window, $0.title) }
        let chosen = perWindow.map { Array(available.prefix($0)) } ?? available
        for topic in chosen {
            for model in models {
                var id = newIdentifier()
                while used.contains(id) { id = newIdentifier() }
                used.insert(id)
                runs.append(PlannedRun(
                    id: id, window: window, title: topic.title,
                    hook: topic.hook, domain: topic.domain, model: model
                ))
            }
        }
    }

    return blind ? runs.shuffled() : runs
}

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
    let id: String
    let model: String
    let window: TimeWindow
    /// The topic as commissioned, which is how a reader groups the versions of
    /// one subject. The lesson's own title is `title`.
    let topic: String
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

// MARK: - Preflight

/// What a model turned out to accept, and the effort setting to use for it.
struct ModelSupport {
    let model: String
    /// Nil where the model rejects `output_config.effort`, so the pipeline must
    /// go without it.
    let effort: Effort?
    /// True when the model accepted the exact shape a generation call sends.
    let usableAsIs: Bool
}

/// Checks the proxy and the model will accept a real request before generating
/// anything.
///
/// The first comparison run spent an hour discovering that eight of its twelve
/// lessons named models the deployed proxy did not allow. The second spent forty
/// minutes discovering that one of the three rejected the request shape: the
/// first version of this check sent a bare message with no `output_config`, so
/// it proved the allowlist and nothing else, and every real call carries an
/// effort setting and a JSON schema in exactly that field.
///
/// So the probes are progressive, and the last one is the real shape. Four
/// sixteen-token calls per model to an unmetered endpoint: it costs a fraction
/// of a penny and it names the field rather than leaving "invalid_request_error"
/// to be guessed at.
func preflight(models: [String], options: Options) async throws -> [ModelSupport] {
    let transport = FoundationHTTPTransport()
    let route = ProxyRoute(
        baseURL: options.baseURL,
        deviceID: options.deviceID,
        operatorToken: options.token
    )

    let trivialSchema = JSONValue.object([
        "type": .string("object"),
        "properties": .object(["ok": .object(["type": .string("string")])]),
        "required": .array([.string("ok")]),
        "additionalProperties": .bool(false),
    ])

    func accepts(_ request: MessagesRequest) async -> String? {
        do {
            let http = try await route.httpRequest(
                for: request, kind: .recallQuestion, context: .plain(window: .three)
            )
            let response = try await transport.send(http)
            guard response.isSuccess else {
                return describe(HTTPTransportMapper.providerError(
                    status: response.statusCode, body: response.body
                ))
            }
            return nil
        } catch {
            return describe(error)
        }
    }

    func probe(_ model: String, effort: Effort?, schema: JSONValue?) -> MessagesRequest {
        MessagesRequest(
            model: model,
            maxTokens: schema == nil ? 16 : 64,
            messages: [.user("Reply with ok.")],
            stream: false,
            effort: effort,
            outputSchema: schema,
            cacheSystemPrompt: false
        )
    }

    var support: [ModelSupport] = []

    for model in models {
        // The real shape first. When it works — the usual case — that is one
        // call and the rest are never sent.
        if await accepts(probe(model, effort: .high, schema: trivialSchema)) == nil {
            print("  ok        \(model)")
            support.append(ModelSupport(model: model, effort: .high, usableAsIs: true))
            continue
        }

        // It did not. Take the shape apart to say which half is the problem,
        // rather than reporting "invalid_request_error" and leaving it there.
        let plain = await accepts(probe(model, effort: nil, schema: nil))
        let withEffort = await accepts(probe(model, effort: .high, schema: nil))
        let withSchema = await accepts(probe(model, effort: nil, schema: trivialSchema))

        if let plain {
            throw Failure(
                "\(model) refuses even a plain request: \(plain)\n"
                + "         Nothing has been generated. If this says modelNotAllowed, the\n"
                + "         deployed Worker predates the model reaching ALLOWED_MODELS —\n"
                + "         redeploy with `cd server; npx wrangler deploy`."
            )
        }

        if let withSchema {
            throw Failure(
                "\(model) rejects structured output: \(withSchema)\n"
                + "         The pipeline parses every response against a schema, so this\n"
                + "         model cannot be used at all. Drop it from --model."
            )
        }

        guard withEffort != nil else {
            throw Failure(
                "\(model) accepts effort and schema separately but not together.\n"
                + "         Nothing has been generated; this needs looking at by hand."
            )
        }

        // Effort is the odd one out, and it is the one the pipeline can do
        // without. Reported loudly, because a model generating without effort
        // control is not running the same experiment as the others — that is
        // the reader's call to make, not something to bury.
        print("  ok        \(model) — WITHOUT effort control")
        print("            it rejects output_config.effort: \(withEffort ?? "")")
        support.append(ModelSupport(model: model, effort: nil, usableAsIs: false))
    }

    let adapted = support.filter { !$0.usableAsIs }
    if !adapted.isEmpty {
        print("")
        print("  NOTE: \(adapted.count) of \(support.count) models are generating without")
        print("        effort control, so they are not running quite the same request as")
        print("        the others. The key file records which.")
    }
    print("")
    return support
}

// MARK: - Run

func run() async throws {
    let options = try Options.parse()
    let plan = options.only.map { [$0] } ?? TimeWindow.allCases

    let table = try options.topicsFile.map { try loadTopics(from: $0) } ?? topics
    let seeding = options.topicsFile != nil

    try FileManager.default.createDirectory(
        at: options.outputDirectory, withIntermediateDirectories: true
    )

    // What is already on disk, so a run that died at lesson ninety does not
    // pay for the first eighty-nine again. Only meaningful when seeding: the
    // comparison table's files are named after the lesson the model wrote,
    // which is not known until it has been bought.
    let alreadyWritten: Set<String>
    if seeding, options.resume {
        let existing = (try? FileManager.default.contentsOfDirectory(
            atPath: options.outputDirectory.path
        )) ?? []
        alreadyWritten = Set(existing)
    } else {
        alreadyWritten = []
    }

    let runs = plannedRuns(
        plan: plan, models: options.models,
        perWindow: options.perWindow, blind: options.isBlind,
        table: table,
        skip: { window, title in
            seeding && alreadyWritten.contains(seedFilename(window: window, title: title))
        }
    )
    let total = runs.count

    if seeding {
        let planned = plan.reduce(0) { $0 + (table[$1]?.count ?? 0) }
        print("")
        print("Seeding the free pool from \(options.topicsFile?.lastPathComponent ?? "?")")
        if planned > total {
            print("  \(planned - total) of \(planned) already written; \(total) to go")
        }
        if total == 0 {
            print("  Nothing left to generate. Every topic in the file is already on disk.")
            return
        }
    }

    if options.isDryRun {
        print("")
        print("Dry run — nothing will be generated and nothing will be spent.")
        for window in plan {
            let forWindow = runs.filter { $0.window == window }
            guard !forWindow.isEmpty else { continue }
            print("")
            print("  \(window.label)  (\(forWindow.count))")
            for run in forWindow {
                print("    \(run.domain.padding(toLength: 16, withPad: " ", startingAt: 0))  \(run.title)")
            }
        }
        print("")
        print("\(total) lessons would be generated on \(options.models.joined(separator: ", ")).")
        return
    }

    print("")
    print("Spare lesson batch — real prompts, real pipeline")
    print("  proxy:  \(options.baseURL.absoluteString)")
    print("  output: \(options.outputDirectory.path)")
    let topicCount = runs.count / max(1, options.models.count)
    if options.isBlind {
        print("  plan:   \(topicCount) topics x \(options.models.count) models = \(total) lessons")
        print("          every topic through every model, so the model is the only variable")
        print("  blinded — this log names lessons by id only, and the mapping is in")
        print("          \(keyFilename), which is the file not to open first")
    } else {
        print("  plan:   \(total) lessons")
        print("  model:  \(options.models[0])")
    }
    print("  two passes each; a 30-minute course is an outline plus 4 chapters x 2")
    print("  reader: \(profile.work)")
    print("")

    let support = try await preflight(models: options.models, options: options)
    let effortByModel = Dictionary(
        uniqueKeysWithValues: support.map { ($0.model, $0.effort) }
    )

    var rows: [Row] = []
    var runningCost = 0.0
    var index = 0

    for run in runs {
        index += 1
        let window = run.window

        // One complete line per lesson, printed when it finishes. The original
        // wrote a partial line first and flushed, which reads better in a
        // terminal but does not compile under Swift 6: `stdout` is a Glibc
        // global var, and touching it from an async context is shared mutable
        // state. In a CI log, where this actually runs, a line appearing every
        // minute or two is the progress indicator.
        let counter = "[" + padLeft("\(index)", 2) + "/\(total)]"
        // Blinded: the id, not the topic. The three lessons on one subject
        // would otherwise be identifiable as a group in the log, with their
        // costs beside them, which is most of the answer.
        let label = options.isBlind ? run.id : run.title
        let prefix = counter + " " + pad(window.label, 7) + " " + pad(label, 40)

        // A ledger per lesson, so the cost reported is this lesson's and not a
        // share of the run. Every call the pipeline makes lands here, which is
        // also how the call count is honest for chaptered formats.
        // Nil where preflight found the model rejects output_config.effort.
        // Written out rather than coalesced, because the dictionary's values are
        // themselves optional and `?? .high` on a double optional is a good way
        // to turn a deliberate nil back into .high without noticing.
        let modelEffort: Effort?
        if let probed = effortByModel[run.model] {
            modelEffort = probed
        } else {
            modelEffort = .high
        }

        let ledger = InMemoryUsageLedger()
        let provider = ProxyProvider(
            transport: FoundationHTTPTransport(),
            baseURL: options.baseURL,
            deviceID: options.deviceID,
            ledger: ledger,
            configuration: ProxyProvider.Configuration(
                model: run.model,
                effort: modelEffort
            ),
            operatorToken: options.token
        )

        let started = Date()
        do {
            let lesson = try await provider.generateLesson(
                topic: run.suggestion, window: window, profile: profile
            )
            let seconds = Date().timeIntervalSince(started)
            let events = await ledger.events
            let cost = events.reduce(0) { $0 + $1.estimatedCostUSD }
            runningCost += cost

            // A seeded lesson without its recall question is a lesson every
            // reader has to generate one for — per reader, which is the exact
            // thing the pool exists to avoid. The batch device is the recorded
            // generator, so it is the only device the proxy will accept an
            // attachment from; if this is skipped, nobody can ever supply one.
            //
            // No test: the seed fills the *free* pool, which has none by
            // design, and the proxy rejects a free-pool attachment carrying
            // one.
            if seeding {
                let store = ProxyAttachmentStore(
                    transport: FoundationHTTPTransport(),
                    baseURL: options.baseURL,
                    deviceID: options.deviceID
                )
                let identity = LessonIdentity(
                    window: window, topic: run.title, interest: run.domain
                )
                do {
                    let recall = try await provider.generateRecallQuestion(for: lesson)
                    try await store.attach(
                        LessonAttachments(recall: recall), for: identity
                    )
                } catch {
                    // Loud but not fatal: the lesson is cached and good, and a
                    // missing recall question costs a later reader one cheap
                    // call rather than costing this run.
                    print(prefix + "  recall not attached — " + describe(error))
                }
            }

            let findings = LessonQualityCheck.findings(for: lesson, window: window)
            let file = try write(
                lesson: lesson, run: run, seconds: seconds, cost: cost,
                events: events, findings: findings,
                blind: options.isBlind, seeded: seeding,
                directory: options.outputDirectory
            )

            let row = Row(
                id: run.id, model: run.model, window: window, topic: run.title,
                title: lesson.title, words: lesson.wordCount,
                budget: window.wordBudget, seconds: seconds, costUSD: cost,
                calls: events.count, findings: findings, file: file
            )
            rows.append(row)

            // Cost and elapsed time are left out when blinded, and they are the
            // two that would give it away outright: Haiku is a twentieth of
            // Opus on price and several times faster. Words and findings are
            // what the reader is judging anyway.
            var line = prefix + "  " + padLeft("\(row.words)", 5) + " words  "
                + pad(row.verdict, 9)
            if !options.isBlind {
                line += "  " + padLeft(money(cost), 9)
                    + "  " + padLeft(String(format: "%.0f", seconds), 4) + "s"
            }
            line += "  " + padLeft("\(events.count)", 2) + " calls"
                + (findings.isEmpty ? "" : "  \(findings.count) findings")
            print(line)
            for finding in findings {
                print("        - \(finding.description)")
            }
        } catch {
            // Elapsed time and the calls that did complete, not just the error.
            //
            // A 30-minute course is nine calls and this printed one line for the
            // whole lesson, so three separate investigations into a failing
            // course each began by not knowing which of the nine broke. The
            // ledger already records every call that succeeded; listing them
            // says exactly how far the course got.
            let seconds = Date().timeIntervalSince(started)
            let done = await ledger.events
            print(prefix + "  FAILED after " + String(format: "%.0f", seconds) + "s  "
                  + describe(error))
            if done.isEmpty {
                print("        no call completed — it failed on the first one")
            } else {
                let completed = done.map { $0.kind.rawValue }.joined(separator: ", ")
                print("        \(done.count) call\(done.count == 1 ? "" : "s") completed: \(completed)")
                let spent = done.reduce(0) { $0 + $1.estimatedCostUSD }
                runningCost += spent
                print("        spent \(CostEstimator.formatted(spent)) before it broke")
            }
            if isFatal(error, producedAnything: !rows.isEmpty) {
                print("")
                print("Stopping: nothing further will succeed.")
                printSummary(
                    rows: rows, plan: plan, cost: runningCost,
                    options: options, support: support,
                    directory: options.outputDirectory
                )
                return
            }
        }
    }

    printSummary(
        rows: rows, plan: plan, cost: runningCost,
        options: options, support: support, directory: options.outputDirectory
    )
}

/// A refusal that means the rest of the run is pointless, rather than one lesson
/// that happened not to work.
///
/// `producedAnything` is the discriminator for the structural failures. A 502 is
/// the proxy saying Anthropic refused what it built, and a 404 is an endpoint
/// the deployed Worker does not have — neither is about the topic, so if the
/// very first lesson hits one, the other seven will too. Today's run proved the
/// point by spending eight topics and twenty-four attempts to say the same
/// thing eight times. After something has succeeded, the same status is treated
/// as one bad lesson and the run continues.
func isFatal(_ error: Error, producedAnything: Bool) -> Bool {
    guard let providerError = error as? LessonProviderError else { return false }
    switch providerError {
    case .limited(let limit, _):
        // dailyLimitReached or lockedWindow here means the operator token was
        // not accepted, so every remaining request will be refused too.
        return limit == .dailyLesson || limit == .lockedWindow || limit == .spendCeiling
    case .missingAPIKey:
        return true
    case .httpStatus(let code, _):
        // 400 joins these: the proxy rebuilds every request from an allowlist,
        // so a 400 is it refusing the shape of what it was handed — a model it
        // will not pay for, a body over the size limit. None of that is about
        // the topic, so the next topic will fail identically.
        return !producedAnything && (code == 400 || code == 404 || code == 502)
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
    case .underWordFloor(let words, let floor):
        return "under the word floor — came back at \(words) words against a floor"
            + " of \(floor), and the retry did too"
    default:
        return ProviderErrorCopy.presentation(for: providerError).title
            + " — " + ProviderErrorCopy.presentation(for: providerError).message
    }
}

// MARK: - Output

/// The file that answers the question, named so it is not opened by accident.
let keyFilename = "KEY-open-after-reading.md"
let keyCSVFilename = "KEY-summary.csv"

func write(
    lesson: Lesson,
    run: PlannedRun,
    seconds: Double,
    cost: Double,
    events: [UsageEvent],
    findings: [LessonQualityCheck.Finding],
    blind: Bool,
    seeded: Bool,
    directory: URL
) throws -> String {
    // Blinded, the id is the whole filename. An index would encode generation
    // order, and the topic slug would group the three versions of one subject —
    // neither names the model, but both make a file identifiable before it is
    // read, and reading it cold is the point.
    let name: String
    if seeded {
        // Named for the request, not the result. See `seedFilename`.
        name = seedFilename(window: run.window, title: run.title)
    } else if blind {
        name = "\(run.id).md"
    } else {
        let slug = lesson.title.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, character in
                if character == "-" && result.hasSuffix("-") { return }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        name = "\(run.window.rawValue)-\(slug)-\(run.id).md"
    }
    let url = directory.appendingPathComponent(name)

    let window = run.window
    let budget = window.wordBudget
    let verdict: String
    if lesson.wordCount < budget.lowerBound { verdict = "under" }
    else if lesson.wordCount > budget.upperBound { verdict = "over" }
    else { verdict = "in budget" }

    var header = """
    # \(lesson.title)

    \(lesson.subtitle)

    - **ID:** \(run.id)
    - **Commissioned as:** \(run.title)
    - **Length:** \(window.label) (\(window.format.displayName))
    - **Domain:** \(lesson.domainTag)
    - **Words:** \(lesson.wordCount) — budget \(budget.lowerBound)–\(budget.upperBound), \(verdict)

    """

    // Cost, tokens, and elapsed time are the tell. Haiku is a twentieth of Opus
    // per token and several times quicker, so a single figure in this header
    // would identify the model before the first paragraph. They are not
    // dropped, they are moved: everything withheld here is in the key file,
    // which is the one to open after reading.
    if !blind {
        header += """
        - **Model:** \(run.model)
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

func printSummary(
    rows: [Row],
    plan: [TimeWindow],
    cost: Double,
    options: Options,
    support: [ModelSupport],
    directory: URL
) {
    let blind = options.isBlind

    print("")
    print(String(repeating: "=", count: 94))
    print("Per lesson")
    print("")

    var header = pad("Length", 8) + pad(blind ? "ID" : "Title", 44)
        + padLeft("Words", 6) + "  " + pad("Budget", 11)
    if !blind { header += padLeft("Cost", 9) + padLeft("Secs", 7) }
    header += padLeft("Findings", 10)
    print(header)

    for row in rows {
        let name: String
        if blind {
            name = row.id
        } else {
            name = row.title.count > 42 ? String(row.title.prefix(41)) + "\u{2026}" : row.title
        }
        var line = pad(row.window.label, 8) + pad(name, 44)
            + padLeft("\(row.words)", 6) + "  " + pad(row.verdict, 11)
        if !blind {
            line += padLeft(money(row.costUSD), 9)
                + padLeft(String(format: "%.0f", row.seconds), 7)
        }
        line += padLeft("\(row.findings.count)", 10)
        print(line)
    }

    print("")
    print("By length")
    print("")
    var byLength = pad("Length", 8) + padLeft("N", 3) + padLeft("Avg words", 11)
        + padLeft("Budget", 13) + padLeft("In budget", 12) + padLeft("Clean", 8)
    if !blind { byLength += padLeft("Avg cost", 11) }
    print(byLength)

    for window in plan {
        let group = rows.filter { $0.window == window }
        guard !group.isEmpty else { continue }
        let averageWords = group.reduce(0) { $0 + $1.words } / group.count
        let averageCost = group.reduce(0.0) { $0 + $1.costUSD } / Double(group.count)
        let inBudget = group.filter { $0.verdict == "in budget" }.count
        let clean = group.filter { $0.findings.isEmpty }.count
        var line = pad(window.label, 8) + padLeft("\(group.count)", 3)
            + padLeft("\(averageWords)", 11)
            + padLeft("\(window.wordBudget.lowerBound)-\(window.wordBudget.upperBound)", 13)
            + padLeft("\(inBudget)/\(group.count)", 12)
            + padLeft("\(clean)/\(group.count)", 8)
        if !blind { line += padLeft(money(averageCost), 11) }
        print(line)
    }

    // Every distinct finding, counted. This is the part that says something
    // about the prompts rather than about one lesson. Not broken down by model
    // when blinded — that breakdown is the answer, and it is in the key file.
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
    // The run's total is safe to print even blinded: it is the sum of all three
    // models and identifies none of them. Per-lesson cost is what gives it away.
    print("\(rows.count) lessons — \(inBudget) in budget, \(clean) with no quality findings"
          + " — total \(CostEstimator.formatted(cost))")
    print("Saved to \(directory.path)")
    if blind {
        print("")
        print("Blinded. Read the lessons first; \(keyFilename) says which model wrote each.")
    }
    print("")

    if blind {
        printBalance(rows: rows, models: options.models)
    }

    writeCSV(rows: rows, blind: blind, directory: directory)
    if blind {
        verifyBlind(rows: rows, models: options.models, directory: directory)
        writeKey(
            rows: rows, options: options, support: support,
            cost: cost, directory: directory
        )
    }
}

/// How many versions of each topic survived.
///
/// A comparison needs the same subject from every model; a topic missing one is
/// not comparable, and a topic down to a single version is not a comparison at
/// all. A partly-failed run still writes a directory of perfectly readable
/// lessons, and nothing about reading them says they are not the set that was
/// asked for — the first run of this mode returned three lessons on three
/// subjects that all happened to come from one model, and looked fine.
///
/// Says nothing about *which* model is missing: that would unblind by
/// elimination. Only how many versions each topic has.
func printBalance(rows: [Row], models: [String]) {
    var versions: [String: Int] = [:]
    for row in rows {
        versions[row.topic, default: 0] += 1
    }
    let complete = versions.values.filter { $0 == models.count }.count

    print("")
    if !versions.isEmpty, complete == versions.count {
        print("Comparable: all \(complete) topics have a version from each of the"
              + " \(models.count) models.")
        return
    }

    print("INCOMPLETE COMPARISON")
    print("")
    print("  \(complete) of \(versions.count) topics have all \(models.count) versions.")
    for (topic, count) in versions.sorted(by: { $0.key < $1.key }) where count < models.count {
        print("    \(count)/\(models.count)  \(topic)")
    }
    print("")
    print("  A topic missing a version cannot be compared: any difference between")
    print("  the versions that did arrive is the subject, not the model. Fix the")
    print("  failures above and re-run before reading these as a comparison.")
}

/// Reads the blinded files back and checks that none of them names a model.
///
/// The blind is the one property of this mode that matters, and it is enforced
/// by a handful of `if !blind` branches scattered through the writer — exactly
/// the shape of thing that breaks quietly when someone adds a field. A unit test
/// cannot reach it: this is an executable target, so none of it is importable.
/// Reading the real output back is the check that would actually have caught a
/// mistake, and it costs milliseconds at the end of an hour-long run.
///
/// Matches whole model identifiers only. A lesson may legitimately contain the
/// word "haiku"; none will contain "claude-haiku-4-5-20251001".
func verifyBlind(rows: [Row], models: [String], directory: URL) {
    var leaks: [String] = []
    for row in rows {
        let url = directory.appendingPathComponent(row.file)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            leaks.append("\(row.file) could not be read back to check")
            continue
        }
        for model in models where text.contains(model) {
            leaks.append("\(row.file) names \(model)")
        }
    }

    print("")
    if leaks.isEmpty {
        print("Blind verified: none of the \(rows.count) lesson files names a model.")
    } else {
        print("BLIND BROKEN — these files name the model that wrote them:")
        for leak in leaks {
            print("  - \(leak)")
        }
        print("Do not read these as a blind comparison.")
    }
}

func writeCSV(rows: [Row], blind: Bool, directory: URL) {
    // Named with the KEY- prefix when blinded, because it carries cost and
    // model per row — everything the markdown deliberately withholds. A file
    // called summary.csv sitting beside twelve blinded lessons is an invitation.
    var csv = "id,model,window,topic,title,words,budget_min,budget_max,verdict,"
        + "cost_usd,seconds,api_calls,findings,file\n"
    for row in rows {
        let findings = row.findings.map(\.description).joined(separator: "; ")
        csv += "\(row.id),\(row.model),\(row.window.rawValue),\"\(row.topic)\","
            + "\"\(row.title)\",\(row.words),"
            + "\(row.budget.lowerBound),\(row.budget.upperBound),\(row.verdict),"
            + String(format: "%.6f", row.costUSD) + ",\(Int(row.seconds)),\(row.calls),"
            + "\"\(findings)\",\(row.file)\n"
    }
    try? csv.write(
        to: directory.appendingPathComponent(blind ? keyCSVFilename : "summary.csv"),
        atomically: true,
        encoding: .utf8
    )
}

/// One line at the top of the key file about whether the set is comparable.
///
/// Repeated there rather than left in the run log, because the log scrolls past
/// and the artifact is what gets read a week later.
func balanceNote(rows: [Row], models: [String]) -> String {
    var versions: [String: Int] = [:]
    for row in rows {
        versions[row.topic, default: 0] += 1
    }
    let incomplete = versions.filter { $0.value < models.count }
    guard !incomplete.isEmpty else {
        return "All \(versions.count) topics have a version from each of the "
            + "\(models.count) models, so every difference below is the model."
    }
    let names = incomplete.keys.sorted().map { "*\($0)*" }.joined(separator: ", ")
    return "**This set is not a complete comparison.** \(incomplete.count) of "
        + "\(versions.count) topics are missing at least one model's version: \(names). "
        + "Any difference read between the versions that did arrive is the subject, "
        + "not the model."
}

/// The mapping, plus everything the blinded output had to withhold.
func writeKey(
    rows: [Row],
    options: Options,
    support: [ModelSupport],
    cost: Double,
    directory: URL
) {
    var out = """
    # Which model wrote which

    Read the twelve lessons first. This file answers the question.

    Every figure the lesson files leave out is here: model, cost, elapsed time,
    and API calls. They are withheld there rather than dropped, because cost and
    speed identify a model on sight — Haiku is a twentieth of Opus per token and
    several times faster — and a blind test you can see the answers to is not a
    blind test.

    Reader profile: \(profile.work).

    \(balanceNote(rows: rows, models: options.models))

    ## By lesson

    | ID | Model | Length | Commissioned as | Words | Budget | Findings | Cost | Secs |
    | -- | ----- | ------ | --------------- | ----- | ------ | -------- | ---- | ---- |

    """

    for row in rows.sorted(by: { ($0.topic, $0.model) < ($1.topic, $1.model) }) {
        out += "| `\(row.id)` | \(row.model) | \(row.window.label) | \(row.topic) |"
            + " \(row.words) | \(row.verdict) | \(row.findings.count) |"
            + " \(CostEstimator.formatted(row.costUSD)) | \(Int(row.seconds)) |\n"
    }

    let adapted = support.filter { !$0.usableAsIs }.map(\.model)
    if !adapted.isEmpty {
        out += "\n> **Not quite the same request.** \(adapted.joined(separator: ", ")) "
        out += "rejects `output_config.effort`, so it generated without effort control "
        out += "while the others used `high`. Any difference you read may be that, not "
        out += "the model.\n"
    }

    out += "\n## By model\n\n"
    out += "| Model | N | Avg words | In budget | Clean | Findings | Total cost | Avg secs |\n"
    out += "| ----- | - | --------- | --------- | ----- | -------- | ---------- | -------- |\n"

    for model in options.models {
        let group = rows.filter { $0.model == model }
        guard !group.isEmpty else {
            out += "| \(model) | 0 | — | — | — | — | — | — |\n"
            continue
        }
        let averageWords = group.reduce(0) { $0 + $1.words } / group.count
        let inBudget = group.filter { $0.verdict == "in budget" }.count
        let clean = group.filter { $0.findings.isEmpty }.count
        let findings = group.reduce(0) { $0 + $1.findings.count }
        let total = group.reduce(0.0) { $0 + $1.costUSD }
        let averageSeconds = group.reduce(0.0) { $0 + $1.seconds } / Double(group.count)
        out += "| \(model) | \(group.count) | \(averageWords) |"
            + " \(inBudget)/\(group.count) | \(clean)/\(group.count) | \(findings) |"
            + " \(CostEstimator.formatted(total)) | \(Int(averageSeconds)) |\n"
    }

    out += """

    ## Findings by model

    """
    for model in options.models {
        let group = rows.filter { $0.model == model }
        guard !group.isEmpty else { continue }
        var tally: [String: Int] = [:]
        for row in group {
            for finding in row.findings {
                tally[String(finding.description.prefix(while: { $0 != ":" })), default: 0] += 1
            }
        }
        out += "\n**\(model)**\n\n"
        if tally.isEmpty {
            out += "- no findings\n"
        } else {
            for (key, count) in tally.sorted(by: { $0.value > $1.value }) {
                out += "- \(count) × \(key)\n"
            }
        }
    }

    out += """

    ## A caveat on the token counts

    The three models do not count in the same units. Claude 4.7 and later use a
    newer tokenizer that produces roughly 30% more tokens for the same text, so
    Opus 5 and Sonnet 5 bill more tokens than Haiku 4.5 for identical prose. The
    dollar figures are exact — each model's own published rate against its own
    reported usage — but token counts compared across the three are not
    comparing like with like.

    Total for the run: \(CostEstimator.formatted(cost)).

    """

    try? out.write(
        to: directory.appendingPathComponent(keyFilename), atomically: true, encoding: .utf8
    )
}


// MARK: - Entry point

do {
    try await run()
} catch let failure as Failure {
    FileHandle.standardError.write(Data("error: \(failure.description)\n".utf8))
    FileHandle.standardError.write(Data("""

    usage: spare-batch --base-url <https://...> --token <admin token>
                       [--only one|three|seven|fifteen|thirty]
                       [--model <id>[,<id>...]]
                       [--per-window <n>]
                       [--topics <file.tsv>] [--resume false] [--dry-run]
                       [--out <dir>]

    --topics reads subjects from a tab-separated file (window, title, hook)
    instead of the built-in comparison table, with "# Category" lines naming
    the interest each block belongs to. That is how the pre-launch pool is
    seeded. Re-running the same command skips topics already written to --out,
    so an interrupted run resumes rather than paying twice; --resume false
    turns that off. --dry-run prints the plan and spends nothing, which is the
    cheap way to find a malformed file.

    Naming more than one --model runs every chosen topic through each of them
    and blinds the output: files are named by a random id, and the model, cost,
    and elapsed time move to KEY-open-after-reading.md.

    Environment fallbacks: SPARE_PROXY_URL, SPARE_ADMIN_TOKEN

    """.utf8))
    exit(2)
}
