import SwiftUI
import Photos

private let amber = Color(red: 0.95, green: 0.70, blue: 0.24)
private let good = Color(red: 0.50, green: 0.81, blue: 0.54)

struct Review: Identifiable {
    let id = UUID()
    let before: UIImage
    let after: UIImage
}

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var tracker = AlignmentTracker()
    @StateObject private var motion = MotionLevel()
    @AppStorage("claudeModel") private var model = "claude-sonnet-5-5"

    @State private var apiKey = Keychain.load() ?? ""
    @State private var analysis: SceneAnalysis?
    @State private var target: UIImage?          // inquadratura obiettivo grezza (per l'allineamento)
    @State private var targetPreview: UIImage?   // obiettivo sviluppato (la sagoma che vedi)
    @State private var ghostOpacity = 0.35
    @State private var busy = false
    @State private var busyText = ""
    @State private var errorText: String?
    @State private var review: Review?
    @State private var showSettings = false

    private var targetAspect: CGFloat {
        guard let t = target, t.size.height > 0 else { return 3.0 / 4.0 }
        return t.size.width / t.size.height
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            viewfinder
            panel
            Spacer(minLength: 0)
            controls
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .onAppear {
            let t = tracker
            camera.onFrame = { [weak t] buf in t?.process(buf) }
            camera.start()
            motion.start()
            if apiKey.isEmpty { showSettings = true }
        }
        .onDisappear {
            camera.stop()
            motion.stop()
        }
        .onChange(of: tracker.hint.isAligned) { _, aligned in
            if aligned { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(apiKey: $apiKey, model: $model)
        }
        .fullScreenCover(item: $review) { r in
            ReviewView(review: r) { review = nil }
        }
    }

    // MARK: Intestazione

    private var header: some View {
        HStack {
            Text("Scatto ").font(.title3.bold()) + Text("Guidato").font(.title3.bold()).foregroundColor(amber)
            Spacer()
            Text(target == nil ? "1 · INQUADRA" : "2 · ALLINEA")
                .font(.caption.monospaced())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(amber, lineWidth: 1))
                .foregroundStyle(amber)
        }
        .padding(.top, 4)
    }

    // MARK: Mirino

    private var viewfinder: some View {
        ZStack {
            CameraPreview(session: camera.session)

            GeometryReader { g in
                let full = CGRect(origin: .zero, size: g.size)
                let r = fitRect(aspect: targetAspect, in: g.size)
                ZStack {
                    if target != nil {
                        Path { p in p.addRect(full); p.addRect(r) }
                            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                        if let ghost = targetPreview {
                            Image(uiImage: ghost)
                                .resizable()
                                .scaledToFill()
                                .frame(width: r.width, height: r.height)
                                .clipped()
                                .opacity(ghostOpacity)
                                .position(x: r.midX, y: r.midY)
                        }
                    }
                    ThirdsGrid()
                        .stroke(Color.white.opacity(0.3), lineWidth: 0.7)
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                    Rectangle()
                        .stroke(tracker.hint.isAligned ? good : (target == nil ? Color.white.opacity(0.4) : amber), lineWidth: 2)
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                }
            }
            .allowsHitTesting(false)

            VStack(spacing: 8) {
                hud
                Spacer()
                liveHint
                level
            }
            .padding(10)

            if busy {
                VStack(spacing: 10) {
                    ProgressView().tint(amber)
                    Text(busyText).font(.subheadline)
                }
                .padding(16)
                .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            }

            if let s = camera.statusText {
                Text(s).multilineTextAlignment(.center).padding()
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var hud: some View {
        HStack {
            if let a = analysis, !a.scene.isEmpty {
                chip(a.scene)
            }
            Spacer()
            if target != nil {
                chip("Match \(Int(tracker.similarity * 100))%", color: tracker.similarity > 0.75 ? good : amber)
            }
        }
    }

    @ViewBuilder
    private var liveHint: some View {
        if target != nil {
            if tracker.hint.isAligned {
                Label("Allineato: scatta ora", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(good.opacity(0.9), in: Capsule())
                    .foregroundStyle(.black)
            } else if !tracker.hint.instructions.isEmpty {
                HStack(spacing: 14) {
                    ForEach(tracker.hint.instructions, id: \.1) { item in
                        VStack(spacing: 2) {
                            Text(item.0).font(.system(size: 30, weight: .bold))
                            Text(item.1).font(.caption2)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(amber)
            }
        }
    }

    private var level: some View {
        let levelOK = abs(motion.roll) < 1.5
        let vertOK = abs(motion.pitch) < 2
        return HStack(spacing: 10) {
            Capsule()
                .fill(levelOK ? good : Color.white.opacity(0.8))
                .frame(width: 70, height: 2)
                .rotationEffect(.degrees(-motion.roll))
            Text(String(format: "%.0f°", motion.roll)).font(.caption.monospaced())
            Text(vertOK ? "verticali ok" : String(format: "incl. %.0f°", motion.pitch))
                .font(.caption.monospaced())
                .foregroundStyle(vertOK ? good : Color.white.opacity(0.7))
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Color.black.opacity(0.5), in: Capsule())
    }

    // MARK: Pannello consigli

    private var panel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let e = errorText {
                    Text(e).font(.footnote).foregroundStyle(Color(red: 0.91, green: 0.53, blue: 0.36))
                }
                if let a = analysis {
                    if !a.light.isEmpty {
                        Text(a.light).font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(a.moves) { m in
                        HStack(alignment: .top, spacing: 10) {
                            Text(m.icon)
                                .font(.headline)
                                .frame(width: 28, height: 28)
                                .background(amber, in: RoundedRectangle(cornerRadius: 7))
                                .foregroundStyle(.black)
                            Text(m.text).font(.subheadline)
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) { ForEach(exposureCells(a.exposure), id: \.0) { c in exifCell(c.0, c.1) } }
                    }
                    if let s = camera.appliedSummary {
                        Label(s, systemImage: "checkmark").font(.caption).foregroundStyle(good)
                    }
                    HStack {
                        Text("Sagoma").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $ghostOpacity, in: 0...0.9).tint(amber)
                    }
                    ForEach(a.tips, id: \.self) { t in
                        Text("• " + t).font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Inquadra il soggetto e tocca Analizza. L'AI studia scena e luce, disegna l'inquadratura ideale e imposta la fotocamera.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 210)
    }

    // MARK: Comandi

    private var controls: some View {
        HStack {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.title2).frame(width: 52, height: 52)
            }
            Spacer()
            Button(action: target == nil ? runAnalysis : shoot) {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 4).frame(width: 76, height: 76)
                    if target == nil {
                        Circle().fill(amber).frame(width: 62, height: 62)
                        VStack(spacing: 0) {
                            Image(systemName: "sparkles").font(.title3)
                            Text("Analizza").font(.caption2.bold())
                        }
                        .foregroundStyle(.black)
                    } else {
                        Circle().fill(tracker.hint.isAligned ? good : Color.white).frame(width: 62, height: 62)
                    }
                }
            }
            .disabled(busy)
            Spacer()
            Button(action: resetGuide) {
                Image(systemName: "arrow.counterclockwise").font(.title2).frame(width: 52, height: 52)
            }
            .disabled(target == nil || busy)
            .opacity(target == nil ? 0.3 : 1)
        }
    }

    // MARK: Azioni

    private func runAnalysis() {
        guard !busy else { return }
        guard !apiKey.isEmpty else { showSettings = true; return }
        guard let frame = camera.currentFrameImage() else {
            errorText = "Il mirino non è ancora pronto. Riprova tra un attimo."
            return
        }
        errorText = nil
        busyText = "Analizzo scena e luce…"
        busy = true
        let client = ClaudeClient(apiKey: apiKey, model: model)
        Task {
            do {
                let a = try await client.analyze(image: frame)
                let raw = ImageTools.idealFrame(from: frame, analysis: a)
                let developed = ImageTools.develop(raw, with: a.develop)
                await MainActor.run {
                    analysis = a
                    target = raw
                    targetPreview = developed
                    tracker.setTarget(raw)
                    camera.apply(a.exposure)
                    busy = false
                }
            } catch {
                await MainActor.run {
                    errorText = error.localizedDescription
                    busy = false
                }
            }
        }
    }

    private func shoot() {
        guard !busy else { return }
        busyText = "Sviluppo la foto…"
        busy = true
        let aspect = targetAspect
        let a = analysis
        Task {
            do {
                let photo = try await camera.capturePhoto(flash: a?.exposure.flash == true)
                let cropped = ImageTools.centerCrop(photo, aspect: aspect)
                let developed = a.map { ImageTools.develop(cropped, with: $0.develop) } ?? cropped
                await MainActor.run {
                    review = Review(before: cropped, after: developed)
                    busy = false
                }
            } catch {
                await MainActor.run {
                    errorText = error.localizedDescription
                    busy = false
                }
            }
        }
    }

    private func resetGuide() {
        analysis = nil
        target = nil
        targetPreview = nil
        errorText = nil
        tracker.setTarget(nil)
        camera.resetToAuto()
    }

    // MARK: Aiuti grafici

    private func fitRect(aspect: CGFloat, in size: CGSize) -> CGRect {
        let inset: CGFloat = target == nil ? 0 : 14
        let W = size.width - inset * 2, H = size.height - inset * 2
        var w = W, h = W / aspect
        if h > H { h = H; w = H * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func chip(_ text: String, color: Color = .white) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(color)
    }

    private func exifCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            Text(value).font(.callout.monospaced().bold())
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.18)))
    }

    private func exposureCells(_ e: SceneAnalysis.Exposure) -> [(String, String)] {
        var out: [(String, String)] = []
        if let ev = e.ev { out.append(("Esposiz.", String(format: "%+.1f EV", ev))) }
        if let iso = e.iso { out.append(("ISO", "\(Int(iso))")) }
        if let s = e.shutter { out.append(("Tempo", s)) }
        if let k = e.whiteBalanceK { out.append(("Bianco", "\(Int(k)) K")) }
        if let h = e.hdr { out.append(("HDR", h ? "Sì" : "No")) }
        if let f = e.flash { out.append(("Flash", f ? "Sì" : "No")) }
        if let f = e.focus { out.append(("Fuoco", f)) }
        return out
    }
}

