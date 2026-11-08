import AppKit
import AVFoundation
import AVKit
import UniformTypeIdentifiers

/// F3 on a video or sound file: plays it with the system player. Page Up and Page Down go through the others in the folder.
final class MediaViewerController: NSWindowController, NSWindowDelegate {
    static func isMedia(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .audiovisualContent)
    }

    var onClosed: (() -> Void)?
    var onIndexChange: ((String) -> Void)?

    private let items: [ViewerItem]
    private var index: Int
    private let playerView = AVPlayerView()
    private let message = NSTextField(labelWithString: "")
    private var keyMonitor: Any?
    private var sizedOnce = false
    private var loadToken = 0

    init(items: [ViewerItem], start: Int) {
        self.items = items
        index = start
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.minSize = NSSize(width: 360, height: 220)
        super.init(window: window)
        window.delegate = self
        build(in: window)
        window.center()
        show(index: start)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build(in window: NSWindow) {
        guard let content = window.contentView else { return }
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        playerView.translatesAutoresizingMaskIntoConstraints = false
        message.textColor = .white
        message.alignment = .center
        message.isHidden = true
        message.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(playerView)
        content.addSubview(message)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            message.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -40),
        ])
        // The player keeps some keys for itself, so these are caught before it sees them.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private var player: AVPlayer? { playerView.player }

    private func show(index newIndex: Int) {
        guard newIndex >= 0, newIndex < items.count else { return }
        index = newIndex
        let item = items[newIndex]
        loadToken += 1
        let token = loadToken
        player?.pause()
        window?.title = "\(item.name) — \(newIndex + 1) / \(items.count)"
        message.isHidden = true
        onIndexChange?(item.name)
        item.fetch { [weak self] url in
            DispatchQueue.main.async {
                guard let self, self.loadToken == token else { return }
                guard let url else { return self.fail(item.name) }
                self.play(url, name: item.name, token: token)
            }
        }
    }

    private func play(_ url: URL, name: String, token: Int) {
        let asset = AVURLAsset(url: url)
        Task { @MainActor [weak self] in
            let playable = (try? await asset.load(.isPlayable)) ?? false
            let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            var size: CGSize?
            if let track = tracks.first, let natural = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                let turned = natural.applying(transform)
                size = CGSize(width: abs(turned.width), height: abs(turned.height))
            }
            guard let self, self.loadToken == token else { return }
            guard playable else { return self.fail(name) }
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            self.playerView.player = player
            if let size, !self.sizedOnce { self.fit(size) }
            player.play()
        }
    }

    private func fail(_ name: String) {
        playerView.player = nil
        message.stringValue = L10n.t("preview.none", name)
        message.isHidden = false
    }

    /// The first video sets the window size, at most most of the screen.
    private func fit(_ size: CGSize) {
        guard let window, let screen = window.screen ?? NSScreen.main, size.width > 0, size.height > 0 else { return }
        sizedOnce = true
        let room = screen.visibleFrame.insetBy(dx: 40, dy: 40)
        let scale = min(1, room.width / size.width, room.height / size.height)
        let wanted = NSSize(width: max(360, size.width * scale), height: max(220, size.height * scale))
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: wanted))
        frame.origin = NSPoint(x: room.midX - frame.width / 2, y: room.midY - frame.height / 2)
        window.setFrame(frame, display: true)
    }

    private func seek(by seconds: Double) {
        guard let player else { return }
        let target = CMTimeAdd(player.currentTime(), CMTime(seconds: seconds, preferredTimescale: 600))
        player.seek(to: CMTimeMaximum(.zero, target))
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty else { return false }
        switch event.keyCode {
        case 53, 99: // Esc, F3
            if window?.styleMask.contains(.fullScreen) == true, event.keyCode == 53 { window?.toggleFullScreen(nil) } else { window?.performClose(nil) }
        case 49: // space
            guard let player else { return true }
            if player.rate == 0 {
                if let item = player.currentItem, item.currentTime() >= item.duration { player.seek(to: .zero) }
                player.play()
            } else {
                player.pause()
            }
        case 123: seek(by: -5)
        case 124: seek(by: 5)
        case 121, 125: show(index: index + 1) // page down, down
        case 116, 126: show(index: index - 1) // page up, up
        default: return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        player?.pause()
        playerView.player = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        onClosed?()
    }
}
