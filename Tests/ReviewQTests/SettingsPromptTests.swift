import AppKit
@testable import ReviewQ
@testable import ReviewQCore
import SwiftUI
import Vision
import XCTest

@MainActor
final class SettingsPromptTests: XCTestCase {
    func testDefaultEditorShowsItsOwnNameAndCharacterLimit() throws {
        let lines = try recognize(render(ReviewInstructionsEditor(title: "Scout", text: .constant(""))))
        XCTAssertTrue(lines.contains { $0.text == "Scout" }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.text.contains("of 1,000 characters") }, "\(lines)")
    }

    func testEachEditorShowsTheExactCountAndTurnsRedOnlyOverTheLimit() throws {
        for title in ["Scout", "GitHub Copilot"] {
            for (count, label) in [(1_000, "1,000"), (1_001, "1,001")] {
                let image = try render(ReviewInstructionsEditor(title: title, text: .constant(String(repeating: "x", count: count))))
                let lines = try recognize(image)
                let counter = try XCTUnwrap(lines.first { $0.text.contains("\(label) of 1,000 characters") })
                let bounds = CGRect(
                    x: counter.bounds.minX * CGFloat(image.width),
                    y: (1 - counter.bounds.maxY) * CGFloat(image.height),
                    width: counter.bounds.width * CGFloat(image.width),
                    height: counter.bounds.height * CGFloat(image.height)
                )
                let cropped = try XCTUnwrap(image.cropping(to: bounds))
                XCTAssertEqual(try hasRedPixels(cropped), count > 1_000)
            }
        }
    }

    private func render(_ view: some View) throws -> CGImage {
        _ = NSApplication.shared
        let renderer = ImageRenderer(
            content: view.frame(width: 560, height: 160)
                .environment(\.colorScheme, .light)
                .environment(\.locale, Locale(identifier: "en_US"))
                .background(Color(nsColor: .windowBackgroundColor))
        )
        renderer.scale = 3
        return try XCTUnwrap(renderer.cgImage)
    }

    private func recognize(_ image: CGImage) throws -> [(text: String, bounds: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return try XCTUnwrap(request.results).map {
            (try XCTUnwrap($0.topCandidates(1).first).string, $0.boundingBox)
        }
    }

    private func hasRedPixels(_ image: CGImage) throws -> Bool {
        let bitmap = NSBitmapImageRep(cgImage: image)
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if color.redComponent > 0.7 && color.greenComponent < 0.4 && color.blueComponent < 0.4 { return true }
            }
        }
        return false
    }
}
