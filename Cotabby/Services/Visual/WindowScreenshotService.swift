import AppKit
import CoreGraphics
import Foundation
import Logging
import ScreenCaptureKit

/// File overview:
/// Captures a compact screenshot around the currently focused input using ScreenCaptureKit.
/// This is the screenshot boundary for prompt augmentation: raw pixels enter here, and the rest
/// of the app never has to know about window discovery, crop math, or coordinate conversion APIs.
///
/// We use ScreenCaptureKit instead of deprecated Core Graphics screenshot APIs because the app
/// targets a modern macOS SDK where `CGWindowListCreateImage` is no longer available.

struct CapturedWindowScreenshot {
    let image: CGImage
    let windowTitle: String?
}

/// Test seam for screen capture.
///
/// ScreenCaptureKit is permissioned, asynchronous, and window-manager dependent. Keeping this
/// protocol narrow lets `ScreenshotContextGenerator` tests focus on context policy instead of
/// requiring a live macOS desktop capture.
protocol WindowScreenshotCapturing {
    func captureSnapshot(
        around context: FocusedInputSnapshot,
        snapshotDimension: Int
    ) async throws -> CapturedWindowScreenshot
}

enum WindowScreenshotError: LocalizedError {
    case screenRecordingPermissionMissing
    case noVisibleWindowForProcess(pid_t)
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionMissing:
            return "Screen Recording permission is required to capture screenshot context."
        case let .noVisibleWindowForProcess(processIdentifier):
            return "No visible frontmost window was found for process \(processIdentifier)."
        case let .captureFailed(message):
            return "Unable to capture the frontmost window screenshot: \(message)"
        }
    }
}

struct WindowScreenshotService: WindowScreenshotCapturing {
    private enum CaptureMetrics {
        /// Extra horizontal context captured around the focused field. ScreenCaptureKit works in
        /// display points here, which map to physical pixels later through `backingScaleFactor`.
        static let horizontalPadding: CGFloat = 160

        /// Capture a taller band above the input so OCR can see nearby labels, messages, and
        /// surrounding page content instead of only the field chrome.
        static let verticalContextHeight: CGFloat = 800
    }

    /// Finds the most relevant visible window for the focused process and captures an expanded
    /// region above the focused input. The crop is expressed in global display points so the
    /// caller does not need to know anything about ScreenCaptureKit's capture coordinate system.
    func captureSnapshot(
        around context: FocusedInputSnapshot,
        snapshotDimension: Int
    ) async throws -> CapturedWindowScreenshot {
        let processIdentifier = pid_t(context.processIdentifier)

        guard CGPreflightScreenCaptureAccess() else {
            CotabbyLogger.app.warning("Screenshot blocked: Screen Recording permission missing")
            throw WindowScreenshotError.screenRecordingPermissionMissing
        }

        let shareableContent = try await currentShareableContent()
        let matchingWindow =
            shareableContent.windows.first(where: {
                $0.owningApplication?.processID == processIdentifier && $0.isActive && $0.isOnScreen
            })
            ?? shareableContent.windows.first(where: {
                $0.owningApplication?.processID == processIdentifier && $0.isOnScreen
            })

        guard let matchingWindow else {
            CotabbyLogger.app.debug("No visible window for pid \(processIdentifier)")
            throw WindowScreenshotError.noVisibleWindowForProcess(processIdentifier)
        }
        let windowTitle = matchingWindow.title ?? "untitled"
        let windowWidth = Int(matchingWindow.frame.width)
        let windowHeight = Int(matchingWindow.frame.height)
        CotabbyLogger.app.trace("Capturing window: \(windowTitle) (\(windowWidth)x\(windowHeight))")

        let sourceRect = snapshotRect(
            around: context,
            windowFrame: matchingWindow.frame,
            snapshotDimension: CGFloat(snapshotDimension)
        )
        let outputScale = backingScaleFactor(for: sourceRect)

        let filter = SCContentFilter(desktopIndependentWindow: matchingWindow)
        let configuration = SCStreamConfiguration()

        let localSourceRect = CGRect(
            x: sourceRect.minX - matchingWindow.frame.minX,
            y: sourceRect.minY - matchingWindow.frame.minY,
            width: sourceRect.width,
            height: sourceRect.height
        )

        configuration.sourceRect = localSourceRect
        configuration.width = max(Int((localSourceRect.width * outputScale).rounded(.up)), 1)
        configuration.height = max(Int((localSourceRect.height * outputScale).rounded(.up)), 1)
        configuration.showsCursor = false

        let image = try await captureImage(filter: filter, configuration: configuration)
        return CapturedWindowScreenshot(image: image, windowTitle: matchingWindow.title)
    }

