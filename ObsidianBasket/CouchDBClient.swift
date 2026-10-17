import Compression
import CryptoKit
import Foundation

struct LiveSyncDocument: Codable, Sendable {
    var _id: String
    var _rev: String?
    var type: String
    var path: String?
    var children: [String]?
    var ctime: Double?
    var mtime: Double?
    var size: Int?
    var deleted: Bool?
    var eden: [String: EdenChunk]?
    var data: String?
    var isEncrypted: Bool?
    var _conflicts: [String]?

    enum CodingKeys: String, CodingKey {
        case _id, _rev, type, path, children, ctime, mtime, size, deleted, eden, data, _conflicts
        case isEncrypted = "e_"
    }

    struct EdenChunk: Codable, Sendable {
        var data: String
        var epoch: Double
    }
}

struct RemoteNote: Sendable {
    var document: LiveSyncDocument
    var text: String
}

struct CouchDBClient: Sendable {
    let settings: ConnectionSettings
    let password: String

    private struct Rows: Decodable {
        var rows: [Row]
        struct Row: Decodable {
            var key: String
            var doc: LiveSyncDocument?
            var value: Value?
            struct Value: Decodable {
                var deleted: Bool?
            }
        }
    }

    private struct WriteResult: Decodable {
        var ok: Bool
    }

    func changes(since sequence: String, waitForChanges: Bool = true) async throws -> (
        sequence: String, hasChanges: Bool
    ) {
        struct Changes: Decodable {
            var lastSequence: String
            var results: [Change]

            enum CodingKeys: String, CodingKey {
                case lastSequence = "last_seq"
                case results
            }

            struct Change: Decodable {
                var id: String
            }
        }

        let data = try await request(
            document: "_changes", method: "POST",
            body: JSONEncoder().encode(["doc_ids": [settings.documentID]]),
            query: [
                URLQueryItem(name: "feed", value: waitForChanges ? "longpoll" : "normal"),
                URLQueryItem(name: "filter", value: "_doc_ids"),
                URLQueryItem(name: "since", value: sequence),
                URLQueryItem(name: "limit", value: "1"),
                URLQueryItem(name: "timeout", value: "60000"),
            ],
            timeoutInterval: waitForChanges ? 75 : 25)
        let changes = try JSONDecoder().decode(Changes.self, from: data)
        return (changes.lastSequence, !changes.results.isEmpty)
    }

    func load() async throws -> RemoteNote? {
        let data: Data
        do {
            data = try await request(
                document: settings.documentID, query: [URLQueryItem(name: "conflicts", value: "true")])
        } catch ObsidianBasketError.http(404) {
            let rows = try await rows(for: [settings.documentID], includeDocuments: false)
            if rows.rows.first?.value?.deleted == true {
                throw ObsidianBasketError.message(
                    String(localized: .noteDeleted))
            }
            return nil
        }
        let document = try JSONDecoder().decode(LiveSyncDocument.self, from: data)
        guard document.deleted != true else {
            throw ObsidianBasketError.message(
                String(localized: .noteDeleted))
        }
        guard document._conflicts?.isEmpty != false else {
            throw ObsidianBasketError.message(
                String(localized: .noteConflicts)
            )
        }
        let matchesPath =
            settings.caseSensitivePaths
            ? document.path == settings.notePath
            : document.path?.lowercased() == settings.notePath.lowercased()
        guard document.isEncrypted != true else {
            throw ObsidianBasketError.message(
                String(localized: .noteEncrypted)
            )
        }
        guard matchesPath else {
            throw ObsidianBasketError.message(
                String(localized: .notePathMismatch)
            )
        }
        guard document.type == "plain" else {
            throw ObsidianBasketError.message(
                String(localized: .unsupportedNoteType(document.type))
            )
        }
        guard let children = document.children else {
            throw ObsidianBasketError.message(
                String(localized: .missingChunkList)
            )
        }
        var chunks = document.eden?.mapValues(\.data) ?? [:]
        let needed = Array(Set(children.filter { chunks[$0] == nil }))
        for start in stride(from: 0, to: needed.count, by: 100) {
            let batch = Array(needed[start..<min(start + 100, needed.count)])
            // A note can arrive before its chunks during replication. Retry missing chunks
            // briefly before reporting an incomplete note.
            for attempt in 0..<3 {
                let missing = batch.filter { chunks[$0] == nil }
                if missing.isEmpty { break }
                let response = try await rows(for: missing)
                for row in response.rows {
                    guard let chunk = row.doc else { continue }
                    guard chunk.isEncrypted != true else {
                        throw ObsidianBasketError.message(
                            String(localized: .chunkEncrypted(row.key))
                        )
                    }
                    guard chunk.type == "leaf" else {
                        throw ObsidianBasketError.message(
                            String(localized: .unsupportedChunkType(chunk.type))
                        )
                    }
                    guard let content = chunk.data else {
                        throw ObsidianBasketError.message(
                            String(localized: .missingChunkText(row.key))
                        )
                    }
                    chunks[row.key] = try decodeContent(content)
                }
                if attempt < 2 && batch.contains(where: { chunks[$0] == nil }) {
                    try await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
                }
            }
        }
        var text = ""
        for id in children {
            guard let piece = chunks[id] else {
                throw ObsidianBasketError.message(
                    String(localized: .noteIncomplete))
            }
            text += piece
        }
        return RemoteNote(document: document, text: text)
    }

