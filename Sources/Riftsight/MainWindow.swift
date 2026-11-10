import AppKit
import SwiftUI

// 앱 본창: OP.GG 데스크톱 앱처럼 왼쪽 게임 줄 + 라인별 티어 / 메타 덱
enum Theme {
    static let bg = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let card = Color(red: 0.16, green: 0.16, blue: 0.18)
    static let line = Color.white.opacity(0.06)
    static let accent = Color(red: 0.33, green: 0.51, blue: 0.91)
    static let sub = Color.white.opacity(0.55)

    static func tier(_ t: Int) -> Color {
        [1: Color(red: 0.0, green: 0.73, blue: 0.64), 2: accent, 3: .yellow, 4: .orange][t] ?? .gray
    }
}

// 이 맥은 Xcode 없이 명령줄 도구만 있어 @State(매크로)를 못 쓰므로 화면 상태를 한 객체에 모은다
@MainActor final class Store: ObservableObject {
    enum Game: String { case lol = "롤", tft = "TFT", settings = "설정" }
    @Published var game = Game.lol
    @Published var tiers: [String: [[String: Any]]] = [:]
    @Published var picked: (name: String, lane: String)?
    @Published var detail: [String: Any]?
    @Published var detailFailed = false
    @Published var decks: [[String: Any]] = []
    @Published var openDeck: String?          // 펼친 덱 id (배치도·아이템 보기)
    @Published var deckStage = "final"

    func loadTiers() async {
        guard tiers.isEmpty else { return }
        for (lane, _) in LoLView.lanes { tiers[lane] = Array(await OPGG.laneTiers(lane).prefix(30)) }
    }

    func pick(_ name: String, _ lane: String) async {
        picked = (name, lane)
        detail = nil
        detailFailed = false
        guard let id = DDragon.shared.championId(name) else { detailFailed = true; return }
        detail = await OPGG.analysis(key: id, position: lane)
        detailFailed = detail == nil
    }

    func loadDecks() async {
        if decks.isEmpty { decks = await OPGG.rawMetaDecks() }
        await DDragon.shared.loadTFT()
    }
}

struct Icon: View {
    let url: URL?
    var size: CGFloat = 28
    var body: some View {
        AsyncImage(url: url) { $0.resizable() } placeholder: { Theme.line }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
    }
}

struct MainView: View {
    @StateObject private var store = Store()
    @StateObject private var dd = DDragon.shared

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                ForEach([Store.Game.lol, .tft], id: \.self) { railButton($0) }
                Spacer()
                railButton(.settings)
            }
            .padding(10)
            .background(Color.black.opacity(0.35))

            Group {
                if !dd.ready { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if store.game == .lol { LoLView(store: store) }
                else if store.game == .tft { TFTView(store: store) }
                else { SettingsView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(.white)
        .background(Theme.bg)
        .task { await dd.load() }
    }

    func railButton(_ g: Store.Game) -> some View {
        Button { store.game = g } label: {
            Text(g.rawValue).font(.system(size: 13, weight: .bold))
                .frame(width: 44, height: 44)
                .background(store.game == g ? Theme.accent : Theme.card, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }
}

// MARK: - 롤

struct LoLView: View {
    static let lanes = [("top", "탑"), ("jungle", "정글"), ("mid", "미드"), ("adc", "원딜"), ("support", "서포터")]
    @ObservedObject var store: Store

    var body: some View {
        if let p = store.picked {
            ChampionDetail(store: store, name: p.name, lane: p.lane)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("챔피언 티어").font(.system(size: 22, weight: .bold))
                    Text("OP.GG 랭크 게임 기준 · 챔피언을 누르면 빌드").font(.system(size: 12)).foregroundStyle(Theme.sub)
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Self.lanes, id: \.0) { lane, title in
                            LaneColumn(title: title, rows: store.tiers[lane] ?? []) { n in Task { await store.pick(n, lane) } }
                        }
                    }.padding(.top, 10)
                }.padding(20)
            }
            .task { await store.loadTiers() }
        }
    }
}

