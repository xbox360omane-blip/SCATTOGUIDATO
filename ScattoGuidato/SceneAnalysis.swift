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
    struct Social {
        var score: Double = 0
        var verdict: String = ""
        var why: [String] = []
        var better: String = ""
        var format: String = ""
        var hashtags: [String] = []
    }

    var scene: String = ""
    var light: String = ""
    var score: Double = 0
    var crop: Crop = Crop(x: 0, y: 0, w: 1, h: 1)
    var rotate: Double = 0
    var moves: [Move] = []
    var lens: Double?
    var exposure = Exposure()
    var develop = Develop()
    var social: Social?
    var tips: [String] = []

    /// Ritaglio sempre valido dentro l'immagine (minimo 30% per evitare zoom digitali eccessivi).
    var safeCrop: Crop {
        let w = min(max(crop.w, 0.3), 1)
        let h = min(max(crop.h, 0.3), 1)
        let x = min(max(crop.x, 0), 1 - w)
        let y = min(max(crop.y, 0), 1 - h)
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
        if let l = num(o["lens"]), l > 0 { a.lens = l }
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
        if let s = o["social"] as? [String: Any] {
            a.social = Social(
                score: min(max(num(s["score"]) ?? 0, 0), 100),
                verdict: s["verdict"] as? String ?? "",
                why: (s["why"] as? [String] ?? []).prefix(3).map { $0 },
                better: s["better"] as? String ?? "",
                format: s["format"] as? String ?? "",
                hashtags: (s["hashtags"] as? [String] ?? []).prefix(6).map { $0 })
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
    private static let developRule = """
    - "develop": correzioni di post-produzione LEGGERE e NATURALI, come farebbe un fotografo esperto (0 = nessuna modifica). Usa valori piccoli e lascia 0 dove non serve. Rispetta l'atmosfera della luce reale: non aumentare mai calore o saturazione se la scena è già calda, arancione o colorata; se c'è una dominante forte (es. luce artificiale molto arancione) correggila verso il neutro con "warmth" negativo moderato. Evita contrasto e saturazione alti.
    """

    private static func socialRule(_ audience: String) -> String {
        let who = audience.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        - "social": valuta con franchezza quanto la foto può funzionare su Instagram, confrontandola con ciò che di solito ottiene buon coinvolgimento nello stesso genere: originalità del soggetto, impatto visivo nel primo istante, pulizia della composizione, qualità della luce, emozione o storia. Se il soggetto è banale o poco interessante dillo chiaramente e in "better" suggerisci cosa fotografare invece (o come cambiare approccio). "format" è il formato consigliato (es. "4:5 post", "9:16 storia", "1:1"). "hashtags" pertinenti, senza spazi.\(who.isEmpty ? "" : "\n  Il profilo social dell'utente è: \(who). Valuta l'interesse per questo pubblico.")
        """
    }

    private static let socialSchema = """
    "social": {"score":0-100, "verdict":"giudizio in una frase", "why":["max 3 motivi concreti"], "better":"cosa fotografare o cambiare, oppure stringa vuota", "format":"4:5 post", "hashtags":["max 5"]}
    """

    private static func fmt(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? "\(Int(r))x" : String(format: "%.1fx", r)
    }

    /// Analisi dal mirino in modalità guidata.
    static func analyze(zoom: Double, lenses: [Double], audience: String) -> String {
        """
        Sei un direttore della fotografia esperto. Questa è un'inquadratura di prova presa dal mirino di un iPhone tenuto in verticale, con zoom attuale \(fmt(zoom)). Obiettivi disponibili: \(lenses.map(fmt).joined(separator: ", ")).
        Capisci il contesto (soggetto, ambiente, direzione e qualità della luce) e decidi l'inquadratura e l'esposizione ideali.

        IMPORTANTE: il fotografo resterà in questa stessa posizione. L'app replicherà la tua inquadratura con lo zoom e guidandolo a puntare e raddrizzare il telefono. Quindi:
        - "crop": la porzione di QUESTA immagine che diventa la foto ideale (coordinate normalizzate dall'angolo in alto a sinistra), larga almeno 0.3. Proporzioni fotografiche adatte alla scena (4:5, 3:4, 2:3, 1:1). Non immaginare punti di vista diversi: scegli la migliore inquadratura possibile da qui.
        - "rotate": gradi per raddrizzare orizzonte o verticali (positivo = orario, 0 se è già dritta).
        - "moves": SOLO spostamenti fisici del fotografo che migliorerebbero davvero la foto (cambiare lato rispetto alla luce, abbassarsi, alzarsi, cambiare punto di vista). Non scrivere istruzioni di inquadratura come "sposta a destra" o "avvicinati": quelle le gestisce l'app. Lista vuota se la posizione va già bene. ⌄ = abbassati, ⌃ = alzati, ↻ = gira attorno al soggetto, ← → = spostati di lato.
        - "lens": l'obiettivo consigliato (es. 0.5 per interni e architettura, 2 o 3 per ritratti) solo se è diverso da quello attuale e migliora la foto, altrimenti null.
        - "exposure": valori consigliati; "focus_point" è dove mettere fuoco ed esposizione, in coordinate di QUESTA immagine.
        \(developRule)
        \(socialRule(audience))

        Rispondi solo con un oggetto JSON con questa forma:
        {
         "scene": "tipo di scena, breve",
         "light": "diagnosi della luce in una frase",
         "score": 0-100,
         "crop": {"x":0-1,"y":0-1,"w":0-1,"h":0-1},
         "rotate": gradi,
         "moves": [{"icon":"⌄|⌃|↻|←|→","text":"istruzione fisica concreta"}],
         "lens": numero o null,
         "exposure": {"ev":numero, "iso":numero, "shutter":"1/250", "wb_k":numero, "hdr":true|false, "flash":true|false, "focus":"1-2 parole", "focus_point":{"x":0-1,"y":0-1}},
         "develop": {"exposure":-1..1, "contrast":-0.5..0.5, "saturation":-0.5..0.5, "warmth":-1..1, "shadows":0..1, "highlights":-1..0},
         \(socialSchema),
         "tips": ["max 3 consigli brevi"]
        }
        Scrivi tutti i testi in italiano.
        """
    }

    /// Valutazione di una foto già scattata (modalità libera).
    static func evaluate(audience: String) -> String {
        """
        Sei un fotografo esperto e un social media manager. Questa è una foto appena scattata con un iPhone.
        Valuta la foto così com'è e suggerisci un ritocco leggero.
        \(developRule)
        \(socialRule(audience))
        - "tips": max 3 consigli concreti per scattare meglio la prossima volta lo stesso soggetto.

        Rispondi solo con un oggetto JSON con questa forma:
        {
         "scene": "tipo di scena, breve",
         "light": "diagnosi della luce in una frase",
         "score": 0-100,
         "develop": {"exposure":-1..1, "contrast":-0.5..0.5, "saturation":-0.5..0.5, "warmth":-1..1, "shadows":0..1, "highlights":-1..0},
         \(socialSchema),
         "tips": ["max 3 consigli brevi"]
        }
        Scrivi tutti i testi in italiano.
        """
    }
}
