import AppKit
import SwiftUI

if CommandLine.arguments.contains("--selftest") {
    OPGG.selfTest()
    AugmentOCR.selfTest()
    Updater.selfTest()
    exit(0)
}

@MainActor final class Model: ObservableObject {
    @Published var lines: [String] = []
    @Published var augments: [AugmentHit] = []
}

// 설정 화면(SettingsView)과 오버레이가 함께 쓰는 값. UserDefaults 에 저장돼 다시 켜도 유지
enum Pref {
    static let defaults: [String: Any] = [
        "overlayOn": true, "showPanel": true, "showAugments": true,
        "corner": "tl", "opacity": 0.7, "scale": 1.0,
    ]
}

struct OverlayView: View {
    @ObservedObject var model: Model
    @AppStorage("showPanel") var showPanel = true
    @AppStorage("corner") var corner = "tl"
    @AppStorage("opacity") var opacity = 0.7
    @AppStorage("scale") var scale = 1.0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if showPanel && !model.lines.isEmpty {
                    let top = corner.hasPrefix("t"), left = corner.hasSuffix("l")
                    VStack(alignment: .leading, spacing: 4 * scale) {
                        ForEach(Array(model.lines.enumerated()), id: \.offset) { i, l in
                            Text(l).font(.system(size: (i == 0 ? 14 : 12) * scale, weight: i == 0 ? .bold : .regular))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(opacity), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: 420 * scale, alignment: .leading)
                    // 위쪽은 게임 상단 정보, 아래쪽은 미니맵·상점을 피하도록 여백
                    .padding(left ? .leading : .trailing, 16)
                    .padding(top ? .top : .bottom, top ? 90 : 120)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: Alignment(horizontal: left ? .leading : .trailing, vertical: top ? .top : .bottom))
                }
                // 증강체 이름 바로 위에 등급 배지
                ForEach(model.augments) { a in
                    Text("\(a.tier)  \(a.note)")
                        .font(.system(size: 15 * scale, weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(color(a), in: Capsule())
                        .position(x: a.box.midX * geo.size.width, y: (1 - a.box.maxY) * geo.size.height - 16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // 롤 증강체는 희귀도 색, TFT 는 등급 색
    func color(_ a: AugmentHit) -> Color {
        ["프리즘": .purple, "골드": .yellow, "실버": Color(white: 0.8)][a.note] ?? ["S": .orange, "A": .yellow, "B": .green, "C": .mint][a.tier] ?? .gray
    }
}

@MainActor final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = Model()
    var window: NSWindow!
    var mainWindow: NSWindow?
    var status: NSStatusItem!
    var shown: Bool { UserDefaults.standard.bool(forKey: "overlayOn") }
    var scanAugments: Bool { shown && UserDefaults.standard.bool(forKey: "showAugments") }
    var buildCache: [String: [String]] = [:]
    var decks: [String]?
    var champIds: [String: Int] = [:]
    var lolAugCache: [String: AugmentOCR.Keyed] = [:]

    func applicationDidFinishLaunching(_ n: Notification) {
        UserDefaults.standard.register(defaults: Pref.defaults)
        let frame = NSScreen.main?.frame ?? .zero
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true  // 클릭은 게임으로 그대로 통과
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = NSHostingView(rootView: OverlayView(model: model))
        applyShown()

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "◈"
        let menu = NSMenu()
        menu.addItem(withTitle: "Riftsight 열기", action: #selector(showMain), keyEquivalent: "")
        menu.addItem(withTitle: "오버레이 보이기/숨기기", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(withTitle: "TFT 등급표 열기", action: #selector(openTiers), keyEquivalent: "")
        menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.prefix(3).forEach { $0.target = self }
        showMain()
        status.menu = menu

        Task {
            await Updater.check()
            await syncTiers()  // 시즌·패치로 증강체가 바뀌었으면 등급표를 맞춰 둠
            await loop()
        }
    }

    // 본창(티어·메타 덱). 닫아도 앱은 메뉴바에 남아 오버레이를 계속 띄운다
    @objc func showMain() {
        if mainWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Riftsight"
            w.titlebarAppearsTransparent = true
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: MainView())
            w.center()
            w.delegate = self
            mainWindow = w
        }
        // 창이 열린 동안은 보통 앱처럼(Dock 아이콘·앞으로 나오기), 닫으면 다시 메뉴바 전용
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ n: Notification) {
        if (n.object as? NSWindow) === mainWindow { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMain()
        return true
    }

    @objc func toggle() {
        UserDefaults.standard.set(!shown, forKey: "overlayOn")
        applyShown()
    }

    // 설정 화면에서 바꿔도 반영되도록 tick 마다 맞춘다
    func applyShown() {
        if shown != window.isVisible { shown ? window.orderFrontRegardless() : window.orderOut(nil) }
    }

    @objc func openTiers() {
        Task {
            await syncTiers()
            NSWorkspace.shared.open(AugmentOCR.tftFile)
        }
    }

    // 등급표를 OP.GG 의 현재 증강체 목록에 맞춘다: 넣어 둔 등급은 유지, 새 증강체는 ?, 사라진 건 빼고 이전 파일은 .bak 로 남김
    func syncTiers() async {
        let augs = await OPGG.tftAugments()
        guard !augs.isEmpty else { return }  // OP.GG 응답이 없으면 등급표를 건드리지 않음
        let f = AugmentOCR.tftFile
        let old = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
        let new = AugmentOCR.mergeTiers(old, augs)
        guard new != old else { return }
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !old.isEmpty { try? old.write(to: f.deletingPathExtension().appendingPathExtension("bak.txt"), atomically: true, encoding: .utf8) }
        try? new.write(to: f, atomically: true, encoding: .utf8)
    }

    func loop() async {
        while true {
            await tick()
            try? await Task.sleep(for: .milliseconds(1500))
        }
    }

    func tick() async {
        applyShown()
        if let g = await League.liveGame() {
            if g.mode == "TFT" {
                if decks == nil { decks = await OPGG.metaDecks() }
                model.lines = decks ?? []
                model.augments = scanAugments ? await AugmentOCR.scan(AugmentOCR.tft(), excluding: CGWindowID(window.windowNumber)) : []
            } else {
                model.lines = await build(g.key, g.name, g.position)
                // 소환사의 협곡(CLASSIC)엔 증강체가 없으니 화면 읽기는 그 밖의 모드(무작위 총력전 등)에서만
                model.augments = scanAugments && g.mode != "CLASSIC"
                    ? await AugmentOCR.scan(await lolAugments(g.key), excluding: CGWindowID(window.windowNumber)) : []
            }
        } else if let c = await League.champSelect() {
            model.augments = []
            model.lines = await build(c.key, c.name, c.position)
        } else {
            model.lines = []
            model.augments = []
        }
    }

    func lolAugments(_ key: String) async -> AugmentOCR.Keyed {
        if let hit = lolAugCache[key] { return hit }
        if champIds.isEmpty { champIds = await OPGG.championIds() }
        guard let id = champIds[key] else { return [:] }
        let table = AugmentOCR.keyed(await OPGG.lolAugments(championId: id))
        if !table.isEmpty { lolAugCache[key] = table }
        return table
    }

    func build(_ key: String, _ name: String, _ pos: String) async -> [String] {
        guard !key.isEmpty else { return [] }
        let k = key + pos
        if let hit = buildCache[k] { return hit }
        let lines = await OPGG.build(key: key, name: name, position: pos)
        buildCache[k] = lines
        return lines
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)  // 독 아이콘 없이 메뉴바에만
    app.run()
}
