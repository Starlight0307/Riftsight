import Foundation

// Riot 공식 이미지 서버(Data Dragon)에서 한글 이름 → 아이콘 주소를 찾는다
@MainActor final class DDragon: ObservableObject {
    static let shared = DDragon()
    @Published private(set) var ready = false
    private var version = ""
    private var champs: [String: String] = [:]  // 한글 이름 → 영문 id(MonkeyKing)
    private var items: [String: String] = [:]   // 한글 이름 → 이미지 파일
    private var runes: [String: String] = [:]   // 한글 이름 → 아이콘 경로
    private var spells: [Int: String] = [:]     // 소환사 주문 번호(4=점멸) → 이미지 파일
    private(set) var itemInfo: [Int: (name: String, gold: Int, heal: Bool, antiHeal: Bool)] = [:]  // 아이템 번호 → 골드 비교·회복 정보용
    private(set) var champInfo: [String: (ad: Int, ap: Int)] = [:]  // 영문 id → 공식 공격·마법 점수(1~10)
    private(set) var champIdByKey: [Int: String] = [:]               // 챔피언 번호(222) → 영문 id(Jinx)

    func load() async {
        guard !ready, let v = (await get("https://ddragon.leagueoflegends.com/api/versions.json") as? [String])?.first else { return }
        version = v
        let base = "https://ddragon.leagueoflegends.com/cdn/\(v)/data/ko_KR"
        if let c = (await get(base + "/champion.json") as? [String: Any])?["data"] as? [String: [String: Any]] {
            for (id, info) in c {
                if let n = info["name"] as? String { champs[n] = id }
                if let k = (info["key"] as? String).flatMap(Int.init) { champIdByKey[k] = id }
                if let i = info["info"] as? [String: Int] { champInfo[id] = (i["attack"] ?? 0, i["magic"] ?? 0) }
            }
        }
        if let i = (await get(base + "/item.json") as? [String: Any])?["data"] as? [String: [String: Any]] {
            for (id, info) in i {
                if let n = info["name"] as? String, let f = (info["image"] as? [String: Any])?["full"] as? String { items[n] = f }
                if let k = Int(id), let n = info["name"] as? String {
                    let tags = Set(info["tags"] as? [String] ?? [])
                    itemInfo[k] = (n, (info["gold"] as? [String: Any])?["total"] as? Int ?? 0, !tags.isDisjoint(with: ["LifeSteal", "SpellVamp"]),
                                   (info["description"] as? String ?? "").contains("고통스러운 상처"))
                }
            }
        }
        if let trees = await get(base + "/runesReforged.json") as? [[String: Any]] {
            for t in trees {
                if let n = t["name"] as? String, let ic = t["icon"] as? String { runes[n] = ic }
                for slot in t["slots"] as? [[String: Any]] ?? [] {
                    for r in slot["runes"] as? [[String: Any]] ?? [] {
                        if let n = r["name"] as? String, let ic = r["icon"] as? String { runes[n] = ic }
                    }
                }
            }
        }
        if let s = (await get(base + "/summoner.json") as? [String: Any])?["data"] as? [String: [String: Any]] {
            for info in s.values {
                if let k = (info["key"] as? String).flatMap(Int.init), let f = (info["image"] as? [String: Any])?["full"] as? String { spells[k] = f }
            }
        }
        ready = true
    }

    func championId(_ koName: String) -> String? { champs[koName] }

    func champion(_ koName: String) -> URL? { champs[koName].flatMap { championById($0) } }
    func championById(_ id: String) -> URL? {
        version.isEmpty ? nil : URL(string: "https://ddragon.leagueoflegends.com/cdn/\(version)/img/champion/\(id).png")
    }
    func item(_ koName: String) -> URL? {
        items[koName].flatMap { URL(string: "https://ddragon.leagueoflegends.com/cdn/\(version)/img/item/\($0)") }
    }
    func spell(_ id: Int) -> URL? {
        spells[id].flatMap { URL(string: "https://ddragon.leagueoflegends.com/cdn/\(version)/img/spell/\($0)") }
    }
    func rune(_ koName: String) -> URL? {
        runes[koName].flatMap { URL(string: "https://ddragon.leagueoflegends.com/cdn/img/\($0)") }
    }

    // TFT 유닛 키(DA_18_Maokai) → Community Dragon 유닛 그림. OP.GG 키와 이름이 같다
    private var tftIcons: [String: URL] = [:]
    private(set) var tftCost: [String: Int] = [:]      // TFT 유닛 키 → 코스트(테두리 색)
    private(set) var tftItems: [String: (name: String, icon: URL?)] = [:]  // TFT 아이템 키(DA_BlueBuff) → 한글 이름·아이콘
    private(set) var tftNames: [String: String] = [:]  // TFT 유닛·시너지 키(DA_18_Solar) → 한글 이름(햇빛)
    private(set) var tftTraits: [String: String] = [:] // 공백 뺀 한글 시너지 이름 → 키 (화면 글자와 맞추기용)
    func tftUnit(_ key: String) -> URL? { tftIcons[key] }

    // 원본이 24MB 라 하루 한 번만 받아 Application Support 에 캐시
    func loadTFT() async {
        guard tftIcons.isEmpty else { return }
        let cache = AugmentOCR.tftFile.deletingLastPathComponent().appendingPathComponent("cdragon_tft_ko.json")
        let age = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow } ?? .infinity
        var data = try? Data(contentsOf: cache)
        if data == nil || age > 86400 {
            var req = URLRequest(url: URL(string: "https://raw.communitydragon.org/latest/cdragon/tft/ko_kr.json")!)
            req.setValue("Riftsight", forHTTPHeaderField: "User-Agent")  // 기본 User-Agent 는 403
            if let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 {
                data = d
                try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? d.write(to: cache)
            }
        }
        guard let d = data, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let sets = j["sets"] as? [String: [String: Any]] else { return }
        func png(_ tex: String) -> URL? { URL(string: "https://raw.communitydragon.org/latest/game/" + tex.lowercased().replacingOccurrences(of: ".tex", with: ".png")) }
        for i in j["items"] as? [[String: Any]] ?? [] {
            if let k = i["apiName"] as? String, let n = i["name"] as? String { tftItems[k] = (n, (i["icon"] as? String).flatMap(png)) }
        }
        var out: [String: URL] = [:]
        // 숫자 순서로 돌아 같은 이름이면 최신 시즌 키가 남게 한다
        for set in sets.sorted(by: { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }).map(\.value) {
            for t in set["traits"] as? [[String: Any]] ?? [] {
                if let k = t["apiName"] as? String, let n = t["name"] as? String { tftNames[k] = n; tftTraits[AugmentOCR.norm(n)] = k }
            }
            for c in set["champions"] as? [[String: Any]] ?? [] {
                if let k = c["apiName"] as? String, let n = c["name"] as? String { tftNames[k] = n; tftCost[k] = c["cost"] as? Int }
            }
            for c in set["champions"] as? [[String: Any]] ?? [] {
                guard let k = c["apiName"] as? String, let tile = c["tileIcon"] as? String, !tile.isEmpty else { continue }
                out[k] = png(tile)
            }
        }
        tftIcons = out
        objectWillChange.send()
    }

    private func get(_ url: String) async -> Any? {
        guard let u = URL(string: url), let (d, _) = try? await URLSession.shared.data(from: u) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }
}