struct LaneColumn: View {
    let title: String
    let rows: [[String: Any]]
    let onPick: (String) -> Void
    @ObservedObject private var dd = DDragon.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 14, weight: .bold)).padding(12)
            Divider().overlay(Theme.line)
            if rows.isEmpty { ProgressView().padding(20).frame(maxWidth: .infinity) }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                let name = r["champion"] as? String ?? "?"
                let tier = Int(r["tier"] as? Double ?? 0)
                Button { onPick(name) } label: {
                    HStack(spacing: 8) {
                        Text("\(Int(r["rank"] as? Double ?? 0))").font(.system(size: 11)).foregroundStyle(Theme.sub).frame(width: 18)
                        Icon(url: dd.champion(name), size: 26)
                        Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(String(format: "%.0f%%", (r["win_rate"] as? Double ?? 0) * 100)).font(.system(size: 11)).foregroundStyle(Theme.sub)
                        Text("\(tier)").font(.system(size: 11, weight: .bold))
                            .frame(width: 20, height: 18).background(Theme.tier(tier), in: RoundedRectangle(cornerRadius: 4))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ChampionDetail: View {
    @ObservedObject var store: Store
    let name: String, lane: String
    @ObservedObject private var dd = DDragon.shared
    var data: [String: Any]? { store.detail }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Button("‹ 티어 목록") { store.picked = nil }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                HStack(spacing: 14) {
                    Icon(url: dd.champion(name), size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.system(size: 24, weight: .bold))
                        Text(LoLView.lanes.first { $0.0 == lane }?.1 ?? lane).foregroundStyle(Theme.sub)
                    }
                    Spacer()
                    if let w = ((data?["summary"] as? [String: Any])?["average_stats"] as? [String: Any])?["win_rate"] as? Double {
                        Stat(title: "승률", value: String(format: "%.1f%%", w * 100))
                    }
                }
                if store.detailFailed { Text("OP.GG 빌드를 불러오지 못했어요").foregroundStyle(Theme.sub) }
                else if let d = data {
                    if let r = d["runes"] as? [String: Any] {
                        Section("룬") {
                            HStack(spacing: 18) {
                                RuneRow(page: r["primary_page_name"] as? String, runes: r["primary_rune_names"] as? [String] ?? [])
                                RuneRow(page: r["secondary_page_name"] as? String, runes: r["secondary_rune_names"] as? [String] ?? [])
                            }
                        }
                    }
                    ForEach([("starter_items", "시작 아이템"), ("core_items", "핵심 아이템"), ("boots", "신발")], id: \.0) { key, title in
                        Section(title) { ItemRow(names: (d[key] as? [String: Any])?["ids_names"] as? [String] ?? [], arrows: key == "core_items") }
                    }
                    if let o = (d["skills"] as? [String: Any])?["order"] as? [String] {
                        Section("스킬 순서") {
                            HStack(spacing: 4) {
                                ForEach(Array(o.enumerated()), id: \.offset) { _, k in
                                    Text(k).font(.system(size: 12, weight: .bold)).frame(width: 24, height: 24)
                                        .background(k == "R" ? Theme.accent : Theme.line, in: RoundedRectangle(cornerRadius: 5))
                                }
                            }
                        }
                    }
                } else { ProgressView() }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    struct Section<C: View>: View {
        let title: String
        @ViewBuilder let content: C
        init(_ title: String, @ViewBuilder content: () -> C) { self.title = title; self.content = content() }
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.sub)
                content
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    struct RuneRow: View {
        let page: String?, runes: [String]
        @ObservedObject private var dd = DDragon.shared
        var body: some View {
            HStack(spacing: 6) {
                if let p = page { Icon(url: dd.rune(p), size: 24) }
                ForEach(runes, id: \.self) { Icon(url: dd.rune($0), size: 32).help($0) }
            }
        }
    }

    struct ItemRow: View {
        let names: [String]
        var arrows = true
        @ObservedObject private var dd = DDragon.shared
        var body: some View {
            HStack(spacing: 6) {
                ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                    if i > 0 && arrows { Text("›").foregroundStyle(Theme.sub) }
                    VStack(spacing: 4) {
                        Icon(url: dd.item(n), size: 40)
                        Text(n).font(.system(size: 10)).foregroundStyle(Theme.sub).lineLimit(1).frame(width: 64)
                    }
                }
            }
        }
    }
}

