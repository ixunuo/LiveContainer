//
//  SideStoreClient.swift
//  SideStoreSupport
//
//  Created by s s on 2025/7/20.
//

import Foundation
import AppIntents
import OSLog
import SQLite3

enum SideStoreIntentError: LocalizedError {
    case typeNotFound(String)
    case typeIsNotAppIntent(String)

    var errorDescription: String? {
        switch self {
        case .typeNotFound(let name):
            return "SideStore refresh intent type was not found: \(name)"
        case .typeIsNotAppIntent(let name):
            return "SideStore type is not an AppIntent: \(name)"
        }
    }
}

@available(iOS 17.0, *)
private func resolveType(_ mangledTypeName: String) throws -> any Any.Type {
    let bytes = Array(mangledTypeName.utf8)
    let resolvedType: Any.Type? = bytes.withUnsafeBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else {
            return nil
        }

        // Swift exposes the runtime symbol swift_getTypeByMangledNameInContext
        // as _getTypeByMangledNameInContext. The name intentionally omits
        // the "$s" prefix, which is the form accepted for this module.
        return _getTypeByMangledNameInContext(
            baseAddress,
            UInt(buffer.count),
            genericContext: nil,
            genericArguments: nil
        )
    }

    guard let resolvedType else {
        throw SideStoreIntentError.typeNotFound(mangledTypeName)
    }

    return resolvedType
}

@available(iOS 17.0, *)
struct SideStoreIntentCaller {
    static let shared = SideStoreIntentCaller()
    
    // call this when a IntentContext already exists (when sidestore is loaded in LiveContainer itself)
    func callRefreshIntent(mangledTypeName: String) async throws {
        let resolvedType = try resolveType(mangledTypeName)
        guard let intentType = resolvedType as? any ProgressReportingIntent.Type else {
            throw SideStoreIntentError.typeIsNotAppIntent(mangledTypeName)
        }
        
        let intent = intentType.init()
        let _ = try await intent.perform()
    }
    
    // call this when no IntentContext exists (when sidestore is loaded in LiveProcess)
    func callRefreshIntent2(identifier: String, mangledTypeName: String, progressCallback: (Progress)->Void ) async throws {
        try await withUnsafeThrowingContinuation { (c: UnsafeContinuation<(), any Error>) in
            let parent = PrivateIntentRunner.run(
                        identifier: identifier,
                        mangledTypeName: mangledTypeName
                    ) { result, error in
                        print("performAction result=\(String(describing: result)), " +
                              "error=\(String(describing: error))")
                        if let error {
                            c.resume(throwing: error)
                        } else {
                            c.resume()
                        }
                    }
            if let parent {
                progressCallback(parent)
            }
        }
    }
}

@available(iOS 17.0, *)
@objc extension SideStoreClient {
    @objc(performRefreshForRealWithIdentifier:mangledTypeName:server:)
    func performRefreshForReal(identifier: String, mangledTypeName: String, server: any RefreshServer) {
        Task {
            let anisetteSeedState = ensureAnisetteServerListExists()
            do {
                var obs: NSKeyValueObservation? = nil
                try await SideStoreIntentCaller.shared.callRefreshIntent2(identifier: identifier, mangledTypeName: mangledTypeName) { progress in
                    obs = progress.observe(\.fractionCompleted, options: [.new]) { progress, change in
                        if let newValue = change.newValue {
                            server.updateProgress(newValue)
                        }
                    }
                }
                obs?.invalidate()
                LCStoreExpiryPublisher.publishNow()
                server.finish(nil)
            } catch {
                server.finish("\(LCAnisetteDiagnostics()) | anisetteSeed=\(anisetteSeedState) | \(error.localizedDescription)")
            }
        }
    }

}

private struct SeedAnisetteServer: Codable {
    let name: String
    let address: String
    let isHidden: Bool
}

/// SideStore keeps its Anisette server list in its Documents directory and normally refreshes it when the app
/// launches. A refresh that runs without the app can find it empty and fail with "no servers configured",
/// so make sure the default server is there before the intent runs.
private func ensureAnisetteServerListExists() -> String {
    let fileManager = FileManager.default
    guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
        return "failedNoDocumentsDir"
    }
    let serversURL = documentsURL.appendingPathComponent("anisette-servers.json")
    if fileManager.fileExists(atPath: serversURL.path) {
        return "skippedExists"
    }

    let servers = [SeedAnisetteServer(name: "SideStore", address: "https://ani.sidestore.io", isHidden: false)]
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(servers).write(to: serversURL, options: .atomic)
        return "written"
    } catch {
        return "failed(\(error.localizedDescription))"
    }
}

