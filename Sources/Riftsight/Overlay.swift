import SwiftUI

// 게임 위 오버레이: 짙은 남색 반투명 창 + 청록 강조, 기능마다 창 하나(추천 빌드·골드 비교·게임 정보), 증강체는 카드 위 띠
enum OV {
    static let bg = Color(red: 0.06, green: 0.08, blue: 0.12)
    static let box = Color.white.opacity(0.04)
    static let stroke = Color.white.opacity(0.09)
    static let teal = Color(red: 0.24, green: 0.83, blue: 0.71)
    static let blue = Color(red: 0.35, green: 0.58, blue: 1)
    static let red = Color(red: 1, green: 0.38, blue: 0.45)
    static let sub = Color.white.opacity(0.5)

    static func grade(_ t: String) -> Color {
        ["S": Color(red: 1, green: 0.55, blue: 0.25), "A": blue, "B": teal, "C": Color(white: 0.7), "D": Color(white: 0.45)][t] ?? Color(white: 0.45)
    }
    static func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "-" }
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
                if showPanel && (model.card != nil || !model.lines.isEmpty) {
                    let top = corner.hasPrefix("t"), left = corner.hasSuffix("l")
                    VStack(alignment: .leading, spacing: 10 * scale) {
                        if let c = model.card {
                            Panel(title: "추천 빌드", scale: scale, opacity: opacity) { BuildPanel(info: c, scale: scale) }
                            if let g = model.gold { Panel(title: "골드 비교", scale: scale, opacity: opacity) { GoldPanel(gold: g, scale: scale) } }
                            if !model.info.isEmpty {
                                Panel(title: "게임 정보", scale: scale, opacity: opacity) {
                                    VStack(alignment: .leading, spacing: 6 * scale) {
                                        ForEach(model.info, id: \.self) { Text($0).font(.system(size: 11 * scale, weight: .medium)) }
                                    }
                                }
                            }
                        } else {
                            Panel(title: model.lines.first ?? "", scale: scale, opacity: opacity) {
                                VStack(alignment: .leading, spacing: 6 * scale) {
                                    ForEach(Array(model.lines.dropFirst().enumerated()), id: \.offset) { Text($1).font(.system(size: 11 * scale, weight: .medium)) }
                                }
                            }
                        }
                    }
                    .foregroundStyle(.white)
                    // 위쪽은 게임 상단 정보, 아래쪽은 미니맵·상점을 피하도록 여백
                    .padding(left ? .leading : .trailing, 16)
                    .padding(top ? .top : .bottom, top ? 90 : 120)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: Alignment(horizontal: left ? .leading : .trailing, vertical: top ? .top : .bottom))
                }
                let best = model.augments.filter { ["S", "A"].contains($0.tier) }.min { $0.tier < $1.tier }
                ForEach(model.augments) { a in
                    AugmentBand(hit: a, recommended: a.id == best?.id, scale: scale, width: geo.size.height * 0.29)
                        // shortcut: 카드 위치는 이름 줄에서 화면 높이 비율로 추정(롤 증강체 카드 기준, 3440×1440 에서 잼), TFT 카드는 어긋날 수 있음
                        .position(x: a.box.midX * geo.size.width,
                                  y: (1 - a.box.midY) * geo.size.height - geo.size.height * 0.226 - 30 * scale)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// 창 하나: 제목 줄 + 내용
struct Panel<C: View>: View {
    let title: String, scale: Double, opacity: Double
    @ViewBuilder let content: C
    var s: CGFloat { CGFloat(scale) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10 * s) {
            HStack(spacing: 8 * s) {
                Text("◈").font(.system(size: 11 * s, weight: .heavy)).foregroundStyle(OV.teal)
                    .padding(.horizontal, 6 * s).padding(.vertical, 2 * s)
                    .background(OV.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(OV.teal.opacity(0.5)))
                Text(title).font(.system(size: 14 * s, weight: .bold))
            }
            content
        }
        .padding(14 * s)
        .frame(width: 300 * s, alignment: .leading)
        .background(OV.bg.opacity(opacity), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(OV.stroke))
    }
}

// 창 안의 구역 상자
struct Box<C: View>: View {
    let title: String?, scale: Double
    var trailing: String? = nil
    @ViewBuilder let content: C
    var s: CGFloat { CGFloat(scale) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8 * s) {
            if let title {
                HStack {
                    Text(title).foregroundStyle(OV.sub)
                    Spacer()
                    if let trailing { Text(trailing) }
                }.font(.system(size: 11 * s, weight: .bold))
            }
            content
        }
        .padding(10 * s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OV.box, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(OV.stroke))
    }
}

