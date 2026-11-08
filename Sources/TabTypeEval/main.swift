// tabtype-eval — offline quality harness for TabType's suggestion pipeline.
//
//   tabtype-eval make-cases <corpus.jsonl> [--out cases.jsonl] [--boundary N] [--midword N] [--seed N]
//   tabtype-eval smoke --model <file.gguf> [--text "…"]
//   tabtype-eval run --model <file.gguf> --cases <cases.jsonl> [--backend decoder|greedy]
//                    [--threshold P] [--max-words N] [--extend P] [--out run.json] [--baseline run.json] [--limit N]
//   tabtype-eval report <run.json> [--baseline run.json]
//                    [--template legacy|base|chatml|chatml-nothink|gemma|llama3|phi] [--author "Name"]
//   tabtype-eval sweep <run.json>            (confidence-threshold tradeoff of a decoder run)
//   tabtype-eval profiles <raw.json> --threshold 0.2 [--out directory]
//       (replay careful/balanced/frequent on scores recorded with --extend 0)
//   `run --style careful|balanced|frequent` uses the app's position-aware gate.
//   tabtype-eval prompt --template <name> --cases <cases.jsonl> [--index N]   (print an assembled prompt)
//   tabtype-eval catalog                     (models in the bundled catalog and how they fit this Mac)
//   tabtype-eval download <model-id> [--dir path]
//
// The v1 (MLX) baseline is produced by the app binary itself:
//   TabType.app/Contents/MacOS/TabType --eval <cases.jsonl> --out <run.json>

