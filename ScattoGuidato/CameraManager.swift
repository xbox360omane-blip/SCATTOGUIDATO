import AVFoundation
import CoreImage
import UIKit

enum CameraError: LocalizedError {
    case noPhoto
    var errorDescription: String? { "Scatto non riuscito. Riprova." }
}

/// Gestisce la fotocamera posteriore: anteprima, obiettivi e zoom, fotogrammi per l'analisi,
/// scatto e impostazioni di esposizione.
final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published var statusText: String?
    @Published var appliedSummary: String?
    /// Zoom come lo mostra la Fotocamera di iPhone (0,5x, 1x, 2x, 3x…).
    @Published var zoomDisplay: Double = 1
    /// Obiettivi disponibili su questo iPhone, in valori "mostrati".
    @Published var lenses: [Double] = [1]

    weak var previewLayer: AVCaptureVideoPreviewLayer?

    /// Chiamato sulla coda video per ogni fotogramma (usato dall'allineamento dal vivo).
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)?

    private let sessionQueue = DispatchQueue(label: "scatto.camera.session")
    private let videoQueue = DispatchQueue(label: "scatto.camera.video")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    /// Fattore di zoom del dispositivo che corrisponde a "1x" (2 se c'è l'ultra grandangolo).
    private var displayBase: CGFloat = 1
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

        // Fotocamera "virtuale" che passa da sola tra ultra grandangolo, grandangolo e tele.
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        guard let dev = types.lazy.compactMap({ AVCaptureDevice.default($0, for: .video, position: .back) }).first,
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

        // Obiettivi disponibili
        let switchOvers = dev.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        let hasUltraWide = dev.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        displayBase = hasUltraWide ? (switchOvers.first ?? 2) : 1

        var list: [Double] = []
        if hasUltraWide { list.append(Double(1 / displayBase)) }
        list.append(1)
        let teles = switchOvers.map { Double($0 / displayBase) }.filter { $0 > 1.05 }
        let maxDisplay = Double(dev.maxAvailableVideoZoomFactor / displayBase)
        if maxDisplay >= 2, !teles.contains(where: { abs($0 - 2) < 0.15 }) { list.append(2) }
        list.append(contentsOf: teles)
        let lensList = Array(Set(list.map { ($0 * 10).rounded() / 10 })).sorted()

        // parte da 1x
        do {
            try dev.lockForConfiguration()
            dev.videoZoomFactor = max(dev.minAvailableVideoZoomFactor, min(displayBase, dev.maxAvailableVideoZoomFactor))
            dev.unlockForConfiguration()
        } catch {}

        DispatchQueue.main.async {
            self.lenses = lensList
            self.zoomDisplay = 1
        }
    }

    // MARK: Zoom

    /// Imposta lo zoom in valori "mostrati" (0,5 = ultra grandangolo, 1 = principale, 3 = tele…).
    func setZoom(display: Double, ramp: Bool = true) {
        sessionQueue.async {
            guard let dev = self.device else { return }
            let maxZ = min(dev.maxAvailableVideoZoomFactor, self.displayBase * 15)
            let z = min(max(CGFloat(display) * self.displayBase, dev.minAvailableVideoZoomFactor), maxZ)
            do {
                try dev.lockForConfiguration()
                if ramp {
                    dev.ramp(toVideoZoomFactor: z, withRate: 8)
                } else {
                    dev.cancelVideoZoomRamp()
                    dev.videoZoomFactor = z
                }
                dev.unlockForConfiguration()
            } catch {}
            let shown = Double(z / self.displayBase)
            DispatchQueue.main.async { self.zoomDisplay = shown }
        }
    }

    /// Converte un punto dello schermo (coordinate dell'anteprima) nel punto del sensore.
    func devicePoint(fromLayerPoint p: CGPoint) -> CGPoint? {
        guard let layer = previewLayer else { return nil }
        let d = layer.captureDevicePointConverted(fromLayerPoint: p)
        guard d.x.isFinite, d.y.isFinite else { return nil }
        return CGPoint(x: min(max(d.x, 0), 1), y: min(max(d.y, 0), 1))
    }

    /// Tocca per mettere a fuoco ed esporre in un punto.
    func focus(atDevicePoint dp: CGPoint) {
        sessionQueue.async {
            guard let dev = self.device else { return }
            do {
                try dev.lockForConfiguration()
                defer { dev.unlockForConfiguration() }
                if dev.isFocusPointOfInterestSupported, dev.isFocusModeSupported(.autoFocus) {
                    dev.focusPointOfInterest = dp
                    dev.focusMode = .autoFocus
                }
                if dev.isExposurePointOfInterestSupported, dev.isExposureModeSupported(.autoExpose) {
                    dev.exposurePointOfInterest = dp
                    dev.exposureMode = .autoExpose
                }
            } catch {}
        }
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
    /// `devicePoint` è il punto di fuoco già convertito in coordinate del sensore.
    func apply(_ e: SceneAnalysis.Exposure, devicePoint: CGPoint?) {
        sessionQueue.async {
            guard let dev = self.device else { return }
            var applied: [String] = []
            do {
                try dev.lockForConfiguration()
                defer { dev.unlockForConfiguration() }

                if let dp = devicePoint {
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

    /// Torna all'automatico (fuoco, esposizione, bianco).
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
