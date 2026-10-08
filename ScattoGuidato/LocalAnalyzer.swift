import UIKit
import Vision

/// Analisi della scena interamente sul telefono, senza AI esterna.
/// Usa Vision (volti, soggetto, orizzonte) e misura la luce dai pixel.
enum LocalAnalyzer {

    private struct LightStats {
        var mean = 0.5      // luminosità media 0-1
        var high = 0.0      // frazione di pixel quasi bianchi
        var low = 0.0       // frazione di pixel quasi neri
        var std = 0.2       // contrasto
        var warmBias = 0.0  // rosso - blu medio
    }

    static func analyze(_ image: UIImage) -> SceneAnalysis {
        let img = image.resized(maxSide: 1024)
        guard let cg = img.cgImage else { return SceneAnalysis() }
        let W = Double(cg.width), H = Double(cg.height)

        // --- Vision ---
        let faces = VNDetectFaceRectanglesRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        let horizon = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([faces, saliency, horizon])

        // riquadri Vision (origine in basso a sinistra) -> normalizzati con origine in alto a sinistra
        func topLeft(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
        }
        let faceBoxes = (faces.results ?? []).map { topLeft($0.boundingBox) }
        let salient = ((saliency.results?.first as? VNSaliencyImageObservation)?.salientObjects ?? []).map { topLeft($0.boundingBox) }
        let horizonAngle = Double((horizon.results?.first as? VNHorizonObservation)?.angle ?? 0) * 180 / .pi

        let isPortrait = !faceBoxes.isEmpty
        var subject: CGRect
        if isPortrait {
            // testa e spalle: allarga il volto
            let f = faceBoxes.dropFirst().reduce(faceBoxes[0]) { $0.union($1) }
            subject = CGRect(x: f.midX - f.width * 1.1, y: f.minY - f.height * 0.4,
                             width: f.width * 2.2, height: f.height * 2.6)
        } else if let first = salient.first {
            subject = salient.dropFirst().reduce(first) { $0.union($1) }
        } else {
            subject = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
        }
        subject = subject.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        if subject.isNull || subject.width <= 0 { subject = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3) }

        // --- luce ---
        let overall = lightStats(cg, region: nil)
        let subjectPx = CGRect(x: subject.minX * W, y: subject.minY * H, width: subject.width * W, height: subject.height * H)
        let subj = lightStats(cg, region: subjectPx)
        let backlit = overall.mean - subj.mean > 0.15

        // --- inquadratura (regola dei terzi) ---
        let aspect = 4.0 / 5.0                                  // larghezza / altezza
        let subjectH = Double(subject.height) * H
        var cropH = min(H, max(H * 0.55, subjectH / (isPortrait ? 0.55 : 0.5)))
        var cropW = cropH * aspect
        if cropW > W { cropW = W; cropH = W / aspect }

        let sx = Double(subject.midX) * W, sy = Double(subject.midY) * H
        let thirdX = sx < W / 2 ? 1.0 / 3.0 : 2.0 / 3.0
        let thirdY = isPortrait ? 0.38 : (sy < H / 2 ? 1.0 / 3.0 : 2.0 / 3.0)
        var cx = sx - cropW * (thirdX - 0.5)
        var cy = sy - cropH * (thirdY - 0.5)
        cx = min(max(cx, cropW / 2), W - cropW / 2)
        cy = min(max(cy, cropH / 2), H - cropH / 2)

        var a = SceneAnalysis()
        a.crop = .init(x: (cx - cropW / 2) / W, y: (cy - cropH / 2) / H, w: cropW / W, h: cropH / H)
        a.rotate = (abs(horizonAngle) > 0.7 && abs(horizonAngle) < 12) ? horizonAngle : 0

        // --- scena e luce a parole ---
        if isPortrait { a.scene = faceBoxes.count > 1 ? "Ritratto di gruppo" : "Ritratto" }
        else if horizon.results?.first != nil && salient.count <= 1 { a.scene = "Paesaggio" }
        else { a.scene = "Soggetto in primo piano" }