import Foundation
import CryptoKit
import TabTypeKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let allArguments = Array(CommandLine.arguments.dropFirst())
guard let command = allArguments.first else {
    fail("usage: tabtype-eval {make-cases|smoke|run|report|sweep|profiles|prompt|catalog|download} …  (see Sources/TabTypeEval/main.swift)")
}
nonisolated(unsafe) let arguments = Array(allArguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name) else { return nil }
    guard i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") else { fail("\(name) needs a value") }
    return arguments[i + 1]
}
func positional() -> String? {
    var skipNext = false
    for a in arguments {
        if skipNext { skipNext = false; continue }
        if a.hasPrefix("--") { skipNext = true; continue }
        return a
    }
    return nil
}
func url(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

func digest(_ file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

func probability(_ name: String, default value: Double) -> Double {
    guard let input = option(name) else { return value }
    guard let parsed = Double(input), parsed.isFinite, (0...1).contains(parsed) else {
        fail("\(name) must be a finite probability between 0 and 1")
    }
    return parsed
}

func integer(_ name: String, default value: Int, range: ClosedRange<Int>) -> Int {
    guard let input = option(name) else { return value }
    guard let parsed = Int(input), range.contains(parsed) else { fail("\(name) must be an integer in \(range)") }
    return parsed
}

func extensionThreshold(default value: Double) -> Double {
    guard let input = option("--extend") else { return value }
    guard let parsed = Double(input), parsed.isFinite, parsed >= 0 else { fail("--extend must be finite and nonnegative") }
    return parsed
}

switch command {
case "make-cases":
    guard let input = positional() else { fail("make-cases needs a corpus .jsonl path") }
    let corpus = try JSONL.read(CorpusEntry.self, from: url(input))
    let seed = option("--seed").map { raw -> UInt64 in
        guard let value = UInt64(raw) else { fail("--seed must be a nonnegative UInt64 integer") }
        return value
    } ?? 42
    let generator = CaseGenerator(
        boundaryPerEntry: integer("--boundary", default: 4, range: 0...10_000),
        midwordPerEntry: integer("--midword", default: 2, range: 0...10_000),
        seed: seed)
    let cases = generator.cases(from: corpus)
    let out = url(option("--out") ?? "eval/cases.jsonl")
    try JSONL.write(cases, to: out)
    print("wrote \(cases.count) cases from \(corpus.count) corpus entries → \(out.path)")

case "smoke":
    guard let modelPath = option("--model") else { fail("smoke needs --model <file.gguf>") }
    let texts = option("--text").map { [$0] } ?? [
        "Hey Priya, thanks for sending the dashboard over. I'll take a look ",
        "Hey Priya, thanks for sending the dashboard over. I'll take a lo",
        "Could you please doub",
        "Thank you for the quick turnar",
    ]
    let loadStart = Date()
    let runtime = try LlamaRuntime(modelPath: modelPath)
    print(String(format: "loaded %@ in %.2fs · vocab %d · splice %@", runtime.modelDescription,
                 Date().timeIntervalSince(loadStart), runtime.vocab.count, runtime.supportsSplice ? "yes" : "no"))
    var options = DecoderOptions()
    options.maxWords = 4
    for text in texts {
        let start = Date()
        guard let r = try CompletionDecoder.complete(text, model: runtime, options: options) else {
            print("\(text.debugDescription) → (nothing)")
            continue
        }
        let ms = Date().timeIntervalSince(start) * 1000
        let words = r.words.map { "\($0.text.debugDescription) \(String(format: "%.2f", $0.probability))" }.joined(separator: ", ")
        let alts = r.alternatives.map { "\($0.text.debugDescription) \(String(format: "%.2f", $0.probability))" }.joined(separator: ", ")
        print("\(text.debugDescription)\n  → \(r.text.debugDescription)  conf \(String(format: "%.2f", r.confidence))  [\(words)]")
        print("    alternatives: \(alts.isEmpty ? "–" : alts)  · prefilled \(runtime.lastPrefillCount)/\(r.promptTokens) · generated \(r.generatedTokens) · \(String(format: "%.0f", ms))ms")
    }

case "run":
    guard let modelPath = option("--model"), let casesPath = option("--cases") else {
        fail("run needs --model <file.gguf> --cases <cases.jsonl>")
    }
    var cases = try JSONL.read(EvalCase.self, from: url(casesPath))
    if let input = option("--limit") {
        guard let limit = Int(input), limit >= 1 else { fail("--limit must be a positive integer") }
        cases = Array(cases.prefix(limit))
    }
    guard !cases.isEmpty else { fail("case file is empty") }
    let history = try option("--history").map { try JSONL.read(CorpusEntry.self, from: url($0)) }
    let historyScope = option("--history-scope").flatMap(PersonalizationScope.init(rawValue:)) ?? .allApps
    if let raw = option("--history-scope"), PersonalizationScope(rawValue: raw) == nil {
        fail("--history-scope must be currentApp or allApps")
    }
    if let history {
        // This mode excludes the case's source document. Reject an unrelated
        // history file instead of silently leaking the test continuation.
        for c in cases {
            guard let entry = Int(c.id.split(separator: "-").first ?? ""), history.indices.contains(entry),
                  history[entry].app == c.app, history[entry].category == c.category,
                  history[entry].text.hasPrefix(c.prefix + c.truth) else {
                fail("--history requires the source corpus for these cases (leave-one-document-out); mismatch at \(c.id)")
            }
        }
    }
    // Validate every option before creating Metal resources: fail()/exit()
    // with a live llama runtime can otherwise abort during process teardown.
    let backendName = option("--backend") ?? "decoder"
    guard ["decoder", "greedy"].contains(backendName) else { fail("unknown backend \(backendName)") }
    let author = option("--author") ?? "Nilava Chowdhury"
    let outPath = option("--out")
    let baseline = try option("--baseline").map { try EvalRunner.load(url($0)) }
    var options = DecoderOptions()
    let style = option("--style").flatMap(PredictionStyle.init(rawValue:))
    if option("--style") != nil, style == nil { fail("--style must be careful, balanced, or frequent") }
    if let style { options.extensionThreshold = style.extensionThreshold }
    options.maxWords = integer("--max-words", default: options.maxWords, range: 1...32)
    options.extensionThreshold = extensionThreshold(default: options.extensionThreshold)
    options.candidates = integer("--candidates", default: options.candidates, range: 1...32)
    options.beamWidth = integer("--beam", default: options.beamWidth, range: 1...64)
    options.beamBranching = integer("--branch", default: options.beamBranching, range: 1...32)
    if arguments.contains("--beam-all-first-words") { options.beamFromBestFirstWord = false }
    let templateName = option("--template") ?? "legacy"
    let template = templateName == "legacy" ? nil : ModelTemplate.named(templateName)
    if templateName != "legacy", template == nil { fail("unknown template \(templateName)") }
    let threshold = probability("--threshold", default: style == nil ? 0 : options.showThreshold)
    let hintFactor = probability("--hint-factor", default: 0.5)
    var configuration = ["casesSHA256": try digest(url(casesPath)),
                         "modelSHA256": try digest(url(modelPath)),
                         "engineBinarySHA256": try digest(Bundle.main.executableURL ?? url(CommandLine.arguments[0])),
                         "caseCount": String(cases.count)]
    if let path = option("--history") { configuration["historySHA256"] = try digest(url(path)) }
    configuration["historyScope"] = historyScope.rawValue
    let runtime = try LlamaRuntime(modelPath: modelPath)
    let backend: CompletionBackend
    switch backendName {
    case "greedy":
        backend = GreedyContinuationBackend(runtime: runtime)
    case "decoder":
        configuration.merge([
            "template": templateName, "situationHeader": String(arguments.contains("--header")),
            "author": author,
            "noisyContext": String(arguments.contains("--noise")),
            "sections": String(arguments.contains("--sections")),
            "conversations": String(!arguments.contains("--plain-chat")),
            "gate": style?.rawValue ?? "fixed", "baseShowThreshold": String(threshold),
            "extensionThreshold": String(options.extensionThreshold), "maxWords": String(options.maxWords),
            "candidates": String(options.candidates), "beamWidth": String(options.beamWidth),
            "beamBranching": String(options.beamBranching),
            "beamFromBestFirstWord": String(options.beamFromBestFirstWord),
            "minFirstTokenProbability": String(options.minFirstTokenProbability),
            "maxTokensPerWord": String(options.maxTokensPerWord), "hintBonus": String(options.hintBonus),
            "hintFactor": String(hintFactor), "history": option("--history") == nil ? "none" : "leave-one-out",
        ]) { _, new in new }
        backend = DecoderBackend(runtime: runtime, options: options,
                                 threshold: threshold,
                                 template: template, templateName: templateName,
                                 authorName: author,
                                 situationHeader: arguments.contains("--header"),
                                 noisy: arguments.contains("--noise"),
                                 sections: arguments.contains("--sections"),
                                 conversations: !arguments.contains("--plain-chat"),
                                 history: history, hintFactor: hintFactor, style: style, historyScope: historyScope)
    case let other:
        fail("unknown backend \(other)")
    }
    let run = try await EvalRunner.run(cases, backend: backend, configuration: configuration) { done, total in
        if done % 25 == 0 || done == total { print("  \(done)/\(total)") }
    }
    let out = url(outPath ?? "eval/results/\(backend.name)-\(Int(Date().timeIntervalSince1970)).json")
    try EvalRunner.write(run, to: out)
    print(EvalReport.render(run, baseline: baseline))
    if let decoder = backend as? DecoderBackend, decoder.hintsOffered > 0 {
        print("personal history: hints offered \(decoder.hintsOffered), followed \(decoder.hintsUsed)")
    }
    print("results → \(out.path)")

case "report":
    guard let path = positional() else { fail("report needs a run .json path") }
    let run = try EvalRunner.load(url(path))
    let baseline = try option("--baseline").map { try EvalRunner.load(url($0)) }
    print(EvalReport.render(run, baseline: baseline))

case "profiles":
    guard let path = positional() else { fail("profiles needs a decoder run recorded with --extend 0") }
    let run = try EvalRunner.load(url(path))
    let threshold = probability("--threshold", default: 0.2)
    let hintFactor = probability("--hint-factor", default: 0.5)
    print("Replayed decisions; latency remains the original inference measurement.")
    for style in PredictionStyle.allCases {
        let replay: EvalRun
        do { replay = try EvalRunner.replay(run, style: style, baseThreshold: threshold, repeatedPhraseFactor: hintFactor) }
        catch { fail("profiles needs complete word scores from a new decoder run with --extend 0") }
        print("\n\(style.rawValue):\n" + EvalReport.render(replay))
        if let out = option("--out") {
            try EvalRunner.write(replay, to: url(out).appendingPathComponent(style.rawValue + ".json"))
        }
    }

case "sweep":
    guard let path = positional() else { fail("sweep needs a run .json path") }
    let run = try EvalRunner.load(url(path))
    guard run.results.contains(where: { $0.confidence != nil }) else { fail("run has no confidences") }
    print("threshold  chars/case  recall  precision  show   wrong-show  fully-right  wrong-words")
    for (t, s) in EvalRunner.sweep(run, thresholds: [0, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]) {
        print(String(format: "  %4.2f      %5.2f     %5.1f%%   %5.1f%%   %5.1f%%   %5.1f%%     %5.1f%%      %5.2f", t,
                     s.acceptedCharsPerCase, s.recall * 100, s.precision * 100, s.showRate * 100, s.wrongShowRate * 100,
                     (s.fullyRightRate ?? 0) * 100, s.wrongWordsPerCase ?? 0))
    }

case "prompt":
    guard let casesPath = option("--cases"), let name = option("--template"),
          let template = ModelTemplate.named(name) else { fail("prompt needs --cases and a valid --template") }
    let cases = try JSONL.read(EvalCase.self, from: url(casesPath))
    guard !cases.isEmpty else { fail("case file is empty") }
    let c = cases[integer("--index", default: 0, range: 0...(cases.count - 1))]
    print(PromptAssembler(template: template, situationHeader: arguments.contains("--header"))
        .assemble(c.promptContext(authorName: option("--author") ?? "Nilava Chowdhury",
                                  noisy: arguments.contains("--noise"))))

case "catalog":
    let catalog = try ModelCatalog.bundled()
    let store = ModelStore()
    let ram = Int64(ProcessInfo.processInfo.physicalMemory)
    let ramGB = Int(ram / 1_073_741_824)
    print("This Mac: \(ramGB) GB RAM · recommended: \(catalog.recommendedEntry(forRAMGB: ramGB)?.id ?? "none")")
    for e in catalog.models {
        let fit = ModelFit.check(modelBytes: e.sizeBytes, physicalMemoryBytes: ram,
                                 freeDiskBytes: store.freeDiskBytes(), alreadyDownloaded: store.isInstalled(e))
        print("  \(e.id.padding(toLength: 20, withPad: " ", startingAt: 0)) \(String(format: "%5.2f", Double(e.sizeBytes) / 1e9)) GB  \(e.template.padding(toLength: 14, withPad: " ", startingAt: 0)) \(store.isInstalled(e) ? "installed" : "—")  \(fit)")
    }

case "download":
    guard let id = positional() else { fail("download needs a model id (see `catalog`)") }
    let catalog = try ModelCatalog.bundled()
    guard let entry = catalog.entry(id: id) else { fail("unknown model \(id)") }
    let store = option("--dir").map { ModelStore(directory: url($0)) } ?? ModelStore()
    let path = try await ModelDownloader().download(entry, into: store) { received, total in
        print(String(format: "  %.0f%%  %.2f / %.2f GB", Double(received) / Double(total) * 100,
                     Double(received) / 1e9, Double(total) / 1e9))
    }
    print("installed → \(path.path)")

default:
    fail("unknown command \(command)")
}
