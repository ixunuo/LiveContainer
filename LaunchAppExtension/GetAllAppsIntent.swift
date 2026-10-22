//
//  GetAllAppsIntent.swift
//  LaunchAppExtension
//

import AppIntents
import SQLite3
import UIKit

struct LCGuestAppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// The menu is the system's own parameter picker backed by a dynamic AppEntity query,
// not a custom snippet view: the picker stays interactive in every run context, and when
// the App parameter is left unset the system asks for an app each time the shortcut runs.
struct GetAllAppsIntent: AppIntent {
    static var title: LocalizedStringResource { "Open App List" }
    static var description: IntentDescription {
        "Shows the list of apps installed in LiveContainer (locked apps included) and launches the one you pick. Leave \"LiveContainer APP List\" unset to choose from the list every time the shortcut runs."
    }

    @Parameter(title: "LiveContainer APP List")
    var app: LCGuestAppEntity

    func perform() async throws -> some IntentResult {
        if app.isSideStore {
            guard LCSideStoreSupport.isEmbedded else {
                throw LCGuestAppError("This LiveContainer build does not include SideStore.")
            }
            guard let appGroupId = LCSharedUtils.appGroupID(),
                  let lcSharedDefaults = UserDefaults(suiteName: appGroupId) else {
                throw LCGuestAppError("lcSharedDefaults failed to initialize, because no app group was found. Did you sign LiveContainer correctly?")
            }
            // the same handoff the built-in "Launch App" action performs for sidestore:// links
            lcSharedDefaults.set("livecontainer", forKey: "LCLaunchExtensionScheme")
            lcSharedDefaults.set("builtinSideStore", forKey: "LCLaunchExtensionBundleID")
            lcSharedDefaults.set(Date.now, forKey: "LCLaunchExtensionLaunchDate")
            let sideStoreURL = URL(string: "sidestore://")!
            try await LaunchAppExtension().openURL(launchOptions: ["url": sideStoreURL])
            return .result()
        }
        if app.isLiveContainerSelf {
            // "ui" is LiveContainer's own pseudo bundle name: upstream boots its interface for it,
            // and when a guest app is running the guest hooks offer to switch back to the LC UI
            guard let uiURL = LCLaunchURLBuilder.launchURL(bundleName: "ui", containerName: nil) else {
                throw LCGuestAppError("Could not build the LiveContainer URL.")
            }
            try await LaunchAppExtension().openURL(launchOptions: ["url": uiURL])
            return .result()
        }
        if let emptyMessage = app.emptyMessage {
            throw LCGuestAppError(emptyMessage)
        }
        guard let bundleName = app.bundleName else {
            throw LCGuestAppError("The selected app is no longer installed in LiveContainer.")
        }
        guard let launchURL = LCLaunchURLBuilder.launchURL(bundleName: bundleName, containerName: app.containerName) else {
            throw LCGuestAppError("Could not build a launch URL for \(app.displayTitle).")
        }

        // mirror the "Launch App" action's scheme handling so multiple LC copies keep working
        let normalizedLaunchScheme = launchURL.scheme?.lowercased()
        var isLiveContainerURL = normalizedLaunchScheme == "livecontainer"
        let preferredScheme = isLiveContainerURL ? nil : (normalizedLaunchScheme == "livecontainer1" ? "livecontainer" : normalizedLaunchScheme)
        if let preferredScheme, let schemes = LCSharedUtils.lcUnorderedUrlSchemes() {
            isLiveContainerURL = schemes.contains(preferredScheme)
        }
        guard isLiveContainerURL else {
            throw LCGuestAppError("Not a livecontainer URL!")
        }

        try await LaunchAppExtension().launchGuestApp(
            bundleName: bundleName,
            containerName: app.containerName,
            forceJIT: false,
            preferredScheme: preferredScheme,
            fallbackURL: launchURL
        )
        return .result()
    }
}

