// tabtype-eval — offline quality harness for TabType's suggestion pipeline.
//
//   tabtype-eval make-cases <corpus.jsonl> [--out cases.jsonl] [--boundary N] [--midword N] [--seed N]
//   tabtype-eval smoke --model <file.gguf> [--text "…"]
//   tabtype-eval run --model <file.gguf> --cases <cases.jsonl> [--backend decoder|greedy]
//                    [--threshold P] [--max-words N] [--extend P] [--out run.json] [--baseline run.json] [--limit N]
//   tabtype-eval report <run.json> [--baseline run.json]
//   tabtype-eval sweep <run.json>            (confidence-threshold tradeoff of a decoder run)
//
// The v1 (MLX) baseline is produced by the app binary itself:
//   TabType.app/Contents/MacOS/TabType --eval <cases.jsonl> --out <run.json>

import Foundation
import TabTypeKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let allArguments = Array(CommandLine.arguments.dropFirst())
guard let command = allArguments.first else {
    fail("usage: tabtype-eval {make-cases|smoke|run|report|sweep} …  (see Sources/TabTypeEval/main.swift)")
}
nonisolated(unsafe) let arguments = Array(allArguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
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

switch command {
case "make-cases":
    guard let input = positional() else { fail("make-cases needs a corpus .jsonl path") }
    let corpus = try JSONL.read(CorpusEntry.self, from: url(input))
    let generator = CaseGenerator(
        boundaryPerEntry: option("--boundary").flatMap(Int.init) ?? 4,
        midwordPerEntry: option("--midword").flatMap(Int.init) ?? 2,
        seed: option("--seed").flatMap(UInt64.init) ?? 42)
    let cases = generator.cases(from: corpus)
    let out = url(option("--out") ?? "eval/cases.jsonl")
    try JSONL.write(cases, to: out)
    print("wrote \(cases.count) cases from \(corpus.count) corpus entries → \(out.path)")

case "smoke":
    guard let modelPath = option("--model") else { fail("smoke needs --model <file.gguf>") }
    let loadStart = Date()
    let runtime = try LlamaRuntime(modelPath: modelPath)
    print(String(format: "loaded %@ in %.2fs · vocab %d · splice %@", runtime.modelDescription,
                 Date().timeIntervalSince(loadStart), runtime.vocab.count, runtime.supportsSplice ? "yes" : "no"))
    let texts = option("--text").map { [$0] } ?? [
        "Hey Priya, thanks for sending the dashboard over. I'll take a look ",
        "Hey Priya, thanks for sending the dashboard over. I'll take a lo",
        "Could you please doub",
        "Thank you for the quick turnar",
    ]
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
    if let limit = option("--limit").flatMap(Int.init) { cases = Array(cases.prefix(limit)) }
    let runtime = try LlamaRuntime(modelPath: modelPath)
    let backend: CompletionBackend
    switch option("--backend") ?? "decoder" {
    case "greedy":
        backend = GreedyContinuationBackend(runtime: runtime)
    case "decoder":
        var options = DecoderOptions()
        if let n = option("--max-words").flatMap(Int.init) { options.maxWords = n }
        if let p = option("--extend").flatMap(Double.init) { options.extensionThreshold = p }
        if let k = option("--candidates").flatMap(Int.init) { options.candidates = k }
        backend = DecoderBackend(runtime: runtime, options: options,
                                 threshold: option("--threshold").flatMap(Double.init) ?? 0)
    case let other:
        fail("unknown backend \(other)")
    }
    let run = try await EvalRunner.run(cases, backend: backend) { done, total in
        if done % 25 == 0 || done == total { print("  \(done)/\(total)") }
    }
    let out = url(option("--out") ?? "eval/results/\(backend.name)-\(Int(Date().timeIntervalSince1970)).json")
    try EvalRunner.write(run, to: out)
    let baseline = try option("--baseline").map { try EvalRunner.load(url($0)) }
    print(EvalReport.render(run, baseline: baseline))
    print("results → \(out.path)")

case "report":
    guard let path = positional() else { fail("report needs a run .json path") }
    let run = try EvalRunner.load(url(path))
    let baseline = try option("--baseline").map { try EvalRunner.load(url($0)) }
    print(EvalReport.render(run, baseline: baseline))

case "sweep":
    guard let path = positional() else { fail("sweep needs a run .json path") }
    let run = try EvalRunner.load(url(path))
    guard run.results.contains(where: { $0.confidence != nil }) else { fail("run has no confidences") }
    print("threshold  chars/case  recall  precision  show   wrong-show")
    for (t, s) in EvalRunner.sweep(run, thresholds: [0, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]) {
        print(String(format: "  %4.2f      %5.2f     %5.1f%%   %5.1f%%   %5.1f%%   %5.1f%%", t,
                     s.acceptedCharsPerCase, s.recall * 100, s.precision * 100, s.showRate * 100, s.wrongShowRate * 100))
    }

default:
    fail("unknown command \(command)")
}
