import Foundation

/// `/api/bandwidth` and `/api/add-torrent`. Read-only mode, auth and the Origin check are applied by
/// ``RemoteRouter/handle(_:sessionAuthed:fromTrustedProxy:)`` before either handler runs.
extension RemoteRouter {

    static func getBandwidth(_ backend: RemoteBackend) async -> Data {
        guard let state = await backend.bandwidthState() else {
            return notFound("This server has no speed limiter.")
        }
        return json(state)
    }

    static func postBandwidth(_ request: RemoteRequest, backend: RemoteBackend) async -> Data {
        guard let update = try? JSONDecoder().decode(RemoteBandwidthUpdate.self, from: request.body)
        else { return badRequest() }
        guard let state = await backend.bandwidthState() else {
            return notFound("This server has no speed limiter.")
        }
        if let problem = update.problem(against: state) { return badRequest(problem) }
        if update.lockedChange(against: state) != nil {
            return forbidden("That setting is managed by your organisation and can’t be changed.")
        }
        guard let updated = await backend.updateBandwidth(update) else {
            return notFound("This server has no speed limiter.")
        }
        return json(updated)
    }

    struct TorrentUploadRow: Encodable {
        struct FileError: Encodable, Equatable {
            var file: String
            var error: String
        }
        var added: Int
        var refused: Int
        var ids: [String]
        var errors: [FileError]
    }

    static func addTorrents(_ request: RemoteRequest, backend: RemoteBackend) async -> Data {
        guard request.body.count <= RemoteTorrentUpload.maxTotalBytes + RemoteTorrentUpload.framingAllowance
        else { return payloadTooLarge() }
        let parts: [MultipartFormData.Part]
        do {
            let boundary = try MultipartFormData.boundary(fromContentType: request.headers["content-type"])
            // Files plus a few text fields; anything past that is not a browser form.
            parts = try MultipartFormData.parse(request.body, boundary: boundary,
                                                maxParts: RemoteTorrentUpload.maxFiles + 8)
        } catch MultipartFormData.ParseError.notMultipart {
            return badRequest("Send the .torrent files as multipart/form-data.")
        } catch MultipartFormData.ParseError.tooManyParts {
            return badRequest("At most \(RemoteTorrentUpload.maxFiles) .torrent files per upload.")
        } catch {
            return badRequest("The upload is malformed.")
        }

        let files = parts.filter { $0.name == "file" }
        guard !files.isEmpty else { return badRequest("No .torrent file in the upload.") }
        guard files.count <= RemoteTorrentUpload.maxFiles else {
            return badRequest("At most \(RemoteTorrentUpload.maxFiles) .torrent files per upload.")
        }
        guard files.reduce(0, { $0 + $1.body.count }) <= RemoteTorrentUpload.maxTotalBytes else {
            return payloadTooLarge()
        }

        func text(_ name: String) -> String? {
            parts.first { $0.name == name && $0.filename == nil }
                .flatMap { String(data: $0.body, encoding: .utf8) }
        }
        // `dir` per the portal contract; `folder` matches `/api/add`'s JSON field.
        let folder = (text("dir") ?? text("folder"))?.trimmingCharacters(in: .whitespaces)
        let saveDirectory = (folder?.isEmpty == false) ? folder : nil
        if let saveDirectory, await backend.remoteSaveDirectoryAllowed(saveDirectory) == false {
            return forbidden(saveFolderRefusal)
        }
        let priority = Self.priority(text("priority"))
        let paused = truthy(text("paused"))
        // As `/api/add`: a malformed spec is refused, not silently downgraded to `auto`.
        var network: NetworkSelection?
        if let raw = text("network")?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            guard let parsed = NetworkSelection(spec: raw) else {
                return badRequest("Unknown network choice.")
            }
            network = parsed
        }
        let sequential = truthy(text("sequential"))
        var startAt: Double?
        if let raw = text("startAt")?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            guard startDate(raw) != nil, let seconds = Double(raw) else { return badRequest(startRefusal) }
            startAt = seconds
        }

        var ids: [String] = []
        var added = 0
        var errors: [TorrentUploadRow.FileError] = []
        for part in files {
            let name = RemoteTorrentUpload.displayName(part.filename)
            let label = name + ".torrent"
            guard part.body.count <= RemoteTorrentUpload.maxFileBytes else {
                errors.append(.init(file: label, error: "Larger than 10 MB — not a .torrent file."))
                continue
            }
            guard RemoteTorrentUpload.looksBencoded(part.body) else {
                errors.append(.init(file: label, error: "Not a .torrent file."))
                continue
            }
            do {
                let id = try await backend.remoteAddTorrent(part.body, named: name,
                                                            saveDirectory: saveDirectory,
                                                            priority: priority, startPaused: paused,
                                                            network: network)
                added += 1
                if let id { ids.append(id.uuidString) }
            } catch let failure as RemoteTorrentUpload.Failure {
                errors.append(.init(file: label, error: failure.message))
            } catch {
                errors.append(.init(file: label, error: RemoteTorrentUpload.Failure.couldNotSave.message))
            }
        }
        await applyAddExtras(ids, sequential: sequential, startAt: startAt, backend: backend)
        let row = TorrentUploadRow(added: added, refused: errors.count, ids: ids, errors: errors)
        guard added > 0 else {
            // Still the JSON envelope, so the portal can name each file that failed.
            guard let body = try? JSONEncoder().encode(row) else { return badRequest() }
            return response(status: "400 Bad Request", type: "application/json", body: body)
        }
        return json(row)
    }

    static func payloadTooLarge() -> Data {
        response(status: "413 Payload Too Large", type: "text/plain",
                 body: Data("Too large: each .torrent may be up to 10 MB, 25 MB per upload.\n".utf8))
    }

    static let saveFolderRefusal = "That save folder cannot be used — it does not exist, is not a folder, this user has no permission for it, or it is a protected system, hidden or Library folder."
}