struct LCGuestAppEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "LiveContainer App") }
    static var defaultQuery = LCGuestAppQuery()

    let id: String
    let displayTitle: String
    let displaySubtitle: String?
    let iconPath: String?
    let bundleName: String?
    let containerName: String?
    // only set on the placeholder row shown when no app could be found
    let emptyMessage: String?
    // only set on the SideStore row shown in the LiveContainer+SideStore build
    let isSideStore: Bool
    // only set on the LiveContainer row shown at the bottom of the list
    let isLiveContainerSelf: Bool

    init(app: LCGuestApp) {
        id = app.id
        displayTitle = app.displayName
        displaySubtitle = app.remark ?? app.bundleIdentifier
        iconPath = app.iconURL?.path
        bundleName = app.relativeBundlePath
        containerName = app.primaryContainer?.folderName
        emptyMessage = nil
        isSideStore = false
        isLiveContainerSelf = false
    }

    private init(emptyMessage: String) {
        id = "__livecontainer_no_apps__"
        displayTitle = "No Apps Found"
        displaySubtitle = "Open LiveContainer once, then try again."
        iconPath = nil
        bundleName = nil
        containerName = nil
        self.emptyMessage = emptyMessage
        isSideStore = false
        isLiveContainerSelf = false
    }

    private init(sideStoreSubtitle: String?) {
        id = "__livecontainer_sidestore__"
        displayTitle = "SideStore"
        displaySubtitle = sideStoreSubtitle
        iconPath = LCSideStoreSupport.iconPath
        bundleName = nil
        containerName = nil
        emptyMessage = nil
        isSideStore = true
        isLiveContainerSelf = false
    }

    private init(liveContainerSubtitle: String?) {
        id = "__livecontainer_self__"
        displayTitle = "LiveContainer"
        displaySubtitle = liveContainerSubtitle
        iconPath = LCLiveContainerApp.iconPath
        bundleName = nil
        containerName = nil
        emptyMessage = nil
        isSideStore = false
        isLiveContainerSelf = true
    }

    static func sideStoreRow() -> LCGuestAppEntity? {
        guard LCSideStoreSupport.isEmbedded else {
            return nil
        }
        return LCGuestAppEntity(sideStoreSubtitle: LCSideStoreSupport.expirySubtitle())
    }

    static func liveContainerRow() -> LCGuestAppEntity {
        LCGuestAppEntity(liveContainerSubtitle: LCLiveContainerApp.expirySubtitle() ?? LCLiveContainerApp.bundleIdentifier)
    }

    static func emptyApps(diagnostics: [String]) -> LCGuestAppEntity {
        var message = "No apps were found in LiveContainer. Open LiveContainer once so it can refresh the extension bookmark, then run this shortcut again."
        if !diagnostics.isEmpty {
            message += "\n" + diagnostics.joined(separator: "\n")
        }
        return LCGuestAppEntity(emptyMessage: message)
    }

    var displayRepresentation: DisplayRepresentation {
        let image: DisplayRepresentation.Image?
        if emptyMessage != nil {
            image = DisplayRepresentation.Image(systemName: "exclamationmark.triangle")
        } else {
            image = LCGuestAppIcons.displayImage(forPath: iconPath, rounded: isSideStore || isLiveContainerSelf)
        }
        return DisplayRepresentation(
            title: "\(displayTitle)",
            subtitle: displaySubtitle.map { LocalizedStringResource(stringLiteral: $0) },
            image: image
        )
    }
}

struct LCGuestAppQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [LCGuestAppEntity] {
        let result = LCGuestAppList.loadVisibleApps()
        var entities: [LCGuestAppEntity] = []
        if let sideStore = LCGuestAppEntity.sideStoreRow(), identifiers.contains(sideStore.id) {
            entities.append(sideStore)
        }
        if result.apps.isEmpty {
            let empty = LCGuestAppEntity.emptyApps(diagnostics: result.diagnostics)
            if identifiers.contains(empty.id) {
                entities.append(empty)
            }
        } else {
            let byID = Dictionary(result.apps.map { LCGuestAppEntity(app: $0) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            entities.append(contentsOf: identifiers.compactMap { byID[$0] })
        }
        let liveContainer = LCGuestAppEntity.liveContainerRow()
        if identifiers.contains(liveContainer.id) {
            entities.append(liveContainer)
        }
        return entities
    }

    func suggestedEntities() async throws -> [LCGuestAppEntity] {
        let result = LCGuestAppList.loadVisibleApps()
        var entities: [LCGuestAppEntity] = []
        if let sideStore = LCGuestAppEntity.sideStoreRow() {
            entities.append(sideStore)
        }
        if result.apps.isEmpty {
            entities.append(LCGuestAppEntity.emptyApps(diagnostics: result.diagnostics))
        } else {
            entities.append(contentsOf: result.apps.map { LCGuestAppEntity(app: $0) })
        }
        entities.append(LCGuestAppEntity.liveContainerRow())
        return entities
    }
}

// builds the same livecontainer://livecontainer-launch URL the "Launch App" action accepts
enum LCLaunchURLBuilder {
    static let scheme: String = {
        // the extension bundle lives in <LiveContainer>.app/PlugIns/, read the app's own Info.plist
        let appBundleURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let plistURL = appBundleURL.appendingPathComponent("Info.plist")
        if let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let urlTypes = plist["CFBundleURLTypes"] as? [[String: Any]] {
            for urlType in urlTypes {
                if let schemes = urlType["CFBundleURLSchemes"] as? [String],
                   let scheme = schemes.first(where: { $0.hasPrefix("livecontainer") }) {
                    return scheme
                }
            }
        }
        return "livecontainer"
    }()

