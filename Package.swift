// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TabType",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TabType", targets: ["TabType"]),
        .executable(name: "tabtype-eval", targets: ["TabTypeEval"]),
    ],
    targets: [
        // llama.cpp (Metal) — the v2 inference engine. Pinned release XCFramework;
        // bump the tag and checksum together (`swift package compute-checksum`).
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11490/llama-b11490-xcframework.zip",
            checksum: "bc19f561ae2504cb2b3e7b189f44c8a81f8aa0fd84f70b9e81c2ff92a98a086c"
        ),
        // v2 core: inference runtime, decoder, prompting, evaluation. Shared by the
        // app and the eval CLI.
        .target(
            name: "TabTypeKit",
            dependencies: ["llama"],
            path: "Sources/TabTypeKit",
            resources: [.process("Catalog/models.json"), .copy("Placement/Fonts")],
            // Hot numeric code (decoder, font fitting) — optimize even in Debug builds.
            swiftSettings: [.unsafeFlags(["-O"])]
        ),
        .executableTarget(
            name: "TabTypeEval",
            dependencies: ["TabTypeKit"],
            path: "Sources/TabTypeEval"
        ),
        .executableTarget(
            name: "TabType",
            dependencies: ["TabTypeKit"],
            path: "Sources/TabType",
            resources: [
                .process("Resources/Assets.xcassets"),
                .process("Resources/emoji.json"),
                .process("Resources/frequency_dictionary_en.txt"),
                .process("Resources/frequency_dictionary_es.txt"),
                .process("Resources/frequency_dictionary_fr.txt"),
                .process("Resources/frequency_dictionary_de.txt"),
                .process("Resources/frequency_dictionary_it.txt"),
                .process("Resources/frequency_dictionary_pt.txt"),
                .process("Resources/frequency_dictionary_hi.txt"),
                .process("Resources/frequency_dictionary_bn.txt"),
                .process("Resources/frequency_dictionary_ta.txt"),
                .process("Resources/frequency_dictionary_te.txt"),
                .process("Resources/frequency_dictionary_ml.txt"),
                .process("Resources/frequency_dictionary_ur.txt"),
            ]
        ),
        .testTarget(
            name: "TabTypeTests",
            dependencies: ["TabType"],
            path: "Tests/TabTypeTests"
        ),
        .testTarget(
            name: "TabTypeKitTests",
            dependencies: ["TabTypeKit"],
            path: "Tests/TabTypeKitTests"
        ),
    ]
)
