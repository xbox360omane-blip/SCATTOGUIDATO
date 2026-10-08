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

    /// Intensità predefinita delle correzioni (0 = nessuna, 1 = piena).
    static let defaultStrength = 0.5

    /// Sviluppo leggero e naturale con Core Image.
    /// I valori dell'AI vengono ridotti e limitati: anche al 100% le correzioni restano contenute.
    static func develop(_ image: UIImage, with d: SceneAnalysis.Develop, strength: Double = defaultStrength) -> UIImage {
        let s = clamp(strength, 0, 1)
        guard s > 0.001, let cg = image.normalizedUp().cgImage else { return image }
        var ci = CIImage(cgImage: cg)
        let extent = ci.extent

        // esposizione: al massimo ±0,6 stop
        let ev = clamp(d.exposure, -1, 1) * 0.6 * s
        if abs(ev) > 0.01, let f = CIFilter(name: "CIExposureAdjust") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(ev, forKey: kCIInputEVKey)
            ci = f.outputImage ?? ci
        }
        // ombre (solo schiarite) e recupero alte luci, moderati
        let sh = clamp(d.shadows, 0, 1) * 0.45 * s
        let hi = 1 - clamp(-d.highlights, 0, 1) * 0.35 * s
        if sh > 0.01 || hi < 0.99, let f = CIFilter(name: "CIHighlightShadowAdjust") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(sh, forKey: "inputShadowAmount")
            f.setValue(hi, forKey: "inputHighlightAmount")
            ci = f.outputImage ?? ci
        }
        // temperatura: al massimo ±600 K
        let dk = clamp(d.warmth, -1, 1) * 600 * s
        if abs(dk) > 20, let f = CIFilter(name: "CITemperatureAndTint") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(CIVector(x: 6500 + CGFloat(dk), y: 0), forKey: "inputNeutral")
            f.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
            ci = f.outputImage ?? ci
        }
        // contrasto leggero
        let con = 1 + clamp(d.contrast, -0.5, 0.5) * 0.25 * s
        if abs(con - 1) > 0.005, let f = CIFilter(name: "CIColorControls") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(con, forKey: kCIInputContrastKey)
            f.setValue(1, forKey: kCIInputSaturationKey)
            f.setValue(0, forKey: kCIInputBrightnessKey)
            ci = f.outputImage ?? ci
        }
        // colore: vibranza (protegge pelle e colori già saturi) invece della saturazione
        let vib = clamp(d.saturation, -0.5, 0.5) * 0.5 * s
        if abs(vib) > 0.01, let f = CIFilter(name: "CIVibrance") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(vib, forKey: "inputAmount")
            ci = f.outputImage ?? ci
        }
        guard let out = context.createCGImage(ci.cropped(to: extent), from: extent) else { return image }
        return UIImage(cgImage: out)
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
}
