import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Opening a file to send it off this host is where a swap wins: the path was checked, then replaced
/// by a link before the open. So every check runs again on the open descriptor, not on the name.
enum RemoteServedFile {

    /// A plain file of at least `minimumSize` bytes (what was promised to the client) whose real path
    /// is inside `root`. The last component must not be a symlink; one earlier in the path is caught
    /// by the real-path check.
    static func open(_ path: String, within root: String, minimumSize: Int64) -> FileHandle? {
        #if canImport(Darwin)
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        #else
        let fd = Glibc.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        #endif
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              Int64(info.st_size) >= minimumSize,
              let real = realPath(of: fd), PathSafety.isContained(real, within: root) else {
            close(fd)
            GoelLog.remote.notice("Refused to serve a file that changed or left its folder", .path(path))
            return nil
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    static func open(_ plan: RemoteStreamService.StreamPlan) -> FileHandle? {
        open(plan.path, within: plan.root, minimumSize: plan.availableBytes)
    }

    /// Where the descriptor really points, whatever name opened it.
    static func realPath(of fd: Int32) -> String? {
        #if os(Linux)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink("/proc/self/fd/\(fd)", &buffer, Int(PATH_MAX))
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #else
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let status = buffer.withUnsafeMutableBytes { fcntl(fd, F_GETPATH, $0.baseAddress!) }
        guard status != -1 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        #endif
    }
}