struct Stat: View {
    let title: String, value: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 18, weight: .bold))
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.sub)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - TFT

struct TFTView: View {
    @ObservedObject var store: Store
    @ObservedObject private var dd = DDragon.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("TFT 메타 덱").font(.system(size: 22, weight: .bold))
                Text("OP.GG 기준").font(.system(size: 12)).foregroundStyle(Theme.sub)
                if store.decks.isEmpty { ProgressView().padding(30).frame(maxWidth: .infinity) }
                ForEach(Array(store.decks.enumerated()), id: \.offset) { _, d in deckCard(d) }
            }.padding(20)
        }
        .task { await store.loadDecks() }
    }

    func deckCard(_ d: [String: Any]) -> some View {
        let stat = d["stat"] as? [String: Any]
        let deck = stat?["deck"] as? [String: Any]
        let units = (d["units"] as? [[String: Any]] ?? []).sorted { ($0["isCore"] as? Bool ?? false) && !($1["isCore"] as? Bool ?? false) }
        let op = stat?["opTier"] as? String ?? "-"
        let id = d["id"] as? String ?? ""
        let open = store.openDeck == id
        return VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 14) {
            Text(op).font(.system(size: 14, weight: .heavy)).frame(width: 40, height: 40)
                .background(op == "OP" ? Theme.tier(1) : op == "S" ? Theme.accent : Theme.tier(3), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 8) {
                Text((d["name"] as? [String: Any])?["ko_KR"] as? String ?? "?").font(.system(size: 15, weight: .bold))
                HStack(spacing: 4) {
                    ForEach(Array(units.enumerated()), id: \.offset) { _, u in
                        let key = u["key"] as? String ?? ""
                        Group {
                            if let url = dd.tftUnit(key) { Icon(url: url, size: 34) }
                            else { Text(String(key.split(separator: "_").last?.prefix(2) ?? "?")).font(.system(size: 10)).frame(width: 34, height: 34).background(Theme.line, in: RoundedRectangle(cornerRadius: 7)) }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(u["isCore"] as? Bool == true ? Color.yellow : .clear, lineWidth: 2))
                    }
                }
            }
            Spacer()
            Stat(title: "평균 등수", value: String(format: "%.2f", deck?["avgPlacement"] as? Double ?? 0))
            Stat(title: "순방률", value: String(format: "%.0f%%", (deck?["top4Rate"] as? Double ?? 0) * 100))
            Stat(title: "1등률", value: String(format: "%.0f%%", (deck?["winRate"] as? Double ?? 0) * 100))
            Text(open ? "⌃" : "⌄").foregroundStyle(Theme.sub)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.openDeck = open ? nil : id }
        if open { deckDetail(d) }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
    }
}