    func save(text: String, replacing remote: RemoteNote?) async throws {
        struct Milestone: Decodable {
            var locked: Bool
            var tweak_values: [String: TweakValues]?

            struct TweakValues: Decodable {
                var encrypt: Bool?
                var usePathObfuscation: Bool?
            }
        }
        do {
            // Keep LiveSync's "obsydian" spelling in this document ID.
            let data = try await request(document: "_local/obsydian_livesync_milestone")
            let milestone = try JSONDecoder().decode(Milestone.self, from: data)
            guard !milestone.locked else {
                throw ObsidianBasketError.message(
                    String(localized: .databaseLocked))
            }
            let configurations = milestone.tweak_values ?? [:]
            let values = configurations["PREFERRED"].map { [$0] } ?? Array(configurations.values)
            guard !values.contains(where: { $0.encrypt == true || $0.usePathObfuscation == true }) else {
                throw ObsidianBasketError.message(String(localized: .encryptedVaultUnsupported))
            }
            guard !values.isEmpty,
                values.allSatisfy({ $0.encrypt == false && $0.usePathObfuscation == false })
            else {
                throw ObsidianBasketError.message(String(localized: .vaultSettingsUnavailable))
            }
        } catch ObsidianBasketError.http(404) {
            throw ObsidianBasketError.message(String(localized: .vaultSettingsUnavailable))
        }
        var children: [String] = []
        // Small chunks stay within LiveSync transport limits. Their IDs use its SHA-1 convention.
        var pieces: [String] = []
        var piece = ""
        var byteCount = 0
        for scalar in text.unicodeScalars {
            let value = String(scalar)
            if byteCount + value.utf8.count > 32_768 {
                pieces.append(piece)
                piece = ""
                byteCount = 0
            }
            piece += value
            byteCount += value.utf8.count
        }
        if !piece.isEmpty { pieces.append(piece) }
        for piece in pieces {
            let hashInput = Data("\(piece)-\(piece.utf16.count)".utf8)
            let hash = Data(Insecure.SHA1.hash(data: hashInput)).base64EncodedString()
            let id = "h:\(hash)"
            let chunk = LiveSyncDocument(_id: id, type: "leaf", data: piece)
            do {
                _ = try await request(document: id, method: "PUT", body: JSONEncoder().encode(chunk))
            } catch ObsidianBasketError.http(409) {
                let existing = try JSONDecoder().decode(
                    LiveSyncDocument.self, from: await request(document: id)
                )
                guard existing.isEncrypted != true, let data = existing.data, try decodeContent(data) == piece
                else {
                    throw ObsidianBasketError.message(
                        String(localized: .chunkConflict(id))
                    )
                }
            }
            children.append(id)
        }
        let now = Date().timeIntervalSince1970 * 1000
        let document = LiveSyncDocument(
            _id: remote?.document._id ?? settings.documentID,
            _rev: remote?.document._rev,
            type: "plain",
            path: remote?.document.path ?? settings.notePath,
            children: children,
            ctime: remote?.document.ctime ?? now,
            mtime: max(now, (remote?.document.mtime ?? 0) + 1),
            size: text.utf8.count,
            eden: [:]
        )
        let result = try await request(
            document: document._id, method: "PUT", body: JSONEncoder().encode(document))
        let written = try JSONDecoder().decode(WriteResult.self, from: result)
        guard written.ok else {
            throw ObsidianBasketError.message(
                String(localized: .saveNotConfirmed))
        }
    }