    static func launchURL(bundleName: String, containerName: String?) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "livecontainer-launch"
        var queryItems = [URLQueryItem(name: "bundle-name", value: bundleName)]
        if let containerName {
            queryItems.append(URLQueryItem(name: "container-folder-name", value: containerName))
        }
        components.queryItems = queryItems
        return components.url
    }
}

private enum LCGuestAppIcons {
    private static let cache = NSCache<NSString, NSData>()

    static func displayImage(forPath path: String?, rounded: Bool = false) -> DisplayRepresentation.Image? {
        guard let path, let data = downscaledPNG(at: path, rounded: rounded) else {
            return nil
        }
        return DisplayRepresentation.Image(data: data)
    }

    // the picker only draws small rows; never hand it full-size app icons
    private static func downscaledPNG(at path: String, rounded: Bool) -> Data? {
        let cacheKey = rounded ? "\(path)|rounded" : path
        if let cached = cache.object(forKey: cacheKey as NSString) {
            return cached as Data
        }
        guard let image = UIImage(contentsOfFile: path), image.size.width > 0, image.size.height > 0 else {
            return nil
        }
        let maxSide: CGFloat = 180
        let scale = min(maxSide / image.size.width, maxSide / image.size.height, 1)
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: targetSize)
            if rounded {
                // guest rows get LiveContainer's IconServices-masked icons, but the raw bundle PNGs
                // behind the SideStore / LiveContainer rows are full-bleed squares: mask them the same
                // way (roughly the iOS icon corner ratio) so every row looks alike
                UIBezierPath(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.2237).addClip()
            }
            image.draw(in: rect)
        }
        guard let data = resized.pngData() else {
            return nil
        }
        cache.setObject(data as NSData, forKey: cacheKey as NSString)
        return data
    }
}

// SideStore is embedded as Frameworks/SideStoreApp.framework only in the LiveContainer+SideStore
// build; the same file check the main app uses (LCBootstrap.m) tells the two builds apart
enum LCSideStoreSupport {
    static let appBundleURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()

    private static var frameworkURL: URL {
        appBundleURL.appendingPathComponent("Frameworks/SideStoreApp.framework")
    }

    static var isEmbedded: Bool {
        FileManager.default.fileExists(atPath: frameworkURL.path)
    }

    static var iconPath: String? {
        for name in ["AppIcon60x60@2x.png", "AppIcon60x60@3x.png", "AppIcon76x76@2x~ipad.png"] {
            let url = frameworkURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                return url.path
            }
        }
        return nil
    }

    static func expirySubtitle(now: Date = Date()) -> String? {
        LCExpiry.date(from: expirySources).map { LCExpiry.text(for: $0, now: now) }
    }

    // What iOS enforces is the profile installed in LiveContainer.app, and that is also the date the
    // store shows for this app; the store's own database can lag behind a refresh (its row may even
    // say expired while the app still launches), so a database value only wins when it is further out.
    private static var expirySources: [Date] {
        var dates: [Date] = []
        if let profile = LCInstalledProfile.profile() {
            dates.append(profile.expiration)
        }
        let records = LCStoreDatabase.entries()
        for identifier in [LCStoreDatabase.sideStoreBundleIdentifier, LCLiveContainerApp.bundleIdentifier].compactMap({ $0 }) {
            if let date = records[identifier] {
                dates.append(date)
            }
        }
        return dates
    }
}

enum LCExpiry {
    // a future value wins over a stale past one; the latest future value wins otherwise
    static func date(from dates: [Date], now: Date = Date()) -> Date? {
        let future = dates.filter { $0 > now }
        return future.max() ?? dates.max()
    }

    // identical to SideStore's own pill: DateComponentsFormatter with the largest allowed unit, which
    // rounds to the nearest unit ("6.999 days" -> "7 days"); expired rows read EXPIRED there too
    static func text(for expiration: Date, now: Date = Date()) -> String {
        guard expiration.timeIntervalSince(now) > 0 else {
            return "EXPIRED"
        }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 1
        return formatter.string(from: now, to: expiration) ?? "EXPIRED"
    }
}

// SideStore's app list renders InstalledApp.expirationDate straight out of its CoreData store, so
// reading the same row is the only way this subtitle can agree with what SideStore shows for that app.
// The store lives in the built-in SideStore's home (<LC documents>/SideStore) and is named after the
// CoreData container ("AltStore").
enum LCStoreDatabase {
    static let sideStoreBundleIdentifier = "com.SideStore.SideStore"

