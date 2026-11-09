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

    // 롤 빌드 카드 (한 줄씩)
    static func build(key: String, name: String, position: String) async -> [String] {
        var args: [String: Any] = [
            "game_mode": "ranked", "champion": key.uppercased(), "lang": "ko_KR",
            "desired_output_fields": [
                "data.summary.average_stats.{win_rate}",
                "data.runes.{primary_page_name,primary_rune_names[],secondary_page_name,secondary_rune_names[]}",
                "data.starter_items.{ids_names[]}", "data.core_items.{ids_names[]}",
                "data.boots.{ids_names[]}", "data.skills.{order[]}",
            ],
        ]
        if !position.isEmpty { args["position"] = position }
        guard let text = await call("lol_get_champion_analysis", args),
              let data = (parse(text) as? [String: Any])?["data"] as? [String: Any] else { return ["\(name): OP.GG 빌드를 불러오지 못했어요"] }
        func names(_ k: String) -> String { ((data[k] as? [String: Any])?["ids_names"] as? [String] ?? []).joined(separator: " → ") }
        var lines = [name + (position.isEmpty ? "" : " · \(position)")]
        if let w = ((data["summary"] as? [String: Any])?["average_stats"] as? [String: Any])?["win_rate"] as? Double {
            lines[0] += String(format: " · 승률 %.1f%%", w * 100)
        }
        if let r = data["runes"] as? [String: Any] {
            let p = (r["primary_rune_names"] as? [String] ?? []).joined(separator: ", ")
            let s = (r["secondary_rune_names"] as? [String] ?? []).joined(separator: ", ")
            lines.append("룬  \(r["primary_page_name"] as? String ?? ""): \(p) / \(r["secondary_page_name"] as? String ?? ""): \(s)")
        }
        lines.append("시작  " + names("starter_items"))
        lines.append("핵심  " + names("core_items"))
        lines.append("신발  " + names("boots"))
        if let o = (data["skills"] as? [String: Any])?["order"] as? [String] { lines.append("스킬  " + o.joined(separator: " ")) }
        return lines
    }

    // 영문 키(MonkeyKing) → 챔피언 번호. 증강체 조회가 번호로만 받는다
    static func championIds() async -> [String: Int] {
        guard let text = await call("lol_list_champions", ["desired_output_fields": ["data.champions[].{champion_id,key}"]]),
              let list = ((parse(text) as? [String: Any])?["data"] as? [String: Any])?["champions"] as? [[String: Any]] else { return [:] }
        return Dictionary(list.compactMap { c in (c["key"] as? String).flatMap { k in (c["champion_id"] as? Double).map { (k, Int($0)) } } },
                          uniquingKeysWith: { a, _ in a })
    }

    // 롤 증강체(무작위 총력전) 챔피언별 성능 → S~D 등급표
    static func lolAugments(championId: Int) async -> [String: AugmentOCR.Entry] {
        guard let text = await call("lol_list_aram_augments", [
            "champion_id": championId, "lang": "ko_KR", "desired_output_fields": ["data.augments[].{name,performance}"],
        ]), let list = ((parse(text) as? [String: Any])?["data"] as? [String: Any])?["augments"] as? [[String: Any]] else { return [:] }
        let scored = list.compactMap { a -> (String, Double)? in
            guard let n = a["name"] as? String, let p = a["performance"] as? Double, p > 0 else { return nil }  // 0 = 표본 없음
            return (n, p)
        }
        return grade(scored).mapValues { AugmentOCR.Entry(tier: $0.0, note: String(format: "성능 %.0f", $0.1)) }
    }

    // OP.GG 의 증강체 "tier" 는 희귀도라서, 성능 점수 순위(상위 15/40/70/90%)로 등급을 매긴다
    static func grade(_ scored: [(String, Double)]) -> [String: (String, Double)] {
        let sorted = scored.sorted { $0.1 > $1.1 }
        var out: [String: (String, Double)] = [:]
        for (i, (name, p)) in sorted.enumerated() {
            let r = Double(i) / Double(max(sorted.count, 1))
            out[name] = (r < 0.15 ? "S" : r < 0.40 ? "A" : r < 0.70 ? "B" : r < 0.90 ? "C" : "D", p)
        }
        return out
    }

    // TFT 메타 덱 상위 5개
    static func metaDecks() async -> [String] {
        guard let text = await call("tft_list_meta_decks", [:]),
              let j = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let decks = j["data"] as? [[String: Any]] else { return ["OP.GG 메타 덱을 불러오지 못했어요"] }
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
        let d = (parse(sample) as? [String: Any])?["data"] as? [String: Any]
        let core = (d?["core_items"] as? [String: Any])?["ids_names"] as? [String]
        assert(core == ["악의", "그림자\"불꽃"], "core items")
        assert(((d?["summary"] as? [String: Any])?["average_stats"] as? [String: Any])?["win_rate"] as? Double == 0.51, "win rate")
        assert((d?["runes"] as? [String: Any])?["primary_page_name"] as? String == "지배", "runes")
        let g = grade((1...20).map { ("a\($0)", Double($0)) })
        assert(g["a20"]?.0 == "S" && g["a18"]?.0 == "S" && g["a17"]?.0 == "A" && g["a1"]?.0 == "D", "grade")
        print("OPGG.parse self-test OK")
    }
}
