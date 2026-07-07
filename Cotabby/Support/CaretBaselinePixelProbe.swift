import CoreGraphics
import Foundation

/// File overview:
/// Pure pixel analysis for the placement probe: given a captured band of the HOST window around
/// the caret line (ghost overlay excluded by the window-filtered capture), finds the bottom row of
/// the host's rendered glyphs. Comparing that row against the AX caret rect turns "the ghost sits
/// a little high in this app" into a signed number per field.
///
/// Kept pure (CGImage in, row number out) so the row-profiling thresholds are unit-testable with
/// synthetic images. No pixels leave this function: callers log derived numbers only, never the
/// image, so the user's text content is never persisted.
nonisolated enum CaretBaselinePixelProbe {
    struct Measurement: Equatable {
        /// Bottom row of the detected glyph run, in image pixel rows (top-left origin).
        let glyphBottomRow: Int
        /// Total text-classified pixels — a confidence signal; tiny counts mean "one antialiased
        /// speck", not text.
        let textPixelCount: Int
    }

    /// Luminance distance from the modal background at which a pixel counts as text.
    private static let textLuminanceDelta = 48
    /// A row participates in a glyph run when it has at least this many text pixels.
    private static let minimumRowPixels = 2
    /// A glyph run must span at least this many rows (glyph cores are ≥5px at 2x for ≥9pt text).
    private static let minimumRunRows = 5

    /// Finds the glyph-run bottom in `image`, or nil when the band contains no measurable text.
    static func measure(_ image: CGImage) -> Measurement? {
        guard let pixels = grayscalePixels(of: image) else { return nil }
        let width = image.width
        let height = image.height
        guard width >= 8, height >= 8 else { return nil }

        // Modal background luminance over the whole band, in 16 coarse buckets. The band is a
        // strip of editor around one text line, so the background dominates by construction.
        var buckets = [Int](repeating: 0, count: 16)
        for value in pixels {
            buckets[Int(value) >> 4] += 1
        }
        guard let modalBucket = buckets.indices.max(by: { buckets[$0] < buckets[$1] }) else {
            return nil
        }
        let background = modalBucket << 4 + 8

        var rowCounts = [Int](repeating: 0, count: height)
        var textPixelCount = 0
        for row in 0..<height {
            var count = 0
            let base = row * width
            for column in 0..<width where abs(Int(pixels[base + column]) - background) >= textLuminanceDelta {
                count += 1
            }
            rowCounts[row] = count
            textPixelCount += count
        }

        // Largest contiguous run of text rows; its last row is the glyph bottom (descender line).
        var bestRun: (start: Int, end: Int)?
        var runStart: Int?
        for row in 0..<height {
            if rowCounts[row] >= minimumRowPixels {
                runStart = runStart ?? row
            } else if let start = runStart {
                if bestRun == nil || (row - 1 - start) > (bestRun!.end - bestRun!.start) {
                    bestRun = (start, row - 1)
                }
                runStart = nil
            }
        }
        if let start = runStart {
            if bestRun == nil || (height - 1 - start) > (bestRun!.end - bestRun!.start) {
                bestRun = (start, height - 1)
            }
        }

        guard let run = bestRun, run.end - run.start + 1 >= minimumRunRows else {
            return nil
        }
        return Measurement(glyphBottomRow: run.end, textPixelCount: textPixelCount)
    }

    /// Renders the image into an 8-bit grayscale buffer. Returns nil when the context cannot be
    /// built (exotic color spaces); the probe then simply skips this sample.
    private static func grayscalePixels(of image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let rendered: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? pixels : nil
    }
}