    // bundle identifier -> expiration, merged from the app group cache and every readable store file
    static func entries() -> [String: Date] {
        var result: [String: Date] = [:]
        func merge(_ identifier: String, _ date: Date) {
            if let existing = result[identifier], existing >= date {
                return
            }
            result[identifier] = date
        }
        // LiveContainer/LiveProcess own the store and republish it after every refresh; the extension
        // itself may be sandboxed away from the store file
        for (identifier, date) in LCStoreExpiryCache.entries() {
            merge(identifier, date)
        }
        for url in storeURLs() {
            for (identifier, date) in read(url: url) {
                merge(identifier, date)
            }
        }
        return result
    }

    private static func read(url: URL) -> [String: Date] {
        var db: OpaquePointer?
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) != SQLITE_OK {
            sqlite3_close(db)
            db = nil
            if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
                sqlite3_close(db)
                db = nil
                // sidecar (-wal/-shm) files may not be openable from the extension; the main file alone
                // still holds the last checkpointed state
                guard sqlite3_open_v2("file:\(url.path)?immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
                    sqlite3_close(db)
                    return [:]
                }
            }
        }
        defer { sqlite3_close(db) }

        // CoreData stores this attribute as REAL seconds since 2001-01-01
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ZBUNDLEIDENTIFIER, ZEXPIRATIONDATE FROM ZINSTALLEDAPP", -1, &stmt, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }

        var result: [String: Date] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let rawIdentifier = sqlite3_column_text(stmt, 0),
                  sqlite3_column_type(stmt, 1) != SQLITE_NULL else {
                continue
            }
            let identifier = String(cString: rawIdentifier)
            let date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))
            if let existing = result[identifier], existing >= date {
                continue
            }
            result[identifier] = date
        }
        return result
    }

    static func storeURLs() -> [URL] {
        var homes: [URL] = []
        if let documents = LCGuestAppList.privateDocURL() {
            homes.append(documents.appendingPathComponent("SideStore"))
        }
        if let appGroup = LCSharedUtils.appGroupPath() {
            homes.append(appGroup.appendingPathComponent("SideStore"))
        }
        var urls: [URL] = []
        for home in homes {
            // the nightly names its CoreData store after the app ("SideStore.sqlite"); older builds
            // used "AltStore.sqlite"
            for relativePath in ["Library/Application Support/SideStore.sqlite",
                                 "Library/Application Support/AltStore.sqlite",
                                 "Library/Application Support/SideStore/SideStore.sqlite",
                                 "Library/Application Support/AltStore/AltStore.sqlite"] {
                let url = home.appendingPathComponent(relativePath)
                if FileManager.default.fileExists(atPath: url.path), !urls.contains(url) {
                    urls.append(url)
                }
            }
            // tolerate layout differences: any sqlite file directly under Application Support
            let support = home.appendingPathComponent("Library/Application Support")
            if let contents = try? FileManager.default.contentsOfDirectory(at: support, includingPropertiesForKeys: nil) {
                for item in contents where item.pathExtension == "sqlite" && !urls.contains(item) {
                    urls.append(item)
                }
            }
        }
        return urls
    }
}

// the profile the sideloader put into LiveContainer.app, i.e. when this app stops launching
enum LCInstalledProfile {
    static func profile() -> (created: Date?, expiration: Date)? {
        let appBundleURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        // embedded.mobileprovision is a CMS blob wrapping the property list that carries the dates
        let profileURL = appBundleURL.appendingPathComponent("embedded.mobileprovision")
        guard let data = try? Data(contentsOf: profileURL),
              let xmlStart = data.range(of: Data("<?xml".utf8)),
              let xmlEnd = data.range(of: Data("</plist>".utf8), in: xmlStart.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[xmlStart.lowerBound..<xmlEnd.upperBound], format: nil) as? [String: Any],
              let expiration = plist["ExpirationDate"] as? Date else {
            return nil
        }
        return (plist["CreationDate"] as? Date, expiration)
    }
}

// the LiveContainer app itself, offered as the last row of the list
enum LCLiveContainerApp {
    static let appBundleURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()

    static var bundleIdentifier: String? {
        let plistURL = appBundleURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["CFBundleIdentifier"] as? String
    }

