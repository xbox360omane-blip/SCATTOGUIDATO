import SwiftUI
import Photos

let amber = Color(red: 0.95, green: 0.70, blue: 0.24)
let good = Color(red: 0.50, green: 0.81, blue: 0.54)
let warn = Color(red: 0.91, green: 0.53, blue: 0.36)

enum ShootMode: String {
    case guided, free
}

struct Review: Identifiable {
    let id = UUID()
    let original: UIImage
    let develop: SceneAnalysis.Develop?
    let social: SceneAnalysis.Social?
}

typealias PhotoEvaluator = (UIImage) async throws -> SceneAnalysis

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var tracker = AlignmentTracker()
    @StateObject private var motion = MotionLevel()
    @AppStorage("claudeModel") private var model = "claude-sonnet-5-5"
    @AppStorage("useAI") private var useAI = true
    @AppStorage("socialProfile") private var socialProfile = ""
    @AppStorage("shootMode") private var modeRaw = ShootMode.guided.rawValue

    @State private var apiKey = Keychain.load() ?? ""
    @State private var analysis: SceneAnalysis?
    @State private var target: UIImage?          // inquadratura obiettivo (per l'allineamento)
    @State private var targetPreview: UIImage?   // obiettivo sviluppato (la sagoma che vedi)
    @State private var ghostOpacity = 0.35
    @State private var busy = false
    @State private var busyText = ""
    @State private var errorText: String?
    @State private var review: Review?
    @State private var showSettings = false
    @State private var panelOpen = false
    @State private var viewAspect: CGFloat = 9.0 / 19.5
    @State private var screenSize: CGSize = .zero
    @State private var zoomBeforeGuide: Double?
    @State private var pinchStart: Double?
    @State private var focusMark: CGPoint?

    private var mode: ShootMode { ShootMode(rawValue: modeRaw) ?? .guided }

    /// L'AI si usa solo se attivata e con una chiave inserita; altrimenti analisi locale.
    private var aiActive: Bool { useAI && !apiKey.isEmpty }

    private var targetAspect: CGFloat {
        guard let t = target, t.size.height > 0 else { return viewAspect }
        return t.size.width / t.size.height
    }

    private var evaluator: PhotoEvaluator? {
        guard aiActive else { return nil }
        let client = ClaudeClient(apiKey: apiKey, model: model)
        let prompt = Prompts.evaluate(audience: socialProfile)
        return { img in try await client.analyze(image: img, prompt: prompt) }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Mirino a tutto schermo e sovrapposizioni nelle stesse coordinate
                ZStack {
                    CameraPreview(camera: camera, fill: mode == .guided)
                    overlay
                    if let p = focusMark {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(amber, lineWidth: 1.5)
                            .frame(width: 70, height: 70)
                            .position(p)
                            .allowsHitTesting(false)
                    }
                }
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .gesture(
                    MagnificationGesture()
                        .onChanged { v in
                            if pinchStart == nil {
                                pinchStart = camera.zoomDisplay
                                if target != nil { resetGuide(restoreZoom: false) }
                            }
                            camera.setZoom(display: (pinchStart ?? 1) * Double(v), ramp: false)
                        }
                        .onEnded { _ in pinchStart = nil }
                )
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { v in focusTap(at: v.location) }
                )

                // Comandi, rispettando le aree sicure
                VStack(spacing: 10) {
                    topBar
                    Spacer()
                    if mode == .guided { liveHint }
                    level
                    if mode == .guided { adviceCard }
                    lensBar
                    modePicker
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
        .onChange(of: modeRaw) { _, _ in resetGuide(restoreZoom: true) }
        .sheet(isPresented: $showSettings) {
            SettingsView(apiKey: $apiKey, model: $model, useAI: $useAI)
        }
        .fullScreenCover(item: $review) { r in
            ReviewView(review: r, evaluate: evaluator) { review = nil }
        }
    }

    /// Proporzioni dell'area visibile del mirino (schermo intero, comprese le aree sicure).
    private func updateViewAspect(_ geo: GeometryProxy) {
        let w = geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing
        let h = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
        guard w > 0, h > 0 else { return }
        screenSize = CGSize(width: w, height: h)
        viewAspect = w / h
        tracker.viewAspect = viewAspect
    }

    // MARK: Sovrapposizioni sul mirino

    private var overlay: some View {
        GeometryReader { g in
            let full = CGRect(origin: .zero, size: g.size)
            // modalità libera: la foto intera 3:4; guidata: il riquadro dell'obiettivo
            let r = fitRect(aspect: mode == .free ? 3.0 / 4.0 : targetAspect, in: g.size)
            ZStack {
                if mode == .guided && target != nil {
                    Path { p in p.addRect(full); p.addRect(r) }
                        .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                    if let ghost = targetPreview {
                        Image(uiImage: ghost)
                            .resizable()
                            .frame(width: r.width, height: r.height)
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
            if mode == .guided, let a = analysis, !a.scene.isEmpty {
                chip(a.scene)
            } else {
                chip(aiActive ? "AI" : "LOCALE")
            }
            if mode == .guided, let s = analysis?.social {
                chip("Social \(Int(s.score))", color: scoreColor(s.score))
            }
            Spacer()
            if mode == .guided && target != nil {
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
                    if !a.moves.isEmpty {
                        moveIcon("!")
                        Text("Per una foto migliore spostati: \(a.moves[0].text)")
                            .font(.subheadline).lineLimit(panelOpen ? nil : 2)
                    } else {
                        moveIcon("✓")
                        Text("Da qui va bene: segui le frecce e allinea la sagoma.")
                            .font(.subheadline).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: panelOpen ? "chevron.down" : "chevron.up")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                if panelOpen {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if !a.light.isEmpty {
                                Text(a.light).font(.footnote).foregroundStyle(.secondary)
                            }
                            ForEach(a.moves.dropFirst()) { m in
                                HStack(alignment: .top, spacing: 10) {
                                    moveIcon(m.icon)
                                    Text(m.text).font(.subheadline)
                                }
                            }
                            if !a.moves.isEmpty {
                                Text("Dopo esserti spostato tocca ↺ e rianalizza.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let l = a.lens, camera.lenses.contains(where: { abs($0 - l) < 0.15 }),
                               abs(l - camera.zoomDisplay) > 0.15 {
                                Button {
                                    resetGuide(restoreZoom: false)
                                    camera.setZoom(display: l)
                                } label: {
                                    Label("Consigliato l'obiettivo \(lensText(l)): passa e rianalizza", systemImage: "camera.aperture")
                                        .font(.footnote.bold())
                                }
                                .tint(amber)
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
                            if let s = a.social {
                                Divider().overlay(Color.white.opacity(0.2))
                                SocialSection(social: s)
                            } else if !aiActive {
                                Text("La valutazione per i social è disponibile con l'AI attiva.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(a.tips, id: \.self) { t in
                                Text("• " + t).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { panelOpen.toggle() } }
        }
    }

    // MARK: Obiettivi e modalità

    private var lensBar: some View {
        let active = activeLens()
        return HStack(spacing: 8) {
            ForEach(camera.lenses, id: \.self) { l in
                let isActive = abs(l - active) < 0.01
                Button { selectLens(l) } label: {
                    Text(isActive ? zoomText(camera.zoomDisplay) : lensText(l, short: true))
                        .font(.system(size: isActive ? 13 : 11, weight: .bold, design: .rounded))
                        .foregroundStyle(isActive ? amber : .white)
                        .frame(width: isActive ? 42 : 34, height: isActive ? 42 : 34)
                        .background(Color.black.opacity(0.5), in: Circle())
                }
            }
        }
        .padding(4)
        .background(Color.black.opacity(0.25), in: Capsule())
    }

    private var modePicker: some View {
        HStack(spacing: 22) {
            ForEach([ShootMode.guided, ShootMode.free], id: \.self) { m in
                Button { modeRaw = m.rawValue } label: {
                    Text(m == .guided ? "GUIDATA" : "LIBERA")
                        .font(.caption.bold())
                        .tracking(1.2)
                        .foregroundStyle(mode == m ? amber : Color.white.opacity(0.75))
                }
            }
        }
        .padding(.vertical, 2)
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
            Button(action: shutterAction) {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 4).frame(width: 78, height: 78)
                    if mode == .guided && target == nil {
                        Circle().fill(amber).frame(width: 64, height: 64)
                        VStack(spacing: 0) {
                            Image(systemName: "sparkles").font(.title3)
                            Text("Analizza").font(.caption2.bold())
                        }
                        .foregroundStyle(.black)
                    } else {
                        Circle().fill(mode == .guided && tracker.aligned ? good : Color.white).frame(width: 64, height: 64)
                    }
                }
            }
            .disabled(busy)
            Spacer()
            Button { resetGuide(restoreZoom: true) } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.title3)
                    .frame(width: 48, height: 48)
                    .background(Color.black.opacity(0.4), in: Circle())
            }
            .disabled(mode == .free || target == nil || busy)
            .opacity(mode == .free || target == nil ? 0.3 : 1)
        }
        .padding(.top, 2)
    }

    private func shutterAction() {
        switch mode {
        case .free: shootFree()
        case .guided:
            if target == nil { runAnalysis() } else { shootGuided() }
        }
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
        let zoomNow = camera.zoomDisplay
        let prompt = Prompts.analyze(zoom: zoomNow, lenses: camera.lenses, audience: socialProfile)
        errorText = nil
        busyText = aiActive ? "L'AI analizza scena, luce e interesse social…" : "Analizzo scena e luce…"
        busy = true
        let client: ClaudeClient? = aiActive ? ClaudeClient(apiKey: apiKey, model: model) : nil
        Task {
            do {
                let a: SceneAnalysis
                if let client {
                    a = try await client.analyze(image: frame, prompt: prompt)
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
                    zoomBeforeGuide = zoomNow
                    applyGuide(frame: frame, ideal: ideal, analysis: a, zoomNow: zoomNow)
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

    /// Zoom automatico: il riquadro ideale riempie la cornice sullo schermo senza cambiare punto di vista,
    /// quindi la sagoma è replicabile solo puntando e raddrizzando il telefono.
    private func applyGuide(frame: UIImage, ideal: UIImage, analysis a: SceneAnalysis, zoomNow: Double) {
        let S = screenSize
        guard S.width > 0, frame.size.width > 0, ideal.size.height > 0 else {
            camera.apply(a.exposure, devicePoint: nil)
            return
        }
        let R = fitRect(aspect: ideal.size.width / ideal.size.height, in: S)
        let effW = ideal.size.width / frame.size.width
        let effH = ideal.size.height / frame.size.height
        let z = Double((R.width / S.width) / max(effW, 0.05))
        camera.setZoom(display: zoomNow * z)

        var dp: CGPoint?
        if let p = a.exposure.focusPoint {
            let c = a.safeCrop
            let cx = c.x + c.w / 2, cy = c.y + c.h / 2
            let sp = CGPoint(x: R.midX + CGFloat(p.x - cx) / effW * R.width,
                             y: R.midY + CGFloat(p.y - cy) / effH * R.height)
            if R.contains(sp) { dp = camera.devicePoint(fromLayerPoint: sp) }
        }
        camera.apply(a.exposure, devicePoint: dp)
    }

    private func shootGuided() {
        guard !busy else { return }
        busyText = "Scatto…"
        busy = true
        let aspect = targetAspect
        let va = viewAspect
        let a = analysis
        Task {
            do {
                let photo = try await camera.capturePhoto(flash: a?.exposure.flash == true)
                // stessa porzione che vedi nella cornice sul mirino
                let visible = ImageTools.centerCrop(photo, aspect: va)
                let cropped = ImageTools.centerCrop(visible, aspect: aspect)
                await MainActor.run {
                    review = Review(original: cropped, develop: a?.develop, social: a?.social)
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

    private func shootFree() {
        guard !busy else { return }
        busyText = "Scatto…"
        busy = true
        Task {
            do {
                let photo = try await camera.capturePhoto(flash: false)
                await MainActor.run {
                    review = Review(original: photo.normalizedUp(), develop: nil, social: nil)
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

    private func resetGuide(restoreZoom: Bool) {
        if restoreZoom, let z = zoomBeforeGuide, target != nil { camera.setZoom(display: z) }
        zoomBeforeGuide = nil
        analysis = nil
        target = nil
        targetPreview = nil
        errorText = nil
        panelOpen = false
        tracker.setTarget(nil)
        camera.resetToAuto()
    }

    private func selectLens(_ l: Double) {
        if target != nil { resetGuide(restoreZoom: false) }
        camera.setZoom(display: l)
    }

    private func focusTap(at p: CGPoint) {
        guard let dp = camera.devicePoint(fromLayerPoint: p) else { return }
        camera.focus(atDevicePoint: dp)
        focusMark = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if focusMark == p { focusMark = nil }
        }
    }

    // MARK: Aiuti grafici

    private func activeLens() -> Double {
        camera.lenses.last(where: { $0 <= camera.zoomDisplay + 0.05 }) ?? (camera.lenses.first ?? 1)
    }

    private func fitRect(aspect: CGFloat, in size: CGSize) -> CGRect {
        let W = size.width, H = size.height
        var w = W, h = W / aspect
        if h > H { h = H; w = H * aspect }
        return CGRect(x: (W - w) / 2, y: (H - h) / 2, width: w, height: h)
    }

    private func numberText(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? "\(Int(r))" : String(format: "%.1f", r).replacingOccurrences(of: ".", with: ",")
    }

    private func zoomText(_ v: Double) -> String { numberText(v) + "×" }

    private func lensText(_ v: Double, short: Bool = false) -> String {
        if short && v < 1 { return "," + numberText(v * 10) }
        return numberText(v) + "×"
    }

    private func scoreColor(_ s: Double) -> Color { s >= 65 ? good : (s >= 40 ? amber : warn) }

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

// MARK: Valutazione social

struct SocialSection: View {
    let social: SceneAnalysis.Social

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("INTERESSE SOCIAL").font(.caption2.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(social.score))/100")
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(social.score >= 65 ? good : (social.score >= 40 ? amber : warn))
            }
            if !social.verdict.isEmpty {
                Text(social.verdict).font(.subheadline)
            }
            ForEach(social.why, id: \.self) { w in
                Text("• " + w).font(.footnote).foregroundStyle(.secondary)
            }
            if !social.better.isEmpty {
                Label(social.better, systemImage: "lightbulb")
                    .font(.footnote)
                    .foregroundStyle(amber)
            }
            if !social.format.isEmpty {
                Text("Formato consigliato: " + social.format).font(.caption).foregroundStyle(.secondary)
            }
            if !social.hashtags.isEmpty {
                Text(social.hashtags.map { $0.hasPrefix("#") ? $0 : "#" + $0 }.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("Stima basata su ciò che di solito funziona sui social, non su dati in tempo reale.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: Revisione con intensità regolabile

struct ReviewView: View {
    let review: Review
    let evaluate: PhotoEvaluator?
    let onClose: () -> Void

    @AppStorage("developStrength") private var strength = ImageTools.defaultStrength
    @State private var shown: UIImage?
    @State private var showOriginal = false
    @State private var saveMessage: String?
    @State private var saved = false
    @State private var working = false
    @State private var develop: SceneAnalysis.Develop?
    @State private var social: SceneAnalysis.Social?
    @State private var tips: [String] = []
    @State private var evaluating = false

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
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if let s = social {
                                SocialSection(social: s)
                            }
                            ForEach(tips, id: \.self) { t in
                                Text("• " + t).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: social == nil && tips.isEmpty ? 0 : 230)

                    if develop != nil {
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
                    if evaluate != nil && social == nil {
                        Button(action: runEvaluation) {
                            HStack {
                                if evaluating { ProgressView().tint(.black) }
                                Text(evaluating ? "Valuto…" : "Valuta foto e interesse social")
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.white)
                        .foregroundStyle(.black)
                        .disabled(evaluating)
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
        .onAppear {
            develop = review.develop
            social = review.social
            render()
        }
    }

    private func runEvaluation() {
        guard let evaluate, !evaluating else { return }
        evaluating = true
        saveMessage = nil
        let img = review.original
        Task {
            do {
                let a = try await evaluate(img)
                await MainActor.run {
                    develop = a.develop
                    social = a.social
                    tips = a.tips
                    evaluating = false
                    render()
                }
            } catch {
                await MainActor.run {
                    saveMessage = error.localizedDescription
                    evaluating = false
                }
            }
        }
    }

    private func render() {
        guard let d = develop else { shown = review.original; return }
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
