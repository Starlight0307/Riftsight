import Foundation

// 롤 클라이언트가 이 컴퓨터 안에서만 여는 공식 창구 두 곳을 읽는다 (게임 메모리는 건드리지 않음)
//  - 라이브 클라이언트(127.0.0.1:2999): 게임 중 정보
//  - LCU(lockfile 의 포트·비밀번호): 챔프 선택 정보
enum League {
    static let lockfile = "/Applications/League of Legends.app/Contents/LoL/lockfile"

    // 두 창구 모두 Riot 이 만든 자체 서명 인증서를 쓰므로, 127.0.0.1 에 한해서만 인증서를 믿는다
    final class LocalTrust: NSObject, URLSessionDelegate {
        func urlSession(_ s: URLSession, didReceive c: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if c.protectionSpace.host == "127.0.0.1", let t = c.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: t))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2
        return URLSession(configuration: cfg, delegate: LocalTrust(), delegateQueue: nil)
    }()

    static func json(_ url: String, auth: String? = nil, method: String = "GET", body: [String: Any]? = nil, array: [Any]? = nil) async -> Any? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.httpMethod = method
        if let payload = body.map({ $0 as Any }) ?? array.map({ $0 as Any }) {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        }
        if let auth { req.setValue("Basic " + Data(auth.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
        guard let (d, r) = try? await session.data(for: req), (200..<300).contains((r as? HTTPURLResponse)?.statusCode ?? 0) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) ?? [:]  // PATCH·PUT 은 빈 응답일 수 있음
    }

    // 게임 중: (모드, 내 챔피언 영문 키, 한글 이름, 라인, 원본 — 골드·억제기 등 계산용)
    static func liveGame() async -> (mode: String, key: String, name: String, position: String, all: [String: Any])? {
        guard let all = await json("https://127.0.0.1:2999/liveclientdata/allgamedata") as? [String: Any],
              let mode = (all["gameData"] as? [String: Any])?["gameMode"] as? String else { return nil }
        let me = (all["activePlayer"] as? [String: Any])?["riotId"] as? String
        let players = all["allPlayers"] as? [[String: Any]] ?? []
        guard let p = players.first(where: { $0["riotId"] as? String == me }) ?? players.first else { return (mode, "", "", "", all) }
        let raw = (p["rawChampionName"] as? String ?? "").replacingOccurrences(of: "game_character_displayname_", with: "")
        let pos = ["TOP": "top", "JUNGLE": "jungle", "MIDDLE": "mid", "BOTTOM": "adc", "UTILITY": "support"][p["position"] as? String ?? ""] ?? ""
        return (mode, raw, p["championName"] as? String ?? raw, pos, all)
    }

    // LCU 주소와 비밀번호 (클라이언트가 켜질 때마다 바뀜)
    static func lcu() -> (base: String, auth: String)? {
        guard let lock = try? String(contentsOfFile: lockfile, encoding: .utf8) else { return nil }
        let f = lock.split(separator: ":")
        guard f.count >= 5 else { return nil }
        return ("https://127.0.0.1:\(f[2])", "riot:\(f[3])")
    }

    // 챔프 선택 중: (영문 키, 한글 이름, 라인, 지금 스펠 두 개). 챔피언을 아직 안 골랐으면 nil
    static func champSelect() async -> (key: String, name: String, position: String, spells: [Int], champId: Int)? {
        guard let (base, auth) = lcu() else { return nil }
        guard let s = await json(base + "/lol-champ-select/v1/session", auth: auth) as? [String: Any],
              let cell = s["localPlayerCellId"] as? Int,
              let me = (s["myTeam"] as? [[String: Any]])?.first(where: { $0["cellId"] as? Int == cell }) else { return nil }
        let id = (me["championId"] as? Int).flatMap { $0 > 0 ? $0 : nil } ?? (me["championPickIntent"] as? Int ?? 0)
        guard id > 0, let champs = await json(base + "/lol-game-data/assets/v1/champion-summary.json", auth: auth) as? [[String: Any]],
              let c = champs.first(where: { $0["id"] as? Int == id }) else { return nil }
        let pos = ["top": "top", "jungle": "jungle", "middle": "mid", "bottom": "adc", "utility": "support"][me["assignedPosition"] as? String ?? ""] ?? ""
        return (c["alias"] as? String ?? "", c["name"] as? String ?? "", pos, [me["spell1Id"] as? Int ?? 0, me["spell2Id"] as? Int ?? 0], id)
    }

    // 로딩 화면: 아직 라이브 클라이언트가 안 열려서 LCU 게임 정보에서 (아군 챔피언 id, 적 챔피언 번호)
    static func loading() async -> (mine: [Int], theirs: [Int])? {
        guard let (base, auth) = lcu(),
              let g = await json(base + "/lol-gameflow/v1/session", auth: auth) as? [String: Any], g["phase"] as? String == "InProgress",
              let data = g["gameData"] as? [String: Any],
              let me = (await json(base + "/lol-summoner/v1/current-summoner", auth: auth) as? [String: Any])?["puuid"] as? String else { return nil }
        let one = data["teamOne"] as? [[String: Any]] ?? [], two = data["teamTwo"] as? [[String: Any]] ?? []
        func ids(_ t: [[String: Any]]) -> [Int] { t.compactMap { $0["championId"] as? Int } }
        return one.contains { $0["puuid"] as? String == me } ? (ids(one), ids(two)) : (ids(two), ids(one))
    }

    // 피해 유형 한 줄: 공식 공격·마법 점수로 팀별 물리 비율 추정
    static func damageLine(mine: [String], theirs: [String], _ info: (String) -> (ad: Int, ap: Int)?) -> String {
        func ad(_ t: [String]) -> Int {
            let s = t.compactMap(info).reduce((0, 0)) { ($0.0 + $1.ad, $0.1 + $1.ap) }
            return s.0 + s.1 == 0 ? 0 : s.0 * 100 / (s.0 + s.1)
        }
        let a = ad(mine), b = ad(theirs)
        return "피해  아군 물리 \(a)% 마법 \(100 - a)% · 적 물리 \(b)% 마법 \(100 - b)%"
    }

    // 골드 비교 창: 블루(ORDER)·레드 팀 아이템 골드와 라인별(같은 라인끼리, 라인 없으면 순서대로) 짝
    struct Gold: Equatable {
        var blue = 0, red = 0
        var lanes: [Lane] = []
        struct Lane: Equatable { let blueKey: String, blueGold: Int, redKey: String, redGold: Int }
    }

    // 게임 중 정보: 골드 비교 + 줄(회복·회복 감소, 억제기 타이머, 초반 피해 유형)
    typealias Item = (name: String, gold: Int, heal: Bool, antiHeal: Bool)
    static func info(_ all: [String: Any], item: (Int) -> Item?, champ: (String) -> (ad: Int, ap: Int)?) -> (gold: Gold?, lines: [String]) {
        let me = (all["activePlayer"] as? [String: Any])?["riotId"] as? String
        let players = all["allPlayers"] as? [[String: Any]] ?? []
        guard let myTeam = players.first(where: { $0["riotId"] as? String == me })?["team"] as? String else { return (nil, []) }
        let time = (all["gameData"] as? [String: Any])?["gameTime"] as? Double ?? 0
        let mine = players.filter { $0["team"] as? String == myTeam }, theirs = players.filter { $0["team"] as? String != myTeam }
        func items(_ t: [[String: Any]]) -> [(Item, Int)] {
            t.flatMap { $0["items"] as? [[String: Any]] ?? [] }.compactMap { i in
                (i["itemID"] as? Int).flatMap(item).map { ($0, i["count"] as? Int ?? 1) }
            }
        }
        func gold(_ t: [[String: Any]]) -> Int { items(t).reduce(0) { $0 + $1.0.gold * $1.1 } }
        func key(_ p: [String: Any]) -> String { (p["rawChampionName"] as? String ?? "").replacingOccurrences(of: "game_character_displayname_", with: "") }
        let order = ["TOP", "JUNGLE", "MIDDLE", "BOTTOM", "UTILITY"]
        func lane(_ t: [[String: Any]]) -> [[String: Any]] { t.sorted { (order.firstIndex(of: $0["position"] as? String ?? "") ?? 9) < (order.firstIndex(of: $1["position"] as? String ?? "") ?? 9) } }
        let blue = lane(players.filter { $0["team"] as? String == "ORDER" }), red = lane(players.filter { $0["team"] as? String != "ORDER" })
        var g = Gold(blue: gold(blue), red: gold(red))
        g.lanes = zip(blue, red).map { Gold.Lane(blueKey: key($0), blueGold: gold([$0]), redKey: key($1), redGold: gold([$1])) }
        var out: [String] = []

        func uniq(_ xs: [String]) -> String { xs.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", ") }
        let heal = uniq(items(theirs).filter { $0.0.heal }.map { $0.0.name })
        let anti = uniq(items(mine).filter { $0.0.antiHeal }.map { $0.0.name })
        if !heal.isEmpty || !anti.isEmpty { out.append("회복  적: \(heal.isEmpty ? "없음" : heal) · 아군 회복 감소: \(anti.isEmpty ? "없음" : anti)") }

        // 억제기는 5분 뒤 다시 생김. 이름 예: Barracks_T2_C1 (T1=블루 ORDER, L1 탑 C1 미드 R1 봇)
        var down: [String: Double] = [:]
        for e in (all["events"] as? [String: Any])?["Events"] as? [[String: Any]] ?? [] {
            if e["EventName"] as? String == "InhibKilled", let n = e["InhibKilled"] as? String, let t = e["EventTime"] as? Double { down[n] = t }
            if e["EventName"] as? String == "InhibRespawned", let n = e["InhibRespawned"] as? String { down[n] = nil }
        }
        let inhib = down.compactMap { n, t -> (String, Double)? in
            let left = 300 - (time - t)
            guard left > 0 else { return nil }
            let team = n.contains("_T1_") == (myTeam == "ORDER") ? "아군" : "적"
            // 칼바람(맵 12)은 길이 하나라 라인 이름을 붙이지 않음
            let lane = (all["gameData"] as? [String: Any])?["mapNumber"] as? Int == 12 ? "억제기" : n.contains("_L1") ? "탑" : n.contains("_C1") ? "미드" : "봇"
            return ("\(team) \(lane) \(Int(left) / 60):\(String(format: "%02d", Int(left) % 60))", left)
        }.sorted { $0.1 < $1.1 }.map(\.0)
        if !inhib.isEmpty { out.append("억제기  " + inhib.joined(separator: " · ")) }

        if time < 90 {
            func keys(_ t: [[String: Any]]) -> [String] { t.compactMap { ($0["rawChampionName"] as? String)?.replacingOccurrences(of: "game_character_displayname_", with: "") } }
            out.append(damageLine(mine: keys(mine), theirs: keys(theirs), champ))
        }
        return (g, out)
    }

    // 내 스펠 바꾸기 (롤 클라이언트 공식 창구). 성공하면 true
    static func setSpells(_ s: [Int]) async -> Bool {
        guard s.count == 2, let (base, auth) = lcu() else { return false }
        return await json(base + "/lol-champ-select/v1/session/my-selection", auth: auth, method: "PATCH", body: ["spell1Id": s[0], "spell2Id": s[1]]) != nil
    }

    // TFT 덱을 클라이언트 팀 플래너에 추가 (클라이언트 '팀 코드 붙여넣기'와 같은 결과, 이름은 덱 이름)
    static func addTFTTeam(set: String, name: String, champions: [String]) async -> Bool {
        guard !champions.isEmpty, let (base, auth) = lcu(),
              let n = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) else { return false }
        let b = base + "/lol-tft-team-planner/v1/sets/\(set)", id = UUID().uuidString.lowercased()
        guard await json(b + "/teams/\(id)/import", auth: auth, method: "POST", body: nil, array: champions) != nil else { return false }
        _ = await json(b + "/teams/\(id)/\(n)", auth: auth, method: "PATCH")
        return await json(base + "/lol-tft-team-planner/v1/sets/push-to-server", auth: auth, method: "POST") != nil
    }

    // 덱 팀 코드 끝의 세트 이름 (…TFTSet18 → TFTSet18)
    static func tftSet(_ teamCode: String) -> String? { teamCode.range(of: "TFTSet").map { String(teamCode[$0.lowerBound...]) } }

    // 추천 아이템 세트를 클라이언트 상점에 넣기. 사용자가 만든 세트는 그대로 두고 Riftsight 세트(uid riftsight-) 하나만 바꿈
    static func setItemSet(champId: Int, map: Int, title: String, blocks: [(title: String, ids: [Int])]) async -> Bool {
        guard !blocks.isEmpty, let (base, auth) = lcu(),
              let sid = (await json(base + "/lol-summoner/v1/current-summoner", auth: auth) as? [String: Any])?["summonerId"] as? Int,
              var all = await json(base + "/lol-item-sets/v1/item-sets/\(sid)/sets", auth: auth) as? [String: Any] else { return false }
        all["itemSets"] = itemSets(all["itemSets"] as? [[String: Any]] ?? [], champId: champId, map: map, title: title, blocks: blocks)
        return await json(base + "/lol-item-sets/v1/item-sets/\(sid)/sets", auth: auth, method: "PUT", body: all) != nil
    }

    static func itemSets(_ old: [[String: Any]], champId: Int, map: Int, title: String, blocks: [(title: String, ids: [Int])]) -> [[String: Any]] {
        old.filter { !($0["uid"] as? String ?? "").hasPrefix("riftsight-") } + [[
            "title": title, "type": "custom", "map": "any", "mode": "any", "startedFrom": "blank", "sortrank": 0,
            "uid": "riftsight-\(champId)", "associatedChampions": [champId], "associatedMaps": [map], "preferredItemSlots": [] as [Any],
            "blocks": blocks.map { b in
                ["type": b.title, "hideIfSummonerSpell": "", "showIfSummonerSpell": "", "items": b.ids.map { ["id": "\($0)", "count": 1] }] as [String: Any]
            },
        ]]
    }

    // 추천 스펠을 넣되, 점멸은 지금 쓰던 칸(D/F)에 그대로 둔다
    static func arrange(_ rec: [Int], current: [Int]) -> [Int] {
        guard rec.count == 2, let want = current.firstIndex(of: 4), let have = rec.firstIndex(of: 4), want != have else { return rec }
        return rec.reversed()
    }

    static func selfTest() {
        assert(arrange([4, 14], current: [14, 4]) == [14, 4], "flash on F")
        assert(arrange([4, 14], current: [4, 7]) == [4, 14], "flash already on D")
        assert(arrange([6, 14], current: [7, 4]) == [6, 14], "no flash recommended")
        assert(arrange([4, 6], current: [7, 3]) == [4, 6], "no flash now")
        let all: [String: Any] = [
            "activePlayer": ["riotId": "나#KR1"],
            "gameData": ["gameTime": 400.0],
            "allPlayers": [
                ["riotId": "나#KR1", "team": "ORDER", "rawChampionName": "game_character_displayname_Jinx", "items": [["itemID": 3123, "count": 1]]],
                ["riotId": "적#KR1", "team": "CHAOS", "rawChampionName": "game_character_displayname_Lux", "items": [["itemID": 3072, "count": 1], ["itemID": 2003, "count": 2]]],
            ],
            "events": ["Events": [
                ["EventName": "InhibKilled", "InhibKilled": "Barracks_T2_C1", "EventTime": 200.0],
                ["EventName": "InhibKilled", "InhibKilled": "Barracks_T1_L1", "EventTime": 50.0],
            ]],
        ]
        let items: [Int: Item] = [3123: ("처형인의 대검", 800, false, true), 3072: ("피바라기", 3400, true, false), 2003: ("체력 물약", 50, false, false)]
        let (g, lines) = info(all, item: { items[$0] }, champ: { ["Jinx": (9, 4), "Lux": (2, 9)][$0] })
        assert(g == Gold(blue: 800, red: 3500, lanes: [.init(blueKey: "Jinx", blueGold: 800, redKey: "Lux", redGold: 3500)]), "\(String(describing: g))")
        assert(lines == ["회복  적: 피바라기 · 아군 회복 감소: 처형인의 대검", "억제기  적 미드 1:40"], "\(lines)")
        assert(damageLine(mine: ["Jinx"], theirs: ["Lux"], { ["Jinx": (9, 4), "Lux": (2, 9)][$0] }) == "피해  아군 물리 69% 마법 31% · 적 물리 18% 마법 82%")
        let sets = itemSets([["uid": "mine", "title": "내 세트"], ["uid": "riftsight-1", "title": "옛 세트"]], champId: 141, map: 12, title: "새", blocks: [("시작", [1055, 2003])])
        assert(sets.count == 2 && sets[0]["uid"] as? String == "mine" && sets[1]["uid"] as? String == "riftsight-141", "itemSets keep user sets")
        assert(((sets[1]["blocks"] as? [[String: Any]])?.first?["items"] as? [[String: Any]])?.first?["id"] as? String == "1055", "itemSets ids")
        assert(tftSet("0241143a40740a41042743b3f1000000TFTSet18") == "TFTSet18" && tftSet("abc") == nil, "tftSet")
        print("League self-test OK")
    }
}