extension RemoteRequest {
    /// The buffering ceiling for a request whose header block is `header`. Only an upload to
    /// ``RemoteTorrentUpload/path`` that declares a multipart body may exceed the general 2 MB;
    /// the route itself still enforces the per-file and total limits.
    static func maxRequestBytes(header: Data) -> Int {
        isTorrentUpload(header: header) ? RemoteTorrentUpload.maxRequestBytes : generalMaxRequestBytes
    }

    static let generalMaxRequestBytes = 2 * 1024 * 1024

    static func isTorrentUpload(header: Data) -> Bool {
        let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
        let fields = lines.first?.split(separator: " ") ?? []
        guard fields.count >= 2, fields[0] == "POST",
              fields[1].split(separator: "?", maxSplits: 1).first == Substring(RemoteTorrentUpload.path)
        else { return false }
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-type"
            else { continue }
            return kv[1].trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("multipart/form-data")
        }
        return false
    }

    /// Whether `buffer` has outgrown what this connection may buffer. Before the header block is
    /// complete only the general ceiling applies; after, the route's.
    static func exceedsLimit(_ buffer: Data) -> Bool {
        var reader = RemoteRequestReader()
        return reader.append(buffer) == .reject
    }
}

/// Accumulates one request off the socket. The header block's decisions (upload or not, the ceiling, the
/// declared length) are made once, when it completes, and the buffer is appended in place: a 25 MB upload
/// re-copied or re-parsed per 64 KB chunk is quadratic work any unauthenticated client can ask for.
struct RemoteRequestReader {
    enum Step: Equatable {
        /// More bytes are needed.
        case needMore
        /// `buffer` holds the whole request.
        case complete
        /// Over a ceiling, or a header block too large: drop the connection.
        case reject
    }

    private(set) var buffer = Data()
    /// Offset of the body once the header block is in.
    private(set) var bodyStart: Int?
    /// Whether the header block declares a multipart upload to ``RemoteTorrentUpload/path``.
    private(set) var isTorrentUpload = false
    private var limit = RemoteRequest.generalMaxRequestBytes
    private var declaredBody = 0

    mutating func append(_ chunk: Data) -> Step {
        buffer.append(chunk)
        guard let start = bodyStart ?? locateHeaderEnd() else {
            return buffer.count > RemoteRequest.generalMaxRequestBytes || RemoteRequest.headerTooLarge(buffer)
                ? .reject : .needMore
        }
        // A declared length past the limit is refused now, not after buffering it.
        if declaredBody > limit - start || buffer.count > limit { return .reject }
        return buffer.count - start < declaredBody ? .needMore : .complete
    }

    private mutating func locateHeaderEnd() -> Int? {
        guard let end = RemoteRequest.headerEnd(buffer) else { return nil }
        let header = buffer.prefix(end)
        bodyStart = end
        isTorrentUpload = RemoteRequest.isTorrentUpload(header: header)
        limit = isTorrentUpload ? RemoteTorrentUpload.maxRequestBytes : RemoteRequest.generalMaxRequestBytes
        declaredBody = RemoteRequest.contentLength(header)
        return end
    }
}
