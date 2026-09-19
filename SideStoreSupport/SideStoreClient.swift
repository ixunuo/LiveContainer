//
//  SideStoreClient.swift
//  SideStoreSupport
//
//  Created by s s on 2025/7/20.
//

import Foundation
import AppIntents
import OSLog

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
