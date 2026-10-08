// tabtype-eval — offline quality harness for TabType's suggestion pipeline.
//
//   tabtype-eval make-cases <corpus.jsonl> [--out cases.jsonl] [--boundary N] [--midword N] [--seed N]
//   tabtype-eval smoke --model <file.gguf> [--text "…"]
//   tabtype-eval run --model <file.gguf> --cases <cases.jsonl> [--out run.json] [--baseline run.json] [--limit N]
//   tabtype-eval report <run.json> [--baseline run.json]
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
    fail("usage: tabtype-eval {make-cases|smoke|run|report} …  (see Sources/TabTypeEval/main.swift)")
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
    let text = option("--text") ?? "Hey Priya, thanks for sending the dashboard over. I'll take a look"
    let loadStart = Date()
    let runtime = try LlamaRuntime(modelPath: modelPath)
    print(String(format: "loaded in %.2fs · vocab %d · adds BOS %@", Date().timeIntervalSince(loadStart),
                 runtime.vocabSize, runtime.addsBOS ? "yes" : "no"))
    let tokens = runtime.tokenize(text, addSpecial: true)
    print("prompt: \(tokens.count) tokens")
    let prefillStart = Date()
    var logits = try runtime.evaluate(tokens)
    print(String(format: "prefill %.0fms", Date().timeIntervalSince(prefillStart) * 1000))
    var bytes: [UInt8] = []
    let decodeStart = Date()
    var generated = 0
    for _ in 0..<24 {
        let token = runtime.argmax(logits)
        if runtime.isEndOfGeneration(token) { break }
        bytes += runtime.pieceBytes(token)
        generated += 1
        logits = try runtime.append(token)
    }
    let decodeMs = Date().timeIntervalSince(decodeStart) * 1000
    print("continuation: \(String(decoding: bytes, as: UTF8.self).debugDescription)")
    print(String(format: "decode %d tokens in %.0fms (%.1f tok/s)", generated, decodeMs,
                 Double(generated) / max(decodeMs / 1000, 0.001)))
    // Cache reuse: re-evaluating the same prompt should prefill a single token.
    runtime.truncate(to: tokens.count)
    let reuseStart = Date()
    _ = try runtime.evaluate(tokens)
    print(String(format: "re-evaluate same prompt (cache hit) %.0fms", Date().timeIntervalSince(reuseStart) * 1000))

case "run":
    guard let modelPath = option("--model"), let casesPath = option("--cases") else {
        fail("run needs --model <file.gguf> --cases <cases.jsonl>")
    }
    var cases = try JSONL.read(EvalCase.self, from: url(casesPath))
    if let limit = option("--limit").flatMap(Int.init) { cases = Array(cases.prefix(limit)) }
    let backend = try GreedyContinuationBackend(modelPath: modelPath)
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

default:
    fail("unknown command \(command)")
}
