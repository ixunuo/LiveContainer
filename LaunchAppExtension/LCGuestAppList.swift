//
//  LCGuestAppList.swift
//  LaunchAppExtension
//

import Foundation
import UIKit

struct LCGuestContainer {
    let folderName: String
    let name: String
}

struct LCGuestApp: Identifiable {
    let id: String
    let relativeBundlePath: String
    let displayName: String
    let bundleIdentifier: String
    let remark: String?
    let containers: [LCGuestContainer]
    let iconURL: URL?
    let lastLaunched: Date?
    let installationDate: Date?

    var primaryContainer: LCGuestContainer? { containers.first }
}

struct LCGuestAppListResult {
    let apps: [LCGuestApp]
    let diagnostics: [String]
}

enum LCGuestAppList {
    private static var cachedPrivateDocURL: URL?

    private enum AppLoadOutcome {
        case app(LCGuestApp)
        case hidden
        case unreadable
    }

    private struct RootLoadResult {
        var apps: [LCGuestApp]
        var hidden = 0
        var unreadable = 0
    }

    static func loadVisibleApps() -> LCGuestAppListResult {
        let groupID: String = LCSharedUtils.appGroupID() ?? "Unknown"
        let groupAccessible = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) != nil
        let sharedDefaults = UserDefaults(suiteName: groupID)

        var diagnostics: [String] = []
        diagnostics.append("extension: \(Bundle.main.bundleIdentifier ?? "?")")
        diagnostics.append("app group: \(groupID)\(groupAccessible ? "" : " (not accessible)")")

        var apps: [LCGuestApp] = []

        if let privateDocURL = resolvePrivateDocURL(sharedDefaults: sharedDefaults) {
            let result = loadApps(in: privateDocURL, isShared: false, sharedDefaults: sharedDefaults)
            apps.append(contentsOf: result.apps)
            diagnostics.append("private apps: \(result.apps.count) shown / \(result.hidden + result.apps.count + result.unreadable) found\(suffix(result))")
        } else {
            let bookmarkPresent = sharedDefaults?.data(forKey: "LCLaunchExtensionPrivateDocBookmark") != nil
            diagnostics.append("private apps: bookmark \(bookmarkPresent ? "not resolvable" : "missing") — open LiveContainer once to create it")
        }

        if let appGroupPath = LCSharedUtils.appGroupPath() {
            let result = loadApps(in: appGroupPath.appendingPathComponent("LiveContainer"), isShared: true, sharedDefaults: sharedDefaults)
            apps.append(contentsOf: result.apps)
            diagnostics.append("shared apps: \(result.apps.count) shown / \(result.hidden + result.apps.count + result.unreadable) found\(suffix(result))")
        } else {
            diagnostics.append("shared apps: app group container unavailable")
        }

