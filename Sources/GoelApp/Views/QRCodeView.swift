import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import Darwin

/// A crisp (nearest-neighbour scaled) QR code for short setup strings — used by
/// the Remote Access pane so a phone can join by pointing its camera.
struct QRCodeView: View {
    let text: String
    var side: CGFloat = 116

    var body: some View {
        if let image = Self.image(for: text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: side, height: side)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
        }
    }

    static func image(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// This Mac's primary LAN IPv4 address, for building the URL other devices use.
enum LANAddress {

    /// Prefers `en0` (the built-in Wi-Fi/Ethernet), falling back to the first
    /// non-loopback IPv4 interface that is up.
    static func primaryIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var fallback: String?
        var pointer = list
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let interface = current.pointee
            guard let sa = interface.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET),
                  (interface.ifa_flags & UInt32(IFF_UP)) != 0,
                  (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: interface.ifa_name)
            let address = String(cString: host)
            if name == "en0" { return address }
            if fallback == nil { fallback = address }
        }
        return fallback
    }
}
