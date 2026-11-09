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

    static func json(_ url: String, auth: String? = nil) async -> Any? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        if let auth { req.setValue("Basic " + Data(auth.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
        guard let (d, r) = try? await session.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
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

    // 챔프 선택 중: (영문 키, 한글 이름, 라인). 챔피언을 아직 안 골랐으면 nil
    static func champSelect() async -> (key: String, name: String, position: String)? {
        guard let lock = try? String(contentsOfFile: lockfile, encoding: .utf8) else { return nil }
        let f = lock.split(separator: ":")
        guard f.count >= 5 else { return nil }
        let base = "https://127.0.0.1:\(f[2])", auth = "riot:\(f[3])"
        guard let s = await json(base + "/lol-champ-select/v1/session", auth: auth) as? [String: Any],
              let cell = s["localPlayerCellId"] as? Int,
              let me = (s["myTeam"] as? [[String: Any]])?.first(where: { $0["cellId"] as? Int == cell }) else { return nil }
        let id = (me["championId"] as? Int).flatMap { $0 > 0 ? $0 : nil } ?? (me["championPickIntent"] as? Int ?? 0)
        guard id > 0, let champs = await json(base + "/lol-game-data/assets/v1/champion-summary.json", auth: auth) as? [[String: Any]],
              let c = champs.first(where: { $0["id"] as? Int == id }) else { return nil }
        let pos = ["top": "top", "jungle": "jungle", "middle": "mid", "bottom": "adc", "utility": "support"][me["assignedPosition"] as? String ?? ""] ?? ""
        return (c["alias"] as? String ?? "", c["name"] as? String ?? "", pos)
    }
}
