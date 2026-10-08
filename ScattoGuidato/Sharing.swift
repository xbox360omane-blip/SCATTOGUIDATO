import SwiftUI
import UIKit
import Photos

/// Pannello di condivisione di iOS (WhatsApp, Facebook, Threads, Mail, AirDrop…).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

enum PhotoLibrary {
    /// Salva nel rullino e restituisce l'identificativo della foto (nil se non riuscito).
    static func save(_ image: UIImage, completion: @escaping (Result<String, Error>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(.failure(LibraryError.denied)) }
                return
            }
            var id: String?
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetChangeRequest.creationRequestForAsset(from: image)
                id = req.placeholderForCreatedAsset?.localIdentifier
            }) { ok, error in
                DispatchQueue.main.async {
                    if ok, let id { completion(.success(id)) }
                    else { completion(.failure(error ?? LibraryError.failed)) }
                }
            }
        }
    }

    enum LibraryError: LocalizedError {
        case denied, failed
        var errorDescription: String? {
            switch self {
            case .denied: return "Consenti l'aggiunta di foto in Impostazioni > Scatto Guidato."
            case .failed: return "Salvataggio non riuscito. Riprova."
            }
        }
    }
}

enum Instagram {
    /// Apre Instagram sul nuovo post con la foto indicata già selezionata.
    static func openNewPost(assetId: String, completion: @escaping (Bool) -> Void) {
        let encoded = assetId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? assetId
        guard let url = URL(string: "instagram://library?LocalIdentifier=\(encoded)") else {
            completion(false)
            return
        }
        UIApplication.shared.open(url, options: [:]) { ok in completion(ok) }
    }
}
