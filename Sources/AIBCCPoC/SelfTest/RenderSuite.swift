import AppKit
import ImageIO

/// Codex runtime review R5: after 4→1 split, switching barracks away and
/// back and shrinking the window, typing ran but the screen did not update.
/// The text model can't show that (it has the text either way), so each
/// check types into a recorder that logs the bytes and writes them back
/// (AIBCC_ECHO), captures the pane before and after, and compares its
/// pixels: bytes delivered and echoed + pixels unchanged = renderer stall. Explicit suite (`--selftest-only=repro-r5`); needs
/// scripts/capture-watcher.sh.
@MainActor
struct RenderSuite {
    let harness: SelfTestHarness

    func run() async -> [TestResult] {
        guard let window = harness.window else { return [] }
        return [
            await check("RP-R5a", "4→1분할·배럭 왕복·창 축소 후 입력이 화면에 그려짐", window) { pane in
                await sequenceFromReview(pane, window)
            },
            await check("RP-R5b", "창 최소화→복원 후 입력이 화면에 그려짐", window) { _ in
                window.miniaturize(nil)
                await harness.pause(.seconds(1))
                window.deminiaturize(nil)
                await harness.pause(.seconds(1))
            },
        ]
    }

    private func sequenceFromReview(_ pane: TerminalPane, _ window: NSWindow) async {
        let workspace = harness.workspace
        let extras = (1...3).compactMap { harness.makeRecorderPane(name: "r5-\($0)")?.pane }
        await harness.install([pane] + extras, layout: .quad)
        await harness.pause(.milliseconds(500))
        workspace.setLayout(.single)
        await harness.pause(.milliseconds(500))
        if let original = workspace.selectedBarrackID,
           let other = workspace.barracks.first(where: { $0.id != original })?.id {
            workspace.selectedBarrackID = other
            await harness.pause(.milliseconds(800))
            workspace.selectedBarrackID = original
            await harness.pause(.milliseconds(800))
        }
        window.setContentSize(AppConstants.SelfTest.resizeSmallSize)
        await harness.pause(.milliseconds(800))
    }

    private func check(
        _ id: String, _ title: String, _ window: NSWindow, _ scenario: (TerminalPane) async -> Void
    ) async -> TestResult {
        let start = ContinuousClock.now
        let original = window.frame
        guard let recorder = harness.makeRecorderPane(name: "r5-echo", environment: ["AIBCC_ECHO": "1"]) else {
            return .make(id, title, status: .fail, cause: .app, evidence: ["reason": "fixture"], startedAt: start)
        }
        let pane = recorder.pane
        await harness.install([pane], layout: .single)
        _ = await harness.waitUntil(AppConstants.SelfTest.readyTimeout) { recorder.log.isReady }
        await scenario(pane)
        harness.focus(pane)
        let marker = "renderprobe\(Int.random(in: 1000...9999))"
        let before = await harness.requestCapture(label: "\(id)-before")
        let mark = recorder.log.mark()
        EventSynthesizer.type(marker, in: window)
        let inModel = await harness.settledBytes(recorder.log, since: mark, expectingAtLeast: marker.utf8.count)
            == Hex.bytes(marker)
        let after = await harness.requestCapture(label: "\(id)-after")
        let changed = paneChangedPixels(before, after, pane: pane, window: window)
        window.setFrame(original, display: true)
        // A blinking cursor alone changes about one cell: require the area
        // of several glyphs so only drawn text counts.
        let cell = pane.state.surfaceSize.map { Int($0.cellWidthPixels) * Int($0.cellHeightPixels) } ?? 0
        let minimum = max(cell * 3, 1)
        let drawn = (changed ?? 0) >= minimum
        return .make(id, title,
                     status: before == nil || after == nil ? .unverified : (inModel && drawn ? .pass : .fail),
                     cause: inModel && !drawn ? .engine : .app,
                     evidence: ["delivered_and_echoed": "\(inModel)", "changed_pixels": changed.map(String.init) ?? "n/a",
                                "minimum_pixels": "\(minimum)",
                                "captures": [before, after].compactMap { $0?.lastPathComponent }.joined(separator: ", ")],
                     startedAt: start)
    }

    /// Pixels that differ inside the pane between two window captures.
    private func paneChangedPixels(_ before: URL?, _ after: URL?, pane: TerminalPane, window: NSWindow) -> Int? {
        guard let before, let after, let view = pane.probeView,
              let first = Self.pixels(before), let second = Self.pixels(after),
              first.width == second.width, first.height == second.height
        else { return nil }
        let scale = CGFloat(first.width) / window.frame.width
        let rect = view.convert(view.bounds, to: nil)
        let x0 = max(Int(rect.minX * scale), 0)
        let x1 = min(Int(rect.maxX * scale), first.width)
        // Window coordinates grow upward; image rows grow downward.
        let y0 = max(Int((window.frame.height - rect.maxY) * scale), 0)
        let y1 = min(Int((window.frame.height - rect.minY) * scale), first.height)
        var changed = 0
        for y in y0..<max(y1, y0) {
            for x in x0..<max(x1, x0) where first.pixel(x, y) != second.pixel(x, y) {
                changed += 1
            }
        }
        return changed
    }

    private struct Bitmap {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func pixel(_ x: Int, _ y: Int) -> UInt32 {
            let i = (y * width + x) * 4
            return UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
        }
    }

    private static func pixels(_ url: URL) -> Bitmap? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Bitmap(width: width, height: height, bytes: bytes) : nil
    }
}
