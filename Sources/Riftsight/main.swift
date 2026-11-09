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
                    Text("\(a.tier)  \(String(format: "%.2f등", a.avg))")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(color(a.tier), in: Capsule())
                        .position(x: a.box.midX * geo.size.width, y: (1 - a.box.maxY) * geo.size.height - 16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    func color(_ t: String) -> Color {
        ["S": .orange, "A": .yellow, "B": .green, "C": .mint][t] ?? .gray
    }
}

@MainActor final class App: NSObject, NSApplicationDelegate {
    let model = Model()
    var window: NSWindow!
    var status: NSStatusItem!
    var shown = true
    var buildCache: [String: [String]] = [:]
    var decks: [String]?

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
        menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.first?.target = self
        status.menu = menu

        Task { await loop() }
    }

    @objc func toggle() {
        shown.toggle()
        shown ? window.orderFrontRegardless() : window.orderOut(nil)
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
                model.augments = shown ? await AugmentOCR.scan(excluding: CGWindowID(window.windowNumber)) : []
            } else {
                model.augments = []
                model.lines = await build(g.key, g.name, g.position)
            }
        } else if let c = await League.champSelect() {
            model.augments = []
            model.lines = await build(c.key, c.name, c.position)
        } else {
            model.lines = []
            model.augments = []
        }
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
