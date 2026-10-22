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
        // SideStore's list renders InstalledApp.expirationDate, so the same field is shown here; the
        // heuristic sources are only a fallback for when the store database cannot be read
        if let expiration = LCStoreDatabase.expirationDate(forBundleIdentifier: LCStoreRecords.sideStoreBundleIdentifier) {
            return LCExpiry.text(for: expiration, now: now)
        }
        return latestExpiration.map { LCExpiry.text(for: $0, now: now, estimated: true) }
    }

    // SideStore's runtime lives inside LiveContainer, so the store dies with this app: the newest
    // renewal out of the store's SideStore/LiveContainer records and the installed profile is the
    // authoritative one (an old entry, e.g. the original SideStore install that the built-in store
    // never re-signed, must not override a fresh 7 day renewal).
    private static var latestExpiration: Date? {
        var candidates: [LCExpiryCandidate] = []
        let wanted = Set([LCStoreRecords.sideStoreBundleIdentifier, LCLiveContainerApp.bundleIdentifier].compactMap { $0 })
        for record in LCStoreRecords.records() where wanted.contains(record.bundleIdentifier) {
            candidates.append(LCExpiryCandidate(renewed: record.renewed ?? .distantPast, expires: record.expires))
        }
        if let profile = LCInstalledProfile.profile() {
            candidates.append(LCExpiryCandidate(renewed: profile.created ?? .distantPast, expires: profile.expiration))
        }
        return LCExpiry.latest(candidates)
    }

    static func expiryText(for expiration: Date, now: Date = Date()) -> String {
        LCExpiry.text(for: expiration, now: now)
    }
}

struct LCExpiryCandidate {
    let renewed: Date
    let expires: Date
}

enum LCExpiry {
    // the most recently renewed source wins; sources are only compared by renewal time, never by
    // picking the latest expiration, so a stale leftover record cannot mask a shorter real deadline
    static func latest(_ candidates: [LCExpiryCandidate]) -> Date? {
        candidates.max { $0.renewed < $1.renewed }?.expires
    }

    // SideStore's own pill uses calendar day components (then hours inside the last day), so the
    // numbers have to be computed the same way or the lists disagree by a day. "≈" marks a fallback
    // value (the store database could not be read), i.e. a number SideStore itself may not show.
    static func text(for expiration: Date, now: Date = Date(), estimated: Bool = false) -> String {
        let prefix = estimated ? "≈" : ""
        guard expiration.timeIntervalSince(now) > 0 else {
            return "⚠️ \(prefix)已过期"
        }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: now, to: expiration).day ?? 0
        if days >= 1 {
            return days <= 2 ? "⚠️ \(prefix)\(days)天后到期" : "\(prefix)\(days)天后到期"
        }
        let hours = max(1, calendar.dateComponents([.hour], from: now, to: expiration).hour ?? 0)
        return "⚠️ \(prefix)\(hours)小时后到期"
    }
}

// SideStore's app list renders InstalledApp.expirationDate straight out of its CoreData store, so
// reading the same row is the only way this subtitle can agree with what SideStore shows for that app.
// The store lives in the built-in SideStore's home (<LC documents>/SideStore) and is named after the
// CoreData container ("AltStore").
enum LCStoreDatabase {
    static func expirationDate(forBundleIdentifier wanted: String) -> Date? {
        guard !wanted.isEmpty else {
            return nil
        }
        for url in storeURLs() {
            if let date = read(url: url, bundleIdentifier: wanted) {
                return date
            }
        }
        return nil
    }

    private static func read(url: URL, bundleIdentifier wanted: String) -> Date? {
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
                    return nil
                }
            }
        }
        defer { sqlite3_close(db) }

        // CoreData stores this attribute as REAL seconds since 2001-01-01
        let sql = "SELECT ZEXPIRATIONDATE FROM ZINSTALLEDAPP WHERE ZBUNDLEIDENTIFIER = ?1 AND ZEXPIRATIONDATE IS NOT NULL ORDER BY ZEXPIRATIONDATE DESC LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(stmt, 1, wanted, -1, transient) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) != SQLITE_NULL else {
            return nil
        }
        return Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0))
    }

    private static func storeURLs() -> [URL] {
        var homes: [URL] = []
        if let documents = LCGuestAppList.privateDocURL() {
            homes.append(documents.appendingPathComponent("SideStore"))
        }
        if let appGroup = LCSharedUtils.appGroupPath() {
            homes.append(appGroup.appendingPathComponent("SideStore"))
        }
        var urls: [URL] = []
        for home in homes {
            for relativePath in ["Library/Application Support/AltStore.sqlite",
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

// SideStore rewrites <app group>/widget_data.json at the end of every refresh with the dates it shows
// in its own app list, so this copy moves with a renewal. The embedded.mobileprovision on disk can
// lag behind it (SideStore itself falls back to its cached dates when the profile is older than the
// last refresh), which is why the record is preferred over the profile.
enum LCStoreRecords {
    static let sideStoreBundleIdentifier = "com.SideStore.SideStore"

    struct Record {
        let bundleIdentifier: String
        let renewed: Date?
        let expires: Date
    }

    private struct Snapshot: Decodable {
        struct App: Decodable {
            let bundleIdentifier: String
            let expirationDate: Date
            let refreshedDate: Date?
        }
        let allApps: [App]?
        let activeApps: [App]?
    }

    static func records() -> [Record] {
        snapshotURLs().flatMap { fileURL -> [Record] in
            guard let data = try? Data(contentsOf: fileURL) else {
                return []
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .deferredToDate
            guard let snapshot = try? decoder.decode(Snapshot.self, from: data) else {
                return []
            }
            let apps = (snapshot.allApps ?? []) + (snapshot.activeApps ?? [])
            return apps.map {
                Record(bundleIdentifier: $0.bundleIdentifier, renewed: $0.refreshedDate, expires: $0.expirationDate)
            }
        }
    }

    // both groups can exist on one device; older installs may have left a snapshot behind, so every
    // candidate file is read and the entries are ranked by their own refreshedDate
    private static func snapshotURLs() -> [URL] {
        var groupIDs: [String] = []
        if let appGroupID = LCSharedUtils.appGroupID() {
            groupIDs.append(appGroupID)
        }
        // SideStore resolves its own group from the executable's entitlements, which can be the store's
        // plain group instead of LiveContainer's team-suffixed one
        groupIDs.append("group.com.SideStore.SideStore")
        var urls: [URL] = []
        for groupID in Set(groupIDs) {
            guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
                continue
            }
            let fileURL = container.appendingPathComponent("widget_data.json")
            if FileManager.default.fileExists(atPath: fileURL.path) {
                urls.append(fileURL)
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
        if let bundleIdentifier, let expiration = LCStoreDatabase.expirationDate(forBundleIdentifier: bundleIdentifier) {
            return LCExpiry.text(for: expiration, now: now)
        }
        return fallbackExpiration.map { LCExpiry.text(for: $0, now: now, estimated: true) }
    }

    private static var fallbackExpiration: Date? {
        var candidates: [LCExpiryCandidate] = []
        if let bundleIdentifier {
            for record in LCStoreRecords.records() where record.bundleIdentifier == bundleIdentifier {
                candidates.append(LCExpiryCandidate(renewed: record.renewed ?? .distantPast, expires: record.expires))
            }
        }
        if let profile = LCInstalledProfile.profile() {
            candidates.append(LCExpiryCandidate(renewed: profile.created ?? .distantPast, expires: profile.expiration))
        }
        return LCExpiry.latest(candidates)
    }
}
