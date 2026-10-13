import AppKit
import ScreenCaptureKit

/// Screenshots of an agent's screen.
public enum Capture {
    public enum Failure: Error, CustomStringConvertible {
        case notPermitted
        case displayMissing
        case encodingFailed

        public var description: String {
            switch self {
            case .notPermitted:
                return "Screen Recording permission is missing for the app that started Backstage."
            case .displayMissing:
                return "The agent screen is not available to ScreenCaptureKit."
            case .encodingFailed:
                return "Could not encode the screenshot."
            }
        }
    }

    /// Captures a display at `pointSize`, so screenshot pixels line up 1:1 with the points the
    /// agent clicks.
    public static func image(of displayID: CGDirectDisplayID, pointSize: CGSize) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else { throw Failure.notPermitted }
        let content: SCShareableContent = try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                if let content { continuation.resume(returning: content) }
                else { continuation.resume(throwing: error ?? Failure.displayMissing) }
            }
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw Failure.displayMissing
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = Int(pointSize.width)
        configuration.height = Int(pointSize.height)
        configuration.showsCursor = false
        configuration.capturesAudio = false
        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? Failure.displayMissing) }
            }
        }
    }

    /// PNG keeps text crisp. Busy screens (photos, video) fall back to JPEG to stay small enough
    /// for the agent's context.
    public static func encode(_ image: CGImage, maxBytes: Int = 1_200_000) throws -> (data: Data, mimeType: String) {
        let rep = NSBitmapImageRep(cgImage: image)
        if let png = rep.representation(using: .png, properties: [:]), png.count <= maxBytes {
            return (png, "image/png")
        }
        for quality in [0.85, 0.7, 0.55] {
            if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]),
               jpeg.count <= maxBytes || quality == 0.55 {
                return (jpeg, "image/jpeg")
            }
        }
        throw Failure.encodingFailed
    }
}
