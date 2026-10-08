import SwiftUI
import AVFoundation

struct CameraPreview: UIViewRepresentable {
    let camera: CameraManager
    /// true: riempie lo schermo (modalità guidata); false: foto intera 3:4 come la Fotocamera (modalità libera).
    var fill: Bool = true

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = camera.session
        v.previewLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        v.backgroundColor = .black
        camera.previewLayer = v.previewLayer
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        let g: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
        if uiView.previewLayer.videoGravity != g { uiView.previewLayer.videoGravity = g }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
