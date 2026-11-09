import AppKit

// GitHub 최신 릴리스를 보고 새 버전이면 DMG 를 받아 앱을 바꿔 끼운 뒤 다시 켠다
enum Updater {
    static let latest = URL(string: "https://api.github.com/repos/Starlight0307/Riftsight/releases/latest")!

    static var current: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }

    // "0.10.0" > "0.9.1" 처럼 숫자 단위로 비교
    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) where (i < x.count ? x[i] : 0) != (i < y.count ? y[i] : 0) {
            return (i < x.count ? x[i] : 0) > (i < y.count ? y[i] : 0)
        }
        return false
    }

    // manual: 설정 화면의 "업데이트 확인" 버튼 — 새 버전이 없어도 결과를 알려 줌
    @MainActor static func check(manual: Bool = false) async {
        func say(_ t: String) { if manual { let a = NSAlert(); a.messageText = t; a.runModal() } }
        guard let cur = current else { return say("개발용 실행(swift run)에서는 업데이트를 확인하지 않아요") }
        var req = URLRequest(url: latest)
        req.setValue("Riftsight", forHTTPHeaderField: "User-Agent")
        guard let (d, _) = try? await URLSession.shared.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let tag = (j["tag_name"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "v")) else {
            return say("업데이트 정보를 받지 못했어요. 인터넷 연결을 확인해 주세요.")
        }
        guard newer(tag, than: cur) else { return say("최신 버전이에요 (\(cur))") }
        guard let dmg = (j["assets"] as? [[String: Any]])?.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true })?["browser_download_url"] as? String,
              let url = URL(string: dmg) else { return }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "새 버전 \(tag)이 있어요"
        alert.informativeText = "지금 업데이트하면 받아서 설치한 뒤 Riftsight를 다시 켭니다. (현재 \(cur))"
        alert.addButton(withTitle: "업데이트")
        alert.addButton(withTitle: "나중에")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try await install(from: url)
        } catch {
            let fail = NSAlert()
            fail.messageText = "업데이트하지 못했어요"
            fail.informativeText = "\(error.localizedDescription)\n릴리스 페이지에서 직접 받아 주세요."
            fail.runModal()
            NSWorkspace.shared.open(URL(string: "https://github.com/Starlight0307/Riftsight/releases/latest")!)
        }
    }

    struct Failure: LocalizedError { let errorDescription: String? }

    static func run(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw Failure(errorDescription: "\(URL(fileURLWithPath: args[0]).lastPathComponent) 실패 (\(p.terminationStatus))") }
    }

    @MainActor static func install(from url: URL) async throws {
        let (tmp, _) = try await URLSession.shared.download(from: url)
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("riftsight-update-\(UUID().uuidString)")
        try run(["/usr/bin/hdiutil", "attach", tmp.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
        defer { try? run(["/usr/bin/hdiutil", "detach", mount.path, "-quiet"]) }

        let new = mount.appendingPathComponent("Riftsight.app")
        guard FileManager.default.fileExists(atPath: new.path) else { throw Failure(errorDescription: "DMG 안에 Riftsight.app 이 없어요") }
        let app = Bundle.main.bundleURL
        // 새 앱을 옆에 먼저 복사해 두고 바꿔 끼운다 → 복사가 실패해도 지금 앱은 그대로 남음
        let staged = app.deletingLastPathComponent().appendingPathComponent(".Riftsight-new.app")
        try? FileManager.default.removeItem(at: staged)
        try run(["/usr/bin/ditto", new.path, staged.path])
        _ = try FileManager.default.replaceItemAt(app, withItemAt: staged)

        // 지금 프로세스가 끝난 뒤 새 앱을 연다
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; open \"$0\"", app.path]
        try relaunch.run()
        NSApp.terminate(nil)
    }

    static func selfTest() {
        assert(newer("0.3.0", than: "0.2.0") && newer("0.10.0", than: "0.9.1") && newer("1.0", than: "0.9.9"))
        assert(!newer("0.2.0", than: "0.2.0") && !newer("0.2", than: "0.2.0") && !newer("0.1.9", than: "0.2.0"))
        print("Updater self-test OK")
    }
}
