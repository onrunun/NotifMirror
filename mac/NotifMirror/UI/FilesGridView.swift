import AppKit
import SwiftUI

/// Visual thumbnail grid for Phone Files (images & videos fetch scaled JPEGs
/// over TLS WS via `fs_thumb`, cached in memory; folders and non-media files
/// render crisp native icon tiles).
struct FilesGridView<MenuContent: View>: View {
    let entries: [AdbEntry]
    let currentPath: String
    let deviceId: String?
    let thumbnailsAvailable: Bool
    @Binding var selection: Set<String>
    let onOpen: (AdbEntry) -> Void
    let onDropURLs: ([URL]) -> Void
    @ViewBuilder let itemContextMenu: (Set<String>) -> MenuContent

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 164), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(entries) { entry in
                    let selected = selection.contains(entry.id)
                    FileGridTile(
                        entry: entry,
                        remotePath: joinPath(currentPath, entry.name),
                        deviceId: deviceId,
                        thumbnailsAvailable: thumbnailsAvailable,
                        isSelected: selected,
                        onToggleSelect: { toggleSelection(entry) },
                        onTap: { handleCardTap(entry) },
                        onDoubleClick: { onOpen(entry) }
                    )
                    .contextMenu {
                        let ids = selection.contains(entry.id) ? selection : [entry.id]
                        itemContextMenu(ids)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .dropDestination(for: URL.self) { urls, _ in
            onDropURLs(urls)
            return true
        }
    }

    private func toggleSelection(_ entry: AdbEntry) {
        if selection.contains(entry.id) {
            selection.remove(entry.id)
        } else {
            selection.insert(entry.id)
        }
    }

    private func handleCardTap(_ entry: AdbEntry) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            toggleSelection(entry)
        } else if flags.contains(.shift),
                  let lastSelected = entries.lastIndex(where: { selection.contains($0.id) }),
                  let targetIdx = entries.firstIndex(where: { $0.id == entry.id }) {
            let range = min(lastSelected, targetIdx)...max(lastSelected, targetIdx)
            for idx in range {
                selection.insert(entries[idx].id)
            }
        } else {
            selection = [entry.id]
        }
    }

    private func joinPath(_ base: String, _ name: String) -> String {
        base == "/" ? "/\(name)" : "\(base)/\(name)"
    }
}

private struct FileGridTile: View {
    let entry: AdbEntry
    let remotePath: String
    let deviceId: String?
    let thumbnailsAvailable: Bool
    let isSelected: Bool
    let onToggleSelect: () -> Void
    let onTap: () -> Void
    let onDoubleClick: () -> Void

    @State private var thumb: NSImage? = nil
    @State private var isHovered: Bool = false

    private var cacheKey: String {
        "\(deviceId ?? "default"):\(remotePath)@\(Int(entry.mtime.timeIntervalSince1970))"
    }

    private var shouldFetchThumb: Bool {
        thumbnailsAvailable && FileClassifier.isMedia(entry)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                previewSurface
                    .frame(height: 108)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        if FileClassifier.isVideo(entry) {
                            Label("Video", systemImage: "play.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.black.opacity(0.65)))
                                .padding(6)
                        }
                    }

                // Always-reachable selection toggle badge for effortless bulk photo picking.
                if isSelected || isHovered {
                    Button(action: onToggleSelect) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.white)
                            .padding(5)
                            .background(Circle().fill(isSelected ? Color.white : Color.black.opacity(0.35)))
                    }
                    .buttonStyle(.plain)
                    .padding(5)
                    .help(isSelected ? "Deselect \(entry.name)" : "Select \(entry.name)")
                    .accessibilityLabel(isSelected ? "Deselect \(entry.name)" : "Select \(entry.name)")
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(metaSubtitle)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.15)
                      : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { onDoubleClick() }
        .onTapGesture(count: 1) { onTap() }
        .task(id: shouldFetchThumb ? cacheKey : "") {
            guard shouldFetchThumb else { return }
            if let hit = ProtocolFileClient.shared.cachedThumbnail(for: cacheKey) {
                thumb = hit
                return
            }
            if let fetched = try? await ProtocolFileClient.shared.thumbnailImage(
                path: remotePath,
                cacheKey: cacheKey,
                deviceId: deviceId,
                maxDim: 260
            ) {
                thumb = fetched
            }
        }
    }

    @ViewBuilder
    private var previewSurface: some View {
        if let thumb {
            Image(nsImage: thumb)
                .resizable()
                .interpolation(.medium)
                .scaledToFill()
        } else {
            ZStack {
                Color.primary.opacity(0.05)
                Image(systemName: FileClassifier.iconName(for: entry))
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(FileClassifier.iconColor(for: entry))
            }
            .accessibilityHidden(true)
        }
    }

    private var metaSubtitle: String {
        if entry.isDirectory { return "Folder" }
        return ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
    }
}
