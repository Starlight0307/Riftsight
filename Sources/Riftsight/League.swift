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

    static func json(_ url: String, auth: String? = nil, patch: [String: Any]? = nil) async -> Any? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        if let patch {
            req.httpMethod = "PATCH"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: patch)
        }
        if let auth { req.setValue("Basic " + Data(auth.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
        guard let (d, r) = try? await session.data(for: req), (200..<300).contains((r as? HTTPURLResponse)?.statusCode ?? 0) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) ?? [:]  // PATCH 는 빈 응답일 수 있음
    }

    // 게임 중: (모드, 내 챔피언 영문 키, 한글 이름, 라인)
    static func liveGame() async -> (mode: String, key: String, name: String, position: String)? {
        guard let all = await json("https://127.0.0.1:2999/liveclientdata/allgamedata") as? [String: Any],
              let mode = (all["gameData"] as? [String: Any])?["gameMode"] as? String else { return nil }
        let me = (all["activePlayer"] as? [String: Any])?["riotId"] as? String
        let players = all["allPlayers"] as? [[String: Any]] ?? []
        guard let p = players.first(where: { $0["riotId"] as? String == me }) ?? players.first else { return (mode, "", "", "") }
        let raw = (p["rawChampionName"] as? String ?? "").replacingOccurrences(of: "game_character_displayname_", with: "")
        let pos = ["TOP": "top", "JUNGLE": "jungle", "MIDDLE": "mid", "BOTTOM": "adc", "UTILITY": "support"][p["position"] as? String ?? ""] ?? ""
        return (mode, raw, p["championName"] as? String ?? raw, pos)
    }

    // LCU 주소와 비밀번호 (클라이언트가 켜질 때마다 바뀜)
    static func lcu() -> (base: String, auth: String)? {
        guard let lock = try? String(contentsOfFile: lockfile, encoding: .utf8) else { return nil }
        let f = lock.split(separator: ":")
        guard f.count >= 5 else { return nil }
        return ("https://127.0.0.1:\(f[2])", "riot:\(f[3])")
    }

    // 챔프 선택 중: (영문 키, 한글 이름, 라인, 지금 스펠 두 개). 챔피언을 아직 안 골랐으면 nil
    static func champSelect() async -> (key: String, name: String, position: String, spells: [Int])? {
        guard let (base, auth) = lcu() else { return nil }
        guard let s = await json(base + "/lol-champ-select/v1/session", auth: auth) as? [String: Any],
              let cell = s["localPlayerCellId"] as? Int,
              let me = (s["myTeam"] as? [[String: Any]])?.first(where: { $0["cellId"] as? Int == cell }) else { return nil }
        let id = (me["championId"] as? Int).flatMap { $0 > 0 ? $0 : nil } ?? (me["championPickIntent"] as? Int ?? 0)
        guard id > 0, let champs = await json(base + "/lol-game-data/assets/v1/champion-summary.json", auth: auth) as? [[String: Any]],
              let c = champs.first(where: { $0["id"] as? Int == id }) else { return nil }
        let pos = ["top": "top", "jungle": "jungle", "middle": "mid", "bottom": "adc", "utility": "support"][me["assignedPosition"] as? String ?? ""] ?? ""
        return (c["alias"] as? String ?? "", c["name"] as? String ?? "", pos, [me["spell1Id"] as? Int ?? 0, me["spell2Id"] as? Int ?? 0])
    }

    // 내 스펠 바꾸기 (롤 클라이언트 공식 창구). 성공하면 true
    static func setSpells(_ s: [Int]) async -> Bool {
        guard s.count == 2, let (base, auth) = lcu() else { return false }
        return await json(base + "/lol-champ-select/v1/session/my-selection", auth: auth, patch: ["spell1Id": s[0], "spell2Id": s[1]]) != nil
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
        print("League self-test OK")
    }
}
