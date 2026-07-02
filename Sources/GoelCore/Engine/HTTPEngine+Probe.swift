import Foundation

// MARK: - Range-support probe & metadata preview

/// Server probing: discovers total size, range support and validators (ETag /
/// Last-Modified) via a cheap HEAD then a one-byte ranged GET, and serves the
/// add-confirmation metadata preview. Split out of ``HTTPEngine`` so the transfer
/// driver isn't interleaved with header parsing.
extension HTTPEngine {

    struct ProbeResult {
        var totalBytes: Int64?
        var acceptsRanges: Bool
        var etag: String?
        var lastModified: String?
        /// Filename from the `Content-Disposition` header, if the server sent one.
        var suggestedName: String?
        /// `Content-Type` MIME, used to infer an extension when the name lacks one.
        var contentType: String?
        /// The `Server` response header, surfaced in the Details tab.
        var server: String?
        /// A checksum the server published via `Digest` / `Repr-Digest` /
        /// `Content-MD5`, decoded to the verifier's hex form.
        var digest: Checksum?
    }

    /// Probe a URL for the add-confirmation preview: returns the best filename
    /// (Content-Disposition / inferred extension) and the total size, plus whether
    /// the server was reachable. Performs the same HEAD/ranged-GET probe a real
    /// download would, but writes nothing and creates no task.
    public func resolveMetadata(for url: URL, currentName: String)
        async -> (name: String, totalBytes: Int64?, reachable: Bool, checksum: Checksum?) {
        guard let result = try? await probe(url) else {
            return (currentName, nil, false, nil)
        }
        let refined = Self.refinedName(current: currentName,
                                       suggestedName: result.suggestedName,
                                       contentType: result.contentType)
        // Header digest wins (it describes this exact representation); otherwise
        // look for a published `.sha256` sidecar next to the file.
        let checksum: Checksum?
        if let fromHeader = result.digest {
            checksum = fromHeader
        } else {
            checksum = await sidecarChecksum(for: url)
        }
        return (refined ?? currentName, result.totalBytes, true, checksum)
    }

    /// Fetch `<url>.sha256` — the conventional published-checksum sidecar — and
    /// parse the leading hex digest out of it. Only attempted for plain path
    /// URLs (a signed/query URL almost never has a sidecar, and appending to it
    /// would corrupt the token). Failures are silent: this is a bonus, not a step.
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

    /// The first token in a checksum-file body that parses as a known digest —
    /// handles both bare hashes and the `sha256sum` "<hex>  <filename>" layout.
    static func checksum(inSidecarBody body: String) -> Checksum? {
        for token in body.split(whereSeparator: { $0.isWhitespace }).prefix(8) {
            if let parsed = Checksum.parse(String(token)) { return parsed }
        }
        return nil
    }

    /// Decode a published integrity header into the verifier's hex ``Checksum``.
    /// Supports RFC 3230 `Digest: sha-256=<base64>`, RFC 9530 `Repr-Digest:
    /// sha-256=:<base64>:` (structured-field byte sequence), and `Content-MD5`.
    static func checksum(fromHeaders http: HTTPURLResponse) -> Checksum? {
        for name in ["Repr-Digest", "Digest"] {
            guard let raw = http.value(forHTTPHeaderField: name) else { continue }
            // A header may list several algorithms: "md5=…, sha-256=…".
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

    /// Decode a base64 digest field (optionally wrapped in RFC 9530's `:…:`
    /// byte-sequence colons) and render it as the hex string the verifier uses.
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

    func probe(_ url: URL) async throws -> ProbeResult {
        // Prefer a cheap HEAD.
        var head = makeRequest(url, userAgent: networkConfig.userAgent)
        head.httpMethod = "HEAD"
        if let (_, resp) = try? await session.data(for: head),
           let http = resp as? HTTPURLResponse,
           (200..<300).contains(http.statusCode) {
            let r = interpretHead(http)
            // Only short-circuit when HEAD has already PROVEN range support. Many
            // servers carry Content-Length but emit `Accept-Ranges` on GET only;
            // for those, fall through to the ranged GET so a real 206 can still
            // unlock segmentation instead of silently dropping to one connection.
            if r.acceptsRanges { return r }
        }

        // Fall back to a one-byte ranged GET, which reveals both range support
        // (a 206 + Content-Range) and the total size.
        var get = makeRequest(url, userAgent: networkConfig.userAgent)
        get.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, resp) = try await session.data(for: get)
        guard let http = resp as? HTTPURLResponse else {
            throw DownloadError.network("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DownloadError.httpStatus(http.statusCode)
        }
        return interpretRangedGet(http)
    }

    private func interpretHead(_ http: HTTPURLResponse) -> ProbeResult {
        let acceptsRanges = (header(http, "Accept-Ranges")?.lowercased() == "bytes")
        let length = header(http, "Content-Length").flatMap { Int64($0) }
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
            // "bytes 0-0/12345" -> 12345
            let total = header(http, "Content-Range")
                .flatMap { $0.split(separator: "/").last }
                .flatMap { Int64($0) }
            return ProbeResult(totalBytes: total, acceptsRanges: total != nil, etag: etag,
                               lastModified: lastModified, suggestedName: suggestedName,
                               contentType: contentType, server: header(http, "Server"),
                               digest: Self.checksum(fromHeaders: http))
        }

        // Server ignored the Range header and returned the whole body.
        let length = header(http, "Content-Length").flatMap { Int64($0) }
        return ProbeResult(totalBytes: length, acceptsRanges: false, etag: etag,
                           lastModified: lastModified, suggestedName: suggestedName,
                           contentType: contentType, server: header(http, "Server"),
                           digest: Self.checksum(fromHeaders: http))
    }

    private func header(_ http: HTTPURLResponse, _ name: String) -> String? {
        http.value(forHTTPHeaderField: name)
    }
}
