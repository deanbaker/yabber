import UIKit

/// Dictation keyboard. It never touches audio: it signals the app over Darwin notifications,
/// shows the app's status, and inserts the returned text.
final class KeyboardViewController: UIInputViewController {
    private enum Mode: Equatable {
        case idle, connecting, recording(Date), transcribing
    }

    private var mode: Mode = .idle { didSet { if mode != oldValue { render() } } }
    private var message: String? { didSet { render() } }
    private var openedApp = false
    private var connectStartedAt = Date.distantPast
    private var lastStatusAt = Date.distantPast
    private var connectTimeout: DispatchWorkItem?
    private var tick: Timer?
    private var deleteRepeat: Timer?

    private let statusLabel = UILabel()
    private let micButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .large)
    private let globeButton = UIButton(type: .system)
    private let fullAccessMessage = "Turn on Allow Full Access: Settings → General → Keyboard → Keyboards → Yabber"

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        DarwinCenter.shared.observe(.status) { [weak self] in
            self?.lastStatusAt = Date()
            self?.refresh()
        }
        SharedLog.write("kbd", "loaded (fullAccess=\(hasFullAccess))")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
        if hasFullAccess { DarwinCenter.shared.post(.ping) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        tick?.invalidate()
        tick = nil
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        globeButton.isHidden = !needsInputModeSwitchKey
    }

    // MARK: - Actions

    @objc private func micTapped() {
        guard hasFullAccess else { message = fullAccessMessage; return }
        feedback()
        let request = DictationRequest(id: UUID(), createdAt: Date())
        SharedStore.write(request, to: .request)
        message = nil
        openedApp = false
        connectStartedAt = Date()
        mode = .connecting

        let status = SharedStore.read(AppStatus.self, from: .status)
        guard status?.sessionActive == true else {
            SharedLog.write("kbd", "mic: no session, opening app")
            openApp()
            return
        }
        SharedLog.write("kbd", "mic: session looks active, sending start \(request.id.uuidString.prefix(8))")
        DarwinCenter.shared.post(.start)
        // A suspended or killed app can't answer; if nothing comes back, jump to it.
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.mode == .connecting, !self.openedApp else { return }
            SharedLog.write("kbd", "no reply to start in 0.8 s, opening app")
            self.openApp()
        }
        connectTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: timeout)
    }

    @objc private func stopTapped() {
        feedback()
        let sentAt = Date()
        mode = .transcribing
        DarwinCenter.shared.post(.stop)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.mode == .transcribing, self.lastStatusAt < sentAt else { return }
            SharedLog.write("kbd", "no reply to stop")
            self.mode = .idle
            self.message = "Yabber didn't respond. Open it to recover the recording."
        }
    }

    @objc private func cancelTapped() {
        feedback()
        DarwinCenter.shared.post(.cancel)
        mode = .idle
        message = nil
    }

    @objc private func spaceTapped() { textDocumentProxy.insertText(" ") }
    @objc private func returnTapped() { textDocumentProxy.insertText("\n") }

    @objc private func deleteDown() {
        textDocumentProxy.deleteBackward()
        deleteRepeat?.invalidate()
        deleteRepeat = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.deleteRepeat = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                self?.textDocumentProxy.deleteBackward()
            }
        }
    }

    @objc private func deleteUp() {
        deleteRepeat?.invalidate()
        deleteRepeat = nil
    }

    // MARK: - Opening the app

    /// The responder-chain route is what Apple DTS suggests for keyboards; it needs Full Access on iOS 26.
    /// `extensionContext.open` is the fallback (it is documented not to work for keyboards).
    private func openApp() {
        guard !openedApp else { return }
        openedApp = true
        connectTimeout?.cancel()
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(YB.dictateURL, options: [:]) { [weak self] success in
                    SharedLog.write("kbd", "open app via UIApplication: \(success)")
                    if !success { self?.openFailed() }
                }
                return
            }
            responder = current.next
        }
        extensionContext?.open(YB.dictateURL) { [weak self] success in
            SharedLog.write("kbd", "open app via extensionContext: \(success)")
            if !success { DispatchQueue.main.async { self?.openFailed() } }
        }
    }

    private func openFailed() {
        mode = .idle
        message = "Couldn't open Yabber. Open it, tap Start session, then come back."
    }

    // MARK: - Status

    private func refresh() {
        guard hasFullAccess else {
            mode = .idle
            message = fullAccessMessage
            return
        }
        guard let status = SharedStore.read(AppStatus.self, from: .status) else { return }
        let request = SharedStore.read(DictationRequest.self, from: .request)
        let isMine = request != nil && status.requestID == request?.id

        if isMine, let request {
            switch status.phase {
            case .recording:
                connectTimeout?.cancel()
                mode = .recording(status.recordingStartedAt ?? Date())
            case .transcribing:
                connectTimeout?.cancel()
                mode = .transcribing
            case .done:
                connectTimeout?.cancel()
                insertIfNeeded(status, request: request)
                mode = .idle
            case .failed:
                mode = .idle
                message = status.message
            case .idle:
                if mode != .connecting { mode = .idle }
            }
        } else if mode == .connecting {
            // The app answered but isn't recording our request: it has no session and is in the
            // background, so only a jump to the foreground can start the mic.
            if !status.sessionActive && status.updatedAt > connectStartedAt {
                SharedLog.write("kbd", "app replied without a session, opening app")
                openApp()
            }
        } else if mode != .idle {
            mode = .idle
        }
    }

    private func insertIfNeeded(_ status: AppStatus, request: DictationRequest) {
        var state = SharedStore.read(KeyboardState.self, from: .keyboard) ?? KeyboardState()
        guard state.lastInsertedID != request.id,
              Date().timeIntervalSince(request.createdAt) < 15 * 60 else { return }
        state.lastInsertedID = request.id
        SharedStore.write(state, to: .keyboard)
        guard let text = status.text, !text.isEmpty else {
            message = status.message ?? "No speech detected"
            return
        }
        textDocumentProxy.insertText(withLeadingSpace(text))
        message = nil
        SharedLog.write("kbd", "inserted \(text.count) chars for \(request.id.uuidString.prefix(8))")
    }

    private func withLeadingSpace(_ text: String) -> String {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        guard let last = before.last, !last.isWhitespace,
              let first = text.first, !",.!?;:)".contains(first) else { return text }
        return " " + text
    }

    // MARK: - UI

    private func render() {
        tick?.invalidate()
        tick = nil
        micButton.isHidden = true
        stopButton.isHidden = true
        cancelButton.isHidden = true
        spinner.stopAnimating()

        switch mode {
        case .idle:
            micButton.isHidden = false
            statusLabel.text = message ?? "Tap to dictate"
            statusLabel.textColor = message == nil ? .secondaryLabel : .systemOrange
        case .connecting:
            spinner.startAnimating()
            cancelButton.isHidden = false
            statusLabel.text = openedApp ? "Opening Yabber… then swipe back" : "Connecting…"
            statusLabel.textColor = .secondaryLabel
        case .recording(let since):
            stopButton.isHidden = false
            cancelButton.isHidden = false
            statusLabel.textColor = .systemRed
            let update = { [weak self] in
                let s = max(0, Int(Date().timeIntervalSince(since)))
                self?.statusLabel.text = String(format: "● Listening  %d:%02d", s / 60, s % 60)
            }
            update()
            tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in update() }
        case .transcribing:
            spinner.startAnimating()
            statusLabel.text = "Transcribing…"
            statusLabel.textColor = .secondaryLabel
        }
    }

    private func buildUI() {
        guard let root = inputView else { return }
        let height = root.heightAnchor.constraint(equalToConstant: 236)
        height.priority = .init(999)
        height.isActive = true

        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.7

        style(micButton, symbol: "mic.fill", size: 34, tint: .white, background: .systemBlue, diameter: 84)
        style(stopButton, symbol: "stop.fill", size: 30, tint: .white, background: .systemRed, diameter: 84)
        style(cancelButton, symbol: "xmark", size: 20, tint: .label, background: .tertiarySystemFill, diameter: 56)
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        micButton.accessibilityLabel = "Dictate"
        stopButton.accessibilityLabel = "Stop and insert"
        cancelButton.accessibilityLabel = "Cancel dictation"

        let center = UIStackView(arrangedSubviews: [cancelButton, micButton, spinner, stopButton])
        center.axis = .horizontal
        center.alignment = .center
        center.spacing = 28

        globeButton.setImage(UIImage(systemName: "globe"), for: .normal)
        globeButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        let space = key(title: "space", action: #selector(spaceTapped))
        let delete = key(symbol: "delete.left", action: nil)
        delete.addTarget(self, action: #selector(deleteDown), for: .touchDown)
        delete.addTarget(self, action: #selector(deleteUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        let ret = key(symbol: "return", action: #selector(returnTapped))
        for button in [globeButton] { keyStyle(button) }

        let bottom = UIStackView(arrangedSubviews: [globeButton, space, delete, ret])
        bottom.axis = .horizontal
        bottom.spacing = 6
        bottom.distribution = .fill
        globeButton.widthAnchor.constraint(equalToConstant: 48).isActive = true
        delete.widthAnchor.constraint(equalToConstant: 60).isActive = true
        ret.widthAnchor.constraint(equalToConstant: 60).isActive = true
        bottom.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let centerHolder = UIView()
        center.translatesAutoresizingMaskIntoConstraints = false
        centerHolder.addSubview(center)
        NSLayoutConstraint.activate([
            center.centerXAnchor.constraint(equalTo: centerHolder.centerXAnchor),
            center.centerYAnchor.constraint(equalTo: centerHolder.centerYAnchor),
        ])

        let stack = UIStackView(arrangedSubviews: [statusLabel, centerHolder, bottom])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            statusLabel.heightAnchor.constraint(equalToConstant: 40),
        ])
        render()
    }

    private func style(_ button: UIButton, symbol: String, size: CGFloat, tint: UIColor, background: UIColor, diameter: CGFloat) {
        let config = UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        button.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
        button.tintColor = tint
        button.backgroundColor = background
        button.layer.cornerRadius = diameter / 2
        button.widthAnchor.constraint(equalToConstant: diameter).isActive = true
        button.heightAnchor.constraint(equalToConstant: diameter).isActive = true
    }

    private func key(title: String? = nil, symbol: String? = nil, action: Selector?) -> UIButton {
        let button = UIButton(type: .system)
        if let title { button.setTitle(title, for: .normal) }
        if let symbol { button.setImage(UIImage(systemName: symbol), for: .normal) }
        if let action { button.addTarget(self, action: action, for: .touchUpInside) }
        keyStyle(button)
        return button
    }

    private func keyStyle(_ button: UIButton) {
        button.backgroundColor = .tertiarySystemFill
        button.tintColor = .label
        button.setTitleColor(.label, for: .normal)
        button.layer.cornerRadius = 8
    }

    private func feedback() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