        let sortedApps = sortApps(apps, sharedDefaults: sharedDefaults)
        diagnostics.append("total: \(sortedApps.count)")
        return LCGuestAppListResult(apps: sortedApps, diagnostics: diagnostics)
    }

    private static func suffix(_ result: RootLoadResult) -> String {
        var parts: [String] = []
        if result.hidden > 0 {
            parts.append("\(result.hidden) hidden")
        }
        if result.unreadable > 0 {
            parts.append("\(result.unreadable) unreadable")
        }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")) skipped)"
    }

    private static func resolvePrivateDocURL(sharedDefaults: UserDefaults?) -> URL? {
        if let cachedPrivateDocURL {
            return cachedPrivateDocURL
        }
        guard let bookmarkData = sharedDefaults?.data(forKey: "LCLaunchExtensionPrivateDocBookmark") else {
            return nil
        }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale) else {
            // a bookmark that cannot be resolved is useless to every extension;
            // clearing it lets LiveContainer recreate it on next launch
            sharedDefaults?.set(nil, forKey: "LCLaunchExtensionPrivateDocBookmark")
            return nil
        }
        _ = url.startAccessingSecurityScopedResource()
        cachedPrivateDocURL = url
        return url
    }

    private static func loadApps(in root: URL, isShared: Bool, sharedDefaults: UserDefaults?) -> RootLoadResult {
        let applicationsURL = root.appendingPathComponent("Applications")
        guard let appDirs = try? FileManager.default.contentsOfDirectory(at: applicationsURL, includingPropertiesForKeys: nil) else {
            return RootLoadResult(apps: [])
        }
        var result = RootLoadResult(apps: [])
        for appURL in appDirs where appURL.pathExtension == "app" {
            switch loadApp(appURL: appURL, isShared: isShared, sharedDefaults: sharedDefaults) {
            case .app(let app):
                result.apps.append(app)
            case .hidden:
                result.hidden += 1
            case .unreadable:
                result.unreadable += 1
            }
        }
        return result
    }

    private static func loadApp(appURL: URL, isShared: Bool, sharedDefaults: UserDefaults?) -> AppLoadOutcome {
        guard let infoPlist = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")) as? [String: Any] else {
            return .unreadable
        }
        let appInfo = (NSDictionary(contentsOf: appURL.appendingPathComponent("LCAppInfo.plist")) as? [String: Any]) ?? [:]

        // hidden apps are only revealed after in-app authentication, they are not offered here
        if appInfo["isHidden"] as? Bool ?? false {
            return .hidden
        }

        let relativeBundlePath = appURL.lastPathComponent
        let displayName = (infoPlist["CFBundleDisplayName"] as? String)
            ?? (infoPlist["CFBundleName"] as? String)
            ?? (infoPlist["CFBundleExecutable"] as? String)
            ?? relativeBundlePath

        let bundleIdentifier: String
        if appInfo["doUseLCBundleId"] as? Bool == true, let original = appInfo["LCOrignalBundleIdentifier"] as? String {
            bundleIdentifier = original
        } else {
            bundleIdentifier = (infoPlist["CFBundleIdentifier"] as? String) ?? "Unknown"
        }

        // apps that were never launched have no container yet; LiveContainer creates one on launch
        let containers = loadContainers(appInfo: appInfo)
        let remark = (appInfo["remark"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        return .app(LCGuestApp(
            id: "\(isShared ? "shared" : "private")|\(relativeBundlePath)",
            relativeBundlePath: relativeBundlePath,
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            remark: remark,
            containers: containers,
            iconURL: iconURL(for: appURL, sharedDefaults: sharedDefaults),
            lastLaunched: appInfo["lastLaunched"] as? Date,
            installationDate: appInfo["installationDate"] as? Date
        ))
    }

    private static func loadContainers(appInfo: [String: Any]) -> [LCGuestContainer] {
        var containers: [LCGuestContainer] = []
        if let containerInfo = appInfo["LCContainers"] as? [[String: Any]] {
            containers = containerInfo.compactMap { dict in
                guard let folderName = dict["folderName"] as? String else {
                    return nil
                }
                return LCGuestContainer(folderName: folderName, name: (dict["name"] as? String) ?? folderName)
            }
        }
        if containers.isEmpty, let folderName = appInfo["LCDataUUID"] as? String {
            containers = [LCGuestContainer(folderName: folderName, name: folderName)]
        }
        return containers
    }

    private static func iconURL(for appURL: URL, sharedDefaults: UserDefaults?) -> URL? {
        let lightIconURL = appURL.appendingPathComponent("LCAppIconLight.png")
        let darkIconURL = appURL.appendingPathComponent("LCAppIconDark.png")

        var preferredIconURL = lightIconURL
        var fallbackIconURL = darkIconURL
        if #available(iOS 18.0, *), sharedDefaults?.bool(forKey: "darkModeIcon") == true {
            preferredIconURL = darkIconURL
            fallbackIconURL = lightIconURL
        }

        if FileManager.default.fileExists(atPath: preferredIconURL.path) {
            return preferredIconURL
        }
        if FileManager.default.fileExists(atPath: fallbackIconURL.path) {
            return fallbackIconURL
        }
        return looseIconURL(in: appURL)
    }

    // fallback for apps whose icon cache has not been generated yet
    private static func looseIconURL(in appURL: URL) -> URL? {
        guard let infoPlist = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")) as? [String: Any] else {
            return nil
        }
        var names: [String] = []
        if let icons = infoPlist["CFBundleIcons"] as? [String: Any],
           let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String] {
            names = iconFiles
        }
        if names.isEmpty, let iconFiles = infoPlist["CFBundleIconFiles"] as? [String] {
            names = iconFiles
        }
        if names.isEmpty, let iconFile = infoPlist["CFBundleIconFile"] as? String {
            names = [iconFile]
        }
        guard !names.isEmpty else {
            return nil
        }

        for name in names.reversed() {
            for suffix in ["@3x", "@2x", ""] {
                let url = appURL.appendingPathComponent(name + suffix + ".png")
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
        }

        let contents = (try? FileManager.default.contentsOfDirectory(at: appURL, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { url in
                url.pathExtension.lowercased() == "png" && names.contains { url.lastPathComponent.hasPrefix($0) }
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .last
    }

    private static func sortApps(_ apps: [LCGuestApp], sharedDefaults: UserDefaults?) -> [LCGuestApp] {
        switch sharedDefaults?.string(forKey: "LCAppSortType") ?? "default" {
        case "alphabetical":
            return apps.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case "reverse_alphabetical":
            return apps.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedDescending }
        case "last_launched":
            let dated = apps.compactMap { app -> (LCGuestApp, Date)? in
                guard let lastLaunched = app.lastLaunched else {
                    return nil
                }
                return (app, lastLaunched)
            }.sorted { $0.1 > $1.1 }.map { $0.0 }
            return dated + apps.filter { $0.lastLaunched == nil }
        case "installationDate":
            let dated = apps.compactMap { app -> (LCGuestApp, Date)? in
                guard let installationDate = app.installationDate else {
                    return nil
                }
                return (app, installationDate)
            }.sorted { $0.1 > $1.1 }.map { $0.0 }
            return dated + apps.filter { $0.installationDate == nil }
        case "custom":
            return sortByCustomOrder(apps, sharedDefaults: sharedDefaults)
        default:
            return apps
        }
    }

    private static func sortByCustomOrder(_ apps: [LCGuestApp], sharedDefaults: UserDefaults?) -> [LCGuestApp] {
        guard let customSortOrder = sharedDefaults?.array(forKey: "LCCustomSortOrder") as? [String],
              !customSortOrder.isEmpty else {
            return apps.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }

        var sortedApps: [LCGuestApp] = []
        var remainingApps = apps
        for uniqueID in customSortOrder {
            if let index = remainingApps.firstIndex(where: { uniqueID == "\($0.bundleIdentifier):\($0.relativeBundlePath)" }) {
                sortedApps.append(remainingApps.remove(at: index))
            }
        }

        remainingApps.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        sortedApps.append(contentsOf: remainingApps)
        return sortedApps
    }
}
