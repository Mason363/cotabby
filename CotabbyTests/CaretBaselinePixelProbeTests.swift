import CoreGraphics
import XCTest

@testable import Cotabby

/// Pins the placement probe's row-profiling on synthetic images: a dark glyph band on a light
/// background must report the band's bottom row; empty or speck-only bands must report nothing.
final class CaretBaselinePixelProbeTests: XCTestCase {
    /// Builds a grayscale test image of `width`×`height` filled with `background`, then paints
    /// each (rowRange, columnRange, value) run.
    private func image(
        width: Int,
        height: Int,
        background: UInt8,
        runs: [(rows: Range<Int>, columns: Range<Int>, value: UInt8)]
    ) -> CGImage {
        var pixels = [UInt8](repeating: background, count: width * height)
        for run in runs {
            for row in run.rows {
                for column in run.columns {
                    pixels[row * width + column] = run.value
                }
            }
        }
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    func test_measure_findsGlyphBandBottomOnLightBackground() {
        // "Text" spanning rows 12...24 (13 rows) — bottom must be row 24.
        let sample = image(
            width: 120, height: 40, background: 240,
            runs: [(rows: 12..<25, columns: 10..<80, value: 20)]
        )
        let measurement = CaretBaselinePixelProbe.measure(sample)
        XCTAssertEqual(measurement?.glyphBottomRow, 24)
    }

    func test_measure_findsLightGlyphsOnDarkBackground() {
        // Dark-mode editors: light text on dark background must measure identically.
        let sample = image(
            width: 120, height: 40, background: 30,
            runs: [(rows: 8..<20, columns: 10..<80, value: 220)]
        )
        XCTAssertEqual(CaretBaselinePixelProbe.measure(sample)?.glyphBottomRow, 19)
    }

    func test_measure_returnsNilForEmptyBand() {
        let sample = image(width: 120, height: 40, background: 240, runs: [])
        XCTAssertNil(CaretBaselinePixelProbe.measure(sample))
    }

    func test_measure_ignoresSpecksShorterThanAGlyphRun() {
        // A 2-row artifact (underline fragment, box border) is not text.
        let sample = image(
            width: 120, height: 40, background: 240,
            runs: [(rows: 30..<32, columns: 10..<80, value: 20)]
        )
        XCTAssertNil(CaretBaselinePixelProbe.measure(sample))
    }

    func test_measure_picksTheDominantRunOverANearbyArtifact() {
        // A real glyph band (rows 10-22) plus a thin separator line (rows 34-35): the band wins.
        let sample = image(
            width: 120, height: 40, background: 240,
            runs: [
                (rows: 10..<23, columns: 10..<80, value: 20),
                (rows: 34..<36, columns: 0..<120, value: 20)
            ]
        )
        XCTAssertEqual(CaretBaselinePixelProbe.measure(sample)?.glyphBottomRow, 22)
    }
}
