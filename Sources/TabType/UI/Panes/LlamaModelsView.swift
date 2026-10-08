import AppKit
import SwiftUI
import TabTypeKit

/// Settings sections for the v2 (llama.cpp) engine: status, the model catalog with
/// download/use/delete, custom models, and the models folder.
struct LlamaModelSections: View {
    @EnvironmentObject var models: LlamaModelManager

    var body: some View {
        Section("Model") {
            HStack {
                statusIcon
                Text(statusText).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if case .downloading(_, let f) = models.status {
                    ProgressView(value: f).frame(width: 120)
                    Text("\(Int(f * 100))%").font(.caption).foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                    Button("Cancel") { models.cancelDownload() }
                }
                if case .loading = models.status { ProgressView().controlSize(.small) }
                if case .failed(let id?, _) = models.status {
                    Button("Retry") { models.select(id) }
                }
            }
        }

        Section {
            ForEach(models.entries.filter { !$0.id.hasPrefix("custom:") }, id: \.id) { entry in
                row(entry)
            }
        } header: {
            Text("Models")
        } footer: {
            Text("Base models continue your writing directly and are the most accurate. Instruct models follow custom instructions more closely but suggest less often. Everything runs on this Mac.")
                .font(.caption)
        }

        Section {
            Picker("Voice adapter", selection: Binding(
                get: { models.adapterName ?? "" },
                set: { models.setAdapter($0.isEmpty ? nil : $0) }
            )) {
                Text("None").tag("")
                ForEach(models.availableAdapters, id: \.self) { Text($0).tag($0) }
            }
            if let error = models.adapterError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text("A LoRA adapter (.gguf) trained for the selected model can tune suggestions toward a particular voice.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open Adapters Folder") {
                    try? FileManager.default.createDirectory(at: models.adaptersDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(models.adaptersDirectory)
                }
            }
        } header: {
            Text("Advanced")
        }

        let custom = models.entries.filter { $0.id.hasPrefix("custom:") }
        Section {
            ForEach(custom, id: \.id) { row($0) }
            HStack {
                Text(custom.isEmpty ? "Drop any .gguf file into the models folder to use it here."
                                    : "Custom models are continued as plain text.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open Models Folder") {
                    try? FileManager.default.createDirectory(at: models.store.directory,
                                                             withIntermediateDirectories: true)
                    NSWorkspace.shared.open(models.store.directory)
                }
            }
        } header: {
            Text("Custom models")
        }
    }

    @ViewBuilder
    private func row(_ entry: TabTypeKit.ModelCatalog.Entry) -> some View {
        let installed = models.isInstalled(entry.id)
        let selected = models.selectedID == entry.id
        let fit = models.fit(entry)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name).fontWeight(.medium)
                    if entry.id == models.recommendedID {
                        Text("Recommended").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
                Text("\(entry.summary) · \(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
                if let warning = warning(fit) {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if installed {
                if !selected || !models.isLoaded {
                    Button("Use") { models.select(entry.id) }
                }
                if !entry.id.hasPrefix("custom:") {
                    Button(role: .destructive) { models.delete(entry.id) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete the downloaded file")
                }
            } else if case .downloading(entry.id, _) = models.status {
                EmptyView()
            } else {
                Button("Download") { models.select(entry.id) }
                    .disabled(isBlocking(fit))
            }
        }
        .padding(.vertical, 2)
    }

    private func warning(_ fit: ModelFit) -> String? {
        switch fit {
        case .good: return nil
        case .heavyMemory(let p): return "Uses about \(p)% of this Mac's memory."
        case .tooLarge(let p): return "Needs about \(p)% of this Mac's memory — likely too large."
        case .insufficientDisk(let need, let free):
            return "Needs \(ByteCountFormatter.string(fromByteCount: need, countStyle: .file)) free; \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) available."
        }
    }

    private func isBlocking(_ fit: ModelFit) -> Bool {
        if case .insufficientDisk = fit { return true }
        return false
    }

    @ViewBuilder private var statusIcon: some View {
        switch models.status {
        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .downloading: Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
        case .loading: Image(systemName: "gearshape.2").foregroundStyle(.secondary)
        case .noModel: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        let name = { (id: String) in models.entry(id: id)?.name ?? id }
        switch models.status {
        case .noModel: return "No model loaded — download one below."
        case .downloading(let id, _): return "Downloading \(name(id))…"
        case .loading(let id): return "Loading \(name(id)) into memory…"
        case .ready(let id): return "\(name(id)) is ready."
        case .failed(_, let message): return message
        }
    }
}
