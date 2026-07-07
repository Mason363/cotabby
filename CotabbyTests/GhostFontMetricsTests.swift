import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the pure ghost-text sizing math. These lock in two behaviors: the fixed-ratio fallback
/// (unchanged from before field-style resolution) and the metric-based path that scales by the host
/// font's own glyph-box ratio so ghost text matches the field's apparent size.
final class GhostFontMetricsTests: XCTestCase {
    private let fallbackRatio: CGFloat = 0.78
    private let minimum: CGFloat = 14
    private let maximum: CGFloat = 24

    private func metrics(pointSize: CGFloat, ascender: CGFloat, descender: CGFloat) -> GhostFontMetrics.FieldFontMetrics {
        GhostFontMetrics.FieldFontMetrics(pointSize: pointSize, ascender: ascender, descender: descender)
    }

    func testFallsBackToFixedRatioWhenNoFieldMetrics() {
        let size = GhostFontMetrics.pointSize(
            caretHeight: 20,
            fieldMetrics: nil,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum
        )
        // max(14, 20 * 0.78) = 15.6, under the cap.
        XCTAssertEqual(size, 15.6, accuracy: 0.0001)
    }

    func testUsesFieldFontGlyphBoxRatioWhenAvailable() {
        // Glyph box = ascender - descender = 11 - (-3) = 14, ratio = 12 / 14.
        let size = GhostFontMetrics.pointSize(
            caretHeight: 20,
            fieldMetrics: metrics(pointSize: 12, ascender: 11, descender: -3),
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum
        )
        XCTAssertEqual(size, 20 * (12.0 / 14.0), accuracy: 0.0001)
    }

    func testMetricRatioIsScaleInvariant() {
        // The same typeface reported at two sizes must yield the same ghost size, since the helper
        // uses only the ratio. This is why callers may instantiate the reference font at any size.
        let small = GhostFontMetrics.pointSize(
            caretHeight: 18,
            fieldMetrics: metrics(pointSize: 12, ascender: 11, descender: -3),
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum
        )
        let large = GhostFontMetrics.pointSize(
            caretHeight: 18,
            fieldMetrics: metrics(pointSize: 24, ascender: 22, descender: -6),
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum
        )
        XCTAssertEqual(small, large, accuracy: 0.0001)
    }

    func testAppliesMinimumFloor() {
        let size = GhostFontMetrics.pointSize(
            caretHeight: 5,
            fieldMetrics: nil,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum
        )
        XCTAssertEqual(size, minimum, accuracy: 0.0001)
    }

    func testAppliesMaximumCap() {
        let size = GhostFontMetrics.pointSize(
            caretHeight: 100,
            fieldMetrics: metrics(pointSize: 12, ascender: 11, descender: -3),
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum
        )
        XCTAssertEqual(size, maximum, accuracy: 0.0001)
    }

    func testDegenerateGlyphBoxFallsBackToFixedRatio() {
        // ascender - descender <= 0 is unusable, so the fixed ratio must be used instead.
        let size = GhostFontMetrics.pointSize(
            caretHeight: 20,
            fieldMetrics: metrics(pointSize: 12, ascender: 5, descender: 5),
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum
        )
        XCTAssertEqual(size, 20 * fallbackRatio, accuracy: 0.0001)
    }

    func testNonPositivePointSizeFallsBackToFixedRatio() {
        let size = GhostFontMetrics.pointSize(
            caretHeight: 20,
            fieldMetrics: metrics(pointSize: 0, ascender: 11, descender: -3),
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum
        )
        XCTAssertEqual(size, 20 * fallbackRatio, accuracy: 0.0001)
    }

    func testDefaultMultiplierLeavesAutoSizeUnchanged() {
        // Omitting the multiplier must reproduce the pre-feature size exactly, so existing callers and
        // the out-of-box default see no change. max(14, 20 * 0.78) = 15.6.
        let size = GhostFontMetrics.pointSize(
            caretHeight: 20,
            fieldMetrics: nil,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum
        )
        XCTAssertEqual(size, 15.6, accuracy: 0.0001)
    }

