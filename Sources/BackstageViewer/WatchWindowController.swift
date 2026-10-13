import AppKit
import BackstageCore
import ScreenCaptureKit

/// A live view of one agent screen, with the controls underneath.
///
/// Frames come from ScreenCaptureKit as IOSurfaces and go straight into a layer, so watching
/// costs almost nothing. The strip of the user's menu bar at the top of the agent screen is cut
/// off, since it is not the agent's.
final class WatchWindowController: NSWindowController, NSWindowDelegate {
    let pid: Int32
    var onClose: (() -> Void)?

    private var session: Registry.SessionInfo
    private let frameView = NSView()
    private let placeholder = NSTextField(labelWithString: "Connecting…")
    private let statusLabel = NSTextField(labelWithString: "")
    private let actionLabel = NSTextField(labelWithString: "")
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    private let takeOverButton = NSButton(title: "Take Over", target: nil, action: nil)
    private let answerButton = NSButton(title: "Answer…", target: nil, action: nil)
    private var capture: StreamOutput?

    init(session: Registry.SessionInfo) {
        self.pid = session.pid
        self.session = session
        let aspect = CGFloat(session.height) / CGFloat(session.width)
        let width: CGFloat = 960
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: width * aspect + 52),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.minSize = NSSize(width: 520, height: 380)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Backstage Watch")
        super.init(window: window)
        window.delegate = self
        build()
        update(session)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.center()
        showWindow(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        startCapture()
    }

    func update(_ session: Registry.SessionInfo) {
        self.session = session
        window?.title = "\(session.name) — \(session.client)"
        var status = StatusController.describe(session.status).capitalized
        if session.status == .needsYou, let message = session.message { status += ": \(message)" }
        statusLabel.stringValue = status
        statusLabel.textColor = StatusController.color(session.status)
        if session.status != .needsYou, let last = session.lastAction {
            actionLabel.stringValue = StatusController.clip(last, 90)
                + (session.lastActionAt.map { " · " + StatusController.relative($0) } ?? "")
        } else {
            actionLabel.stringValue = ""
        }
        let control = Registry.readControl(pid: pid)
        pauseButton.title = control.paused ? "Resume" : "Pause"
        takeOverButton.title = control.takenOver ? "Give Back" : "Take Over"
        answerButton.isHidden = session.status != .needsYou
    }

    func sessionEnded() {
        capture?.stop()
        capture = nil
        frameView.layer?.contents = nil
        placeholder.stringValue = "This agent has finished and its screen is gone."
        placeholder.isHidden = false
        statusLabel.stringValue = "Ended"
        actionLabel.stringValue = ""
        [pauseButton, takeOverButton, answerButton].forEach { $0.isEnabled = false }
    }

    func windowWillClose(_ notification: Notification) {
        capture?.stop()
        capture = nil
        onClose?()
    }

    // MARK: - Layout

    private func build() {
        guard let content = window?.contentView else { return }
        frameView.wantsLayer = true
        frameView.layer?.backgroundColor = NSColor.black.cgColor
        frameView.layer?.contentsGravity = .resizeAspect
        frameView.translatesAutoresizingMaskIntoConstraints = false

        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.lineBreakMode = .byTruncatingTail
        actionLabel.font = .systemFont(ofSize: 12)
        actionLabel.textColor = .secondaryLabelColor
        actionLabel.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [statusLabel, actionLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The labels take the spare width, which pushes the buttons to the right edge.
        labels.setContentHuggingPriority(.init(1), for: .horizontal)
        statusLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        actionLabel.setContentHuggingPriority(.init(1), for: .horizontal)

        for (button, selector) in [(pauseButton, #selector(togglePause)), (takeOverButton, #selector(toggleTakeOver)),
                                   (answerButton, #selector(answer))] {
            button.target = self
            button.action = selector
            button.bezelStyle = .rounded
        }
        answerButton.keyEquivalent = "\r"

        let bar = NSStackView(views: [labels, answerButton, pauseButton, takeOverButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        bar.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(frameView)
        content.addSubview(placeholder)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            frameView.topAnchor.constraint(equalTo: content.topAnchor),
            frameView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            frameView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            frameView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            placeholder.centerXAnchor.constraint(equalTo: frameView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: frameView.centerYAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    @objc private func togglePause() { Controls.togglePause(pid); refreshSoon() }
    @objc private func toggleTakeOver() { Controls.toggleTakeOver(pid); refreshSoon() }
    @objc private func answer() { Controls.answer(pid); refreshSoon() }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let session = Registry.sessions().first(where: { $0.pid == self.pid }) else { return }
            self.update(session)
        }
    }

    // MARK: - Capture

    private func startCapture() {
        guard capture == nil else { return }
        guard CGPreflightScreenCaptureAccess() else {
            placeholder.stringValue = "Backstage needs Screen Recording permission to show the agent's screen.\nTurn it on in System Settings › Privacy & Security › Screen & System Audio Recording, then reopen this window."
            CGRequestScreenCaptureAccess()
            return
        }
        let output = StreamOutput { [weak self] surface in
            self?.frameView.layer?.contents = surface
            self?.placeholder.isHidden = true
        }
        capture = output
        output.start(displayID: session.displayID) { [weak self] error in
            self?.placeholder.stringValue = "Could not show this screen: \(error.localizedDescription)"
        }
    }
}

/// Receives ScreenCaptureKit frames and hands each finished one to the main thread.
private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let onFrame: (IOSurface) -> Void
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "Backstage watch frames", qos: .userInteractive)

    init(onFrame: @escaping (IOSurface) -> Void) {
        self.onFrame = onFrame
    }

    func start(displayID: CGDirectDisplayID, onError: @escaping (Error) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            guard let display = content?.displays.first(where: { $0.displayID == displayID }) else {
                DispatchQueue.main.async { onError(error ?? NSError(domain: "Backstage", code: 1, userInfo: [NSLocalizedDescriptionKey: "the screen is not available"])) }
                return
            }
            DispatchQueue.main.async {
                let menuBar = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }
                    .map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 0
                let configuration = SCStreamConfiguration()
                let scale = 2
                configuration.sourceRect = CGRect(x: 0, y: menuBar, width: CGFloat(display.width), height: CGFloat(display.height) - menuBar)
                configuration.width = display.width * scale
                configuration.height = Int(CGFloat(display.height) - menuBar) * scale
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 20)
                configuration.queueDepth = 4
                configuration.showsCursor = false
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: self)
                do {
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                } catch {
                    onError(error)
                    return
                }
                self.stream = stream
                stream.startCapture { error in
                    if let error { DispatchQueue.main.async { onError(error) } }
                }
            }
        }
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { self.onFrame(surface) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.warn("watch stream stopped: \(error.localizedDescription)")
    }
}
