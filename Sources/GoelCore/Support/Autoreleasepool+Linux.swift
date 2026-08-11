#if !canImport(ObjectiveC)
/// Linux has no Objective-C runtime and no autorelease pools; Foundation there no
/// longer ships the compatibility shim either. The SFTP engine wraps its libssh2
/// callbacks in `autoreleasepool` for Darwin's sake — on Linux the body just runs.
@discardableResult
@inlinable
func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}
#endif
