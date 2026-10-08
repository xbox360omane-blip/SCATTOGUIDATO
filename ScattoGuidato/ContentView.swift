import SwiftUI
import Photos

private let amber = Color(red: 0.95, green: 0.70, blue: 0.24)
private let good = Color(red: 0.50, green: 0.81, blue: 0.54)
private let warn = Color(red: 0.91, green: 0.53, blue: 0.36)

struct Review: Identifiable {
    let id = UUID()
    let original: UIImage
    let develop: SceneAnalysis.Develop?
}

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var tracker = AlignmentTracker()
    @StateObject private var motion = MotionLevel()
    @AppStorage("claudeModel") private var model = "claude-sonnet-5-5"
    @AppStorage("useAI") private var useAI = true

    @State private var apiKey = Keychain.load() ?? ""
    @State private var analysis: SceneAnalysis?
    @State private var target: UIImage?          // inquadratura obiettivo grezza (per l'allineamento)
    @State private var targetPreview: UIImage?   // obiettivo sviluppato (la sagoma che vedi)
    @State private var ghostOpacity = 0.3
    @State private var busy = false
    @State private var busyText = ""
    @State private var errorText: String?
    @State private var review: Review?
    @State private var showSettings = false
    @State private var panelOpen = false
    @State private var viewAspect: CGFloat = 9.0 / 19.5

    /// L'AI si usa solo se attivata e con una chiave inserita; altrimenti analisi locale.
    private var aiActive: Bool { useAI && !apiKey.isEmpty }

    private var targetAspect: CGFloat {
        guard let t = target, t.size.height > 0 else { return viewAspect }
        return t.size.width / t.size.height
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Mirino a tutto schermo e sovrapposizioni nelle stesse coordinate
                ZStack {
                    CameraPreview(session: camera.session)
                    overlay(size: geo.size)
                }
                .ignoresSafeArea()

                // Comandi, rispettando le aree sicure
                VStack(spacing: 10) {
                    topBar
                    Spacer()
                    liveHint
                    level
                    adviceCard
                    controls
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 4)

                if busy {
                    VStack(spacing: 10) {
                        ProgressView().tint(amber)
                        Text(busyText).font(.subheadline)
                    }
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }

                if let s = camera.statusText {
                    Text(s).multilineTextAlignment(.center).padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .onAppear { updateViewAspect(geo) }
            .onChange(of: geo.size) { _, _ in updateViewAspect(geo) }
        }
        .background(Color.black)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .onAppear {
            let t = tracker
            camera.onFrame = { [weak t] buf in t?.process(buf) }
            camera.start()
            motion.start()
        }
        .onDisappear {
            camera.stop()
            motion.stop()
        }
        .onChange(of: tracker.aligned) { _, aligned in
            if aligned { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(apiKey: $apiKey, model: $model, useAI: $useAI)
        }
        .fullScreenCover(item: $review) { r in
            ReviewView(review: r) { review = nil }
        }
    }

    /// Proporzioni dell'area visibile del mirino (schermo intero, comprese le aree sicure).
    private func updateViewAspect(_ geo: GeometryProxy) {
        let w = geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing
        let h = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
        guard w > 0, h > 0 else { return }
        viewAspect = w / h
        tracker.viewAspect = viewAspect
    }

    // MARK: Sovrapposizioni sul mirino

    private func overlay(size: CGSize) -> some View {
        GeometryReader { g in
            let full = CGRect(origin: .zero, size: g.size)
            let r = fitRect(aspect: targetAspect, in: g.size)
            ZStack {
                if target != nil {
                    Path { p in p.addRect(full); p.addRect(r) }
                        .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                    if let ghost = targetPreview {
                        Image(uiImage: ghost)
                            .resizable()
                            .scaledToFill()
                            .frame(width: r.width, height: r.height)
                            .clipped()
                            .opacity(ghostOpacity)
                            .position(x: r.midX, y: r.midY)
                    }
                    Rectangle()
                        .stroke(tracker.aligned ? good : amber, lineWidth: 2)
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                }
                ThirdsGrid()
                    .stroke(Color.white.opacity(0.28), lineWidth: 0.7)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Barra in alto

    private var topBar: some View {
        HStack(spacing: 8) {
            if let a = analysis, !a.scene.isEmpty {
                chip(a.scene)
            } else {
                chip(aiActive ? "AI" : "LOCALE")
            }
            Spacer()
            if target != nil {
                chip("Match \(Int(tracker.similarity * 100))%", color: tracker.similarity > 0.75 ? good : amber)
            }
        }
        .padding(.top, 4)
    }

    // MARK: Guida dal vivo

    @ViewBuilder
    private var liveHint: some View {
        if target != nil {
            if tracker.aligned {
                Label("Allineato: scatta ora", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(good.opacity(0.92), in: Capsule())
                    .foregroundStyle(.black)
            } else if tracker.hint.withinTolerance {
                Label("Quasi: tieni fermo…", systemImage: "scope")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(good)
            } else if !tracker.hint.instructions.isEmpty {
                HStack(spacing: 16) {
                    ForEach(tracker.hint.instructions, id: \.1) { item in
                        VStack(spacing: 2) {
                            Text(item.0).font(.system(size: 30, weight: .bold))
                            Text(item.1).font(.caption2)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(amber)
            }
        }
    }

    private var level: some View {
        let levelOK = abs(motion.roll) < 1.5
        let vertOK = abs(motion.pitch) < 2
        return HStack(spacing: 10) {
            Capsule()
                .fill(levelOK ? good : Color.white.opacity(0.85))
                .frame(width: 60, height: 2)
                .rotationEffect(.degrees(-motion.roll))
            Text(String(format: "%.0f°", motion.roll)).font(.caption2.monospaced())
            Text(vertOK ? "verticali ok" : String(format: "incl. %.0f°", motion.pitch))
                .font(.caption2.monospaced())
                .foregroundStyle(vertOK ? good : Color.white.opacity(0.75))
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Color.black.opacity(0.4), in: Capsule())
    }

    // MARK: Scheda consigli (compatta, si apre col tocco)

    @ViewBuilder
    private var adviceCard: some View {
        if let e = errorText {
            Text(e)
                .font(.footnote)
                .foregroundStyle(warn)
                .lineLimit(4)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .onTapGesture { errorText = nil }
        } else if let a = analysis {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    if let first = a.moves.first {
                        moveIcon(first.icon)
                        Text(first.text).font(.subheadline).lineLimit(panelOpen ? nil : 2)
                    } else {
                        Text(a.light).font(.subheadline).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: panelOpen ? "chevron.down" : "chevron.up")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                if panelOpen {
                    if !a.light.isEmpty {
                        Text(a.light).font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(a.moves.dropFirst()) { m in
                        HStack(alignment: .top, spacing: 10) {
                            moveIcon(m.icon)
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
                        Slider(value: $ghostOpacity, in: 0...0.8).tint(amber)
                    }
                    ForEach(a.tips, id: \.self) { t in
                        Text("• " + t).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { panelOpen.toggle() } }
        }
    }

    // MARK: Comandi

    private var controls: some View {
        HStack {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .frame(width: 48, height: 48)
                    .background(Color.black.opacity(0.4), in: Circle())
            }
            Spacer()
            Button(action: target == nil ? runAnalysis : shoot) {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 4).frame(width: 78, height: 78)
                    if target == nil {
                        Circle().fill(amber).frame(width: 64, height: 64)
                        VStack(spacing: 0) {
                            Image(systemName: "sparkles").font(.title3)
                            Text("Analizza").font(.caption2.bold())
                        }
                        .foregroundStyle(.black)
                    } else {
                        Circle().fill(tracker.aligned ? good : Color.white).frame(width: 64, height: 64)
                    }
                }
            }
            .disabled(busy)
            Spacer()
            Button(action: resetGuide) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.title3)
                    .frame(width: 48, height: 48)
                    .background(Color.black.opacity(0.4), in: Circle())
            }
            .disabled(target == nil || busy)
            .opacity(target == nil ? 0.35 : 1)
        }
        .padding(.top, 2)
    }

    // MARK: Azioni

    private func runAnalysis() {
        guard !busy else { return }
        guard let raw = camera.currentFrameImage() else {
            errorText = "Il mirino non è ancora pronto. Riprova tra un attimo."
            return
        }
        // l'analisi vede esattamente ciò che vedi sullo schermo
        let frame = ImageTools.centerCrop(raw, aspect: viewAspect)
        errorText = nil
        busyText = aiActive ? "L'AI analizza scena e luce…" : "Analizzo scena e luce…"
        busy = true
        let client: ClaudeClient? = aiActive ? ClaudeClient(apiKey: apiKey, model: model) : nil
        Task {
            do {
                let a: SceneAnalysis
                if let client {
                    a = try await client.analyze(image: frame)
                } else {
                    a = await Task.detached(priority: .userInitiated) { LocalAnalyzer.analyze(frame) }.value
                }
                let ideal = ImageTools.idealFrame(from: frame, analysis: a)
                let preview = ImageTools.develop(ideal.resized(maxSide: 900), with: a.develop, strength: ImageTools.defaultStrength)
                await MainActor.run {
                    analysis = a
                    target = ideal
                    targetPreview = preview
                    panelOpen = false
                    tracker.setTarget(ideal)
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
        busyText = "Scatto…"
        busy = true
        let aspect = targetAspect
        let va = viewAspect
        let a = analysis
        Task {
            do {
                let photo = try await camera.capturePhoto(flash: a?.exposure.flash == true)
                // stessa porzione che vedi nel riquadro sul mirino
                let visible = ImageTools.centerCrop(photo, aspect: va)
                let cropped = ImageTools.centerCrop(visible, aspect: aspect)
                await MainActor.run {
                    review = Review(original: cropped, develop: a?.develop)
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
        panelOpen = false
        tracker.setTarget(nil)
        camera.resetToAuto()
    }

    // MARK: Aiuti grafici

    private func fitRect(aspect: CGFloat, in size: CGSize) -> CGRect {
        let W = size.width, H = size.height
        var w = W, h = W / aspect
        if h > H { h = H; w = H * aspect }
        return CGRect(x: (W - w) / 2, y: (H - h) / 2, width: w, height: h)
    }

    private func moveIcon(_ s: String) -> some View {
        Text(s)
            .font(.headline)
            .frame(width: 28, height: 28)
            .background(amber, in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(.black)
    }

    private func chip(_ text: String, color: Color = .white) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(color)
    }

    private func exifCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            Text(value).font(.callout.monospaced().bold())
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.2)))
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

// MARK: Revisione con intensità regolabile

struct ReviewView: View {
    let review: Review
    let onClose: () -> Void

    @AppStorage("developStrength") private var strength = ImageTools.defaultStrength
    @State private var shown: UIImage?
    @State private var showOriginal = false
    @State private var saveMessage: String?
    @State private var saved = false
    @State private var working = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: showOriginal ? review.original : (shown ?? review.original))
                .resizable()
                .scaledToFit()
                .ignoresSafeArea(edges: .top)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !showOriginal { showOriginal = true } }
                        .onEnded { _ in showOriginal = false }
                )

            VStack(spacing: 10) {
                Spacer()
                VStack(spacing: 10) {
                    if review.develop != nil {
                        HStack(spacing: 10) {
                            Text("Correzioni").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $strength, in: 0...1, onEditingChanged: { editing in
                                if !editing { render() }
                            })
                            .tint(amber)
                            Text("\(Int(strength * 100))%")
                                .font(.caption.monospaced())
                                .frame(width: 40, alignment: .trailing)
                        }
                        Text("Tieni premuta la foto per vedere l'originale")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let m = saveMessage {
                        Text(m).font(.footnote).foregroundStyle(saved ? good : .secondary)
                    }
                    HStack(spacing: 12) {
                        Button(action: onClose) {
                            Text("Rifai").frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        Button(action: save) {
                            Text(saved ? "Salvata" : "Salva in Foto").frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(amber)
                        .foregroundStyle(.black)
                        .disabled(saved || working)
                    }
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 14)
            }
        }
        .foregroundStyle(.white)
        .onAppear { render() }
    }

    private func render() {
        guard let d = review.develop else { shown = review.original; return }
        working = true
        saved = false
        let s = strength
        let src = review.original
        Task.detached(priority: .userInitiated) {
            let img = ImageTools.develop(src, with: d, strength: s)
            await MainActor.run {
                shown = img
                working = false
            }
        }
    }

    private func save() {
        let image = shown ?? review.original
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
