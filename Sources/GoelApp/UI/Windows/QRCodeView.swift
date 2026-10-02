import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import Darwin
import GoelCore

/// A QR code for a URL (`.qr`). The modules are always ink-on-card from the *light* palette, in
/// both appearances: phone cameras read dark-on-light far more reliably than the inverse.
struct QRCodeView: View {
    let text: String
    var side: CGFloat = 116

    var body: some View {
        if let image = Self.image(for: text) {
            let shape = RoundedRectangle(cornerRadius: Studio.Radius.tile, style: .continuous)
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .padding(side * 0.06)
                .frame(width: side, height: side)
                .background(shape.fill(Color(nsColor: Studio.Tones.card.light.nsColor)))
                .overlay(shape.strokeBorder(Studio.Palette.hairline, lineWidth: 1))
                .accessibilityLabel(L10n.t("QR code for %@", text))
        }
    }

    static func image(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let modules = filter.outputImage else { return nil }
        let tinted = CIFilter.falseColor()
        tinted.inputImage = modules
        tinted.color0 = CIColor(color: Studio.Tones.ink.light.nsColor) ?? CIColor.black
        tinted.color1 = CIColor(color: Studio.Tones.card.light.nsColor) ?? CIColor.white
        let output = tinted.outputImage ?? modules
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// This Mac's LAN address, for the Web Access pane's phone link.
enum LANAddress {

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
