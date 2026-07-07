import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Self-measuring placement: when a ghost is presented, captures a thin band of the HOST window
/// around the caret line (the window-filtered capture structurally excludes Cotabby's own overlay),
/// finds where the host's glyphs actually sit, and logs the signed offset between that measured
/// glyph bottom and the AX caret rect the overlay anchored to. This is the CoTypist-style
/// "use screenshots to improve suggestion appearance" loop, in its measurement-only first stage:
/// it turns per-app "the ghost sits slightly high/low" reports into `stage=placement-probe` JSONL
/// numbers gathered from real fields during real use.
///
/// Privacy: the captured pixels never leave the probe — only derived row numbers are logged, the
/// image is discarded, and nothing runs unless the debug build flag and Screen Recording
/// permission are both present.
///
/// Cost: one ScreenCaptureKit single-frame capture per focused-field identity (re-armed when the
/// caret line height changes, i.e. a font change), entirely off the per-keystroke path.
@MainActor
final class GhostPlacementProbeService {
    private let screenshotService = WindowScreenshotService()

    /// Field identities already measured this run, keyed to the caret height they were measured
    /// at. A >2pt height change means the field's font changed; re-arm the probe.
    private var probedCaretHeights: [UInt64: CGFloat] = [:]
    private var isCaptureInFlight = false

    private enum Metrics {
        /// Horizontal reach of the host-text band, ending just before the caret.
        static let bandWidth: CGFloat = 220
        static let caretClearance: CGFloat = 6
        /// Vertical slack around the caret line box.
        static let verticalSlack: CGFloat = 4
        /// Minimum band width worth measuring — a caret at the line start has no host text.
        static let minimumBandWidth: CGFloat = 30
        static let heightRearmThreshold: CGFloat = 2
    }

    /// Fire-and-forget: measures at most once per field identity (per font size), only on debug
    /// builds, and never blocks the present path.
    func probeIfNeeded(
        geometry: SuggestionOverlayGeometry,
        processIdentifier: Int32,
        bundleIdentifier: String
    ) {
        guard CotabbyDebugOptions.isEnabled, !isCaptureInFlight else { return }
        let identity = geometry.focusedInputIdentityKey
        let caretRect = geometry.caretRect
        if let probedHeight = probedCaretHeights[identity],
           abs(probedHeight - caretRect.height) <= Metrics.heightRearmThreshold {
            return
        }

        let leftLimit = geometry.inputFrameRect.map { $0.minX + 8 } ?? (caretRect.minX - Metrics.bandWidth)
        let bandMinX = max(leftLimit, caretRect.minX - Metrics.bandWidth)
        let bandWidth = caretRect.minX - Metrics.caretClearance - bandMinX
        guard bandWidth >= Metrics.minimumBandWidth else { return }

        let band = CGRect(
            x: bandMinX,
            y: caretRect.minY - Metrics.verticalSlack,
            width: bandWidth,
            height: caretRect.height + Metrics.verticalSlack * 2
        )

        isCaptureInFlight = true
        let quality = geometry.caretQuality
        Task { [weak self] in
            defer { self?.isCaptureInFlight = false }
            guard let self else { return }
            do {
                let capture = try await self.screenshotService.captureBand(
                    cocoaRect: band,
                    processIdentifier: pid_t(processIdentifier)
                )
                guard let measurement = CaretBaselinePixelProbe.measure(capture.image) else {
                    return
                }
                // Image rows are top-left; the band's Cocoa maxY is row 0. Row bottoms sit at the
                // NEXT row boundary, hence +1.
                let glyphBottomCocoaY = capture.capturedCocoaRect.maxY
                    - CGFloat(measurement.glyphBottomRow + 1) / capture.scale
                let delta = glyphBottomCocoaY - caretRect.minY
                self.probedCaretHeights[identity] = caretRect.height
                CotabbyLogger.suggestion.debug(
                    "Placement probe measured the host glyph bottom against the caret rect.",
                    metadata: [
                        "stage": .string("placement-probe"),
                        "host_bundle_id": .string(bundleIdentifier),
                        "caret_quality": .string(String(describing: quality)),
                        "caret_h": .stringConvertible(Double(caretRect.height)),
                        "caret_min_y": .stringConvertible(Double(caretRect.minY)),
                        // Positive: the host's glyphs bottom out ABOVE the caret box bottom by
                        // this many points — the offset the ghost anchor should absorb.
                        "host_glyph_bottom_delta_pt": .stringConvertible((Double(delta) * 100).rounded() / 100),
                        "band_w": .stringConvertible(Double(band.width)),
                        "text_px": .stringConvertible(measurement.textPixelCount),
                        "scale": .stringConvertible(Double(capture.scale))
                    ]
                )
            } catch {
                // Permission missing, window vanished, capture raced a close — all fine to skip;
                // the probe is opportunistic diagnostics, never product behavior.
                CotabbyLogger.suggestion.trace(
                    "Placement probe skipped: \(error.localizedDescription)")
            }
        }
    }
}
