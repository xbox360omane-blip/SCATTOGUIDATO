import Foundation
import CoreImage
import UIKit
import Vision
import simd

/// Suggerimento di allineamento calcolato sul telefono, circa 3 volte al secondo.
struct AlignHint: Equatable {
    var dx: Double = 0      // >0: il soggetto obiettivo è a destra del centro
    var dy: Double = 0      // >0: il soggetto obiettivo è sotto il centro
    var scale: Double = 1   // <1: l'obiettivo appare più piccolo, bisogna avvicinarsi
    var valid = false

    static let none = AlignHint()

    var isAligned: Bool {
        valid && abs(dx) < 0.05 && abs(dy) < 0.05 && abs(scale - 1) < 0.1
    }

    var instructions: [(String, String)] {
        guard valid else { return [] }
        var out: [(String, String)] = []
        if dx > 0.05 { out.append(("→", "Gira a destra")) }
        if dx < -0.05 { out.append(("←", "Gira a sinistra")) }
        if dy > 0.05 { out.append(("↓", "Inclina in giù")) }
        if dy < -0.05 { out.append(("↑", "Inclina in su")) }
        if scale < 0.9 { out.append(("⤢", "Avvicinati")) }
        if scale > 1.1 { out.append(("⤡", "Allontanati")) }
        return out
    }

    /// Se le frecce verticali risultassero invertite sul tuo dispositivo, metti false.
    static let visionOriginBottomLeft = true

    static func from(_ m: simd_float3x3, targetSize: CGSize, liveSize: CGSize) -> AlignHint {
        let c = m * SIMD3<Float>(Float(targetSize.width / 2), Float(targetSize.height / 2), 1)
        guard abs(c.z) > 1e-6 else { return .none }
        let mx = Double(c.x / c.z), my = Double(c.y / c.z)
        let lw = Double(liveSize.width), lh = Double(liveSize.height)
        let dx = (mx - lw / 2) / lw
        var dy = (my - lh / 2) / lh
        if visionOriginBottomLeft { dy = -dy }
        let det = Double(m.columns.0.x * m.columns.1.y - m.columns.1.x * m.columns.0.y)
        let scale = sqrt(abs(det)) / Double(abs(c.z))
        let ok = scale > 0.25 && scale < 4 && abs(dx) < 1 && abs(dy) < 1
        return AlignHint(dx: dx, dy: dy, scale: scale, valid: ok)
    }
}

/// Confronta il mirino con l'inquadratura obiettivo: somiglianza e direzione in cui muoversi.
final class AlignmentTracker: ObservableObject {
    @Published var similarity: Double = 0
    @Published var hint: AlignHint = .none

    private let queue = DispatchQueue(label: "scatto.align")
    private let ciContext = CIContext()
    private let stateLock = NSLock()
    private var targetCG: CGImage?
    private var targetPrint: VNFeaturePrintObservation?
    private var targetAspect: CGFloat = 3.0 / 4.0
    private var lastRun = Date.distantPast
    private var running = false

    func setTarget(_ image: UIImage?) {
        queue.async {
            guard let image, let cg = image.resized(maxSide: 480).cgImage else {
                self.stateLock.lock()
                self.targetCG = nil
                self.targetPrint = nil
                self.stateLock.unlock()
                DispatchQueue.main.async { self.similarity = 0; self.hint = .none }
                return
            }
            let print = Self.featurePrint(cg)
            self.stateLock.lock()
            self.targetCG = cg
            self.targetPrint = print
            self.targetAspect = CGFloat(cg.width) / CGFloat(max(cg.height, 1))
            self.stateLock.unlock()
        }
    }

    /// Chiamato dalla coda video.
    func process(_ buffer: CVPixelBuffer) {
        stateLock.lock()
        let hasTarget = targetCG != nil
        let busy = running
        let aspect = targetAspect
        stateLock.unlock()
        guard hasTarget, !busy, Date().timeIntervalSince(lastRun) > 0.33 else { return }
        lastRun = Date()

        // ritaglio centrale con le proporzioni dell'obiettivo, ridotto a 480 px
        var ci = CIImage(cvPixelBuffer: buffer)
        let W = ci.extent.width, H = ci.extent.height
        var w = W, h = W / aspect
        if h > H { h = H; w = H * aspect }
        ci = ci.cropped(to: CGRect(x: (W - w) / 2, y: (H - h) / 2, width: w, height: h))
        let k = 480 / max(w, h)
        ci = ci.transformed(by: CGAffineTransform(scaleX: k, y: k))
        guard let live = ciContext.createCGImage(ci, from: ci.extent) else { return }

        stateLock.lock(); running = true; stateLock.unlock()
        queue.async {
            defer { self.stateLock.lock(); self.running = false; self.stateLock.unlock() }
            self.stateLock.lock()
            let target = self.targetCG
            let tPrint = self.targetPrint
            self.stateLock.unlock()
            guard let target else { return }

            var sim = 0.0
            if let tPrint, let lPrint = Self.featurePrint(live) {
                var d: Float = 0
                if (try? lPrint.computeDistance(&d, to: tPrint)) != nil {
                    sim = max(0, min(1, 1 - Double(d) / 1.1))
                }
            }

            var hint = AlignHint.none
            let req = VNHomographicImageRegistrationRequest(targetedCGImage: target, options: [:])
            let handler = VNImageRequestHandler(cgImage: live, options: [:])
            if (try? handler.perform([req])) != nil,
               let obs = req.results?.first as? VNImageHomographicAlignmentObservation {
                hint = AlignHint.from(obs.warpTransform,
                                      targetSize: CGSize(width: target.width, height: target.height),
                                      liveSize: CGSize(width: live.width, height: live.height))
            }
            if sim < 0.3 { hint.valid = false }   // scena troppo diversa: niente frecce

            DispatchQueue.main.async {
                self.similarity = sim
                self.hint = hint
            }
        }
    }

    private static func featurePrint(_ cg: CGImage) -> VNFeaturePrintObservation? {
        let req = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? handler.perform([req])) != nil else { return nil }
        return req.results?.first as? VNFeaturePrintObservation
    }
}
