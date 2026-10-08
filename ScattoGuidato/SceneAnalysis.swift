import Foundation

/// Risposta dell'AI, letta in modo tollerante (numeri come stringhe, campi mancanti).
struct SceneAnalysis {
    struct Crop { var x: Double; var y: Double; var w: Double; var h: Double }
    struct Point { var x: Double; var y: Double }
    struct Move: Identifiable { let id = UUID(); var icon: String; var text: String }
    struct Exposure {
        var ev: Double?
        var iso: Double?
        var shutter: String?
        var whiteBalanceK: Double?
        var hdr: Bool?
        var flash: Bool?
        var focus: String?
        var focusPoint: Point?   // coordinate normalizzate nell'immagine verticale, origine in alto a sinistra
    }
    struct Develop {
        var exposure: Double = 0
        var contrast: Double = 0
        var saturation: Double = 0
        var warmth: Double = 0
        var shadows: Double = 0
        var highlights: Double = 0
    }

    var scene: String = ""
    var light: String = ""
    var score: Double = 0
    var crop: Crop = Crop(x: 0, y: 0, w: 1, h: 1)
    var rotate: Double = 0
    var moves: [Move] = []
    var exposure = Exposure()
    var develop = Develop()
    var tips: [String] = []

    /// Ritaglio sempre valido dentro l'immagine.
    var safeCrop: Crop {
        let x = min(max(crop.x, 0), 0.95)
        let y = min(max(crop.y, 0), 0.95)
        let w = min(max(crop.w, 0.05), 1 - x)
        let h = min(max(crop.h, 0.05), 1 - y)
        return Crop(x: x, y: y, w: w, h: h)
    }

    static func parse(_ text: String) throws -> SceneAnalysis {
        guard let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"), s < e,
              let data = String(text[s...e]).data(using: .utf8),
              let o = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ClaudeError.badResponse }

        var a = SceneAnalysis()
        a.scene = o["scene"] as? String ?? ""
        a.light = o["light"] as? String ?? ""
        a.score = num(o["score"]) ?? 0
        a.rotate = min(max(num(o["rotate"]) ?? 0, -20), 20)
        if let c = o["crop"] as? [String: Any] {
            a.crop = Crop(x: num(c["x"]) ?? 0, y: num(c["y"]) ?? 0, w: num(c["w"]) ?? 1, h: num(c["h"]) ?? 1)
        }
        if let ms = o["moves"] as? [[String: Any]] {
            a.moves = ms.prefix(4).compactMap { m in
                guard let t = m["text"] as? String, !t.isEmpty else { return nil }
                return Move(icon: String((m["icon"] as? String ?? "•").prefix(2)), text: t)
            }
        }
        if let e = o["exposure"] as? [String: Any] {
            var x = Exposure()
            x.ev = num(e["ev"])
            x.iso = num(e["iso"])
            x.shutter = e["shutter"] as? String
            x.whiteBalanceK = num(e["wb_k"])
            x.hdr = bool(e["hdr"])
            x.flash = bool(e["flash"])
            x.focus = e["focus"] as? String
            if let p = e["focus_point"] as? [String: Any], let px = num(p["x"]), let py = num(p["y"]) {
                x.focusPoint = Point(x: min(max(px, 0), 1), y: min(max(py, 0), 1))
            }
            a.exposure = x
        }
        if let d = o["develop"] as? [String: Any] {
            a.develop = Develop(
                exposure: num(d["exposure"]) ?? 0,
                contrast: num(d["contrast"]) ?? 0,
                saturation: num(d["saturation"]) ?? 0,
                warmth: num(d["warmth"]) ?? 0,
                shadows: num(d["shadows"]) ?? 0,
                highlights: num(d["highlights"]) ?? 0)
        }
        a.tips = (o["tips"] as? [String] ?? []).prefix(3).map { $0 }
        return a
    }

    private static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String {
            let cleaned = s.replacingOccurrences(of: ",", with: ".").filter { "0123456789.-".contains($0) }
            return Double(cleaned)
        }
        return nil
    }

    private static func bool(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let s = v as? String { return ["true", "sì", "si", "yes", "on"].contains(s.lowercased()) }
        return nil
    }
}

enum Prompts {
    static let schema = """
    {
     "scene": "tipo di scena in italiano, breve (es. 'Ritratto in controluce al tramonto')",
     "light": "diagnosi della luce in una frase",
     "score": 0-100,
     "crop": {"x":0-1,"y":0-1,"w":0-1,"h":0-1},
     "rotate": gradi,
     "moves": [{"icon":"←|→|↑|↓|↻|⤢|⤡|⌄|⌃","text":"istruzione fisica concreta in italiano"}],
     "exposure": {"ev":numero, "iso":numero, "shutter":"1/250", "wb_k":numero, "hdr":true|false, "flash":true|false, "focus":"1-2 parole", "focus_point":{"x":0-1,"y":0-1}},
     "develop": {"exposure":-1..1, "contrast":-0.5..0.5, "saturation":-0.5..0.5, "warmth":-1..1, "shadows":-1..1, "highlights":-1..1},
     "tips": ["max 3 consigli brevi in italiano"]
    }
    """

    static let analyze = """
    Sei un direttore della fotografia esperto. Questa è un'inquadratura di prova presa dal mirino di un iPhone, tenuto in verticale.
    Capisci il contesto (soggetto, ambiente, direzione e qualità della luce) e decidi l'inquadratura e l'esposizione ideali per questo tipo di foto.

    Regole per i campi:
    - "score": qualità attuale di inquadratura e luce.
    - "crop": la porzione di QUESTA immagine che diventa la foto ideale (coordinate normalizzate dall'angolo in alto a sinistra). Usa proporzioni fotografiche adatte alla scena (4:5, 3:4, 2:3, 1:1, 16:9). Il fotografo dovrà poi avvicinarsi e puntare finché il mirino coincide con questo ritaglio, quindi resta realistico.
    - "rotate": gradi per ruotare l'immagine in senso orario e raddrizzare orizzonte o verticali (positivo = orario, 0 se è già dritta).
    - "moves": al massimo 4 istruzioni fisiche per il fotografo (spostarsi, abbassarsi, girare attorno al soggetto per cambiare la luce), la più importante per prima. ⤢ = avvicinati, ⤡ = allontanati, ⌄ = abbassati, ⌃ = alzati.
    - "exposure": valori consigliati per lo scatto; "focus_point" è dove mettere fuoco ed esposizione, in coordinate normalizzate di QUESTA immagine.
    - "develop": correzioni di post-produzione da applicare alla foto finale (0 = nessuna modifica).

    Rispondi solo con un oggetto JSON con questa forma:
    """ + schema
}
