import AppKit
import SwiftUI

if CommandLine.arguments.contains("--selftest") {
    OPGG.selfTest()
    AugmentOCR.selfTest()
    League.selfTest()
    Updater.selfTest()
    exit(0)
}

@MainActor final class Model: ObservableObject {
    @Published var lines: [String] = []
    @Published var augments: [AugmentHit] = []
    @Published var card: BuildPanel.Info?  // 롤 빌드가 있으면 글줄 대신 빌드·골드·정보 창으로
    @Published var gold: League.Gold?
    @Published var info: [String] = []     // 게임 정보 창 줄(회복·억제기·피해 유형)
}

// 설정 화면(SettingsView)과 오버레이가 함께 쓰는 값. UserDefaults 에 저장돼 다시 켜도 유지
enum Pref {
    static let defaults: [String: Any] = [
        "overlayOn": true, "showPanel": true, "showAugments": true,
        "corner": "tl", "opacity": 0.7, "scale": 1.0,
    ]
}

@MainActor final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = Model()
    var window: NSWindow!
    var mainWindow: NSWindow?
    var status: NSStatusItem!
    var shown: Bool { UserDefaults.standard.bool(forKey: "overlayOn") }
    var scanAugments: Bool { shown && UserDefaults.standard.bool(forKey: "showAugments") }
    var buildCache: [String: (lines: [String], spells: [Int], data: [String: Any]?)] = [:]
    var spellsSetFor: String?  // 이 챔프 선택에서 스펠을 넣어 준 챔피언. 그 뒤 사용자가 바꾸면 덮어쓰지 않음
    var decks: [String]?
    var rawDecks: [[String: Any]]?
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
        window.level = NSWindow.Level(NSWindow.Level.screenSaver.rawValue + 1)  // 롤 게임 창이 .screenSaver(1000) 층이라 같은 층이면 가려짐
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
            await DDragon.shared.load()  // 오버레이 카드 아이콘용
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
        // 켤 때 화면 크기에 묶이지 않도록 지금 주 모니터(메뉴 막대 있는 쪽)에 맞춤
        if let f = NSScreen.screens.first?.frame, window.frame != f { window.setFrame(f, display: false) }
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
                model.card = nil
                model.info = []
                model.gold = nil
                if rawDecks == nil { rawDecks = await OPGG.rawMetaDecks(); await DDragon.shared.loadTFT() }
                // 화면 한 번 읽어 증강체와 왼쪽 시너지 목록을 함께 찾는다
                let lines = scanAugments ? await AugmentOCR.read(excluding: CGWindowID(window.windowNumber)) : []
                let names = DDragon.shared.tftNames
                // 시너지 줄은 "3 햇빛"·"햇빛 2/3" 처럼 숫자가 붙어 읽히므로 숫자·/ 를 빼고 이름과 정확히 같을 때만
                let seen = Set(lines.compactMap { DDragon.shared.tftTraits[AugmentOCR.norm($0.0.filter { !$0.isNumber && $0 != "/" })] })
                let advice = OPGG.closestDecks(seen: seen, decks: rawDecks ?? [], name: { names[$0] })
                model.lines = advice.isEmpty ? (decks ?? []) : advice
                model.augments = AugmentOCR.hits(AugmentOCR.tft(), lines)
            } else {
                let b = await build(g.key, g.name, g.position)
                model.lines = b.lines
                model.card = b.data.map { .init(key: g.key, name: g.name, position: g.position, data: $0) }
                let dd = DDragon.shared
                (model.gold, model.info) = League.info(g.all, item: { dd.itemInfo[$0] }, champ: { dd.champInfo[$0] })
                // 소환사의 협곡(CLASSIC)엔 증강체가 없으니 화면 읽기는 그 밖의 모드(무작위 총력전 등)에서만
                model.augments = scanAugments && g.mode != "CLASSIC"
                    ? await AugmentOCR.scan(await lolAugments(g.key), excluding: CGWindowID(window.windowNumber)) : []
            }
        } else if let l = await League.loading() {
            let dd = DDragon.shared
            func keys(_ ids: [Int]) -> [String] { ids.compactMap { dd.champIdByKey[$0] } }
            model.card = nil
            model.augments = []
            model.lines = ["로딩 중", League.damageLine(mine: keys(l.mine), theirs: keys(l.theirs), { dd.champInfo[$0] })]
        } else if let c = await League.champSelect() {
            model.augments = []
            let b = await build(c.key, c.name, c.position)
            model.lines = b.lines
            model.card = b.data.map { .init(key: c.key, name: c.name, position: c.position, data: $0) }
            model.info = []
            model.gold = nil
            if spellsSetFor != c.key, b.spells.count == 2, await League.setSpells(League.arrange(b.spells, current: c.spells)) {
                spellsSetFor = c.key
            }
        } else {
            spellsSetFor = nil  // 다음 판 챔프 선택에서 다시 넣도록
            model.card = nil
            model.info = []
            model.gold = nil
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

    func build(_ key: String, _ name: String, _ pos: String) async -> (lines: [String], spells: [Int], data: [String: Any]?) {
        guard !key.isEmpty else { return ([], [], nil) }
        let k = key + pos
        if let hit = buildCache[k] { return hit }
        let b = await OPGG.build(key: key, name: name, position: pos)
        buildCache[k] = b
        return b
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)  // 독 아이콘 없이 메뉴바에만
    app.run()
}
