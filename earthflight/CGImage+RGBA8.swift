import CoreGraphics
import Foundation

extension CGImage {
    /// Tightly packed RGBA8 texels, top row first, as an image RealityKit can
    /// turn into a texture. Tiles, the sky and the stars all come this way.
    ///
    /// Through a `CGImage`, not `TextureResource`'s raw-contents initialiser:
    /// the raw path showed one white frame before every new texture on the M2
    /// Vision Pro, even after a completed GPU copy proved its pixels readable.
    ///
    /// The texels are sRGB, as glTF base colour is, and saying so is what makes
    /// RealityKit convert them to Display P3. Labelling them Display P3 skips
    /// that conversion and oversaturates every strong colour.
    nonisolated static func rgba8(
        _ texels: Data,
        width: Int,
        height: Int,
        alpha: CGImageAlphaInfo
    ) -> CGImage {
        precondition(
            width > 0 && height > 0 && texels.count == width * height * 4,
            "RGBA8 texels do not fill a \(width) x \(height) image"
        )
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: [.byteOrder32Big, CGBitmapInfo(rawValue: alpha.rawValue)],
            provider: CGDataProvider(data: texels as CFData)!,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
    }
}
