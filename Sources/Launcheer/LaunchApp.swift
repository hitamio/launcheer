import AppKit
import Darwin
import Foundation

struct LaunchApp: Identifiable, @unchecked Sendable {
    let id: String
    let name: String
    let url: URL
    let bundleIdentifier: String?
    let icon: NSImage
    let addedDate: Date

    var searchText: String {
        "\(name) \(bundleIdentifier ?? "")".localizedLowercase
    }

    var canMoveToTrash: Bool {
        let path = url.standardizedFileURL.path
        guard !path.hasPrefix("/System/Applications/") else { return false }

        let userApplications = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first?
            .standardizedFileURL
            .path
        if let userApplications, path.hasPrefix(userApplications + "/") {
            return true
        }

        if path.hasPrefix("/Applications/") {
            return true
        }

        return false
    }

    var needsFinderForDeletion: Bool {
        let path = url.standardizedFileURL.path
        guard canMoveToTrash else { return false }
        if path.hasPrefix("/Applications/"), !isOwnedByCurrentUser {
            return true
        }
        return !FileManager.default.isDeletableFile(atPath: path)
    }

    private var isOwnedByCurrentUser: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.standardizedFileURL.path),
              let ownerID = attributes[.ownerAccountID] as? NSNumber
        else { return false }
        return ownerID.uint32Value == getuid()
    }
}

struct LaunchFolder: Identifiable {
    let id: String
    let name: String
    let apps: [LaunchApp]

    var searchText: String {
        let childText = apps.map(\.searchText).joined(separator: " ")
        return "\(name) \(childText)".localizedLowercase
    }
}

enum LauncherItem: Identifiable {
    case app(LaunchApp)
    case folder(LaunchFolder)

    var id: String {
        switch self {
        case .app(let app):
            app.id
        case .folder(let folder):
            folder.id
        }
    }

    var name: String {
        switch self {
        case .app(let app):
            app.name
        case .folder(let folder):
            folder.name
        }
    }

    var searchText: String {
        switch self {
        case .app(let app):
            app.searchText
        case .folder(let folder):
            folder.searchText
        }
    }
}
