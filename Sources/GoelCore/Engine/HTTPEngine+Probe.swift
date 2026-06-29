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
    }

    /// Probe a URL for the add-confirmation preview: returns the best filename
    /// (Content-Disposition / inferred extension) and the total size, plus whether
    /// the server was reachable. Performs the same HEAD/ranged-GET probe a real
    /// download would, but writes nothing and creates no task.
    public func resolveMetadata(for url: URL, currentName: String)
        async -> (name: String, totalBytes: Int64?, reachable: Bool) {
        guard let result = try? await probe(url) else {
            return (currentName, nil, false)
        }
        let refined = Self.refinedName(current: currentName,
                                       suggestedName: result.suggestedName,
                                       contentType: result.contentType)
        return (refined ?? currentName, result.totalBytes, true)
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
            contentType: header(http, "Content-Type")
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
                               lastModified: lastModified, suggestedName: suggestedName, contentType: contentType)
        }

        // Server ignored the Range header and returned the whole body.
        let length = header(http, "Content-Length").flatMap { Int64($0) }
        return ProbeResult(totalBytes: length, acceptsRanges: false, etag: etag,
                           lastModified: lastModified, suggestedName: suggestedName, contentType: contentType)
    }

    private func header(_ http: HTTPURLResponse, _ name: String) -> String? {
        http.value(forHTTPHeaderField: name)
    }
}