// WR 59.1% 같은 알약 표시
struct Chip: View {
    let label: String, value: String, scale: Double
    var accent = false
    var body: some View {
        let s = CGFloat(scale)
        (Text(label + " ").foregroundColor(accent ? OV.teal : OV.sub) + Text(value))
            .font(.system(size: 11 * s, weight: .bold))
            .padding(.horizontal, 8 * s).padding(.vertical, 4 * s)
            .background(OV.box, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(accent ? OV.teal.opacity(0.6) : OV.stroke))
    }
}

struct BuildPanel: View {
    struct Info { let key: String, name: String, position: String, data: [String: Any] }
    let info: Info
    var scale: Double = 1
    @ObservedObject private var dd = DDragon.shared

    var s: CGFloat { CGFloat(scale) }
    var d: [String: Any] { info.data }
    var stats: [String: Any]? { (d["summary"] as? [String: Any])?["average_stats"] as? [String: Any] }
    var core: [String: Any] { d["core_items"] as? [String: Any] ?? [:] }
    var fourth: [[String: Any]] { d["fourth_items"] as? [[String: Any]] ?? [] }
    func names(_ x: [String: Any]?) -> [String] { x?["ids_names"] as? [String] ?? [] }
    func wr(_ x: [String: Any]) -> Double? { (x["win"] as? Double).flatMap { w in (x["play"] as? Double).map { $0 > 0 ? w / $0 : 0 } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * s) {
            HStack(spacing: 10 * s) {
                Icon(url: dd.championById(info.key), size: 38 * s)
                VStack(alignment: .leading, spacing: 3 * s) {
                    HStack(spacing: 6 * s) {
                        Text(info.name).font(.system(size: 14 * s, weight: .bold))
                        if let t = stats?["tier"] as? Double {
                            Text("\(Int(t))티어").font(.system(size: 10 * s, weight: .bold))
                                .padding(.horizontal, 5 * s).padding(.vertical, 2 * s)
                                .background(Theme.tier(Int(t)), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Text([LoLView.lanes.first { $0.0 == info.position }?.1 ?? "무작위 총력전",
                          (stats?["rank"] as? Double).map { "\(Int($0))위" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11 * s)).foregroundStyle(OV.sub)
                }
            }
            Box(title: "추천 빌드", scale: scale) {
                HStack(spacing: 6 * s) {
                    Chip(label: "WR", value: OV.pct(wr(core)), scale: scale, accent: true)
                    Chip(label: "PR", value: OV.pct(core["pick_rate"] as? Double), scale: scale)
                }
                items(names(core) + names(fourth.first).prefix(1), size: 30, arrows: true)
            }
            if fourth.count > 1 {
                Box(title: "다른 빌드", scale: scale) {
                    ForEach(Array(fourth.dropFirst().prefix(3).enumerated()), id: \.offset) { _, f in
                        HStack(spacing: 4 * s) {
                            items(names(core) + names(f), size: 22)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1 * s) {
                                Text("WR " + OV.pct(wr(f)))
                                Text("PR " + OV.pct(f["pick_rate"] as? Double)).foregroundStyle(OV.sub)
                            }.font(.system(size: 10 * s, weight: .bold))
                        }
                    }
                }
            }
            Box(title: "시작 · 신발 · 스펠", scale: scale) {
                HStack(spacing: 4 * s) {
                    items(names(d["starter_items"] as? [String: Any]) + names(d["boots"] as? [String: Any]), size: 24)
                    ForEach(((d["summoner_spells"] as? [String: Any])?["ids_names"] as? [Double] ?? []).map(Int.init), id: \.self) {
                        Icon(url: dd.spell($0), size: 24 * s)
                    }
                }
            }
            if let r = d["runes"] as? [String: Any] {
                Box(title: "룬", scale: scale) {
                    HStack(spacing: 4 * s) {
                        ForEach((r["primary_rune_names"] as? [String] ?? []) + (r["secondary_rune_names"] as? [String] ?? []), id: \.self) {
                            Icon(url: dd.rune($0), size: 24 * s)
                        }
                    }
                }
            }
            if let o = (d["skills"] as? [String: Any])?["order"] as? [String] {
                let master = (d["skill_masteries"] as? [String: Any])?["ids"] as? [String] ?? []
                Box(title: "스킬", scale: scale, trailing: master.isEmpty ? nil : master.joined(separator: " › ")) {
                    HStack(spacing: 2 * s) {
                        ForEach(Array(o.prefix(15).enumerated()), id: \.offset) { _, k in
                            Text(k).font(.system(size: 9 * s, weight: .bold)).frame(width: 15 * s, height: 15 * s)
                                .background(k == "R" ? OV.teal.opacity(0.8) : OV.box, in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                }
            }
        }
    }

    func items(_ names: [String], size: CGFloat, arrows: Bool = false) -> some View {
        HStack(spacing: 4 * s) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                if i > 0 && arrows { Text("▸").font(.system(size: 9 * s)).foregroundStyle(OV.teal) }
                Icon(url: dd.item(n), size: size * s)
            }
        }
    }
}

struct GoldPanel: View {
    let gold: League.Gold
    var scale: Double = 1
    @ObservedObject private var dd = DDragon.shared
    var s: CGFloat { CGFloat(scale) }

    var body: some View {
        let diff = gold.blue - gold.red
        VStack(alignment: .leading, spacing: 8 * s) {
            Box(title: "팀 골드", scale: scale) {
                HStack(spacing: 8 * s) {
                    team("블루", gold.blue, OV.blue, .leading)
                    Text((diff >= 0 ? "◂ " : "") + "\(abs(diff))" + (diff < 0 ? " ▸" : ""))
                        .font(.system(size: 12 * s, weight: .bold)).foregroundStyle(diff >= 0 ? OV.blue : OV.red)
                    team("레드", gold.red, OV.red, .trailing)
                }
                bar(gold.blue, gold.red, height: 6)
            }
            Box(title: "라인별 골드", scale: scale, trailing: diff == 0 ? nil : diff > 0 ? "블루 우세" : "레드 우세") {
                ForEach(Array(gold.lanes.enumerated()), id: \.offset) { _, l in
                    HStack(spacing: 6 * s) {
                        Icon(url: dd.championById(l.blueKey), size: 20 * s)
                        VStack(spacing: 2 * s) {
                            HStack {
                                Text("\(l.blueGold)").foregroundStyle(OV.blue)
                                Spacer()
                                Text("\(l.redGold)").foregroundStyle(OV.red)
                            }.font(.system(size: 10 * s, weight: .bold))
                            bar(l.blueGold, l.redGold, height: 3)
                        }
                        Icon(url: dd.championById(l.redKey), size: 20 * s)
                    }
                }
            }
        }
    }

    func team(_ name: String, _ g: Int, _ c: Color, _ align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 2 * s) {
            Text(name).font(.system(size: 10 * s, weight: .bold)).foregroundStyle(c)
            Text("\(g)").font(.system(size: 17 * s, weight: .heavy))
        }
        .padding(8 * s).frame(maxWidth: .infinity, alignment: Alignment(horizontal: align, vertical: .center))
        .background(c.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(c.opacity(0.5)))
    }

    func bar(_ a: Int, _ b: Int, height: CGFloat) -> some View {
        GeometryReader { g in
            let f = a + b == 0 ? 0.5 : CGFloat(a) / CGFloat(a + b)
            HStack(spacing: 0) {
                OV.blue.frame(width: g.size.width * f)
                OV.red
            }.clipShape(Capsule())
        }.frame(height: height * s)
    }
}

// 증강체 카드 위 띠: 아이콘 · 이름(추천) · 한 줄 평 · 등급 칸
struct AugmentBand: View {
    let hit: AugmentHit, recommended: Bool, scale: Double, width: CGFloat
    var s: CGFloat { CGFloat(scale) }
    var graded: Bool { hit.tier.count == 1 }
    var body: some View {
        HStack(spacing: 8 * s) {
            if hit.icon != nil { Icon(url: hit.icon, size: 26 * s) }
            VStack(alignment: .leading, spacing: 2 * s) {
                HStack(spacing: 5 * s) {
                    Text(hit.name).font(.system(size: 12 * s, weight: .bold)).lineLimit(1)
                    if recommended {
                        Text("추천").font(.system(size: 9 * s, weight: .bold)).foregroundStyle(OV.teal)
                            .padding(.horizontal, 5 * s).padding(.vertical, 1 * s)
                            .background(OV.teal.opacity(0.15), in: Capsule())
                    }
                }
                Text([hit.note, hit.blurb].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 10 * s)).foregroundStyle(OV.sub).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(graded ? hit.tier : "-").font(.system(size: 13 * s, weight: .heavy)).foregroundStyle(OV.grade(hit.tier))
                .frame(width: 26 * s, height: 26 * s)
                .background(OV.grade(hit.tier).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(OV.grade(hit.tier).opacity(0.7)))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10 * s).padding(.vertical, 7 * s)
        .frame(width: width)
        .background(OV.bg.opacity(0.94), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(recommended ? OV.grade(hit.tier).opacity(0.8) : OV.stroke))
    }
}
