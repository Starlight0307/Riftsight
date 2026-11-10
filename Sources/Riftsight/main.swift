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
    @Published var tftDeck: (name: String, stage: String, units: [TFTBoard.Unit], traits: [TFTBoard.Trait], deck: [String: Any])?  // TFT 덱 정보 창 배치도
}

// 설정 화면(SettingsView)과 오버레이가 함께 쓰는 값. UserDefaults 에 저장돼 다시 켜도 유지
enum Pref {
    static let defaults: [String: Any] = [
        "overlayOn": true, "showPanel": true, "showAugments": true,
        "opacity": 0.7, "scale": 1.0,
    ]
}

@MainActor final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = Model()
    var window: NSWindow!
    var mainWindow: NSWindow?
    var panels: [String: NSPanel] = [:]  // 정보 창마다 클릭·끌기를 받는 작은 창 (전체 화면 층은 클릭 통과)
    var dragOffset: CGPoint?
    var status: NSStatusItem!
    var shown: Bool { UserDefaults.standard.bool(forKey: "overlayOn") }
    var scanAugments: Bool { shown && UserDefaults.standard.bool(forKey: "showAugments") }
    var buildCache: [String: (lines: [String], spells: [Int], data: [String: Any]?)] = [:]
    var spellsSetFor: String?  // 이 챔프 선택에서 스펠을 넣어 준 챔피언. 그 뒤 사용자가 바꾸면 덮어쓰지 않음
    var itemSetFor: String?    // 아이템 세트를 넣어 준 챔피언
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

        for kind in PanelsView.kinds {
            // 눌러도 게임 창이 뒤로 가지 않도록 앞으로 나오지 않는(nonactivating) 창
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = true
            p.level = window.level
            p.collectionBehavior = window.collectionBehavior
            let host = NSHostingController(rootView: PanelsView(model: model, kind: kind))
            host.sizingOptions = .preferredContentSize  // 창 크기가 내용을 따라감
            p.contentViewController = host
            p.identifier = NSUserInterfaceItemIdentifier(kind)
            p.delegate = self
            p.setFrameTopLeftPoint(topLeft(kind))
            panels[kind] = p
        }
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

    // 정보 창 왼쪽 위 위치 (저장값, 없으면 화면 왼쪽 위부터 옆으로 나란히, 게임 상단 정보를 피한 높이)
    func topLeft(_ kind: String) -> CGPoint {
        let d = UserDefaults.standard
        if d.object(forKey: "panel.\(kind).x") != nil { return CGPoint(x: d.double(forKey: "panel.\(kind).x"), y: d.double(forKey: "panel.\(kind).y")) }
        let f = NSScreen.screens.first?.frame ?? .zero
        let column = ["build": 0, "tft": 0, "gold": 1, "lines": 1, "info": 2, "settings": 3][kind] ?? 0
        return CGPoint(x: f.minX + 16 + CGFloat(column) * 320 * d.double(forKey: "scale"), y: f.maxY - 90)
    }

    func dragPanel(_ kind: String) {
        guard let p = panels[kind] else { return }
        let m = NSEvent.mouseLocation
        if dragOffset == nil { dragOffset = CGPoint(x: m.x - p.frame.minX, y: m.y - p.frame.maxY) }
        guard let o = dragOffset else { return }
        p.setFrameTopLeftPoint(CGPoint(x: m.x - o.x, y: m.y - o.y))
    }

    func endPanelDrag(_ kind: String) {
        dragOffset = nil
        guard let p = panels[kind] else { return }
        UserDefaults.standard.set(p.frame.minX, forKey: "panel.\(kind).x")
        UserDefaults.standard.set(p.frame.maxY, forKey: "panel.\(kind).y")
    }

    @objc func resetPanelPosition() {
        for (kind, p) in panels {
            UserDefaults.standard.removeObject(forKey: "panel.\(kind).x")
            UserDefaults.standard.removeObject(forKey: "panel.\(kind).y")
            p.setFrameTopLeftPoint(topLeft(kind))
        }
    }

    // 내용이 늘거나 줄면 아래 모서리 기준으로 바뀌므로 왼쪽 위를 다시 맞춘다
    func windowDidResize(_ n: Notification) {
        if let p = n.object as? NSPanel, let kind = p.identifier?.rawValue, panels[kind] === p, dragOffset == nil {
            p.setFrameTopLeftPoint(topLeft(kind))
        }
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
        for p in panels.values where shown != p.isVisible { shown ? p.orderFrontRegardless() : p.orderOut(nil) }
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
                model.lines = advice.lines.isEmpty ? (decks ?? []) : advice.lines
                // 배치도: 가까운 덱(시너지를 못 읽었으면 1위 메타 덱)을 지금 레벨 단계로
                if let deck = advice.best ?? rawDecks?.first {
                    let bu = await OPGG.buildUp(deckId: deck["id"] as? String ?? "")
                    let stage = TFTBoard.stage(forLevel: (g.all["activePlayer"] as? [String: Any])?["level"] as? Int, buildUp: bu)
                    model.tftDeck = ((deck["name"] as? [String: Any])?["ko_KR"] as? String ?? "?", stage, TFTBoard.units(deck, stage: stage, buildUp: bu), TFTBoard.traits(deck, stage: stage, buildUp: bu), deck)
                }
                model.augments = AugmentOCR.hits(AugmentOCR.tft(), lines)
                if scanAugments && AugmentOCR.denied { model.lines.append(Self.deniedLine) }
            } else {
                model.tftDeck = nil
                let b = await build(g.key, g.name, g.position)
                model.lines = b.lines
                model.card = b.data.map { .init(key: g.key, name: g.name, position: g.position, data: $0) }
                let dd = DDragon.shared
                (model.gold, model.info) = League.info(g.all, item: { dd.itemInfo[$0] }, champ: { dd.champInfo[$0] })
                // 소환사의 협곡(CLASSIC)엔 증강체가 없으니 화면 읽기는 그 밖의 모드(무작위 총력전 등)에서만
                model.augments = scanAugments && g.mode != "CLASSIC"
                    ? await AugmentOCR.scan(await lolAugments(g.key, mode: g.mode), excluding: CGWindowID(window.windowNumber)) : []
                if scanAugments && g.mode != "CLASSIC" && AugmentOCR.denied { model.info.append(Self.deniedLine) }
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
            // 그 챔피언·그 맵(협곡 11, 라인 없는 모드는 칼바람 12) 상점 추천에 OP.GG 빌드
            if itemSetFor != c.key, let d = b.data,
               await League.setItemSet(champId: c.champId, map: c.position.isEmpty ? 12 : 11,
                                       title: "Riftsight · \(c.name)" + (c.position.isEmpty ? " (무작위 총력전)" : ""), blocks: OPGG.itemBlocks(d)) {
                itemSetFor = c.key
            }
        } else {
            spellsSetFor = nil  // 다음 판 챔프 선택에서 다시 넣도록
            itemSetFor = nil
            model.tftDeck = nil
            model.card = nil
            model.info = []
            model.gold = nil
            model.lines = []
            model.augments = []
        }
    }

    static let deniedLine = "증강체  화면 기록 권한이 없어 읽지 못해요 — 허용 후 메뉴바 ◈ 종료·다시 실행"

    // 아수라장(KIWI)은 OP.GG 웹 아수라장 등급, 못 읽거나 다른 모드면 공식 무작위 총력전 성적
    func lolAugments(_ key: String, mode: String) async -> AugmentOCR.Keyed {
        if let hit = lolAugCache[key + mode] { return hit }
        var raw = mode == "KIWI" ? await OPGG.mayhemAugments(key: key) : [:]
        if raw.isEmpty {
            if champIds.isEmpty { champIds = await OPGG.championIds() }
            guard let id = champIds[key] else { return [:] }
            raw = await OPGG.lolAugments(championId: id)
        }
        let table = AugmentOCR.keyed(raw)
        if !table.isEmpty { lolAugCache[key + mode] = table }
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
