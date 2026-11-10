import Foundation

// OP.GG 공식 MCP 서버(https://github.com/opgginc/opgg-mcp, MIT)에서 빌드·메타 덱을 받는다
enum OPGG {
    static let endpoint = URL(string: "https://mcp-api.op.gg/mcp")!

    static func call(_ tool: String, _ args: [String: Any]) async -> String? {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": args],
        ])
        guard let (d, _) = try? await URLSession.shared.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let content = (j["result"] as? [String: Any])?["content"] as? [[String: Any]] else { return nil }
        return content.first?["text"] as? String
    }

    // 챔피언 빌드 원본 (오버레이 카드·앱 상세 화면이 함께 씀)
    static func analysis(key: String, position: String) async -> [String: Any]? {
        let args: [String: Any] = [
            // 라인 없는 게임(무작위 총력전·KIWI·연습)은 무작위 총력전 빌드. OP.GG 가 position 을 꼭 받지만 aram 에선 값을 무시함
            "game_mode": position.isEmpty ? "aram" : "ranked", "position": position.isEmpty ? "mid" : position,
            "champion": key.uppercased(), "lang": "ko_KR",
            "desired_output_fields": [
                "data.summary.average_stats.{win_rate,tier,rank}",
                "data.core_items.{pick_rate,play,win}", "data.fourth_items[].{ids_names[],pick_rate,play,win}", "data.skill_masteries.{ids[]}",
                "data.runes.{primary_page_name,primary_rune_names[],secondary_page_name,secondary_rune_names[]}",
                "data.starter_items.{ids_names[]}", "data.core_items.{ids_names[]}",
                "data.boots.{ids_names[]}", "data.skills.{order[]}", "data.summoner_spells.{ids_names[]}",
            ],
        ]
        guard let text = await call("lol_get_champion_analysis", args) else { return nil }
        return (parse(text) as? [String: Any])?["data"] as? [String: Any]
    }

    // 롤 빌드 카드 (한 줄씩) + 추천 스펠 번호(챔프 선택 때 자동으로 넣음)
    static func build(key: String, name: String, position: String) async -> (lines: [String], spells: [Int], data: [String: Any]?) {
        guard let data = await analysis(key: key, position: position) else { return (["\(name): OP.GG 빌드를 불러오지 못했어요"], [], nil) }
        func names(_ k: String) -> String { ((data[k] as? [String: Any])?["ids_names"] as? [String] ?? []).joined(separator: " → ") }
        // shortcut: 아수라장(KIWI)도 OP.GG 에 따로 없어 무작위 총력전 통계로 보여 줌, OP.GG 가 모드를 추가하면 나누기
        var lines = [name + " · " + (position.isEmpty ? "무작위 총력전" : position)]
        let stats = (data["summary"] as? [String: Any])?["average_stats"] as? [String: Any]
        if let t = stats?["tier"] as? Double, let r = stats?["rank"] as? Double { lines[0] += " · \(Int(t))티어 \(Int(r))위" }
        if let w = stats?["win_rate"] as? Double { lines[0] += String(format: " · 승률 %.1f%%", w * 100) }
        if let r = data["runes"] as? [String: Any] {
            let p = (r["primary_rune_names"] as? [String] ?? []).joined(separator: ", ")
            let s = (r["secondary_rune_names"] as? [String] ?? []).joined(separator: ", ")
            lines.append("룬  \(r["primary_page_name"] as? String ?? ""): \(p) / \(r["secondary_page_name"] as? String ?? ""): \(s)")
        }
        lines.append("시작  " + names("starter_items"))
        lines.append("핵심  " + names("core_items"))
        lines.append("신발  " + names("boots"))
        // OP.GG 가 스펠은 이름 대신 번호로 줌 (롤 소환사 주문 번호, 거의 안 바뀜)
        let spell: [Int: String] = [1: "정화", 3: "탈진", 4: "점멸", 6: "유체화", 7: "회복", 11: "강타", 12: "순간이동", 13: "총명", 14: "점화", 21: "방어막", 32: "표식"]
        let ids = (data["summoner_spells"] as? [String: Any])?["ids_names"] as? [Double] ?? []
        if !ids.isEmpty { lines.append("스펠  " + ids.map { spell[Int($0)] ?? "\(Int($0))번" }.joined(separator: " + ")) }
        if let o = (data["skills"] as? [String: Any])?["order"] as? [String] { lines.append("스킬  " + o.joined(separator: " ")) }
        return (lines, ids.map { Int($0) }, data)
    }

    // 영문 키(MonkeyKing) → 챔피언 번호. 증강체 조회가 번호로만 받는다
    static func championIds() async -> [String: Int] {
        guard let text = await call("lol_list_champions", ["desired_output_fields": ["data.champions[].{champion_id,key}"]]),
              let list = ((parse(text) as? [String: Any])?["data"] as? [String: Any])?["champions"] as? [[String: Any]] else { return [:] }
        return Dictionary(list.compactMap { c in (c["key"] as? String).flatMap { k in (c["champion_id"] as? Double).map { (k, Int($0)) } } },
                          uniquingKeysWith: { a, _ in a })
    }

    // 롤 증강체(무작위 총력전) 챔피언별 S~D 등급 + 희귀도
    static func lolAugments(championId: Int) async -> [String: AugmentOCR.Entry] {
        guard let text = await call("lol_list_aram_augments", [
            "champion_id": championId, "lang": "ko_KR", "desired_output_fields": ["data.augments[].{name,performance,popular}"],
        ]), let list = ((parse(text) as? [String: Any])?["data"] as? [String: Any])?["augments"] as? [[String: Any]] else { return [:] }
        let rarity = await rarities()
        let scored = list.compactMap { a in (a["name"] as? String).flatMap { n in (a["performance"] as? Double).map { (n, $0, a["popular"] as? Double ?? 0) } } }
        let g = grades(scored.map(\.1))
        let pops = scored.map(\.2).sorted()
        let median = pops.isEmpty ? 0 : pops[pops.count / 2]
        let graded = Dictionary(zip(scored, g).map { s, t in
            (s.0, AugmentOCR.Entry(tier: t, note: rarity[s.0]?.rarity ?? "", blurb: blurb(t, popular: s.2 >= median), icon: rarity[s.0]?.icon))
        }, uniquingKeysWith: { a, _ in a })
        // OP.GG 는 성적 좋은(tier 3 이상) 증강체만 주므로, 나머지(아수라장 전용 포함)는 희귀도만 보이고 등급은 "자료 없음"
        let rest = rarity.filter { graded[$0.key] == nil }.mapValues { AugmentOCR.Entry(tier: "자료 없음", note: $0.rarity, blurb: "통계 부족", icon: $0.icon) }
        return graded.merging(rest) { a, _ in a }
    }

    // 등급(성능)과 선호도(이 챔피언 안 중앙값 이상인지)로 한 줄 평
    static func blurb(_ grade: String, popular: Bool) -> String {
        switch (["S", "A"].contains(grade), grade == "D", popular) {
        case (true, _, true): return "성능과 선호도가 모두 좋음"
        case (true, _, false): return "숨은 고성능 선택"
        case (_, true, _): return "성적이 낮은 편"
        case (_, _, true): return "자주 고르는 무난한 픽"
        default: return "안정적인 선택"
        }
    }

    // OP.GG 성능 점수를 이 챔피언 증강체 안에서 줄 세워 5등분 → S A B C D
    // shortcut: OP.GG 가 이미 걸러 낸(tier 3 이상) 증강체끼리의 상대 등급이라 D 도 나쁜 편은 아님, 절대 기준이 생기면 바꾸기
    static func grades(_ perf: [Double]) -> [String] {
        let order = perf.indices.sorted { perf[$0] > perf[$1] }
        var out = Array(repeating: "D", count: perf.count)
        for (rank, i) in order.enumerated() { out[i] = ["S", "A", "B", "C", "D"][rank * 5 / perf.count] }
        return out
    }

    // 증강체 희귀도(실버·골드·프리즘)는 OP.GG 데이터에 없어 Community Dragon(롤 게임 파일 공개본)에서 받는다
    // shortcut: 아레나용 희귀도 표라 무작위 총력전과 다른 증강체가 있으면 틀릴 수 있음, 어긋나면 모드별 표로 바꾸기
    static var rarityCache: [String: (rarity: String, icon: URL?)]?
    static func rarities() async -> [String: (rarity: String, icon: URL?)] {
        if let r = rarityCache { return r }
        var req = URLRequest(url: URL(string: "https://raw.communitydragon.org/latest/plugins/rcp-be-lol-game-data/global/ko_kr/v1/cherry-augments.json")!)
        req.setValue("Riftsight", forHTTPHeaderField: "User-Agent")  // 기본 User-Agent 는 403
        guard let (d, _) = try? await URLSession.shared.data(for: req),
              let list = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [:] }
        let ko = ["kSilver": "실버", "kGold": "골드", "kPrismatic": "프리즘"]
        // 아이콘 경로 /lol-game-data/assets/ASSETS/... → Community Dragon 의 소문자 주소
        func icon(_ p: String?) -> URL? {
            p.flatMap { URL(string: "https://raw.communitydragon.org/latest/plugins/rcp-be-lol-game-data/global/default/"
                                 + $0.replacingOccurrences(of: "/lol-game-data/assets/", with: "").lowercased()) }
        }
        let r = Dictionary(list.compactMap { a in
            (a["nameTRA"] as? String).flatMap { n in ko[a["rarity"] as? String ?? ""].map { (n, ($0, icon(a["augmentSmallIconPath"] as? String))) } }
        }, uniquingKeysWith: { a, _ in a })
        if !r.isEmpty { rarityCache = r }
        return r
    }

    // TFT 증강체 이름과 희귀도 (등급표 양식 만들기용)
    static func tftAugments() async -> [(name: String, rarity: String)] {
        guard let text = await call("tft_list_augments", ["lang": "ko_KR"]),
              let j = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let headers = j["headers"] as? [String], let rows = j["rows"] as? [[Any]],
              let ni = headers.firstIndex(of: "name"), let ti = headers.firstIndex(of: "tier") else { return [] }
        let ko = ["silver": "실버", "gold": "골드", "prism": "프리즘"]
        var seen = Set<String>()  // 같은 이름이 여러 번 나옴
        return rows.compactMap { r in
            guard let n = r[ni] as? String, seen.insert(n).inserted else { return nil }
            return (n, ko[r[ti] as? String ?? ""] ?? "")
        }
    }

    // 라인별 챔피언 티어: [{champion(한글), tier, rank, win_rate, pick_rate, ban_rate}]
    static func laneTiers(_ position: String) async -> [[String: Any]] {
        guard let text = await call("lol_list_lane_meta_champions", [
            "lang": "ko_KR", "position": position,
            "desired_output_fields": ["data.positions.\(position)[].{champion,tier,rank,win_rate,pick_rate,ban_rate}"],
        ]), let pos = ((parse(text) as? [String: Any])?["data"] as? [String: Any])?["positions"] as? [String: Any] else { return [] }
        return pos[position] as? [[String: Any]] ?? []
    }

    static func rawMetaDecks() async -> [[String: Any]] {
        guard let text = await call("tft_list_meta_decks", [:]),
              let j = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [] }
        return j["data"] as? [[String: Any]] ?? []
    }

    // 화면에서 읽은 내 시너지와 메타 덱을 비교: 내 시너지 한 줄 + 가장 많이 겹치는 덱 2개
    // shortcut: 시너지 이름만 비교(유닛 수·등급 무시), 화면 글자 인식이 시너지 목록을 놓치면 덱 추천도 빠짐
    static func closestDecks(seen: Set<String>, decks: [[String: Any]], name: (String) -> String?) -> (lines: [String], best: [String: Any]?) {
        guard !seen.isEmpty else { return ([], nil) }
        let mine = seen.compactMap(name).sorted()
        let scored = decks.map { d -> (deck: [String: Any], hit: Int, total: Int) in
            let active = (d["traits"] as? [[String: Any]] ?? []).filter { ($0["style"] as? Int ?? 0) > 0 }.compactMap { $0["key"] as? String }
            return (d, active.filter(seen.contains).count, active.count)
        }.filter { $0.hit > 0 }.sorted { $0.hit > $1.hit }
        return (["내 시너지  " + mine.joined(separator: ", ")] + scored.prefix(2).map { s in
            let deckName = (s.deck["name"] as? [String: Any])?["ko_KR"] as? String ?? "?"
            let core = (s.deck["units"] as? [[String: Any]] ?? []).filter { $0["isCore"] as? Bool == true }.compactMap { ($0["key"] as? String).flatMap(name) }
            return "가까운 덱  \(deckName) (시너지 \(s.hit)/\(s.total))" + (core.isEmpty ? "" : " · 핵심 " + core.joined(separator: ", "))
        }, scored.first?.deck)
    }

    // 덱 레벨별(4~10) 배치: 공식 창구에 없어 OP.GG 웹 덱 상세 페이지 안의 "buildUp" 자료를 읽는다 (비공식).
    // 레벨마다 가장 많이 쓰인 배치. 페이지 구조가 바뀌면 빈 값 → 공식 레벨 5·7·최종으로 돌아감
    static var buildUpCache: [String: TFTBoard.BuildUp] = [:]
    static func buildUp(deckId: String) async -> TFTBoard.BuildUp {
        if let hit = buildUpCache[deckId] { return hit }
        var req = URLRequest(url: URL(string: "https://op.gg/ko/tft/meta-trends/comps/\(deckId)")!)
        req.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        guard let (d, _) = try? await URLSession.shared.data(for: req), let html = String(data: d, encoding: .utf8) else { return [:] }
        let b = parseBuildUp(html)
        if !b.isEmpty { buildUpCache[deckId] = b }
        return b
    }

    static func parseBuildUp(_ html: String) -> TFTBoard.BuildUp {
        // 페이지 스크립트 안 JSON 은 \" 로 감싸져 있음
        let text = html.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        guard let start = text.range(of: "\"buildUp\":[")?.upperBound else { return [:] }
        // 짝 맞는 ] 까지 (문자열 안 괄호는 건너뜀)
        var depth = 1, inString = false, escaped = false, end = start
        for i in text[start...].indices {
            let c = text[i]
            if escaped { escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == "\"" { inString.toggle(); continue }
            if inString { continue }
            if c == "[" || c == "{" { depth += 1 } else if c == "]" || c == "}" { depth -= 1 }
            if depth == 0 { end = i; break }
        }
        guard depth == 0, let list = try? JSONSerialization.jsonObject(with: Data(("[" + text[start..<end] + "]").utf8)) as? [[String: Any]] else { return [:] }
        var best: [Int: (play: Int, units: [TFTBoard.Unit])] = [:]
        for b in list {
            guard let l = b["level"] as? Int, let units = b["units"] as? [[String: Any]] else { continue }
            let play = b["play"] as? Int ?? 0
            if play > best[l]?.play ?? -1 { best[l] = (play, units.compactMap(TFTBoard.unit)) }
        }
        return best.mapValues(\.units)
    }

    // TFT 메타 덱 상위 5개
    static func metaDecks() async -> [String] {
        let decks = await rawMetaDecks()
        if decks.isEmpty { return ["OP.GG 메타 덱을 불러오지 못했어요"] }
        return ["메타 덱 (OP.GG)"] + decks.prefix(5).map { d in
            let name = (d["name"] as? [String: Any])?["ko_KR"] as? String ?? "?"
            let stat = d["stat"] as? [String: Any]
            let deck = stat?["deck"] as? [String: Any]
            return String(format: "[%@] %@ · 평균 %.2f등 · 순방 %.0f%%",
                          stat?["opTier"] as? String ?? "-", name,
                          deck?["avgPlacement"] as? Double ?? 0, (deck?["top4Rate"] as? Double ?? 0) * 100)
        }
    }

    // OP.GG 롤 응답은 JSON 이 아니라 "class X: a,b" 머리말 + X(값, 값) 꼴이라 직접 푼다
    static func parse(_ text: String) -> Any? {
        var fields: [String: [String]] = [:]
        var body = ""
        for line in text.split(separator: "\n") {
            if line.hasPrefix("class "), let colon = line.firstIndex(of: ":") {
                let name = line[line.index(line.startIndex, offsetBy: 6)..<colon]
                fields[String(name)] = line[line.index(after: colon)...].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty { body = String(line) }
        }
        var s = Substring(body)
        return value(&s, fields)
    }

    private static func value(_ s: inout Substring, _ fields: [String: [String]]) -> Any? {
        s = s.drop(while: { $0 == " " })
        guard let c = s.first else { return nil }
        if c == "\"" {  // JSON 문자열 그대로
            var i = s.index(after: s.startIndex), esc = false
            while i < s.endIndex, esc || s[i] != "\"" { esc = !esc && s[i] == "\\"; i = s.index(after: i) }
            guard i < s.endIndex else { return nil }
            let lit = s[s.startIndex...i]
            s = s[s.index(after: i)...]
            return try? JSONSerialization.jsonObject(with: Data(lit.utf8), options: .fragmentsAllowed)
        }
        if c == "[" { s = s.dropFirst(); return list(&s, close: "]", fields) }
        if c.isLetter {
            let ident = String(s.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
            s = s.dropFirst(ident.count)
            if s.first == "(" {
                s = s.dropFirst()
                let args = list(&s, close: ")", fields)
                return Dictionary(zip(fields[ident] ?? [], args), uniquingKeysWith: { a, _ in a })
            }
            return ["true": true, "false": false][ident] as Any? ?? NSNull()
        }
        let num = s.prefix(while: { "-+.0123456789eE".contains($0) })
        s = s.dropFirst(num.count)
        return Double(num)
    }

    private static func list(_ s: inout Substring, close: Character, _ fields: [String: [String]]) -> [Any] {
        var out: [Any] = []
        while true {
            s = s.drop(while: { $0 == " " || $0 == "," })
            guard let c = s.first else { return out }
            if c == close { s = s.dropFirst(); return out }
            guard let v = value(&s, fields) else { return out }
            out.append(v)
        }
    }

    static func selfTest() {
        let sample = """
        class LolGetChampionAnalysis: data
        class Data: summary,core_items,runes
        class Summary: average_stats
        class AverageStats: win_rate,tier
        class CoreItems: ids_names,play,win
        class Runes: primary_page_name,primary_rune_names

        LolGetChampionAnalysis(Data(Summary(AverageStats(0.51,1)),CoreItems(["악의","그림자\\"불꽃"],7105,3852),Runes("지배",["감전","피의 맛"])))
        """
        assert(grades([70, 90, 80, 60, 50, 85, 75, 65, 55, 95]) == ["B", "S", "A", "C", "D", "A", "B", "C", "D", "S"], "grades")
        let decks: [[String: Any]] = [
            ["name": ["ko_KR": "햇빛 유나라"], "traits": [["key": "S", "style": 4], ["key": "E", "style": 1], ["key": "X", "style": 0]],
             "units": [["key": "U", "isCore": true], ["key": "V", "isCore": false]]],
            ["name": ["ko_KR": "다른 덱"], "traits": [["key": "Z", "style": 2]], "units": []],
        ]
        let names = ["S": "햇빛", "E": "처형자", "X": "엉뚱", "U": "유나라"]
        let near = closestDecks(seen: ["S", "X"], decks: decks, name: { names[$0] })
        assert(near.lines == ["내 시너지  엉뚱, 햇빛", "가까운 덱  햇빛 유나라 (시너지 1/2) · 핵심 유나라"], "closestDecks")
        assert((near.best?["name"] as? [String: Any])?["ko_KR"] as? String == "햇빛 유나라", "closest best")
        assert(closestDecks(seen: [], decks: decks, name: { names[$0] }).lines.isEmpty)
        let page = #"x self.__next_f.push([1,"{\"buildUp\":[{\"level\":4,\"play\":5,\"units\":[{\"key\":\"A\",\"star\":2,\"cell\":{\"x\":1,\"y\":2},\"items\":[],\"name\":\"[괄호]\"}]},{\"level\":4,\"play\":9,\"units\":[{\"key\":\"B\",\"star\":1,\"cell\":{\"x\":3,\"y\":4},\"items\":[\"I\"]}]}],\"x\":1}"])"#
        let bu = parseBuildUp(page)
        assert(bu.count == 1 && bu[4]?.first?.key == "B" && bu[4]?.first?.items == ["I"] && bu[4]?.first?.x == 3, "parseBuildUp \(bu)")
        assert(blurb("S", popular: true) == "성능과 선호도가 모두 좋음" && blurb("B", popular: true) == "자주 고르는 무난한 픽"
               && blurb("D", popular: true) == "성적이 낮은 편" && blurb("C", popular: false) == "안정적인 선택", "blurb")
        let d = (parse(sample) as? [String: Any])?["data"] as? [String: Any]
        let core = (d?["core_items"] as? [String: Any])?["ids_names"] as? [String]
        assert(core == ["악의", "그림자\"불꽃"], "core items")
        assert(((d?["summary"] as? [String: Any])?["average_stats"] as? [String: Any])?["win_rate"] as? Double == 0.51, "win rate")
        assert((d?["runes"] as? [String: Any])?["primary_page_name"] as? String == "지배", "runes")
        print("OPGG.parse self-test OK")
    }
}
