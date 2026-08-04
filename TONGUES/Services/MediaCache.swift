import Foundation
import CryptoKit
import FirebaseStorage

// Two-tier audio cache: device disk + Firebase Storage. Disk is read first for
// instant hits; Firebase is checked on miss so a user hearing audio another
// user already generated skips the upstream API call entirely.
//
// Keys are SHA-256 hashes of a domain-prefixed string (e.g. "elevenlabs-…",
// "forvo-…") so different providers never collide and you can clear one
// provider's cache without touching the others.
enum MediaCache {
    private static let remotePrefix = "audio-cache"
    private static let maxSizeBytes: Int64 = 10 * 1024 * 1024  // 10 MB safety cap

    static func shaKey(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // Returns cached data if present locally or in Firebase Storage.
    // Side effects: hydrates the disk cache on a Firebase hit. `ext` selects
    // the payload type ("mp3" audio by default, "json" for the timestamp
    // alignment sidecar) so both share one key but never collide on disk.
    static func fetch(key: String, ext: String = "mp3") async -> Data? {
        if let local = diskRead(key: key, ext: ext) {
            return local
        }

        do {
            let ref = Storage.storage().reference(withPath: "\(remotePrefix)/\(key).\(ext)")
            let data = try await ref.data(maxSize: maxSizeBytes)
            diskWrite(data, key: key, ext: ext)
            return data
        } catch {
            return nil
        }
    }

    // Writes to disk immediately, then uploads to Firebase Storage in the
    // background. Upload errors are swallowed — a missed upload just means the
    // next user pays the upstream cost again; it's not playback-blocking.
    static func store(_ data: Data, key: String, ext: String = "mp3") async {
        diskWrite(data, key: key, ext: ext)
        let ref = Storage.storage().reference(withPath: "\(remotePrefix)/\(key).\(ext)")
        let metadata = StorageMetadata()
        metadata.contentType = ext == "json" ? "application/json" : "audio/mpeg"
        _ = try? await ref.putDataAsync(data, metadata: metadata)
    }

    // MARK: Disk layer

    private static func diskURL(key: String, ext: String) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = caches.appendingPathComponent("MediaCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(key).\(ext)")
    }

    static func diskRead(key: String, ext: String = "mp3") -> Data? {
        guard let url = diskURL(key: key, ext: ext),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func diskWrite(_ data: Data, key: String, ext: String = "mp3") {
        guard let url = diskURL(key: key, ext: ext) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