    private func rows(for keys: [String], includeDocuments: Bool = true) async throws -> Rows {
        let body = try JSONEncoder().encode(["keys": keys])
        let data = try await request(
            document: "_all_docs", method: "POST", body: body,
            query: [URLQueryItem(name: "include_docs", value: includeDocuments ? "true" : "false")]
        )
        return try JSONDecoder().decode(Rows.self, from: data)
    }

    private func request(
        document: String, method: String = "GET", body: Data? = nil,
        query: [URLQueryItem] = [], timeoutInterval: TimeInterval = 25
    ) async throws -> Data {
        guard var components = URLComponents(string: settings.server) else {
            throw ObsidianBasketError.message(
                String(localized: .invalidServerURL))
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let database = settings.database.addingPercentEncoding(withAllowedCharacters: allowed)
        else {
            throw ObsidianBasketError.message(
                String(localized: .databaseEncodingFailed)
            )
        }
        components.percentEncodedPath += "/" + database
        let isLocal = document.hasPrefix("_local/")
        let identifier = isLocal ? String(document.dropFirst(7)) : document
        guard let encoded = identifier.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw ObsidianBasketError.message(
                String(localized: .noteURLEncodingFailed)
            )
        }
        components.percentEncodedPath += (isLocal ? "/_local/" : "/") + encoded
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw ObsidianBasketError.message(
                String(localized: .invalidDatabaseURL)
            )
        }
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeoutInterval)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Basic " + Data("\(settings.username):\(password)".utf8).base64EncodedString(),
            forHTTPHeaderField: "Authorization"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ObsidianBasketError.message(
                String(localized: .invalidServerResponse)
            )
        }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 404, document == "_all_docs" {
                throw ObsidianBasketError.message(
                    String(localized: .databaseNotFound(settings.database))
                )
            }
            throw ObsidianBasketError.http(response.statusCode)
        }
        return data
    }

    private func decodeContent(_ value: String) throws -> String {
        guard value.hasPrefix("\u{000E}LZ\u{001D}") else { return value }
        var encoded = String(value.dropFirst(4))
        let wasBase64 = encoded.hasPrefix("~")
        if wasBase64 { encoded.removeFirst() }
        guard let data = Data(base64Encoded: encoded) else {
            throw ObsidianBasketError.message(
                String(localized: .invalidChunkBase64)
            )
        }
        for capacity in [65_536, 262_144, 1_048_576, 4_194_304, 16_777_216] {
            var output = [UInt8](repeating: 0, count: capacity)
            let size = data.withUnsafeBytes { source in
                guard let address = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    &output, capacity, address, data.count, nil, COMPRESSION_ZLIB)
            }
            if size > 0 && size < capacity {
                let decoded = Data(output.prefix(size))
                if wasBase64 { return decoded.base64EncodedString() }
                guard let text = String(data: decoded, encoding: .utf8) else {
                    throw ObsidianBasketError.message(
                        String(localized: .invalidChunkUTF8)
                    )
                }
                return text
            }
        }
        throw ObsidianBasketError.message(
            String(localized: .chunkDecompressionFailed)
        )
    }
}