struct ThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for i in 1...2 {
            let x = rect.minX + rect.width * CGFloat(i) / 3
            p.move(to: CGPoint(x: x, y: rect.minY))
            p.addLine(to: CGPoint(x: x, y: rect.maxY))
            let y = rect.minY + rect.height * CGFloat(i) / 3
            p.move(to: CGPoint(x: rect.minX, y: y))
            p.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return p
    }
}

// MARK: Revisione e salvataggio

struct ReviewView: View {
    let review: Review
    let onClose: () -> Void
    @State private var showOriginal = false
    @State private var saveMessage: String?
    @State private var saved = false

    var body: some View {
        VStack(spacing: 14) {
            Image(uiImage: showOriginal ? review.before : review.after)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .frame(maxHeight: .infinity)
            Picker("Versione", selection: $showOriginal) {
                Text("Sviluppata").tag(false)
                Text("Originale").tag(true)
            }
            .pickerStyle(.segmented)
            if let m = saveMessage {
                Text(m).font(.footnote).foregroundStyle(saved ? good : .secondary)
            }
            HStack(spacing: 12) {
                Button(action: onClose) {
                    Text("Rifai").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                Button(action: save) {
                    Text(saved ? "Salvata" : "Salva in Foto").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(amber)
                .foregroundStyle(.black)
                .disabled(saved)
            }
        }
        .padding()
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
    }

    private func save() {
        let image = showOriginal ? review.before : review.after
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { saveMessage = "Consenti l'aggiunta di foto in Impostazioni > Scatto Guidato." }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { ok, _ in
                DispatchQueue.main.async {
                    saved = ok
                    saveMessage = ok ? "Salvata nel rullino." : "Salvataggio non riuscito. Riprova."
                }
            }
        }
    }
}