    /// Captures a small band of the focused process's window, given in AppKit/Cocoa screen
    /// coordinates. Used by the placement pixel probe to read the host's rendered text around the
    /// caret line. The `desktopIndependentWindow` filter captures ONLY the host window's own
    /// content, so Cotabby's overlay panels are structurally excluded from the image even while
    /// the ghost is on screen — the probe always sees clean host pixels.
    /// Returns the image, the backing scale it was rendered at, and the band actually captured in
    /// Cocoa coordinates (the request is clamped to the window, so the caller must map pixel rows
    /// against this rect, not the requested one).
    func captureBand(
        cocoaRect: CGRect,
        processIdentifier: pid_t
    ) async throws -> (image: CGImage, scale: CGFloat, capturedCocoaRect: CGRect) {
        guard CGPreflightScreenCaptureAccess() else {
            throw WindowScreenshotError.screenRecordingPermissionMissing
        }

        let shareableContent = try await currentShareableContent()
        let matchingWindow =
            shareableContent.windows.first(where: {
                $0.owningApplication?.processID == processIdentifier && $0.isActive && $0.isOnScreen
            })
            ?? shareableContent.windows.first(where: {
                $0.owningApplication?.processID == processIdentifier && $0.isOnScreen
            })
        guard let matchingWindow else {
            throw WindowScreenshotError.noVisibleWindowForProcess(processIdentifier)
        }

        let sourceRect = convertBetweenAppKitAndCG(rect: cocoaRect)
            .intersection(matchingWindow.frame)
            .integral
        guard !sourceRect.isEmpty else {
            throw WindowScreenshotError.captureFailed("Probe band lies outside the host window.")
        }
        let outputScale = backingScaleFactor(for: sourceRect)

        let filter = SCContentFilter(desktopIndependentWindow: matchingWindow)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(
            x: sourceRect.minX - matchingWindow.frame.minX,
            y: sourceRect.minY - matchingWindow.frame.minY,
            width: sourceRect.width,
            height: sourceRect.height
        )
        configuration.width = max(Int((sourceRect.width * outputScale).rounded(.up)), 1)
        configuration.height = max(Int((sourceRect.height * outputScale).rounded(.up)), 1)
        configuration.showsCursor = false

        let image = try await captureImage(filter: filter, configuration: configuration)
        // The Cocoa↔CG flip is an involution, so converting the clamped CG rect back yields the
        // band's true Cocoa frame for row→screen mapping.
        return (image, outputScale, convertBetweenAppKitAndCG(rect: sourceRect))
    }

    private func snapshotRect(
        around context: FocusedInputSnapshot,
        windowFrame: CGRect,
        snapshotDimension: CGFloat
    ) -> CGRect {
        let targetHeight = min(CaptureMetrics.verticalContextHeight, windowFrame.height)
        let targetWidth: CGFloat
        let proposedX: CGFloat
        let proposedY: CGFloat

        if let inputFrameAppKit = context.inputFrameRect, !inputFrameAppKit.isEmpty {
            let inputFrameCG = convertBetweenAppKitAndCG(rect: inputFrameAppKit)
            targetWidth = min(
                inputFrameCG.width + (CaptureMetrics.horizontalPadding * 2),
                windowFrame.width
            )
            proposedX = inputFrameCG.minX - CaptureMetrics.horizontalPadding
            proposedY = inputFrameCG.minY - targetHeight
        } else {
            // Fall back to the caret if the input frame is completely unavailable.
            let caretRectCG = convertBetweenAppKitAndCG(rect: context.caretRect)
            targetWidth = min(
                snapshotDimension + (CaptureMetrics.horizontalPadding * 2),
                windowFrame.width
            )
            proposedX = caretRectCG.midX - (targetWidth / 2)
            proposedY = caretRectCG.minY - targetHeight
        }

        // Clamp within the window frame bounds so SCK does not fail or crop incorrectly.
        let clampedX = min(max(proposedX, windowFrame.minX), windowFrame.maxX - targetWidth)
        let clampedY = min(max(proposedY, windowFrame.minY), windowFrame.maxY - targetHeight)

        return CGRect(
            x: clampedX,
            y: clampedY,
            width: targetWidth,
            height: targetHeight
        ).integral
    }

    private func backingScaleFactor(for rect: CGRect) -> CGFloat {
        let appKitRect = convertBetweenAppKitAndCG(rect: rect)
        let midpoint = CGPoint(x: appKitRect.midX, y: appKitRect.midY)

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(midpoint) }) {
            return screen.backingScaleFactor
        }

        return NSScreen.main?.backingScaleFactor ?? 2.0
    }

    private func convertBetweenAppKitAndCG(rect: CGRect) -> CGRect {
        let desktopBounds = NSScreen.screens.map(\.frame).reduce(into: CGRect.null) {
            $0 = $0.union($1)
        }
        guard !desktopBounds.isNull else { return rect }
        return CGRect(
            x: rect.origin.x,
            y: desktopBounds.maxY - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// Wraps ScreenCaptureKit's callback API so the rest of the app can use structured concurrency.
    private func currentShareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
                if let error {
                    continuation.resume(throwing: WindowScreenshotError.captureFailed(error.localizedDescription))
                    return
                }

                guard let content else {
                    continuation.resume(throwing: WindowScreenshotError.captureFailed("Shareable content was unavailable."))
                    return
                }

                continuation.resume(returning: content)
            }
        }
    }

    /// Captures one CGImage for the chosen window filter.
    private func captureImage(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: WindowScreenshotError.captureFailed(error.localizedDescription))
                    return
                }

                guard let image else {
                    continuation.resume(throwing: WindowScreenshotError.captureFailed("ScreenCaptureKit returned no image."))
                    return
                }

                continuation.resume(returning: image)
            }
        }
    }
}
