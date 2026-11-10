import Foundation
import ScreenCaptureKit
import Vision

// TFT 증강체 선택지는 클라이언트 API 에 없어서, 화면을 찍어 글자를 읽고 등급표와 맞춘다
struct AugmentHit: Identifiable {
    let id = UUID()
    let name: String, tier: String, note: String
    let box: CGRect  // Vision 정규화 좌표 (원점 왼쪽 아래)
}

enum AugmentOCR {
    struct Entry { let tier: String; let note: String }
    typealias Keyed = [String: (String, Entry)]

    // TFT 증강체 성적은 공개 데이터가 없어 사용자가 직접 채우는 등급표를 쓴다 (메뉴 → TFT 등급표 열기)
    static let tftFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Riftsight/tft_tiers.txt")

    // 고치면 다음 화면 읽기부터 바로 반영되도록 매번 읽는다 (파일이 작음)
    static func tft() -> Keyed { keyed(parseTiers((try? String(contentsOf: tftFile, encoding: .utf8)) ?? "")) }

    // 한 줄에 "등급 이름" (예: "S 대출 선지급"). # 뒤는 메모, 등급이 S·A·B·C·D 가 아니면 건너뜀
    static func parseTiers(_ text: String) -> [String: Entry] {
        var out: [String: Entry] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
            guard let sp = line.firstIndex(of: " ") else { continue }
            let tier = line[..<sp].uppercased(), name = line[sp...].trimmingCharacters(in: .whitespaces)
            if ["S", "A", "B", "C", "D"].contains(tier), !name.isEmpty { out[name] = Entry(tier: tier, note: "") }
        }
        return out
    }

    static func keyed(_ t: [String: Entry]) -> Keyed {
        Dictionary(t.map { (norm($0.key), ($0.key, $0.value)) }, uniquingKeysWith: { a, _ in a })
    }

    static func norm(_ s: String) -> String { s.filter { !$0.isWhitespace } }

    // OCR 한 줄을 등급표 이름과 맞춘다: 공백 무시 후 같거나, 3글자 이상 이름이 줄에 들어 있으면
    static func match(_ line: String, in k: Keyed) -> (String, Entry)? {
        let n = norm(line)
        if let hit = k[n] { return hit }
        if let hit = k.filter({ $0.key.count >= 3 && n.contains($0.key) }).max(by: { $0.key.count < $1.key.count }) { return hit.value }
        // 긴 이름은 카드에서 두 줄로 나뉘어 읽히므로 첫 줄(6글자 이상, "업그레이드" 같은 둘째 줄은 거름)이 이름 앞부분이면 인정
        return n.count >= 6 ? k.filter { $0.key.hasPrefix(n) }.min(by: { $0.key.count < $1.key.count })?.value : nil
    }

    static func scan(_ table: Keyed, excluding window: CGWindowID?) async -> [AugmentHit] {
        table.isEmpty ? [] : hits(table, await read(excluding: window))
    }

    static func hits(_ table: Keyed, _ lines: [(String, CGRect)]) -> [AugmentHit] {
        lines.compactMap { text, box in match(text, in: table).map { AugmentHit(name: $0.0, tier: $0.1.tier, note: $0.1.note, box: box) } }
    }

    // 화면을 찍어 글자 줄과 위치(Vision 정규화 좌표)를 돌려준다. 증강체·TFT 시너지가 함께 씀
    static func read(excluding window: CGWindowID?) async -> [(String, CGRect)] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { return [] }
        let mine = content.windows.filter { $0.windowID == window }
        let cfg = SCStreamConfiguration()
        cfg.width = display.width * 2
        cfg.height = display.height * 2
        guard let img = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: mine), configuration: cfg) else { return [] }


        let req = VNRecognizeTextRequest()
        req.recognitionLanguages = ["ko-KR", "en-US"]
        req.recognitionLevel = .accurate
        try? VNImageRequestHandler(cgImage: img).perform([req])
        return (req.results ?? []).compactMap { obs in obs.topCandidates(1).first.map { ($0.string, obs.boundingBox) } }
    }

    static func mergeTiers(_ old: String, _ augs: [(name: String, rarity: String)]) -> String {
        let grades = parseTiers(old)
        let head = "# 맨 앞 ? 를 S·A·B·C·D 로 바꾸세요. ? 로 남긴 줄은 쓰지 않습니다. # 뒤는 메모.\n"
        return head + augs.sorted { ($0.rarity, $0.name) < ($1.rarity, $1.name) }
            .map { "\(grades[$0.name]?.tier ?? "?") \($0.name)  # \($0.rarity)" }.joined(separator: "\n") + "\n"
    }

    static func selfTest() {
        // 등급표 없이 매칭 규칙만 확인
        let k = keyed(["대출 선지급": Entry(tier: "A", note: ""), "초월": Entry(tier: "S", note: ""), "꽃피는 새벽의 검 업그레이드": Entry(tier: "B", note: ""), "업그레이드: 즈롯 차원문": Entry(tier: "C", note: "")])
        func m(_ l: String) -> String? { match(l, in: k)?.0 }
        assert(m("대출 선지급") == "대출 선지급")
        assert(m("대출선지급 II") == "대출 선지급")
        assert(m("초월") == "초월")
        assert(m("초월적인 힘") == nil, "2글자 이름은 정확히 같을 때만")
        assert(m("꽃피는 새벽의 검") == "꽃피는 새벽의 검 업그레이드", "two-line name")
        assert(m("업그레이드") == nil, "short prefix")
        let p = parseTiers("# 메모\nS 대출 선지급  # 골드\n? 초월\na 빛나는 별\nX 엉뚱\n")
        assert(p.count == 2 && p["대출 선지급"]?.tier == "S" && p["빛나는 별"]?.tier == "A", "parseTiers")
        let m = mergeTiers("S 대출 선지급\nA 사라진 증강체\n", [("대출 선지급", "골드"), ("새 증강체", "실버")])
        assert(m.contains("S 대출 선지급  # 골드") && m.contains("? 새 증강체  # 실버") && !m.contains("사라진"), "mergeTiers")
        assert(mergeTiers(m, [("대출 선지급", "골드"), ("새 증강체", "실버")]) == m, "같은 목록이면 그대로")
        print("AugmentOCR.match self-test OK")
    }
}
