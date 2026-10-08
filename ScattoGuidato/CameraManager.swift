import AVFoundation
import CoreImage
import UIKit

enum CameraError: LocalizedError {
    case noPhoto
    var errorDescription: String? { "Scatto non riuscito. Riprova." }
}

/// Gestisce la fotocamera posteriore: anteprima, fotogrammi per l'analisi, scatto e impostazioni di esposizione.
final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published var statusText: String?
    @Published var appliedSummary: String?

    /// Chiamato sulla coda video per ogni fotogramma (usato dall'allineamento dal vivo).
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)?

    private let sessionQueue = DispatchQueue(label: "scatto.camera.session")
    private let videoQueue = DispatchQueue(label: "scatto.camera.video")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private let ciContext = CIContext()
    private let bufferLock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var photoContinuation: CheckedContinuation<UIImage, Error>?

    // MARK: Avvio

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                if ok { self.configureAndRun() } else { self.setStatus("Consenti l'accesso alla fotocamera in Impostazioni > Scatto Guidato.") }
            }
        default:
            setStatus("Consenti l'accesso alla fotocamera in Impostazioni > Scatto Guidato.")
        }
    }

    func stop() {
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func setStatus(_ s: String?) {
        DispatchQueue.main.async { self.statusText = s }
    }

    private func configureAndRun() {
        sessionQueue.async {
            if self.session.inputs.isEmpty { self.configure() }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input) else {
            session.commitConfiguration()
            setStatus("Fotocamera non disponibile su questo dispositivo.")
            return
        }
        session.addInput(input)
        device = dev

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        // fotogrammi e foto in verticale
        for conn in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)].compactMap({ $0 }) {
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
        }
        session.commitConfiguration()
    }

    // MARK: Fotogrammi

    /// Ultimo fotogramma del mirino, già verticale.
    func currentFrameImage() -> UIImage? {
        bufferLock.lock()
        let buf = latestBuffer
        bufferLock.unlock()
        guard let buf else { return nil }
        let ci = CIImage(cvPixelBuffer: buf)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: Scatto

    func capturePhoto(flash: Bool) async throws -> UIImage {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UIImage, Error>) in
            sessionQueue.async {
                self.photoContinuation = cont
                let settings = AVCapturePhotoSettings()
                settings.photoQualityPrioritization = .quality
                if flash && self.photoOutput.supportedFlashModes.contains(.on) {
                    settings.flashMode = .on
                }
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    // MARK: Esposizione

    /// Applica i valori consigliati dall'AI alla fotocamera.
    func apply(_ e: SceneAnalysis.Exposure) {
        sessionQueue.async {
            guard let dev = self.device else { return }
            var applied: [String] = []
            do {
                try dev.lockForConfiguration()
                defer { dev.unlockForConfiguration() }

                if let p = e.focusPoint {
                    // punto nell'immagine verticale -> coordinate del sensore (orizzontale)
                    let dp = CGPoint(x: p.y, y: 1 - p.x)
                    if dev.isFocusPointOfInterestSupported, dev.isFocusModeSupported(.continuousAutoFocus) {
                        dev.focusPointOfInterest = dp
                        dev.focusMode = .continuousAutoFocus
                        applied.append("fuoco")
                    }
                    if dev.isExposurePointOfInterestSupported {
                        dev.exposurePointOfInterest = dp
                    }
                }
                if dev.isExposureModeSupported(.continuousAutoExposure) {
                    dev.exposureMode = .continuousAutoExposure
                }
                if let ev = e.ev {
                    let bias = min(max(Float(ev), dev.minExposureTargetBias), dev.maxExposureTargetBias)
                    dev.setExposureTargetBias(bias, completionHandler: nil)
                    applied.append(String(format: "%+.1f EV", bias))
                }
                if let k = e.whiteBalanceK, k > 1500, k < 15000,
                   dev.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                    let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: Float(k), tint: 0)
                    var g = dev.deviceWhiteBalanceGains(for: tt)
                    let maxG = dev.maxWhiteBalanceGain
                    g.redGain = min(max(g.redGain, 1), maxG)
                    g.greenGain = min(max(g.greenGain, 1), maxG)
                    g.blueGain = min(max(g.blueGain, 1), maxG)
                    dev.setWhiteBalanceModeLocked(with: g, completionHandler: nil)
                    applied.append("\(Int(k)) K")
                }
            } catch {
                return
            }
            let summary = applied.isEmpty ? nil : "Applicati: " + applied.joined(separator: " · ")
            DispatchQueue.main.async { self.appliedSummary = summary }
        }
    }

    /// Torna all'automatico.
    func resetToAuto() {
        sessionQueue.async {
            guard let dev = self.device else { return }
            do {
                try dev.lockForConfiguration()
                defer { dev.unlockForConfiguration() }
                let center = CGPoint(x: 0.5, y: 0.5)
                if dev.isFocusPointOfInterestSupported { dev.focusPointOfInterest = center }
                if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
                if dev.isExposurePointOfInterestSupported { dev.exposurePointOfInterest = center }
                if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
                dev.setExposureTargetBias(0, completionHandler: nil)
                if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
            } catch {}
            DispatchQueue.main.async { self.appliedSummary = nil }
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buf = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        bufferLock.lock()
        latestBuffer = buf
        bufferLock.unlock()
        onFrame?(buf)
    }
}

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let cont = photoContinuation
        photoContinuation = nil
        if let error {
            cont?.resume(throwing: error)
            return
        }
        guard let data = photo.fileDataRepresentation(), let img = UIImage(data: data) else {
            cont?.resume(throwing: CameraError.noPhoto)
            return
        }
        cont?.resume(returning: img)
    }
}