    static var iconPath: String? {
        for name in ["AppIcon60x60@2x.png", "AppIcon60x60@3x.png", "AppIcon76x76@2x~ipad.png"] {
            let url = appBundleURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                return url.path
            }
        }
        return nil
    }

    static func expirySubtitle(now: Date = Date()) -> String? {
        LCExpiry.date(from: expirySources).map { LCExpiry.text(for: $0, now: now) }
    }

    private static var expirySources: [Date] {
        var dates: [Date] = []
        if let profile = LCInstalledProfile.profile() {
            dates.append(profile.expiration)
        }
        if let bundleIdentifier, let date = LCStoreDatabase.entries()[bundleIdentifier] {
            dates.append(date)
        }
        return dates
    }
}

// LiveContainer/LiveProcess republish SideStore's own renewal dates into the app group after each
// refresh (they own the store container), so this is the same data SideStore's list shows.
enum LCStoreExpiryCache {
    private struct Entry: Decodable {
        let exp: Double
        let refreshed: Double?
    }

    private struct CacheFile: Decodable {
        let written: Double?
        let apps: [String: Entry]
    }

    static func entries() -> [String: Date] {
        guard let groupURL = LCSharedUtils.appGroupPath(),
              let data = try? Data(contentsOf: groupURL.appendingPathComponent("LCStoreExpiry.json")),
              let cache = try? JSONDecoder().decode(CacheFile.self, from: data) else {
            return [:]
        }
        return cache.apps.mapValues { Date(timeIntervalSinceReferenceDate: $0.exp) }
    }
}

// Reports exactly what the extension can see, so a "still shows ≈" report can be diagnosed without
// guessing. Run the action in Shortcuts; the thrown error carries the report.
enum LCAppListDiagnostics {
    private struct CacheHeader: Decodable {
        struct Entry: Decodable {
            let exp: Double
        }
        let written: Double?
        let apps: [String: Entry]
        let home: String?
        let found: String?
        let tried: [String]?
        let error: String?
        let process: String?
    }

    static func report() -> String {
        var lines: [String] = []
        lines.append("extension: \(Bundle.main.bundleIdentifier ?? "?")")
        let groupID = LCSharedUtils.appGroupID() ?? "nil"
        let groupURL = LCSharedUtils.appGroupPath()
        lines.append("app group: \(groupID) accessible=\(groupURL != nil)")

        if let groupURL {
            let cacheURL = groupURL.appendingPathComponent("LCStoreExpiry.json")
            var cacheLine = "cache: exists=\(FileManager.default.fileExists(atPath: cacheURL.path))"
            if let data = try? Data(contentsOf: cacheURL) {
                cacheLine += " size=\(data.count)"
                if let header = try? JSONDecoder().decode(CacheHeader.self, from: data) {
                    if let written = header.written {
                        cacheLine += " written=\(Date(timeIntervalSinceReferenceDate: written))"
                    }
                    cacheLine += " apps=\(header.apps.keys.sorted().joined(separator: ","))"
                }
            }
            lines.append(cacheLine)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: groupURL.path)) ?? []
            lines.append("group files: \(names.sorted().joined(separator: ", "))")
        }

        if let documents = LCGuestAppList.privateDocURL() {
            lines.append("private doc: \(documents.path)")
        } else {
            lines.append("private doc: unresolved (bookmark missing or not resolvable)")
        }

        let storeURLs = LCStoreDatabase.storeURLs()
        lines.append("store files: \(storeURLs.count)")
        for url in storeURLs {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            let sidecars = ["-wal", "-shm"].filter { FileManager.default.fileExists(atPath: url.path + $0) }
            lines.append("  \(url.path) size=\(size) sidecars=\(sidecars.joined(separator: ","))")
        }

        for home in [URL(fileURLWithPath: NSHomeDirectory())] {
            lines.append("HOME: \(home.path)")
            let support = home.appendingPathComponent("Library/Application Support")
            let supportNames = (try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? []
            lines.append("  HOME/Library/Application Support: \(supportNames.sorted().prefix(12).joined(separator: ", "))")
        }

        let entries = LCStoreDatabase.entries()
        lines.append("store entries: \(entries.count)")
        for (identifier, date) in entries.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(identifier) expires=\(date)")
        }
        if let profile = LCInstalledProfile.profile() {
            lines.append("installed profile expires: \(profile.expiration)")
        } else {
            lines.append("installed profile: none")
        }
        return lines.joined(separator: "\n")
    }
}

struct LCDiagnosticsIntent: AppIntent {
    static var title: LocalizedStringResource { "LC Diagnostics" }
    static var description = IntentDescription("Copies where LiveContainer's app list looks for SideStore's expiry data to the clipboard.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        UIPasteboard.general.string = LCAppListDiagnostics.report()
        return .result(dialog: "Diagnostics copied to the clipboard.")
    }
}
