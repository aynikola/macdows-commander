import AppKit
import Darwin
import MacdowsCore
import SwiftTerm

/// What a terminal session is attached to. Each target keeps its own running session.
enum TerminalTarget: Hashable {
    case local
    case site(UUID)
}

/// One shell inside a terminal view: local, or on an SSH server.
final class TerminalSession: LocalProcessTerminalViewDelegate {
    let target: TerminalTarget
    let view: LocalProcessTerminalView
    private(set) var isRunning = false
    private(set) var directory: String
    var onTerminated: ((TerminalSession) -> Void)?
    var onDirectoryChange: (() -> Void)?

    init(target: TerminalTarget, directory: String) {
        self.target = target
        self.directory = directory
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 260))
        view.font = AppFont.mono
        applyTheme()
        view.processDelegate = self
    }

    func applyTheme() {
        view.nativeBackgroundColor = Theme.resolved(Theme.terminalBackground)
        view.nativeForegroundColor = Theme.resolved(Theme.terminalText)
        view.caretColor = Theme.resolved(Theme.accent)
    }

    private static func environment(extra: [String: String] = [:]) -> [String] {
        var values = ProcessInfo.processInfo.environment
        values["TERM"] = "xterm-256color"
        values["COLORTERM"] = "truecolor"
        // Apps started from Finder get no locale, and Turkish file names need UTF-8.
        if values["LANG"] == nil { values["LANG"] = "en_US.UTF-8" }
        extra.forEach { values[$0.key] = $0.value }
        return values.map { "\($0.key)=\($0.value)" }
    }

    private static var loginShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell, shell.pointee != 0 {
            return String(cString: shell)
        }
        return "/bin/zsh"
    }

    func startLocal() {
        let shell = Self.loginShell
        let name = "-" + (shell as NSString).lastPathComponent
        isRunning = true
        view.startProcess(executable: shell, args: [], environment: Self.environment(), execName: name, currentDirectory: directory)
    }

    func startSSH(_ invocation: SSHClient.ShellInvocation) {
        isRunning = true
        view.startProcess(executable: "/usr/bin/ssh", args: invocation.arguments, environment: Self.environment(extra: invocation.environment), execName: "ssh")
    }

    /// Types a command at the prompt. `run` false leaves it there for Enter, and `back` puts the cursor that far from its end.
    @discardableResult
    func type(_ command: String, run: Bool, back: Int = 0) -> Bool {
        guard isRunning, !view.getTerminal().isCurrentBufferAlternate else { return false }
        view.send(txt: "\u{05}\u{15}" + command + (run ? "\r" : String(repeating: "\u{1b}[D", count: back)))
        return true
    }

    /// Shown once when a session starts, before the shell's first prompt.
    func showHints() {
        let lines = L10n.t("terminal.hints").components(separatedBy: "\n")
        view.feed(text: lines.map { "\u{1b}[2m\($0)\u{1b}[0m\r\n" }.joined() + "\r\n")
    }

    func stop() {
        guard isRunning else { return }
        // Interactive shells ignore SIGTERM, so hang up the way closing a terminal window does.
        kill(view.process.shellPid, SIGHUP)
    }

    /// True only for a local shell waiting at its prompt. Over SSH the foreground program is always ssh itself.
    var isLocalShellIdle: Bool {
        guard isRunning, target == .local else { return false }
        return tcgetpgrp(view.process.childfd) == view.process.shellPid
    }

    /// Types a `cd` into the shell. Full-screen programs such as vim are left alone.
    func changeDirectory(_ path: String) {
        guard isRunning, path != directory, !view.getTerminal().isCurrentBufferAlternate else { return }
        directory = path
        onDirectoryChange?()
        // Ctrl-E Ctrl-U clears half-typed text, so it can't run together with the cd.
        view.send(txt: "\u{05}\u{15} cd \(SSHClient.shellQuote(path))\r")
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isRunning = false
        onTerminated?(self)
    }
}

/// The strip above the terminal. Dragging it resizes the pane.
private final class PaneHeader: NSView {
    var onDrag: ((CGFloat) -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }

    override func mouseDragged(with event: NSEvent) { onDrag?(event.deltaY) }
}

/// Bottom pane of the main window, holding one session per target and showing one at a time.
final class TerminalPane: NSView {
    var onClose: (() -> Void)?
    var onResize: ((CGFloat) -> Void)?

    private let header = PaneHeader()
    private let titleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let holder = NSView()
    private let gitLabel = NSTextField(labelWithString: "Git")
    private let gitBar = NSStackView()
    private var sessions: [TerminalTarget: TerminalSession] = [:]
    private var titles: [TerminalTarget: String] = [:]
    private(set) var current: TerminalSession?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        applyLayerColors()

        titleLabel.font = AppFont.interface(11, bold: true)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintLabel.font = AppFont.interface(11)
        hintLabel.textColor = .secondaryLabelColor
        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .small
        closeButton.refusesFirstResponder = true
        closeButton.target = self
        closeButton.action = #selector(closeClicked)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [titleLabel, spacer, hintLabel, closeButton])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(row)
        header.onDrag = { [weak self] delta in self?.onResize?(delta) }

