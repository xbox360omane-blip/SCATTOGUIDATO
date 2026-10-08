import Foundation
import CoreImage
import UIKit
import Vision
import simd

/// Suggerimento di allineamento calcolato sul telefono, circa 4 volte al secondo.
struct AlignHint: Equatable {
    var dx: Double = 0        // >0: l'obiettivo è a destra del centro
    var dy: Double = 0        // >0: l'obiettivo è sotto il centro
    var scale: Double = 1     // <1: l'obiettivo appare più piccolo, bisogna avvicinarsi
    var rotation: Double = 0  // gradi
    var valid = false

    static let none = AlignHint()

    // Tolleranze: entro queste soglie la differenza non si nota nella foto.
    static let posTolerance = 0.025     // 2,5% del riquadro
    static let scaleTolerance = 0.05    // 5% di dimensione
    static let rotTolerance = 2.0       // gradi
    static let hintThreshold = 0.03     // sotto questo valore non mostra la freccia

    /// Dentro le tolleranze in questo istante (la conferma finale richiede stabilità, vedi tracker).
    var withinTolerance: Bool {
        valid && abs(dx) < Self.posTolerance && abs(dy) < Self.posTolerance
            && abs(scale - 1) < Self.scaleTolerance && abs(rotation) < Self.rotTolerance
    }

    var instructions: [(String, String)] {
        guard valid else { return [] }
        var out: [(String, String)] = []
        if dx > Self.hintThreshold { out.append(("→", "Gira a destra")) }
        if dx < -Self.hintThreshold { out.append(("←", "Gira a sinistra")) }
        if dy > Self.hintThreshold { out.append(("↓", "Inclina in giù")) }
        if dy < -Self.hintThreshold { out.append(("↑", "Inclina in su")) }
        if scale < 1 - Self.scaleTolerance { out.append(("⤢", "Avvicinati")) }
        if scale > 1 + Self.scaleTolerance { out.append(("⤡", "Allontanati")) }
        if rotation > Self.rotTolerance { out.append(("↻", "Ruota in senso orario")) }
        if rotation < -Self.rotTolerance { out.append(("↺", "Ruota in senso antiorario")) }
        return out
    }

    /// Se le frecce verticali risultassero invertite sul tuo dispositivo, metti false.
    static let visionOriginBottomLeft = true
    /// Se la freccia di rotazione risultasse invertita, metti -1.
    static let rotationSign = 1.0

    static func from(_ m: simd_float3x3, targetSize: CGSize, liveSize: CGSize) -> AlignHint {
        let c = m * SIMD3<Float>(Float(targetSize.width / 2), Float(targetSize.height / 2), 1)
        guard abs(c.z) > 1e-6 else { return .none }
        let mx = Double(c.x / c.z), my = Double(c.y / c.z)
        let lw = Double(liveSize.width), lh = Double(liveSize.height)
        let dx = (mx - lw / 2) / lw
        var dy = (my - lh / 2) / lh
        if visionOriginBottomLeft { dy = -dy }
        let a = Double(m.columns.0.x), b = Double(m.columns.0.y)
        let cc = Double(m.columns.1.x), d = Double(m.columns.1.y)
        let scale = sqrt(abs(a * d - cc * b)) / Double(abs(c.z))
        var rot = atan2(b, a) * 180 / .pi * rotationSign
        if visionOriginBottomLeft { rot = -rot }
        let ok = scale > 0.25 && scale < 4 && abs(dx) < 1 && abs(dy) < 1 && abs(rot) < 45
        return AlignHint(dx: dx, dy: dy, scale: scale, rotation: rot, valid: ok)
    }

    /// Media mobile per togliere il tremolio delle misure.
    func smoothed(with prev: AlignHint, alpha: Double = 0.5) -> AlignHint {
        guard valid, prev.valid else { return self }
        return AlignHint(dx: prev.dx + (dx - prev.dx) * alpha,
                         dy: prev.dy + (dy - prev.dy) * alpha,
                         scale: prev.scale + (scale - prev.scale) * alpha,
                         rotation: prev.rotation + (rotation - prev.rotation) * alpha,
                         valid: true)
    }
}

/// Confronta il mirino con l'inquadratura obiettivo: somiglianza e direzione in cui muoversi.
final class AlignmentTracker: ObservableObject {
    @Published var similarity: Double = 0
    @Published var hint: AlignHint = .none
    /// Vero solo quando l'allineamento è dentro le tolleranze per almeno 3 misure di fila (~0,8 s).
    @Published var aligned = false

    /// Proporzioni dell'area visibile del mirino (impostate dalla schermata).
    var viewAspect: CGFloat {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _viewAspect }
        set { stateLock.lock(); _viewAspect = newValue; stateLock.unlock() }
    }

    private let queue = DispatchQueue(label: "scatto.align")
    private let ciContext = CIContext()
    private let stateLock = NSLock()
    private var _viewAspect: CGFloat = 9.0 / 19.5
    private var targetCG: CGImage?
    private var targetPrint: VNFeaturePrintObservation?
    private var targetAspect: CGFloat = 3.0 / 4.0
    private var lastRun = Date.distantPast
    private var running = false
    private var lastHint = AlignHint.none
    private var stableCount = 0

    func setTarget(_ image: UIImage?) {
        queue.async {
            self.lastHint = .none
            self.stableCount = 0
            guard let image, let cg = image.resized(maxSide: 480).cgImage else {
                self.stateLock.lock()
                self.targetCG = nil
                self.targetPrint = nil
                self.stateLock.unlock()
                DispatchQueue.main.async { self.similarity = 0; self.hint = .none; self.aligned = false }
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
        let va = _viewAspect
        stateLock.unlock()
        guard hasTarget, !busy, Date().timeIntervalSince(lastRun) > 0.25 else { return }
        lastRun = Date()

        // 1) porzione visibile sullo schermo, 2) riquadro dell'obiettivo al centro, ridotto a 480 px
        var ci = CIImage(cvPixelBuffer: buffer)
        let W = ci.extent.width, H = ci.extent.height
        var vw = W, vh = W / va
        if vh > H { vh = H; vw = H * va }
        var w = vw, h = vw / aspect
        if h > vh { h = vh; w = vh * aspect }
        ci = ci.cropped(to: CGRect(x: ci.extent.minX + (W - w) / 2, y: ci.extent.minY + (H - h) / 2, width: w, height: h))
        let k = 480 / max(w, h)
        ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
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
            hint = hint.smoothed(with: self.lastHint)
            self.lastHint = hint

            // conferma solo se stabile e con alta somiglianza
            if hint.withinTolerance && sim > 0.75 { self.stableCount += 1 } else { self.stableCount = 0 }
            let isAligned = self.stableCount >= 3

            DispatchQueue.main.async {
                self.similarity = sim
                self.hint = hint
                if self.aligned != isAligned { self.aligned = isAligned }
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
