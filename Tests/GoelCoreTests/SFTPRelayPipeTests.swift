import XCTest
@testable import GoelCore

final class SFTPRelayPipeTests: XCTestCase {

    private func drain(_ pipe: SFTPRelayPipe, chunk: Int = 4096) -> [UInt8] {
        var out: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: chunk)
        while true {
            let n = buffer.withUnsafeMutableBytes { raw in pipe.read(into: raw) }
            if n <= 0 { break }
            out.append(contentsOf: buffer[0..<n])
        }
        return out
    }

    private func write(_ pipe: SFTPRelayPipe, _ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { pipe.write($0) }
    }

    func testBytesArriveInOrderAcrossChunkBoundaries() {
        let pipe = SFTPRelayPipe(capacity: 64 * 1024)
        let payload = (0..<10_000).map { UInt8($0 % 251) }

        let producer = Thread {
            var offset = 0
            let sizes = [1, 7, 999, 3, 4096, 512]
            var i = 0
            while offset < payload.count {
                let size = min(sizes[i % sizes.count], payload.count - offset)
                _ = payload[offset..<(offset + size)].withUnsafeBytes { pipe.write($0) }
                offset += size
                i += 1
            }
            pipe.finish()
        }
        producer.start()

        XCTAssertEqual(drain(pipe, chunk: 333), payload)
    }

    func testWriterBlocksWhileTheBufferIsFull() {
        let pipe = SFTPRelayPipe(capacity: 64 * 1024)
        let unblocked = XCTestExpectation(description: "writer completed")
        let secondWriteReturned = Flag()
        let payload = [UInt8](repeating: 0xAB, count: 200 * 1024)

        Thread {
            _ = payload.withUnsafeBytes { pipe.write($0) }
            _ = payload.withUnsafeBytes { pipe.write($0) }
            secondWriteReturned.set()
            pipe.finish()
            unblocked.fulfill()
        }.start()

        // Sampled, not waited on: an expectation may only be waited on once, and it is needed below.
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(secondWriteReturned.isSet,
                       "the writer should still be parked on a full pipe")

        XCTAssertEqual(drain(pipe).count, payload.count * 2)
        wait(for: [unblocked], timeout: 2)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testFailureWakesABlockedWriter() {
        let pipe = SFTPRelayPipe(capacity: 64 * 1024)
        let refused = XCTestExpectation(description: "write refused")
        let payload = [UInt8](repeating: 1, count: 200 * 1024)

        Thread {
            _ = payload.withUnsafeBytes { pipe.write($0) }
            let accepted = payload.withUnsafeBytes { pipe.write($0) }
            XCTAssertFalse(accepted)
            refused.fulfill()
        }.start()

        Thread.sleep(forTimeInterval: 0.05)
        pipe.fail("destination went away")
        wait(for: [refused], timeout: 2)
        XCTAssertEqual(pipe.failureReason, "destination went away")
    }

    func testFailureWakesABlockedReaderWithAnError() {
        let pipe = SFTPRelayPipe()
        let errored = XCTestExpectation(description: "read reported failure")

        Thread {
            var buffer = [UInt8](repeating: 0, count: 1024)
            let n = buffer.withUnsafeMutableBytes { pipe.read(into: $0) }
            XCTAssertEqual(n, -1, "a failed copy must not look like a clean EOF")
            errored.fulfill()
        }.start()

        Thread.sleep(forTimeInterval: 0.05)
        pipe.fail("source went away")
        wait(for: [errored], timeout: 2)
    }

    func testCleanFinishReadsAsEndOfStreamNotFailure() {
        let pipe = SFTPRelayPipe()
        XCTAssertTrue(write(pipe, [1, 2, 3]))
        pipe.finish()
        XCTAssertEqual(drain(pipe), [1, 2, 3])
        XCTAssertNil(pipe.failureReason)
    }

    func testFirstFailureReasonIsTheOneReported() {
        let pipe = SFTPRelayPipe()
        pipe.fail("first")
        pipe.fail("second")
        XCTAssertEqual(pipe.failureReason, "first")
    }
}
