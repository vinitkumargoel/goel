import Foundation

extension HTTPEngine {

    struct ProbeResult {
        var totalBytes: Int64?
        var acceptsRanges: Bool
        var etag: String?
        var lastModified: String?
        var suggestedName: String?
        var contentType: String?
        var server: String?
        var digest: Checksum?
    }

    public func resolveMetadata(for url: URL, currentName: String)
        async -> (name: String, totalBytes: Int64?, reachable: Bool, checksum: Checksum?) {
        guard let result = try? await probe(url) else {
            return (currentName, nil, false, nil)
        }
        let refined = Self.refinedName(current: currentName,
                                       suggestedName: result.suggestedName,
                                       contentType: result.contentType)
        let checksum: Checksum?
        if let fromHeader = result.digest {
            checksum = fromHeader
        } else {
            checksum = await sidecarChecksum(for: url)
        }
        return (refined ?? currentName, result.totalBytes, true, checksum)
    }

    /// Plain path URLs only: appending `.sha256` to a signed or query-bearing URL would corrupt the token.
    private func sidecarChecksum(for url: URL) async -> Checksum? {
        guard url.query == nil,
              !url.lastPathComponent.isEmpty,
              let sidecar = URL(string: url.absoluteString + ".sha256") else { return nil }
        var request = makeRequest(sidecar, userAgent: networkConfig.userAgent)
        request.timeoutInterval = 5
        guard let (data, resp) = try? await session.data(for: request),
              let http = resp as? HTTPURLResponse,
              http.statusCode == 200,
              data.count <= 4096,
              let body = String(data: data, encoding: .utf8) else { return nil }
        return Self.checksum(inSidecarBody: body)
    }

    static func checksum(inSidecarBody body: String) -> Checksum? {
        for token in body.split(whereSeparator: { $0.isWhitespace }).prefix(8) {
            if let parsed = Checksum.parse(String(token)) { return parsed }
        }
        return nil
    }

    static func checksum(fromHeaders http: HTTPURLResponse) -> Checksum? {
        for name in ["Repr-Digest", "Digest"] {
            guard let raw = http.value(forHTTPHeaderField: name) else { continue }
            for entry in raw.split(separator: ",") {
                let parts = entry.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let algoName = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let algorithm: ChecksumAlgorithm?
                switch algoName {
                case "sha-256": algorithm = .sha256
                case "sha", "sha-1": algorithm = .sha1
                case "md5": algorithm = .md5
                default: algorithm = nil
                }
                guard let algorithm,
                      let checksum = Self.checksum(fromBase64Field: String(parts[1]),
                                                   algorithm: algorithm) else { continue }
                return checksum
            }
        }
        if let contentMD5 = http.value(forHTTPHeaderField: "Content-MD5") {
            return Self.checksum(fromBase64Field: contentMD5, algorithm: .md5)
        }
        return nil
    }

    /// RFC 9530 wraps the base64 in `:…:` byte-sequence colons; they must be stripped before decoding.
    private static func checksum(fromBase64Field field: String, algorithm: ChecksumAlgorithm)
        -> Checksum? {
        var value = field.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix(":") && value.hasSuffix(":") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        guard let data = Data(base64Encoded: value),
              data.count * 2 == algorithm.hexLength else { return nil }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        return Checksum(algorithm: algorithm, value: hex)
    }

    func probe(_ url: URL, referer: String? = nil,
               extraHeaders: [String: String] = [:]) async throws -> ProbeResult {
        var head = makeRequest(url, userAgent: networkConfig.userAgent,
                               referer: referer, extraHeaders: extraHeaders)
        head.httpMethod = "HEAD"
        if let (_, resp) = try? await session.data(for: head),
           let http = resp as? HTTPURLResponse,
           (200..<300).contains(http.statusCode) {
            let r = interpretHead(http)
            // Short-circuit only when HEAD proved range support: many servers emit `Accept-Ranges` on GET only, and returning early there drops us to one connection.
            if r.acceptsRanges { return r }
        }

        // Must stream, not `session.data(for:)`: a server ignoring `Range` returns the whole body → OOM.
        var get = makeRequest(url, userAgent: networkConfig.userAgent,
                              referer: referer, extraHeaders: extraHeaders)
        get.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (http, _, streamer) = try await SegmentedTransfer.openStream(
            session: session, request: get) { _ in }
        // Stop before the body streams, or an unranged 200 pulls the whole file into memory.
        streamer.cancelTask()
        guard (200..<300).contains(http.statusCode) else {
            throw DownloadError.httpStatus(http.statusCode)
        }
        return interpretRangedGet(http)
    }

    /// Reject negatives: a hostile `-1` traps the `UInt64(size)` conversion in ``SegmentedTransfer/preallocate``.
    private static func declaredSize(_ raw: String?) -> Int64? {
        guard let value = raw.flatMap({ Int64($0) }), value >= 0 else { return nil }
        return value
    }

    private func interpretHead(_ http: HTTPURLResponse) -> ProbeResult {
        let acceptsRanges = (header(http, "Accept-Ranges")?.lowercased() == "bytes")
        let length = Self.declaredSize(header(http, "Content-Length"))
        return ProbeResult(
            totalBytes: length,
            acceptsRanges: acceptsRanges && length != nil,
            etag: header(http, "ETag"),
            lastModified: header(http, "Last-Modified"),
            suggestedName: Self.filename(fromContentDisposition: header(http, "Content-Disposition")),
            contentType: header(http, "Content-Type"),
            server: header(http, "Server"),
            digest: Self.checksum(fromHeaders: http)
        )
    }

    private func interpretRangedGet(_ http: HTTPURLResponse) -> ProbeResult {
        let etag = header(http, "ETag")
        let lastModified = header(http, "Last-Modified")
        let suggestedName = Self.filename(fromContentDisposition: header(http, "Content-Disposition"))
        let contentType = header(http, "Content-Type")

        if http.statusCode == 206 {
            let total = Self.declaredSize(header(http, "Content-Range")
                .flatMap { $0.split(separator: "/").last }
                .map(String.init))
            return ProbeResult(totalBytes: total, acceptsRanges: total != nil, etag: etag,
                               lastModified: lastModified, suggestedName: suggestedName,
                               contentType: contentType, server: header(http, "Server"),
                               digest: Self.checksum(fromHeaders: http))
        }

        let length = Self.declaredSize(header(http, "Content-Length"))
        return ProbeResult(totalBytes: length, acceptsRanges: false, etag: etag,
                           lastModified: lastModified, suggestedName: suggestedName,
                           contentType: contentType, server: header(http, "Server"),
                           digest: Self.checksum(fromHeaders: http))
    }

    private func header(_ http: HTTPURLResponse, _ name: String) -> String? {
        http.value(forHTTPHeaderField: name)
    }
}