/// SideStore's app list renders `InstalledApp.expirationDate` out of its CoreData store. Only the
/// processes that own the store (LiveContainer / LiveProcess, whose HOME is the store container) can
/// always read it, so the values are published into the app group for the Shortcuts extension.
@objc(LCStoreExpiryPublisher)
public final class LCStoreExpiryPublisher: NSObject {
    private struct StoreEntry: Codable {
        let exp: Double
        let refreshed: Double?
    }

    private struct CacheFile: Codable {
        let written: Double
        let apps: [String: StoreEntry]
        // what this process could see, so a "still shows ≈" report can be diagnosed from the app group
        let home: String
        let found: String?
        let tried: [String]
        let error: String?
        let process: String
    }

    @objc public static func publish() {
        DispatchQueue.global(qos: .utility).async {
            publishNow()
        }
    }

    // LiveProcess can be torn down as soon as the refresh is reported, so the exit path writes inline
    @objc public static func publishNow() {
        guard let groupURL = LCSharedUtils.appGroupPath() else {
            return
        }
        let candidates = storeURLs()
        var tried: [String] = []
        var found: String?
        var apps: [String: StoreEntry] = [:]
        for url in candidates {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            tried.append("\(url.path) exists=\(size > 0) size=\(size)")
            if found == nil, size > 0, let entries = read(url: url) {
                found = url.path
                apps = entries
            }
        }
        let error: String?
        if candidates.isEmpty {
            error = "no store candidates under HOME"
        } else if found == nil {
            error = "store found but unreadable"
        } else if apps.isEmpty {
            error = "store readable but ZINSTALLEDAPP is empty"
        } else {
            error = nil
        }
        let cache = CacheFile(written: Date().timeIntervalSinceReferenceDate,
                              apps: apps,
                              home: NSHomeDirectory(),
                              found: found,
                              tried: tried,
                              error: error,
                              process: Bundle.main.bundleURL.pathExtension == "appex" ? "extension" : "app")
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: groupURL.appendingPathComponent("LCStoreExpiry.json"), options: .atomic)
    }

    private static func read(url: URL) -> [String: StoreEntry]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK
                || sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        // CoreData stores these attributes as REAL seconds since 2001-01-01
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ZBUNDLEIDENTIFIER, ZEXPIRATIONDATE, ZREFRESHEDDATE FROM ZINSTALLEDAPP", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        var result: [String: StoreEntry] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let rawIdentifier = sqlite3_column_text(stmt, 0),
                  sqlite3_column_type(stmt, 1) != SQLITE_NULL else {
                continue
            }
            let identifier = String(cString: rawIdentifier)
            let expiration = sqlite3_column_double(stmt, 1)
            if let existing = result[identifier], existing.exp >= expiration {
                continue
            }
            let refreshed = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2)
            result[identifier] = StoreEntry(exp: expiration, refreshed: refreshed)
        }
        return result
    }

    private static func storeURLs() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        // LiveProcess: HOME is the store container; LiveContainer itself: the store lives under Documents
        let fixedURLs = [
            home.appendingPathComponent("Library/Application Support/SideStore.sqlite"),
            home.appendingPathComponent("Library/Application Support/AltStore.sqlite"),
            home.appendingPathComponent("Library/Application Support/SideStore/SideStore.sqlite"),
            home.appendingPathComponent("Library/Application Support/AltStore/AltStore.sqlite"),
            home.appendingPathComponent("Documents/SideStore/Library/Application Support/SideStore.sqlite"),
            home.appendingPathComponent("Documents/SideStore/Library/Application Support/AltStore.sqlite"),
            home.appendingPathComponent("Documents/Library/Application Support/SideStore.sqlite")
        ]
        let existing = fixedURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty {
            return existing
        }
        // unknown layout: shallow search for the store file, skipping app bundles and payload folders
        for root in [home.appendingPathComponent("Documents/SideStore"),
                     home.appendingPathComponent("Library/Application Support"),
                     home.appendingPathComponent("Documents")] {
            if let found = findStore(under: root, depth: 0) {
                return [found]
            }
        }
        return []
    }

    private static func findStore(under url: URL, depth: Int) -> URL? {
        guard depth <= 4 else { return nil }
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return nil
        }
        for item in items {
            let name = item.lastPathComponent
            if name == "SideStore.sqlite" || name == "AltStore.sqlite" {
                return item
            }
            guard name != "Applications", name != "Data",
                  !name.hasSuffix(".app"), !name.hasSuffix(".ipa"), !name.hasSuffix(".appex") else {
                continue
            }
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory), isDirectory.boolValue,
               let found = findStore(under: item, depth: depth + 1) {
                return found
            }
        }
        return nil
    }
}