        if backlit { a.light = "Controluce: il soggetto è più scuro dello sfondo." }
        else if overall.high > 0.08 { a.light = "Alte luci bruciate in una parte dell'immagine." }
        else if subj.mean < 0.3 { a.light = "Scena scura: il soggetto è sottoesposto." }
        else if subj.mean > 0.72 { a.light = "Scena molto chiara: rischio di sovraesposizione." }
        else { a.light = "Luce equilibrata sul soggetto." }

        // --- esposizione ---
        var ev = (0.46 - subj.mean) * 3
        if overall.high > 0.08 && !backlit { ev = min(ev, -0.3) }
        ev = (min(max(ev, -1.5), 1.5) * 3).rounded() / 3          // passi di 1/3 di stop
        a.exposure.ev = ev
        a.exposure.hdr = backlit || overall.high > 0.05
        a.exposure.flash = false
        a.exposure.focus = isPortrait ? "Occhi" : "Soggetto"
        a.exposure.focusPoint = SceneAnalysis.Point(x: Double(subject.midX), y: Double(isPortrait ? subject.minY + subject.height * 0.3 : subject.midY))

        // --- sviluppo ---
        a.develop.shadows = backlit ? 0.5 : (overall.low > 0.15 ? 0.3 : 0)
        a.develop.highlights = overall.high > 0.04 ? -0.5 : 0
        a.develop.contrast = overall.std < 0.15 ? 0.2 : (overall.std > 0.3 ? -0.1 : 0.05)
        a.develop.saturation = isPortrait ? 0.05 : 0.12
        a.develop.warmth = overall.warmBias < -0.05 ? 0.3 : (overall.warmBias > 0.12 ? -0.2 : 0)

        // --- istruzioni ---
        var moves: [SceneAnalysis.Move] = []
        if backlit {
            moves.append(.init(icon: "↻", text: "Gira attorno al soggetto finché la luce non arriva di lato o alle tue spalle."))
        }
        if isPortrait && Double(subject.minY) < 0.05 {
            moves.append(.init(icon: "⌄", text: "Fai un passo indietro e rianalizza: la testa è troppo vicina al bordo."))
        }
        a.moves = Array(moves.prefix(4))

        // --- punteggio ---
        var score = 85.0
        if backlit { score -= 20 }
        if overall.high > 0.08 { score -= 10 }
        if abs(a.rotate) > 0 { score -= 8 }
        score -= min(20, (1 - cropH / H) * 40)
        a.score = max(20, score)

        // --- consigli ---
        if isPortrait {
            a.tips = ["Metti a fuoco sugli occhi e lascia spazio nella direzione dello sguardo.",
                      "Una luce laterale morbida (finestra, ombra aperta) valorizza il volto."]
        } else if a.scene == "Paesaggio" {
            a.tips = ["Tieni l'orizzonte su una linea dei terzi, non al centro.",
                      "Cerca un elemento in primo piano per dare profondità."]
        } else {
            a.tips = ["Semplifica lo sfondo: avvicinati o cambia angolazione per togliere distrazioni."]
        }
        return a
    }

    private static func lightStats(_ cg: CGImage, region: CGRect?) -> LightStats {
        let src = region.flatMap { r -> CGImage? in
            let rr = r.integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return (rr.isNull || rr.width < 4 || rr.height < 4) ? nil : cg.cropping(to: rr)
        } ?? cg

        let side = 64
        var px = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(src, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return LightStats() }

        var sum = 0.0, sum2 = 0.0, high = 0, low = 0, rb = 0.0
        let n = side * side
        for i in 0..<n {
            let r = Double(px[i * 4]) / 255, g = Double(px[i * 4 + 1]) / 255, b = Double(px[i * 4 + 2]) / 255
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            sum += l
            sum2 += l * l
            if l > 0.94 { high += 1 }
            if l < 0.06 { low += 1 }
            rb += r - b
        }
        let mean = sum / Double(n)
        let variance = max(0, sum2 / Double(n) - mean * mean)
        return LightStats(mean: mean, high: Double(high) / Double(n), low: Double(low) / Double(n),
                          std: sqrt(variance), warmBias: rb / Double(n))
    }
}
