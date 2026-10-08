import Foundation
import UIKit

enum ClaudeError: LocalizedError {
    case missingKey
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Inserisci la tua chiave API Anthropic nelle impostazioni."
        case .http(401, _):
            return "Chiave API non valida. Controllala nelle impostazioni."
        case .http(429, _):
            return "Troppe richieste in poco tempo. Riprova tra qualche secondo."
        case .http(let code, let body):
            return "Errore dal servizio AI (\(code)). \(body.prefix(160))"
        case .badResponse:
            return "La risposta dell'AI non era leggibile. Riprova."
        }
    }
}

/// Chiama direttamente l'API Messages di Anthropic.
/// Per la pubblicazione sull'App Store la chiave va spostata su un tuo server intermedio.
struct ClaudeClient {
    var apiKey: String
    var model: String

    func analyze(image: UIImage) async throws -> SceneAnalysis {
        guard !apiKey.isEmpty else { throw ClaudeError.missingKey }
        guard let b64 = image.jpegBase64(maxSide: 1280) else { throw ClaudeError.badResponse }

        let content: [[String: Any]] = [
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": b64]],
            ["type": "text", "text": Prompts.analyze]
        ]
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1500,
            "messages": [["role": "user", "content": content]]
        ]

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw ClaudeError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = obj["content"] as? [[String: Any]] else { throw ClaudeError.badResponse }
        let text = blocks.compactMap { b -> String? in
            ((b["type"] as? String) == "text") ? (b["text"] as? String) : nil
        }.joined()
        return try SceneAnalysis.parse(text)
    }
}
