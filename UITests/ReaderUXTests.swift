import XCTest

/// A scriptable driver for exploring the app's real behaviour.
///
/// Screenshots tell you what a screen looks like; they can't tell you what happens when
/// you tap the right edge of a page, whether the chrome fades, or whether a control is
/// reachable at all. This test exists to answer those questions without rebuilding for
/// every question asked.
///
/// The step list arrives through the `UX_SCRIPT` environment variable, so one build can
/// run any number of different explorations:
///
///     UX_SCRIPT="shot:library;tapXY:0.1,0.25;wait:2;shot:opened;dump:reader"
///
/// Artefacts land in the simulator's temporary directory, which the host reads back at
/// `~/Library/Developer/CoreSimulator/Devices/<UDID>/data/tmp/uxprobe/`.
final class ReaderUXTests: XCTestCase {

    private var app: XCUIApplication!
    private var outputDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = true

        outputDirectory = URL(fileURLWithPath: "/tmp/uxprobe", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        app = XCUIApplication(bundleIdentifier: "com.lingobook.ipad")
        app.launch()
    }

    /// Runs whatever the script asks for. Steps are `verb:arguments`, separated by `;`.
    ///
    /// The script is read from a file rather than the environment so that a new
    /// exploration costs a `test-without-building` run instead of a full rebuild.
    func testRunScript() throws {
        let scriptFile = outputDirectory.appendingPathComponent("script.txt")
        let script = (try? String(contentsOf: scriptFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ProcessInfo.processInfo.environment["UX_SCRIPT"]
            ?? "shot:default;dump:default"

        for rawStep in script.split(separator: ";") {
            let step = rawStep.trimmingCharacters(in: .whitespaces)
            guard !step.isEmpty else { continue }

            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let verb = parts[0]
            let argument = parts.count > 1 ? parts[1] : ""

            switch verb {
            case "shot":
                capture(named: argument.isEmpty ? "shot" : argument)

            case "dump":
                dumpHierarchy(named: argument.isEmpty ? "dump" : argument)

            case "wait":
                Thread.sleep(forTimeInterval: TimeInterval(argument) ?? 1)

            case "tapXY":
                tapNormalized(argument)

            case "tapText":
                tapElement(matching: argument)

            case "swipeLeft":
                app.swipeLeft()

            case "swipeRight":
                app.swipeRight()

            case "rotate":
                rotate(to: argument)

            case "press":
                // press:0.9,0.5,1.5 — a long press, for testing hold-to-select behaviour
                let fields = argument.split(separator: ",").compactMap { Double($0) }
                guard fields.count >= 2 else { break }
                let point = coordinate(x: fields[0], y: fields[1])
                point.press(forDuration: fields.count > 2 ? fields[2] : 1.0)

            default:
                XCTFail("Unknown step verb: \(verb)")
            }
        }
    }

    // MARK: - Steps

    private func coordinate(x: Double, y: Double) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    /// Rotates the device, and fails if the rotation did not actually happen.
    ///
    /// Setting `XCUIDevice.orientation` against a simulator booted headless (no
    /// Simulator.app) is accepted silently and then ignored — the window keeps its
    /// portrait frame. A rotation step that quietly does nothing is worse than no step at
    /// all, because the run still reports success while having exercised only portrait.
    /// So this checks the window really changed shape and says so when it didn't.
    private func rotate(to argument: String) {
        let wantsLandscape = (argument == "landscape")
        let before = app.frame.size

        XCUIDevice.shared.orientation = wantsLandscape ? .landscapeLeft : .portrait
        Thread.sleep(forTimeInterval: 2)

        let after = app.frame.size
        let isLandscape = after.width > after.height

        XCTAssertEqual(
            isLandscape, wantsLandscape,
            """
            Device did not rotate: \(before) → \(after). A headless simulator ignores \
            orientation changes; boot Simulator.app to exercise landscape.
            """
        )
    }

    private func tapNormalized(_ argument: String) {
        let fields = argument.split(separator: ",").compactMap { Double($0) }
        guard fields.count == 2 else {
            XCTFail("tapXY needs two normalised numbers, got \(argument)")
            return
        }
        coordinate(x: fields[0], y: fields[1]).tap()
    }

    /// Taps the first element whose label or identifier contains `text`.
    ///
    /// Deliberately searches every element type rather than `app.buttons`: the point of
    /// these runs is to find out what the app exposes, and a control that only answers to
    /// a coordinate tap is itself a finding worth recording.
    private func tapElement(matching text: String) {
        let predicate = NSPredicate(
            format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@", text, text
        )
        let match = app.descendants(matching: .any).matching(predicate).firstMatch

        if match.waitForExistence(timeout: 5) {
            match.tap()
        } else {
            XCTFail("No element matching “\(text)”")
        }
    }

    // MARK: - Artefacts

    private func capture(named name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        let destination = outputDirectory.appendingPathComponent("\(name).png")
        try? data.write(to: destination)
    }

    /// Writes the accessibility hierarchy — every element the system can see, with its
    /// frame. This is the record of what a VoiceOver or keyboard user would find.
    private func dumpHierarchy(named name: String) {
        let destination = outputDirectory.appendingPathComponent("\(name).txt")
        try? app.debugDescription.write(to: destination, atomically: true, encoding: .utf8)
    }
}
