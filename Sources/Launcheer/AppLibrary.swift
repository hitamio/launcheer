import AppKit
import Foundation

@MainActor
final class AppLibrary: ObservableObject {
    @Published private(set) var items: [LauncherItem] = []
    @Published private(set) var isLoading = false
    @Published var lastLaunchError: String?

    private var appsByID: [String: LaunchApp] = [:]
    private var layout: [LauncherLayoutItem] = []

    func reload(showLoading: Bool = true) async {
        if showLoading {
            isLoading = true
        }
        let scanned = await Task.detached(priority: .userInitiated) {
            ApplicationScanner.scan()
        }.value
        appsByID = Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, $0) })
        layout = LauncherLayoutStore.load()
        reconcileLayout(with: scanned)
        if !LauncherLayoutStore.hasAppliedAddedDateSort {
            sortLayoutByAddedDate()
            LauncherLayoutStore.hasAppliedAddedDateSort = true
        }
        publishItems()
        LauncherLayoutStore.save(layout)
        if showLoading {
            isLoading = false
        }
    }

    func launch(_ app: LaunchApp) {
        lastLaunchError = nil
        if NSWorkspace.shared.open(app.url) {
            LauncherCommands.hide()
        } else {
            lastLaunchError = L10n.tr("error.openApp", app.name, "NSWorkspace.open returned false")
        }
    }

    @discardableResult
    func moveToTrash(_ app: LaunchApp) async -> Bool {
        lastLaunchError = nil
        do {
            try await recycleApplication(at: app.url)
            removeAppFromLayout(app.id)
            return true
        } catch {
            lastLaunchError = L10n.tr("error.moveToTrash", app.name, error.localizedDescription)
            DebugLog.write("moveToTrash failed app=\(app.name) path=\(app.url.path) error=\(error.localizedDescription)")
            return false
        }
    }

    func moveItem(_ draggedID: String, relativeTo targetID: String, placement: LayoutPlacement) {
        guard draggedID != targetID,
              let sourceIndex = layout.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = layout.firstIndex(where: { $0.id == targetID })
        else { return }

        let item = layout.remove(at: sourceIndex)
        var insertionIndex = targetIndex
        if sourceIndex < targetIndex {
            insertionIndex -= 1
        }
        if placement == .after {
            insertionIndex += 1
        }
        insertionIndex = max(0, min(insertionIndex, layout.count))

        layout.insert(item, at: insertionIndex)
        persistAndPublish()
    }

    func groupItem(_ draggedID: String, on targetID: String) {
        guard draggedID != targetID,
              let sourceIndex = layout.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = layout.firstIndex(where: { $0.id == targetID })
        else { return }

        let source = layout[sourceIndex]
        let target = layout[targetIndex]
        let sourceApps = appIDs(in: source)
        let targetApps = appIDs(in: target)
        guard !sourceApps.isEmpty, !targetApps.isEmpty else { return }

        if target.kind == .folder {
            layout[targetIndex].appIDs = mergedAppIDs(targetApps + sourceApps)
            layout.remove(at: sourceIndex)
        } else if source.kind == .folder {
            layout[sourceIndex].appIDs = mergedAppIDs(sourceApps + targetApps)
            layout.remove(at: targetIndex)
        } else {
            let insertionIndex = targetIndex - (sourceIndex < targetIndex ? 1 : 0)
            let folder = LauncherLayoutItem(
                id: "folder-\(UUID().uuidString)",
                kind: .folder,
                title: L10n.tr("folder.defaultName"),
                appID: nil,
                appIDs: mergedAppIDs([target.appID, source.appID].compactMap { $0 })
            )

            let lowerIndex = min(sourceIndex, targetIndex)
            let upperIndex = max(sourceIndex, targetIndex)
            layout.remove(at: upperIndex)
            layout.remove(at: lowerIndex)
            layout.insert(folder, at: insertionIndex)
        }

        persistAndPublish()
    }

    func moveAppFromFolder(_ appID: String, from folderID: String, relativeTo targetID: String, placement: LayoutPlacement) {
        guard appID != targetID,
              appsByID[appID] != nil,
              layout.contains(where: { $0.id == targetID }),
              detachApp(appID, from: folderID)
        else { return }

        guard let targetIndex = layout.firstIndex(where: { $0.id == targetID }) else { return }
        var insertionIndex = targetIndex
        if placement == .after {
            insertionIndex += 1
        }
        insertionIndex = max(0, min(insertionIndex, layout.count))

        layout.insert(appLayoutItem(appID), at: insertionIndex)
        persistAndPublish()
    }

    func groupAppFromFolder(_ appID: String, from folderID: String, on targetID: String) {
        guard appID != targetID,
              appsByID[appID] != nil,
              layout.contains(where: { $0.id == targetID }),
              detachApp(appID, from: folderID)
        else { return }

        guard let targetIndex = layout.firstIndex(where: { $0.id == targetID }) else { return }
        let target = layout[targetIndex]

        if target.kind == .folder {
            layout[targetIndex].appIDs = mergedAppIDs((target.appIDs ?? []) + [appID])
        } else {
            let folder = LauncherLayoutItem(
                id: "folder-\(UUID().uuidString)",
                kind: .folder,
                title: L10n.tr("folder.defaultName"),
                appID: nil,
                appIDs: mergedAppIDs([target.appID, appID].compactMap { $0 })
            )
            layout[targetIndex] = folder
        }

        persistAndPublish()
    }

    func ungroupApp(_ appID: String, from folderID: String) {
        guard let folderIndex = layout.firstIndex(where: { $0.id == folderID }),
              appsByID[appID] != nil,
              detachApp(appID, from: folderID)
        else { return }

        let insertionIndex = min(folderIndex + 1, layout.count)
        layout.insert(appLayoutItem(appID), at: insertionIndex)
        persistAndPublish()
    }

    func renameFolder(_ folderID: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let folderIndex = layout.firstIndex(where: { $0.id == folderID && $0.kind == .folder })
        else { return }

        layout[folderIndex].title = trimmed
        persistAndPublish()
    }

    func app(withID id: String) -> LaunchApp? {
        appsByID[id]
    }

    private func reconcileLayout(with scanned: [LaunchApp]) {
        let knownIDs = Set(scanned.map(\.id))
        var seenAppIDs = Set<String>()

        layout = layout.compactMap { item in
            switch item.kind {
            case .app:
                guard let appID = item.appID, knownIDs.contains(appID), !seenAppIDs.contains(appID) else {
                    return nil
                }
                seenAppIDs.insert(appID)
                return item
            case .folder:
                let appIDs = mergedAppIDs((item.appIDs ?? []).filter { knownIDs.contains($0) && !seenAppIDs.contains($0) })
                guard !appIDs.isEmpty else { return nil }
                seenAppIDs.formUnion(appIDs)
                return LauncherLayoutItem(
                    id: item.id,
                    kind: .folder,
                    title: item.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? L10n.tr("folder.defaultName"),
                    appID: nil,
                    appIDs: appIDs
                )
            }
        }

        let missingApps = scanned
            .filter { !seenAppIDs.contains($0.id) }
            .sorted(by: sortAppsByAddedDate)

        layout.append(contentsOf: missingApps.map {
            LauncherLayoutItem(id: $0.id, kind: .app, title: nil, appID: $0.id, appIDs: nil)
        })
    }

    private func sortLayoutByAddedDate() {
        layout = layout
            .map { item -> LauncherLayoutItem in
                guard item.kind == .folder, let appIDs = item.appIDs else { return item }
                var folder = item
                folder.appIDs = appIDs.sorted { lhs, rhs in
                    sortAppIDsByAddedDate(lhs, rhs)
                }
                return folder
            }
            .sorted { lhs, rhs in
                if layoutSortDate(for: lhs) != layoutSortDate(for: rhs) {
                    return layoutSortDate(for: lhs) < layoutSortDate(for: rhs)
                }
                return layoutSortName(for: lhs).localizedStandardCompare(layoutSortName(for: rhs)) == .orderedAscending
            }
    }

    private func publishItems() {
        items = layout.compactMap { item in
            switch item.kind {
            case .app:
                guard let appID = item.appID, let app = appsByID[appID] else { return nil }
                return .app(app)
            case .folder:
                let apps = (item.appIDs ?? []).compactMap { appsByID[$0] }
                guard !apps.isEmpty else { return nil }
                return .folder(LaunchFolder(id: item.id, name: item.title ?? L10n.tr("folder.defaultName"), apps: apps))
            }
        }
    }

    private func removeAppFromLayout(_ appID: String) {
        appsByID[appID] = nil
        layout = layout.compactMap { item in
            switch item.kind {
            case .app:
                return item.appID == appID ? nil : item
            case .folder:
                let appIDs = mergedAppIDs((item.appIDs ?? []).filter { $0 != appID })
                guard !appIDs.isEmpty else { return nil }
                return LauncherLayoutItem(
                    id: item.id,
                    kind: .folder,
                    title: item.title,
                    appID: nil,
                    appIDs: appIDs
                )
            }
        }
        publishItems()
        LauncherLayoutStore.save(layout)
    }

    private func recycleApplication(at url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle([url]) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func persistAndPublish() {
        publishItems()
        LauncherLayoutStore.save(layout)
    }

    private func appIDs(in item: LauncherLayoutItem) -> [String] {
        switch item.kind {
        case .app:
            return [item.appID].compactMap { $0 }
        case .folder:
            return item.appIDs ?? []
        }
    }

    private func mergedAppIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private func sortAppsByAddedDate(_ lhs: LaunchApp, _ rhs: LaunchApp) -> Bool {
        if lhs.addedDate != rhs.addedDate {
            return lhs.addedDate < rhs.addedDate
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func sortAppIDsByAddedDate(_ lhs: String, _ rhs: String) -> Bool {
        guard let lhsApp = appsByID[lhs] else { return false }
        guard let rhsApp = appsByID[rhs] else { return true }
        return sortAppsByAddedDate(lhsApp, rhsApp)
    }

    private func layoutSortDate(for item: LauncherLayoutItem) -> Date {
        switch item.kind {
        case .app:
            return item.appID.flatMap { appsByID[$0]?.addedDate } ?? .distantFuture
        case .folder:
            return (item.appIDs ?? [])
                .compactMap { appsByID[$0]?.addedDate }
                .min() ?? .distantFuture
        }
    }

    private func layoutSortName(for item: LauncherLayoutItem) -> String {
        switch item.kind {
        case .app:
            return item.appID.flatMap { appsByID[$0]?.name } ?? item.id
        case .folder:
            return item.title ?? item.id
        }
    }

    private func detachApp(_ appID: String, from folderID: String) -> Bool {
        guard let folderIndex = layout.firstIndex(where: { $0.id == folderID && $0.kind == .folder }),
              var appIDs = layout[folderIndex].appIDs,
              let appIndex = appIDs.firstIndex(of: appID)
        else { return false }

        appIDs.remove(at: appIndex)

        if appIDs.isEmpty {
            layout.remove(at: folderIndex)
        } else if appIDs.count == 1 {
            layout[folderIndex] = appLayoutItem(appIDs[0])
        } else {
            layout[folderIndex].appIDs = appIDs
        }

        return true
    }

    private func appLayoutItem(_ appID: String) -> LauncherLayoutItem {
        LauncherLayoutItem(id: appID, kind: .app, title: nil, appID: appID, appIDs: nil)
    }
}

enum LayoutPlacement {
    case before
    case after
}

private struct LauncherLayoutItem: Codable, Identifiable {
    enum Kind: String, Codable {
        case app
        case folder
    }

    var id: String
    var kind: Kind
    var title: String?
    var appID: String?
    var appIDs: [String]?
}

private enum LauncherLayoutStore {
    private static let addedDateSortVersionKey = "Launcheer.addedDateSortVersion"
    private static let currentAddedDateSortVersion = 1

    static var hasAppliedAddedDateSort: Bool {
        get {
            UserDefaults.standard.integer(forKey: addedDateSortVersionKey) >= currentAddedDateSortVersion
        }
        set {
            UserDefaults.standard.set(newValue ? currentAddedDateSortVersion : 0, forKey: addedDateSortVersionKey)
        }
    }

    static func load() -> [LauncherLayoutItem] {
        do {
            let data = try Data(contentsOf: layoutURL)
            return try JSONDecoder().decode([LauncherLayoutItem].self, from: data)
        } catch {
            return []
        }
    }

    static func save(_ items: [LauncherLayoutItem]) {
        do {
            try FileManager.default.createDirectory(
                at: layoutURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(items)
            try data.write(to: layoutURL, options: .atomic)
        } catch {
            DebugLog.write("layout save failed: \(error.localizedDescription)")
        }
    }

    private static var layoutURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("Launcheer", isDirectory: true)
            .appendingPathComponent("layout.json")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
