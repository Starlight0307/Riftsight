import AppKit
import SwiftUI

if CommandLine.arguments.contains("--selftest") {
    OPGG.selfTest()
    AugmentOCR.selfTest()
    exit(0)
}

@MainActor final class Model: ObservableObject {
    @Published var lines: [String] = []
    @Published var augments: [AugmentHit] = []
}

struct OverlayView: View {
    @ObservedObject var model: Model

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if !model.lines.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.lines.enumerated()), id: \.offset) { i, l in
                            Text(l).font(.system(size: i == 0 ? 14 : 12, weight: i == 0 ? .bold : .regular))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: 420, alignment: .leading)
                    .padding(.leading, 16).padding(.top, 90)
                }
                // 증강체 이름 바로 위에 등급 배지
                ForEach(model.augments) { a in
                    Text("\(a.tier)  \(a.note)")
                        .font(.system(size: 15, weight: .heavy))
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

@MainActor final class App: NSObject, NSApplicationDelegate {
    let model = Model()
    var window: NSWindow!
    var status: NSStatusItem!
    var shown = true
    var buildCache: [String: [String]] = [:]
    var decks: [String]?
    var champIds: [String: Int] = [:]
    var lolAugCache: [String: AugmentOCR.Keyed] = [:]

    func applicationDidFinishLaunching(_ n: Notification) {
        let frame = NSScreen.main?.frame ?? .zero
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true  // 클릭은 게임으로 그대로 통과
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = NSHostingView(rootView: OverlayView(model: model))
        window.orderFrontRegardless()

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "◈"
        let menu = NSMenu()
        menu.addItem(withTitle: "오버레이 보이기/숨기기", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(withTitle: "TFT 등급표 열기", action: #selector(openTiers), keyEquivalent: "")
        menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.prefix(2).forEach { $0.target = self }
        status.menu = menu

        Task { await loop() }
    }

    @objc func toggle() {
        shown.toggle()
        shown ? window.orderFrontRegardless() : window.orderOut(nil)
    }

    // 등급표가 없으면 OP.GG 의 이번 시즌 증강체 이름을 채운 양식을 만들어 연다
    @objc func openTiers() {
        Task {
            let f = AugmentOCR.tftFile
            if !FileManager.default.fileExists(atPath: f.path) {
                let augs = await OPGG.tftAugments().sorted { ($0.rarity, $0.name) < ($1.rarity, $1.name) }
                let head = "# 맨 앞 ? 를 S·A·B·C·D 로 바꾸세요. ? 로 남긴 줄은 쓰지 않습니다. # 뒤는 메모.\n"
                let body = augs.map { "? \($0.name)  # \($0.rarity)" }.joined(separator: "\n")
                try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? (head + body + "\n").write(to: f, atomically: true, encoding: .utf8)
            }
            NSWorkspace.shared.open(f)
        }
    }

    func loop() async {
        while true {
            await tick()
            try? await Task.sleep(for: .milliseconds(1500))
        }
    }

    func tick() async {
        if let g = await League.liveGame() {
            if g.mode == "TFT" {
                if decks == nil { decks = await OPGG.metaDecks() }
                model.lines = decks ?? []
                model.augments = shown ? await AugmentOCR.scan(AugmentOCR.tft(), excluding: CGWindowID(window.windowNumber)) : []
            } else {
                model.lines = await build(g.key, g.name, g.position)
                // 소환사의 협곡(CLASSIC)엔 증강체가 없으니 화면 읽기는 그 밖의 모드(무작위 총력전 등)에서만
                model.augments = shown && g.mode != "CLASSIC"
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