extension TFTView {
    // 펼친 덱: 레벨 탭 + 배치도 + (최종) 챔피언별 아이템
    func deckDetail(_ d: [String: Any]) -> some View {
        let units = TFTBoard.units(d, stage: store.deckStage)
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(TFTBoard.stages, id: \.0) { key, title in
                        Button(title) { store.deckStage = key }.buttonStyle(.plain)
                            .font(.system(size: 12, weight: .bold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .foregroundStyle(store.deckStage == key ? OV.teal : Theme.sub)
                            .background(store.deckStage == key ? OV.teal.opacity(0.12) : Theme.line, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                if units.isEmpty { Text("이 단계 배치 정보가 없어요").foregroundStyle(Theme.sub) }
                else { TFTBoard(units: units, cell: 48) }
            }
            let withItems = units.filter { !$0.items.isEmpty }
            if !withItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("챔피언별 아이템").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.sub)
                    ForEach(Array(withItems.enumerated()), id: \.offset) { _, u in
                        HStack(spacing: 8) {
                            Icon(url: dd.tftUnit(u.key), size: 30)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(TFTBoard.costColor(dd.tftCost[u.key]), lineWidth: 2))
                            Text(dd.tftNames[u.key] ?? u.key).font(.system(size: 12, weight: .bold)).frame(width: 70, alignment: .leading)
                            ForEach(Array(u.items.enumerated()), id: \.offset) { _, i in
                                Icon(url: dd.tftItems[i]?.icon, size: 26).help(dd.tftItems[i]?.name ?? i)
                            }
                            Text(u.items.compactMap { dd.tftItems[$0]?.name }.joined(separator: ", "))
                                .font(.system(size: 11)).foregroundStyle(Theme.sub)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 설정

struct SettingsView: View {
    @AppStorage("overlayOn") var overlayOn = true
    @AppStorage("showPanel") var showPanel = true
    @AppStorage("showAugments") var showAugments = true
    @AppStorage("corner") var corner = "tl"
    @AppStorage("opacity") var opacity = 0.7
    @AppStorage("scale") var scale = 1.0
    var screenOK: Bool { CGPreflightScreenCaptureAccess() }  // 권한은 앱을 다시 켜야 반영돼서 매번 읽어도 됨

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("설정").font(.system(size: 22, weight: .bold))

                card("오버레이") {
                    Toggle("게임 위에 오버레이 띄우기", isOn: $overlayOn)
                    Toggle("빌드·메타 덱 패널", isOn: $showPanel).disabled(!overlayOn)
                    Toggle("증강체 등급 배지 (끄면 화면 읽기도 멈춤)", isOn: $showAugments).disabled(!overlayOn)
                }

                card("화면 기록 권한") {
                    // 증강체 화면을 읽을 때만 쓰는 권한이라 게임 중에 처음 묻게 되므로 여기서 미리 켤 수 있게
                    Text(screenOK ? "허용됨 — 증강체 화면을 읽을 수 있어요" : "아직 허용 안 됨 — 증강체 배지를 쓰려면 필요해요")
                        .foregroundStyle(screenOK ? Theme.tier(1) : .orange)
                    if !screenOK {
                        Button("권한 요청 · 시스템 설정 열기") {
                            CGRequestScreenCaptureAccess()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                        Text("시스템 설정에서 Riftsight 를 켠 뒤, 메뉴바 ◈ → 종료 후 다시 실행해 주세요.").font(.system(size: 12)).foregroundStyle(Theme.sub)
                    }
                }

                card("모양") {
                    Picker("패널 위치", selection: $corner) {
                        Text("왼쪽 위").tag("tl"); Text("오른쪽 위").tag("tr")
                        Text("왼쪽 아래").tag("bl"); Text("오른쪽 아래").tag("br")
                    }.pickerStyle(.segmented)
                    HStack {
                        Text("패널 배경 진하기")
                        Slider(value: $opacity, in: 0.2...1)
                        Text("\(Int(opacity * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    HStack {
                        Text("글자 크기")
                        Slider(value: $scale, in: 0.8...1.6, step: 0.1)
                        Text("\(Int(scale * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    preview
                }

                card("TFT 증강체 등급표") {
                    Text("증강체마다 S~D 를 직접 정해 두면 TFT 증강체 화면에 배지로 뜹니다.").font(.system(size: 12)).foregroundStyle(Theme.sub)
                    Button("등급표 열기") { (NSApp.delegate as? App)?.openTiers() }
                }

                card("정보") {
                    Text("버전 \(Updater.current ?? "개발용 실행")").foregroundStyle(Theme.sub)
                    Button("업데이트 확인") { Task { await Updater.check(manual: true) } }
                }
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }

    // 바꾼 값이 오버레이에서 어떻게 보이는지 미리 보기
    var preview: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            Text("말파이트 · top · 승률 52.0%").font(.system(size: 14 * scale, weight: .bold))
            Text("핵심  태양불꽃 방패 → 가시 갑옷 → 얼어붙은 심장").font(.system(size: 12 * scale))
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(opacity), in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.green.opacity(0.5), .brown.opacity(0.6)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 8))  // 게임 화면 대신 배경
    }

    func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.sub)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
    }
}
