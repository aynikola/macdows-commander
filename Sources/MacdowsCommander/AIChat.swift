import AppKit
import MacdowsCore

/// Where the AI is set up: which service, its address, model and key. Used by the F12 chat and by Write.
final class AISettingsForm: NSObject {
    private let store: AISettingsStore
    private let provider = NSPopUpButton()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let keyLink = NSButton()
    private let address = NSTextField()
    private let model = NSComboBox()
    private let key = NSSecureTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let loadButton = NSButton(title: "", target: nil, action: nil)
    private let testButton = NSButton(title: "", target: nil, action: nil)
    private let findButton = NSButton(title: "", target: nil, action: nil)
    private var work: Task<Void, Never>?
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 270))

    init(store: AISettingsStore = AISettingsStore()) {
        self.store = store
        super.init()
        let saved = store.load()
        provider.addItems(withTitles: AIProviders.all.map(\.name))
        provider.selectItem(at: AIProviders.all.firstIndex { $0.id == saved.providerID } ?? 0)
        provider.target = self
        provider.action = #selector(providerChanged)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        keyLink.title = L10n.t("ai.getKey")
        keyLink.isBordered = false
        keyLink.contentTintColor = .linkColor
        keyLink.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        keyLink.target = self
        keyLink.action = #selector(openKeyPage)
        model.completes = true
        model.usesDataSource = false
        loadButton.title = L10n.t("ai.loadModels")
        loadButton.target = self
        loadButton.action = #selector(loadModelsClicked)
        testButton.title = L10n.t("ai.test")
        testButton.target = self
        testButton.action = #selector(runTest)
        findButton.title = L10n.t("ai.findWorking")
        findButton.target = self
        findButton.action = #selector(findWorking)
        for button in [loadButton, testButton, findButton] { button.bezelStyle = .rounded; button.controlSize = .small }
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.maximumNumberOfLines = 3

        func label(_ key: String) -> NSTextField {
            let field = NSTextField(labelWithString: L10n.t(key))
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 70).isActive = true
            return field
        }
        func row(_ views: [NSView]) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.spacing = 8
            stack.alignment = .centerY
            return stack
        }
        address.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        key.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        model.widthAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        let noteRow = row([NSView(), note])
        let stack = NSStackView(views: [
            row([label("ai.provider"), provider]),
            noteRow,
            row([NSView(), keyLink]),
            row([label("ai.address"), address]),
            row([label("ai.model"), model, loadButton]),
            row([NSView(), findButton]),
            row([label("ai.key"), key]),
            row([NSView(), testButton, status]),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            note.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            status.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])
        fill(with: saved)
    }

    private var chosen: AIProvider { AIProviders.all[max(0, provider.indexOfSelectedItem)] }

    private func fill(with config: AIConfig) {
        let selected = chosen
        note.stringValue = selected.note
        keyLink.isHidden = selected.keyPage == nil
        address.stringValue = config.baseURL
        address.isEnabled = selected.id == "custom"
        model.removeAllItems()
        model.addItems(withObjectValues: AIProviders.choices(for: config, fetched: store.fetchedModels(for: selected.id), working: store.workingModels(for: selected.id)))
        model.stringValue = config.model
        key.stringValue = config.apiKey
        key.placeholderString = selected.needsKey ? L10n.t("ai.keyNeeded") : L10n.t("ai.keyOptional")
        status.stringValue = ""
        // The service's own list is the one that is right, so it is asked for without being told to.
        if !selected.needsKey || !config.apiKey.isEmpty { loadModels(silent: true) }
    }

    var config: AIConfig {
        AIConfig(providerID: chosen.id,
                 baseURL: address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                 model: model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                 apiKey: key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @objc private func providerChanged() { fill(with: store.config(for: chosen.id)) }

    @objc private func openKeyPage() {
        if let page = chosen.keyPage, let url = URL(string: page) { NSWorkspace.shared.open(url) }
    }

    private func show(_ text: String, isError: Bool = false) {
        status.stringValue = text
        status.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    @objc private func loadModelsClicked() { loadModels(silent: false) }

    private func loadModels(silent: Bool) {
        let current = config
        if !silent { show(L10n.t("ai.testing")) }
        work?.cancel()
        work = Task { @MainActor [weak self] in
            do {
                let names = try await AIClient(config: current).models()
                guard let self, self.chosen.id == current.providerID else { return }
                self.store.setFetchedModels(names, for: current.providerID)
                let typed = self.model.stringValue
                self.model.removeAllItems()
                self.model.addItems(withObjectValues: AIProviders.choices(for: current, fetched: names, working: self.store.workingModels(for: current.providerID)))
                self.model.stringValue = typed.isEmpty ? (names.first ?? "") : typed
                self.show(L10n.t("ai.modelsLoaded", String(names.count)))
            } catch {
                if !silent, !(error is CancellationError) { self?.show(error.localizedDescription, isError: true) }
            }
        }
    }

    /// Tries each model with a tiny request and keeps those that answer: quota and retired names are found here, not in the middle of a chat.
    @objc private func findWorking() {
        let current = config
        guard current.isReady else {
            show(L10n.t(current.model.isEmpty && !current.provider.needsKey ? "ai.needModel" : "ai.needKey"), isError: true)
            return
        }
        show(L10n.t("ai.testing"))
        findButton.isEnabled = false
        work?.cancel()
        work = Task { @MainActor [weak self] in
            // The service's own list is the best list of candidates; its suggestions stand in when that cannot be fetched.
            var candidates = (try? await AIClient(config: current).models()) ?? []
            if candidates.isEmpty { candidates = AIClient.chatModels(current.provider.suggestedModels, provider: current.providerID) }
            if candidates.isEmpty, !current.model.isEmpty { candidates = [current.model] }
            let found = Array(await AIClient.working(among: AIProviders.top(candidates, count: 8), config: current) { done, total in
                DispatchQueue.main.async { self?.show(L10n.t("ai.checking", String(done), String(total))) }
            }.prefix(AIProviders.maxChoices))
            guard let self, !Task.isCancelled, self.chosen.id == current.providerID else { return }
            self.findButton.isEnabled = true
            self.store.setFetchedModels(candidates, for: current.providerID)
            self.store.setWorkingModels(found, for: current.providerID)
            let typed = self.model.stringValue
            self.model.removeAllItems()
            self.model.addItems(withObjectValues: AIProviders.choices(for: current, fetched: candidates, working: found))
            // A model that does not answer is replaced by the first one that does.
            self.model.stringValue = found.contains(typed) || found.isEmpty ? typed : found[0]
            self.show(found.isEmpty ? L10n.t("ai.noneWork") : L10n.t("ai.someWork", String(found.count), String(candidates.count)), isError: found.isEmpty)
        }
    }

    @objc private func runTest() {
        let current = config
        guard current.isReady else {
            show(L10n.t(current.model.isEmpty ? "ai.needModel" : "ai.needKey"), isError: true)
            return
        }
        show(L10n.t("ai.testing"))
        work?.cancel()
        work = Task { @MainActor [weak self] in
            do {
                let reply = try await AIClient(config: current).complete([AIMessage(.user, "Reply with the single word: OK")])
                self?.show(L10n.t("ai.testOK", String(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))))
            } catch {
                if !(error is CancellationError) { self?.show(error.localizedDescription, isError: true) }
            }
        }
    }

    func save() {
        work?.cancel()
        store.save(config)
    }

    func cancel() { work?.cancel() }

    /// Shows the form as a sheet on `window`. `done` runs after Save.
    static func present(on window: NSWindow?, done: (() -> Void)? = nil) {
        let form = AISettingsForm()
        let alert = NSAlert()
        alert.messageText = L10n.t("ai.settings")
        alert.accessoryView = form.view
        alert.addButton(withTitle: L10n.t("ai.save"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                form.save()
                done?()
            } else {
                form.cancel()
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}

/// The F12 pane: a conversation with the chosen AI. The text of the file under the cursor can be added to a question.
final class AIChatView: NSView, NSTextFieldDelegate {
    /// The name and text of the file the question can include, or nil when there is none to offer.
    var contextProvider: (() -> (name: String, text: String)?)?
    var onSettings: (() -> Void)?
    var onEscape: (() -> Void)?
    var onConfigChange: ((String) -> Void)?

    private let scroll = NSTextView.scrollableTextView()
    let input = NSTextField()
    private let sendButton = NSButton()
    private let settingsButton = NSButton()
    private let newChatButton = NSButton()
    private let contextCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let modelPopup = NSPopUpButton()
    private let store = AISettingsStore()
    nonisolated(unsafe) private static var listedThisRun = Set<String>()
    private var history: [AIMessage] = []
    private var answering: Task<Void, Never>?
    private var transcript: NSTextView? { scroll.documentView as? NSTextView }
    private var currentContext: (name: String, text: String)?

    static let contextLimit = 20_000

    static let systemPrompt = "You are an assistant inside Macdows Commander, a two-panel file manager for macOS. Be concise and practical. Reply in the language the user writes in. When the content of a file is given, base your answer on it."

    init() {
        super.init(frame: .zero)
        input.placeholderString = L10n.t("ai.placeholder")
        input.font = AppFont.interface(AppFont.size)
        input.delegate = self
        input.target = self
        input.action = #selector(sendClicked)
        input.bezelStyle = .roundedBezel
        sendButton.title = L10n.t("ai.send")
        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(sendClicked)
        settingsButton.title = "⚙ " + L10n.t("ai.settingsShort")
        settingsButton.toolTip = L10n.t("ai.settings")
        settingsButton.bezelStyle = .rounded
        settingsButton.target = self
        settingsButton.action = #selector(settingsClicked)
        newChatButton.title = L10n.t("ai.clear")
        newChatButton.bezelStyle = .rounded
        newChatButton.controlSize = .small
        newChatButton.font = AppFont.interface(11)
        newChatButton.target = self
        newChatButton.action = #selector(newChat)
        contextCheck.controlSize = .small
        contextCheck.font = AppFont.interface(11)
        modelPopup.controlSize = .small
        modelPopup.font = AppFont.interface(11)
        modelPopup.target = self
        modelPopup.action = #selector(modelPicked)
        modelPopup.toolTip = L10n.t("ai.model")
        transcript?.isEditable = false
        transcript?.drawsBackground = false
        transcript?.textContainerInset = NSSize(width: 10, height: 10)
        scroll.drawsBackground = false

        let options = NSStackView(views: [contextCheck, NSView(), modelPopup, newChatButton])
        options.spacing = 8
        let entry = NSStackView(views: [input, sendButton, settingsButton])
        entry.spacing = 6
        let bottom = NSStackView(views: [options, entry])
        bottom.orientation = .vertical
        bottom.alignment = .leading
        bottom.spacing = 6
        for view in [scroll, bottom] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -4),
            bottom.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            bottom.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            options.widthAnchor.constraint(equalTo: bottom.widthAnchor),
            entry.widthAnchor.constraint(equalTo: bottom.widthAnchor),
        ])
        showWelcome()
        refreshContext()
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    // MARK: Transcript

    private func append(_ text: String, color: NSColor = Theme.text, bold: Bool = false, spacingAfter: CGFloat = 0) {
        guard let storage = transcript?.textStorage else { return }
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacingAfter
        storage.append(NSAttributedString(string: text, attributes: [
            .font: bold ? AppFont.interface(AppFont.size, bold: true) : AppFont.interface(AppFont.size),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]))
        transcript?.scrollToEndOfDocument(nil)
    }

    private func showWelcome() {
        transcript?.string = ""
        append(L10n.t("ai.hello"), color: Theme.hiddenText)
    }

    /// The service and model in use, for the title bar: it shows where the text goes.
    var summary: String {
        let config = store.load()
        return "\(config.provider.name.components(separatedBy: " (").first ?? config.provider.name) · \(config.model.isEmpty ? "—" : config.model)"
    }

    /// Called as the cursor moves: offers the file it is on.
    func refreshContext() {
        refreshModels()
        currentContext = contextProvider?()
        if let currentContext {
            contextCheck.title = L10n.t("ai.context", currentContext.name)
            contextCheck.isEnabled = true
        } else {
            contextCheck.title = L10n.t("ai.contextNone")
            contextCheck.state = .off
            contextCheck.isEnabled = false
        }
        onConfigChange?(summary)
    }

    // MARK: Actions

    @objc private func settingsClicked() { onSettings?() }

    @objc private func newChat() {
        stop()
        history = []
        showWelcome()
    }

    func configChanged() {
        refreshModels()
        onConfigChange?(summary)
    }

    // MARK: Model

    /// The models to switch between: the one in use, the service's own list, and the suggestions.
    private func refreshModels() {
        let config = store.load()
        let choices = AIProviders.choices(for: config, fetched: store.fetchedModels(for: config.providerID), working: store.workingModels(for: config.providerID))
        if modelPopup.itemTitles != choices {
            modelPopup.removeAllItems()
            modelPopup.addItems(withTitles: choices)
        }
        modelPopup.selectItem(withTitle: config.model)
        modelPopup.isEnabled = !choices.isEmpty
        // Once per service per run the real list is fetched, so names that were retired drop out of the menu.
        guard config.isReady, Self.listedThisRun.insert(config.providerID).inserted else { return }
        Task { @MainActor [weak self] in
            guard let names = try? await AIClient(config: config).models(), !names.isEmpty else { return }
            self?.store.setFetchedModels(names, for: config.providerID)
            // The first time, each model gets a tiny request, so the menu holds only models that answer; a model that
            // does not (retired, or out of free quota) is replaced by one that does.
            if self?.store.workingModels(for: config.providerID).isEmpty == true {
                // Only the best few are tried, so a first run costs a handful of tiny requests.
                let found = Array(await AIClient.working(among: AIProviders.top(names, count: 8), config: config).prefix(AIProviders.maxChoices))
                if !found.isEmpty, let self {
                    self.store.setWorkingModels(found, for: config.providerID)
                    if !found.contains(config.model), let better = AIProviders.preferred(from: found) {
                        var changed = self.store.load()
                        changed.model = better
                        self.store.save(changed)
                    }
                }
            }
            self?.refreshModels()
            if let summary = self?.summary { self?.onConfigChange?(summary) }
        }
    }

    @objc private func modelPicked() {
        guard let title = modelPopup.titleOfSelectedItem else { return }
        var config = store.load()
        config.model = title
        store.save(config)
        onConfigChange?(summary)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onEscape?()
            return true
        }
        return false
    }

    private func stop() {
        answering?.cancel()
        answering = nil
        sendButton.title = L10n.t("ai.send")
    }

    @objc private func sendClicked() {
        if answering != nil {
            stop()
            return
        }
        let question = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let config = store.load()
        guard config.isReady else {
            append("\n" + L10n.t("ai.notReady") + "\n", color: Theme.warning)
            onSettings?()
            return
        }
        input.stringValue = ""
        if history.isEmpty { transcript?.string = "" }
        var sent = question
        if contextCheck.state == .on, let currentContext {
            sent = "File: \(currentContext.name)\n```\n\(currentContext.text.prefix(Self.contextLimit))\n```\n\n\(question)"
        }
        append(L10n.t("ai.you") + "\n", color: Theme.accent, bold: true)
        append(question + "\n\n", spacingAfter: 2)
        append(L10n.t("ai.assistant") + "\n", color: Theme.accent, bold: true)
        history.append(AIMessage(.user, sent))
        let messages = [AIMessage(.system, Self.systemPrompt)] + history
        sendButton.title = L10n.t("ai.stop")
        var reply = ""
        answering = Task { @MainActor [weak self] in
            do {
                for try await piece in AIClient(config: config).stream(messages) {
                    reply += piece
                    self?.append(piece)
                }
                if reply.isEmpty { self?.append(L10n.t("ai.empty"), color: Theme.hiddenText) }
            } catch {
                if !(error is CancellationError) { self?.append("\n⚠︎ " + error.localizedDescription, color: Theme.warning) }
            }
            guard let self else { return }
            // A stopped or failed answer is kept as far as it got, so the next question still follows from it.
            if !reply.isEmpty { self.history.append(AIMessage(.assistant, reply)) } else { self.history.removeLast() }
            self.append("\n\n")
            self.answering = nil
            self.sendButton.title = L10n.t("ai.send")
        }
    }

    deinit { answering?.cancel() }
}
