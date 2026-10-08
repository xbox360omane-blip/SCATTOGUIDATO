import UIKit
import CoreImage

extension UIImage {
    /// Ridisegna l'immagine con orientamento .up e scala 1 (pixel = punti).
    func normalizedUp() -> UIImage {
        if imageOrientation == .up && scale == 1 { return self }
        let px = CGSize(width: size.width * scale, height: size.height * scale)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: px, format: fmt).image { _ in
            draw(in: CGRect(origin: .zero, size: px))
        }
    }

    func resized(maxSide: CGFloat) -> UIImage {
        let px = CGSize(width: size.width * scale, height: size.height * scale)
        let k = min(1, maxSide / max(px.width, px.height))
        let out = CGSize(width: (px.width * k).rounded(), height: (px.height * k).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: out, format: fmt).image { _ in
            draw(in: CGRect(origin: .zero, size: out))
        }
    }

    func jpegBase64(maxSide: CGFloat) -> String? {
        resized(maxSide: maxSide).jpegData(compressionQuality: 0.82)?.base64EncodedString()
    }
}

enum ImageTools {
    static let context = CIContext()

    /// Applica ritaglio e rotazione suggeriti dall'AI: è l'inquadratura obiettivo (la "sagoma").
    static func idealFrame(from image: UIImage, analysis a: SceneAnalysis) -> UIImage {
        let img = image.normalizedUp()
        let W = img.size.width, H = img.size.height
        let c = a.safeCrop
        let rot = CGFloat(a.rotate) * .pi / 180
        var w = CGFloat(c.w) * W
        var h = CGFloat(c.h) * H
        if rot != 0 {
            // rimpicciolisce il riquadro perché, ruotato, resti dentro la foto
            let k = min(1, 1 / (abs(cos(rot)) + abs(sin(rot)) * max(w / h, h / w)))
            w *= k
            h *= k
        }
        let cx = CGFloat(c.x + c.w / 2) * W
        let cy = CGFloat(c.y + c.h / 2) * H
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let size = CGSize(width: max(1, w.rounded()), height: max(1, h.rounded()))
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let g = ctx.cgContext
            g.translateBy(x: size.width / 2, y: size.height / 2)
            g.rotate(by: rot)
            img.draw(at: CGPoint(x: -cx, y: -cy))
        }
    }

    /// Ritaglio centrale con le proporzioni dell'inquadratura obiettivo.
    static func centerCrop(_ image: UIImage, aspect: CGFloat) -> UIImage {
        let img = image.normalizedUp()
        guard let cg = img.cgImage else { return img }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        var w = W, h = W / aspect
        if h > H { h = H; w = H * aspect }
        let rect = CGRect(x: ((W - w) / 2).rounded(), y: ((H - h) / 2).rounded(), width: w.rounded(), height: h.rounded())
        guard let cut = cg.cropping(to: rect) else { return img }
        return UIImage(cgImage: cut)
    }

    /// Sviluppo con Core Image secondo i valori dell'AI.
    static func develop(_ image: UIImage, with d: SceneAnalysis.Develop) -> UIImage {
        guard let cg = image.normalizedUp().cgImage else { return image }
        var ci = CIImage(cgImage: cg)
        let extent = ci.extent

        if d.exposure != 0, let f = CIFilter(name: "CIExposureAdjust") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(clamp(d.exposure, -1.5, 1.5), forKey: kCIInputEVKey)
            ci = f.outputImage ?? ci
        }
        if d.shadows != 0 || d.highlights < 0, let f = CIFilter(name: "CIHighlightShadowAdjust") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(clamp(d.shadows, -1, 1) * 0.8, forKey: "inputShadowAmount")
            f.setValue(clamp(1 + min(0, d.highlights) * 0.7, 0.3, 1), forKey: "inputHighlightAmount")
            ci = f.outputImage ?? ci
        }
        if d.warmth != 0, let f = CIFilter(name: "CITemperatureAndTint") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(CIVector(x: 6500 + CGFloat(clamp(d.warmth, -1, 1)) * 1500, y: 0), forKey: "inputNeutral")
            f.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
            ci = f.outputImage ?? ci
        }
        if d.contrast != 0 || d.saturation != 0, let f = CIFilter(name: "CIColorControls") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(1 + clamp(d.contrast, -0.6, 0.6) * 0.5, forKey: kCIInputContrastKey)
            f.setValue(1 + clamp(d.saturation, -0.6, 0.6), forKey: kCIInputSaturationKey)
            f.setValue(0, forKey: kCIInputBrightnessKey)
            ci = f.outputImage ?? ci
        }
        guard let out = context.createCGImage(ci.cropped(to: extent), from: extent) else { return image }
        return UIImage(cgImage: out)
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
}