    func testSizeMultiplierScalesResolvedSize() {
        // The multiplier scales the auto-approximated 15.6 in both directions.
        let smaller = GhostFontMetrics.pointSize(
            caretHeight: 20,
            fieldMetrics: nil,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum,
            sizeMultiplier: 0.7
        )
        XCTAssertEqual(smaller, 15.6 * 0.7, accuracy: 0.0001)

        let larger = GhostFontMetrics.pointSize(
            caretHeight: 20,
            fieldMetrics: nil,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum,
            sizeMultiplier: 1.3
        )
        XCTAssertEqual(larger, 15.6 * 1.3, accuracy: 0.0001)
    }

    func testSizeMultiplierAppliesAfterTheMinimumClamp() {
        // The multiplier scales the floored auto-size (not the raw caret math), so a field auto-sizing
        // to the 14 floor still shrinks: 14 * 0.8 = 11.2, which is above the absolute floor.
        let size = GhostFontMetrics.pointSize(
            caretHeight: 5,
            fieldMetrics: nil,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum,
            sizeMultiplier: 0.8
        )
        XCTAssertEqual(size, minimum * 0.8, accuracy: 0.0001)
    }

    func testSizeMultiplierRespectsAbsoluteFloor() {
        // A degenerate multiplier far below the shipped range cannot push ghost text under the
        // legibility floor: 14 * 0.5 = 7, clamped up to absoluteMinimumPointSize.
        let size = GhostFontMetrics.pointSize(
            caretHeight: 5,
            fieldMetrics: nil,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum,
            sizeMultiplier: 0.5
        )
        XCTAssertEqual(size, GhostFontMetrics.absoluteMinimumPointSize, accuracy: 0.0001)
    }

    // MARK: - Trusted reported point size

    func testTrustedPointSizeRendersAtReportedSizeBypassingMinimumFloor() {
        // The whole point of this path: an 11pt host must render 11pt ghost text, not get floored up
        // to the 14pt minimum the caret-height approximation applies. Caret height is ignored here.
        let size = GhostFontMetrics.pointSize(
            caretHeight: 30,
            fieldMetrics: metrics(pointSize: 11, ascender: 10, descender: -3),
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum,
            trustedPointSize: 11
        )
        XCTAssertEqual(size, 11, accuracy: 0.0001)
    }

    func testTrustedPointSizeIgnoresCaretHeight() {
        // Two wildly different caret heights must yield the same size when the reported size is trusted,
        // proving the caret-height derivation is fully bypassed.
        let small = GhostFontMetrics.pointSize(
            caretHeight: 8,
            fieldMetrics: nil,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum,
            trustedPointSize: 13
        )
        let large = GhostFontMetrics.pointSize(
            caretHeight: 40,
            fieldMetrics: nil,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum,
            trustedPointSize: 13
        )
        XCTAssertEqual(small, 13, accuracy: 0.0001)
        XCTAssertEqual(large, 13, accuracy: 0.0001)
    }

    func testTrustedPointSizeScaledByMultiplier() {
        let size = GhostFontMetrics.pointSize(
            caretHeight: 20,
            fieldMetrics: nil,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum,
            sizeMultiplier: 1.2,
            trustedPointSize: 12
        )
        XCTAssertEqual(size, 12 * 1.2, accuracy: 0.0001)
    }

    func testTrustedPointSizeCappedByMaximum() {
        // A host-reported size above the cap is still bounded so a bogus reading can't bloat the panel.
        let size = GhostFontMetrics.pointSize(
            caretHeight: 20,
            fieldMetrics: nil,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum,
            trustedPointSize: 60
        )
        XCTAssertEqual(size, maximum, accuracy: 0.0001)
    }

    func testTrustedPointSizeRespectsAbsoluteFloor() {
        // A tiny reported size (or a small size shrunk by the multiplier) still cannot drop below the
        // legibility backstop.
        let size = GhostFontMetrics.pointSize(
            caretHeight: 20,
            fieldMetrics: nil,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum,
            trustedPointSize: 5
        )
        XCTAssertEqual(size, GhostFontMetrics.absoluteMinimumPointSize, accuracy: 0.0001)
    }

    func testNonPositiveTrustedPointSizeFallsBackToCaretDerivation() {
        // A zero/absent reported size must not be treated as trusted; the caret-height path takes over.
        let size = GhostFontMetrics.pointSize(
            caretHeight: 20,
            fieldMetrics: nil,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum,
            trustedPointSize: 0
        )
        // Falls back to max(14, 20 * 0.78) = 15.6.
        XCTAssertEqual(size, 15.6, accuracy: 0.0001)
    }
}
