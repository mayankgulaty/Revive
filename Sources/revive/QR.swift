import AppKit
import CoreImage

/// QR codes for pairing a phone: printed in the terminal and shown in the menu-bar pairing window.
enum QR {
    /// Module grid (true = dark) with a 2-module quiet zone.
    static func matrix(_ text: String) -> [[Bool]]? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage,
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 255, count: w * h)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let pad = 2
        var grid = [[Bool]](repeating: [Bool](repeating: false, count: w + 2 * pad), count: h + 2 * pad)
        for y in 0..<h { for x in 0..<w { grid[y + pad][x + pad] = pixels[y * w + x] < 128 } }
        return grid
    }

    /// Two modules per character using half blocks, black on white so it scans in light and dark terminals.
    static func terminal(_ text: String) -> String? {
        guard let m = matrix(text) else { return nil }
        var out = ""
        for y in stride(from: 0, to: m.count, by: 2) {
            out += "    \u{1B}[30;47m"
            for x in 0..<m[y].count {
                let top = m[y][x], bottom = y + 1 < m.count ? m[y + 1][x] : false
                out += top && bottom ? "█" : top ? "▀" : bottom ? "▄" : " "
            }
            out += "\u{1B}[0m\n"
        }
        return out
    }

    static func image(_ text: String, size: CGFloat) -> NSImage? {
        guard let m = matrix(text) else { return nil }
        return NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            NSColor.white.setFill(); rect.fill()
            let cell = rect.width / CGFloat(m.count)
            NSColor.black.setFill()
            for (y, row) in m.enumerated() {
                for (x, dark) in row.enumerated() where dark {
                    NSRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell + 0.5, height: cell + 0.5).fill()
                }
            }
            return true
        }
    }
}