        buildGitBar()
        [header, gitBar, holder].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 26),
            row.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
            gitBar.topAnchor.constraint(equalTo: header.bottomAnchor),
            gitBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            gitBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            holder.topAnchor.constraint(equalTo: gitBar.bottomAnchor),
            holder.leadingAnchor.constraint(equalTo: leadingAnchor),
            holder.trailingAnchor.constraint(equalTo: trailingAnchor),
            holder.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        relabel()
        NotificationCenter.default.addObserver(self, selector: #selector(fontChanged), name: .appFontChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .themeChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    /// Commands that only look run at once. Those that change something wait at the prompt for Enter.
    static let gitCommands: [(title: String, command: String, run: Bool, back: Int)] = [
        ("status", "git status", true, 0),
        ("diff", "git diff", true, 0),
        ("log", "git log --oneline -20", true, 0),
        ("branch", "git branch -a", true, 0),
        ("add .", "git add .", false, 0),
        ("commit", "git commit -m \"\"", false, 1),
        ("pull", "git pull", false, 0),
        ("push", "git push", false, 0),
        ("switch", "git switch ", false, 0),
    ]

    private func buildGitBar() {
        gitLabel.font = AppFont.interface(11, bold: true)
        gitLabel.textColor = .secondaryLabelColor
        gitBar.addArrangedSubview(gitLabel)
        for (index, git) in Self.gitCommands.enumerated() {
            let button = NSButton(title: git.title, target: self, action: #selector(gitClicked(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = AppFont.interface(11)
            button.refusesFirstResponder = true
            button.toolTip = git.command + (git.run ? "" : " · " + L10n.t("terminal.gitWaits"))
            gitBar.addArrangedSubview(button)
        }
        gitBar.addArrangedSubview(NSView())
        gitBar.spacing = 4
        gitBar.edgeInsets = NSEdgeInsets(top: 2, left: 10, bottom: 4, right: 6)
    }

    @objc private func gitClicked(_ sender: NSButton) {
        guard let current else { return }
        let git = Self.gitCommands[sender.tag]
        if !current.type(git.command, run: git.run, back: git.back) { NSSound.beep() }
        window?.makeFirstResponder(current.view)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshBranch() }
    }

    /// Shows the branch of a local shell's folder. A server's folder can't be asked from here.
    func refreshBranch() {
        guard let current, current.target == .local else {
            gitLabel.stringValue = "Git"
            return
        }
        let directory = current.directory
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", directory, "branch", "--show-current"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var branch = ""
            if (try? process.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 { branch = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            DispatchQueue.main.async { self?.gitLabel.stringValue = branch.isEmpty ? "Git" : "Git: \(branch)" }
        }
    }

    private func applyLayerColors() {
        layer?.backgroundColor = Theme.resolved(Theme.terminalBackground).cgColor
        layer?.borderColor = Theme.resolved(Theme.border).cgColor
    }

    @objc private func themeChanged() {
        applyLayerColors()
        sessions.values.forEach { $0.applyTheme() }
    }

    @objc private func fontChanged() {
        sessions.values.forEach { $0.view.font = AppFont.mono }
    }

    func relabel() {
        hintLabel.stringValue = L10n.t("terminal.hint")
        closeButton.title = L10n.t("terminal.hide")
        updateTitle()
    }

    private func updateTitle() {
        guard let current else { titleLabel.stringValue = L10n.t("terminal.title"); return }
        let name = titles[current.target] ?? L10n.t("panel.local")
        let state = current.isRunning ? "" : " · " + L10n.t("terminal.ended")
        titleLabel.stringValue = "\(L10n.t("terminal.title")) · \(name)\(state)"
    }

    @objc private func closeClicked() { onClose?() }

    /// The running session for a target, if any.
    func runningSession(for target: TerminalTarget) -> TerminalSession? {
        guard let session = sessions[target], session.isRunning else { return nil }
        return session
    }

    /// Shows the target's session, creating one with `start` when it has none.
    /// An ended session stays on screen so its last message can be read, until `restart` asks for a new one.
    /// Layout happens before starting so the shell sees the real terminal size from its first line.
    @discardableResult
    func show(target: TerminalTarget, title: String, directory: String, restart: Bool, start: (TerminalSession) -> Void) -> TerminalSession {
        titles[target] = title
        if let session = sessions[target], session.isRunning || !restart {
            display(session)
            return session
        }
        let session = TerminalSession(target: target, directory: directory)
        session.onTerminated = { [weak self] ended in
            ended.view.feed(text: "\r\n[\(L10n.t("terminal.ended"))]\r\n")
            self?.updateTitle()
        }
        sessions[target]?.view.removeFromSuperview()
        sessions[target] = session
        session.onDirectoryChange = { [weak self] in self?.refreshBranch() }
        display(session)
        window?.contentView?.layoutSubtreeIfNeeded()
        session.showHints()
        start(session)
        refreshBranch()
        updateTitle()
        return session
    }

    private func display(_ session: TerminalSession) {
        defer { updateTitle() }
        guard current !== session || session.view.superview == nil else { return }
        current?.view.removeFromSuperview()
        current = session
        let view = session.view
        view.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: holder.topAnchor, constant: 2),
            view.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 4),
            view.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -2),
            view.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -2),
        ])
    }

    func stopAll() {
        sessions.values.forEach { $0.stop() }
    }
}
