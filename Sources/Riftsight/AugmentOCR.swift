import Foundation
import ScreenCaptureKit
import Vision

// TFT 증강체 선택지는 클라이언트 API 에 없어서, 화면을 찍어 글자를 읽고 등급표와 맞춘다
struct AugmentHit: Identifiable {
    let id = UUID()
    let name: String, tier: String, avg: Double
    let box: CGRect  // Vision 정규화 좌표 (원점 왼쪽 아래)
}

enum AugmentOCR {
    struct Entry: Decodable { let tier: String; let avg: Double; let n: Int }
    struct File: Decodable { let augments: [String: Entry] }

    // tools/augment_tiers.py 가 Riot 공식 API 로 계산한 등급표
    // shortcut: 앱에 묶여 있어 등급표를 바꾸면 다시 빌드해야 함, 자주 바꾸게 되면 원격 파일로 받기
    static let table: [String: Entry] = {
        guard let url = Bundle.module.url(forResource: "augment_tiers", withExtension: "json"),
              let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d) else { return [:] }
        return f.augments
    }()
    static let keyed = Dictionary(table.map { (norm($0.key), ($0.key, $0.value)) }, uniquingKeysWith: { a, _ in a })

    static func norm(_ s: String) -> String { s.filter { !$0.isWhitespace } }

    // OCR 한 줄을 등급표 이름과 맞춘다: 공백 무시 후 같거나, 3글자 이상 이름이 줄에 들어 있으면
    static func match(_ line: String, in k: [String: (String, Entry)] = keyed) -> (String, Entry)? {
        let n = norm(line)
        if let hit = k[n] { return hit }
        return k.filter { $0.key.count >= 3 && n.contains($0.key) }.max(by: { $0.key.count < $1.key.count })?.value
    }

    static func scan(excluding window: CGWindowID?) async -> [AugmentHit] {
        guard !table.isEmpty,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
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
        return (req.results ?? []).compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string, let (name, e) = match(text) else { return nil }
            return AugmentHit(name: name, tier: e.tier, avg: e.avg, box: obs.boundingBox)
        }
    }

    static func selfTest() {
        // 등급표 없이 매칭 규칙만 확인
        let t = ["대출 선지급": Entry(tier: "A", avg: 4.2, n: 50), "초월": Entry(tier: "S", avg: 3.9, n: 80)]
        let k = Dictionary(t.map { (norm($0.key), ($0.key, $0.value)) }, uniquingKeysWith: { a, _ in a })
        func m(_ l: String) -> String? { match(l, in: k)?.0 }
        assert(m("대출 선지급") == "대출 선지급")
        assert(m("대출선지급 II") == "대출 선지급")
        assert(m("초월") == "초월")
        assert(m("초월적인 힘") == nil, "2글자 이름은 정확히 같을 때만")
        print("AugmentOCR.match self-test OK")
    }
}
