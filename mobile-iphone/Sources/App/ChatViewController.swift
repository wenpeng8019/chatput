import UIKit
import WebRTC
import Combine

/// 交互页面：header + 消息列表 + 输入栏 + 屏幕面板（video + minimap 拖拽）。
final class ChatViewController: UIViewController {
    private let connectionId: String
    private let sessionId: String
    private unowned var connections: ConnectionManager?
    private let screenState = ScreenState()
    private var messages: [ChatMessage] = []

    private let headerBar = ChatHeaderBar()
    private let messageList = UITableView(frame: .zero, style: .plain)
    private let inputBar = ChatInputBar()
    private let screenPanel = ScreenPanelView()
    private let screenShadow = UIView()
    private var collapseZone: UIView?
    private var screenPanelTopConstraint: NSLayoutConstraint?
    private var collapseZoneHeightConstraint: NSLayoutConstraint?
    // Keyboard-aware text input bar (matches Android text_input_card)
    private let textInputBar = UIView()
    private let textField = UITextField()
    private let textSendBtn = UIButton(type: .system)
    private let textMicBtn = UIButton(type: .system)
    private var textInputBottomConstraint: NSLayoutConstraint?
    private var inputBarBottomConstraint: NSLayoutConstraint?
    private var messageListToInputBar: NSLayoutConstraint?
    private var messageListToTextBar: NSLayoutConstraint?
    private var kbHeight: CGFloat = 0
    private var isTextMode = false
    private var cancellables = Set<AnyCancellable>()

    override var prefersStatusBarHidden: Bool { screenPanel.isOpen }

    private var session: DesktopSession? {
        connections?.session(connectionId: connectionId, sessionId: sessionId)
    }

    init(connectionId: String, sessionId: String, connections: ConnectionManager?) {
        self.connectionId = connectionId; self.sessionId = sessionId
        self.connections = connections
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        setupHeader(); setupMessages(); setupInput(); setupScreenPanel()
        reloadMessages()
        // Observe session inputAvailable changes (from desktop or engineering menu)
        connections?.$sessions.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, let s = self.session else { return }
            let dp = s.inputAvailable == false
            self.dPadMode = dp
            self.inputBar.isDpadMode = dp
        }.store(in: &cancellables)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        connections?.setScreenListener(connectionId: connectionId, listener: screenState)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let g = screenShadow.layer.sublayers?.first as? CAGradientLayer {
            g.frame = screenShadow.bounds
        }
    }

    private func setupHeader() {
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        headerBar.onBack = { [weak self] in self?.navigationController?.popViewController(animated: true) }
        headerBar.onMenu = { [weak self] in self?.showMenu() }
        headerBar.onEngineering = { [weak self] in self?.showEngineeringMenu() }
        view.addSubview(headerBar)
        if let s = session { headerBar.update(app: s.displayApp, title: s.displayTitle) }
        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
        ])
    }

    private func setupMessages() {
        messageList.transform = CGAffineTransform(scaleX: 1, y: -1)
        messageList.contentInset.top = 8  // visual bottom padding (inverted table)
        messageList.register(MessageCell.self, forCellReuseIdentifier: "c")
        messageList.backgroundColor = .clear; messageList.separatorStyle = .none
        messageList.dataSource = self; messageList.estimatedRowHeight = 60
        messageList.rowHeight = UITableView.automaticDimension
        messageList.showsVerticalScrollIndicator = false
        messageList.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageList)

        NSLayoutConstraint.activate([
            messageList.topAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: 12),
            messageList.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            messageList.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func setupInput() {
        // Voice input bar
        inputBar.translatesAutoresizingMaskIntoConstraints = false
        inputBar.onSend = { [weak self] text in
            guard let self, let s = self.session else { return }
            self.connections?.sendText(session: s, text: text); self.reloadMessages()
        }
        inputBar.onAction = { [weak self] action in
            guard let self, let s = self.session else { return }
            self.connections?.sendAction(session: s, action: action)
        }
        inputBar.onTextModeRequest = { [weak self] in self?.showTextInput() }
        view.addSubview(inputBar)
        let ibBottom = inputBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        inputBarBottomConstraint = ibBottom
        let msgToInput = inputBar.topAnchor.constraint(equalTo: messageList.bottomAnchor)
        messageListToInputBar = msgToInput
        NSLayoutConstraint.activate([
            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ibBottom,
            msgToInput,
        ])

        // Text input bar (keyboard-aware, matches Android text_input_card)
        textInputBar.backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        textInputBar.isHidden = true
        // Top separator line (matches Android 1dp border)
        let sep = UIView(); sep.backgroundColor = UIColor(white: 0.25, alpha: 1)
        sep.translatesAutoresizingMaskIntoConstraints = false; textInputBar.addSubview(sep)
        NSLayoutConstraint.activate([
            sep.topAnchor.constraint(equalTo: textInputBar.topAnchor),
            sep.leadingAnchor.constraint(equalTo: textInputBar.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: textInputBar.trailingAnchor),
            sep.heightAnchor.constraint(equalToConstant: 0.5),
        ])

        textField.placeholder = "输入文字…"; textField.font = .systemFont(ofSize: 16)
        textField.textColor = .white; textField.backgroundColor = UIColor(white: 0.2, alpha: 1)
        textField.layer.cornerRadius = 14
        textField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: 0))
        textField.leftViewMode = .always; textField.returnKeyType = .send
        textField.delegate = self

        textSendBtn.setImage(UIImage(systemName: "paperplane.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
        textSendBtn.tintColor = .white; textSendBtn.backgroundColor = UIColor(red: 1, green: 0.58, blue: 0.22, alpha: 1)
        textSendBtn.layer.cornerRadius = 20
        textSendBtn.addTarget(self, action: #selector(sendTextTapped), for: .touchUpInside)

        textMicBtn.setImage(UIImage(systemName: "mic.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
        textMicBtn.tintColor = UIColor(red: 1, green: 0.58, blue: 0.22, alpha: 1)
        textMicBtn.backgroundColor = UIColor(white: 0.2, alpha: 1); textMicBtn.layer.cornerRadius = 20
        textMicBtn.addTarget(self, action: #selector(hideTextInput), for: .touchUpInside)

        let textSwipe = UIPanGestureRecognizer(target: self, action: #selector(handleTextBarSwipe(_:)))
        textInputBar.addGestureRecognizer(textSwipe)

        [textInputBar, textMicBtn, textField, textSendBtn].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        view.addSubview(textInputBar)
        textInputBar.addSubview(textMicBtn)
        textInputBar.addSubview(textField)
        textInputBar.addSubview(textSendBtn)

        let bc = textInputBar.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        textInputBottomConstraint = bc
        NSLayoutConstraint.activate([
            textInputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textInputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bc,
            textInputBar.heightAnchor.constraint(equalToConstant: 60),
            textMicBtn.leadingAnchor.constraint(equalTo: textInputBar.leadingAnchor, constant: 14),
            textMicBtn.centerYAnchor.constraint(equalTo: textInputBar.centerYAnchor),
            textMicBtn.widthAnchor.constraint(equalToConstant: 40),
            textMicBtn.heightAnchor.constraint(equalToConstant: 40),
            textField.leadingAnchor.constraint(equalTo: textMicBtn.trailingAnchor, constant: 10),
            textField.topAnchor.constraint(equalTo: textInputBar.topAnchor, constant: 10),
            textField.bottomAnchor.constraint(equalTo: textInputBar.bottomAnchor, constant: -10),
            textSendBtn.leadingAnchor.constraint(equalTo: textField.trailingAnchor, constant: 10),
            textSendBtn.trailingAnchor.constraint(equalTo: textInputBar.trailingAnchor, constant: -14),
            textSendBtn.centerYAnchor.constraint(equalTo: textInputBar.centerYAnchor),
            textSendBtn.widthAnchor.constraint(equalToConstant: 40),
            textSendBtn.heightAnchor.constraint(equalToConstant: 40),
        ])

        // Text-mode: messageList bottom → textInputBar top (deactivated until text mode)
        messageListToTextBar = messageList.bottomAnchor.constraint(equalTo: textInputBar.topAnchor)
        messageListToTextBar?.isActive = false

        // Keyboard observers
        NotificationCenter.default.addObserver(self, selector: #selector(kbWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(kbWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(kbDidHide(_:)),
            name: UIResponder.keyboardDidHideNotification, object: nil)
    }

    private func setupScreenPanel() {
        screenPanel.isHidden = true; screenPanel.translatesAutoresizingMaskIntoConstraints = false
        screenPanel.onViewportMove = { [weak self] x, y in
            guard let self, let s = self.session, self.screenState.metaW > 0 else { return }
            self.connections?.sendViewport(session: s, x: x, y: y,
                                           w: Int(self.screenPanel.minimapVpW), h: Int(self.screenPanel.minimapVpH))
        }
        screenPanel.onViewportResize = { [weak self] x, y, w, h in
            guard let self, let s = self.session else { return }
            self.connections?.sendViewport(session: s, x: x, y: y, w: w, h: h)
        }
        screenPanel.onPointerClick = { [weak self] x, y in
            guard let self, let s = self.session else { return }
            self.connections?.sendPointerDown(session: s, x: x, y: y)
            self.connections?.sendPointerUp(session: s, x: x, y: y)
        }
        screenPanel.onPointerScroll = { [weak self] dx, dy in
            guard let self, let s = self.session else { return }
            self.connections?.sendPointerScroll(session: s, dx: dx, dy: dy)
        }
        screenPanel.onOpen = { [weak self] in
            guard let self else { return }
            self.screenShadow.isHidden = false
            self.collapseZone?.isHidden = false
            self.messageList.isHidden = true
        }
        screenPanel.onClose = { [weak self] in
            guard let self else { return }
            self.screenShadow.isHidden = true
            self.collapseZone?.isHidden = true
            self.messageList.isHidden = false
            self.closeScreenPanel()
        }
        // External shadow: purely visual, must not block touches
        screenShadow.isHidden = true
        screenShadow.isUserInteractionEnabled = false
        screenShadow.translatesAutoresizingMaskIntoConstraints = false
        let sg = CAGradientLayer()
        sg.colors = [UIColor.black.withAlphaComponent(0.5).cgColor, UIColor.clear.cgColor]
        sg.startPoint = CGPoint(x: 0.5, y: 0); sg.endPoint = CGPoint(x: 0.5, y: 1)
        screenShadow.layer.addSublayer(sg)
        view.addSubview(screenShadow)

        view.addSubview(screenPanel)

        let spTop = screenPanel.topAnchor.constraint(equalTo: view.topAnchor)
        screenPanelTopConstraint = spTop
        let spBottom = screenPanel.bottomAnchor.constraint(equalTo: inputBar.topAnchor, constant: -8)

        NSLayoutConstraint.activate([
            spTop,
            screenPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            screenPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            spBottom,
        ])

        // Shadow sits below panel bottom edge (behind panel, visible only below it)
        NSLayoutConstraint.activate([
            screenShadow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            screenShadow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            screenShadow.topAnchor.constraint(equalTo: screenPanel.bottomAnchor),
            screenShadow.heightAnchor.constraint(equalToConstant: 8),
        ])

        // Collapse zone: topmost view, straddles panel bottom for swipe-up-to-close
        let cz = UIView()
        cz.backgroundColor = .clear
        cz.isHidden = true; cz.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cz)  // added LAST = topmost z-order (above shadow, above textInputBar)
        NSLayoutConstraint.activate([
            cz.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cz.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cz.topAnchor.constraint(equalTo: screenPanel.bottomAnchor, constant: -8),
        ])
        collapseZoneHeightConstraint = cz.heightAnchor.constraint(equalToConstant: 32)
        collapseZoneHeightConstraint?.isActive = true
        let collapsePan = UIPanGestureRecognizer(target: self, action: #selector(handleCollapseDrag(_:)))
        cz.addGestureRecognizer(collapsePan)
        collapseZone = cz

        // Sync shadow + collapse zone transform with panel visual offset
        screenPanel.onTransformChanged = { [weak self] offset in
            guard let self else { return }
            self.screenShadow.transform = CGAffineTransform(translationX: 0, y: offset)
            self.collapseZone?.transform = CGAffineTransform(translationX: 0, y: offset)
            let show = !self.screenPanel.isHidden
            self.screenShadow.isHidden = !show
            self.collapseZone?.isHidden = !show
        }

        // Header swipe-down gesture to open screen curtain
        let headerSwipe = UIPanGestureRecognizer(target: self, action: #selector(handleHeaderSwipe(_:)))
        headerBar.addGestureRecognizer(headerSwipe)
    }

    private func showMenu() {
        let a = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        a.addAction(UIAlertAction(title: "查看屏幕", style: .default) { [weak self] _ in self?.openScreenPanel() })
        a.addAction(UIAlertAction(title: "撤销", style: .default) { [weak self] _ in
            self?.sendAction("undo")
        })
        a.addAction(UIAlertAction(title: "全选", style: .default) { [weak self] _ in
            self?.sendAction("selectAll")
        })
        a.addAction(UIAlertAction(title: "清空", style: .default) { [weak self] _ in
            self?.sendAction("clear")
        })
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(a, animated: true)
    }

    private func sendAction(_ action: String) {
        guard let s = session else { return }
        connections?.sendAction(session: s, action: action)
    }

    private var debugHotZones = false
    private var dPadMode = false

    private func showEngineeringMenu() {
        let a = UIAlertController(title: "工程菜单", message: nil, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "透明热区（调试）", style: .default) { [weak self] _ in
            self?.debugHotZones.toggle()
            let visible = self?.debugHotZones ?? false
            self?.inputBar.setHotZonesVisible(visible)
            self?.screenPanel.setHotZonesVisible(visible)
            self?.collapseZone?.backgroundColor = visible ? UIColor(red: 1, green: 0, blue: 0, alpha: 0.5) : .clear
        })
        a.addAction(UIAlertAction(title: "文本/方向交互切换", style: .default) { [weak self] _ in
            self?.dPadMode.toggle()
            self?.inputBar.isDpadMode = self?.dPadMode ?? false
        })
        a.addAction(UIAlertAction(title: "关闭", style: .cancel))
        present(a, animated: true)
    }

    private func openScreenPanel() {
        screenPanel.screenState = screenState
        connections?.setScreenListener(connectionId: connectionId, listener: screenState)
        screenPanel.open()
        // If keyboard is showing in text mode, push panel up to match
        if isTextMode, kbHeight > 0 {
            let targetBottom = view.bounds.height - kbHeight - 60
            screenPanel.keyboardLift = targetBottom - screenPanel.frame.maxY
        }
        setNeedsStatusBarAppearanceUpdate()
        if let s = session {
            screenPanel.layoutIfNeeded()
            let vb = screenPanel.videoBounds
            let vpW = max(2, Int(vb.width))
            let vpH = max(2, Int(vb.height))
            connections?.startScreen(session: s, viewportW: vpW, viewportH: vpH)
        }
    }

    private func closeScreenPanel() {
        guard let s = session else { return }
        connections?.stopScreen(session: s)
        setNeedsStatusBarAppearanceUpdate()
    }

    @objc private func handleCollapseDrag(_ gesture: UIPanGestureRecognizer) {
        guard screenPanel.isOpen else { return }
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .changed:
            if translation.y < 0 { screenPanel.curtainOffset = translation.y; screenPanel.applyCombinedTransform() }
        case .ended, .cancelled:
            if translation.y < -50 { screenPanel.close() }
            else if screenPanel.curtainOffset < 0 {
                UIView.animate(withDuration: 0.25) { self.screenPanel.curtainOffset = 0; self.screenPanel.applyCombinedTransform() }
            }
        default: break
        }
    }

    @objc private func handleHeaderSwipe(_ gesture: UIPanGestureRecognizer) {
        guard !screenPanel.isOpen else { return }
        let t = gesture.translation(in: view)
        switch gesture.state {
        case .changed:
            screenPanel.reveal(t.y)
        case .ended, .cancelled:
            let v = gesture.velocity(in: view).y
            if t.y > screenPanel.curtainHeight * 0.3 || v > 600 {
                openScreenPanel()
            } else {
                screenPanel.close()
            }
        default: break
        }
    }

    private func reloadMessages() {
        let real = session?.messages ?? []
        messages = real.isEmpty
            ? [ChatMessage(text: "你好", fromMe: false),
               ChatMessage(text: "收到，这是一条测试回复消息", fromMe: true)]
            : real
        messageList.reloadData()
        if let last = messages.last { messageList.scrollToRow(at: IndexPath(row: messages.count-1, section: 0), at: .bottom, animated: false) }
    }

    // MARK: - Text input mode (keyboard-aware, matches Android)

    private func showTextInput() {
        guard !isTextMode else { return }
        isTextMode = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        inputBar.animateVoiceOut()

        // Collapse zone: 8pt inside + 8pt outside (covers shadow area only)
        collapseZoneHeightConstraint?.constant = 16

        // Bring textInputBar + shadow above screenPanel, collapse zone on very top
        view.bringSubviewToFront(textInputBar)
        view.bringSubviewToFront(screenShadow)
        if let cz = collapseZone { view.bringSubviewToFront(cz) }

        // Switch messageList bottom to textInputBar.top (keyboard-aware)
        messageListToInputBar?.isActive = false
        messageListToTextBar?.isActive = true
        // inputBar stays at safeArea bottom (voice content hidden), screen panel keeps its frame

        textInputBar.isHidden = false; textInputBar.alpha = 0
        textInputBottomConstraint?.constant = -kbHeight
        UIView.animate(withDuration: 0.22, delay: 0.06) { [weak self] in
            self?.textInputBar.alpha = 1
            self?.view.layoutIfNeeded()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.textField.becomeFirstResponder()
        }
    }

    @objc private func hideTextInput() {
        guard isTextMode else { return }
        isTextMode = false
        textField.resignFirstResponder()
        inputBar.animateVoiceIn()
        screenPanel.keyboardLift = 0
        collapseZoneHeightConstraint?.constant = 32

        // Restore layout: messageList back to inputBar.top
        messageListToTextBar?.isActive = false
        messageListToInputBar?.isActive = true

        textInputBottomConstraint?.constant = 0
        UIView.animate(withDuration: 0.15) { [weak self] in
            self?.textInputBar.alpha = 0; self?.view.layoutIfNeeded()
        } completion: { [weak self] _ in
            self?.textInputBar.isHidden = true
            self?.textInputBar.alpha = 1
        }
    }

    @objc private func sendTextTapped() {
        guard let t = textField.text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let s = session else { return }
        connections?.sendText(session: s, text: t)
        textField.text = ""
        reloadMessages()
    }

    @objc private func handleTextBarSwipe(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let t = gesture.translation(in: textInputBar)
        if t.y < -28, screenPanel.isOpen { screenPanel.close() }   // swipe up → close curtain
        else if t.y > 28 { hideTextInput() }                        // swipe down → voice mode
    }

    // MARK: - Keyboard

    @objc private func kbWillShow(_ notification: Notification) {
        guard let info = notification.userInfo,
              let frame = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double else { return }
        kbHeight = frame.height
        if isTextMode {
            textInputBottomConstraint?.constant = -kbHeight
            if screenPanel.isOpen {
                let targetBottom = view.bounds.height - kbHeight - 60
                let lift = targetBottom - screenPanel.frame.maxY
                UIView.animate(withDuration: duration) {
                    self.screenPanel.keyboardLift = lift
                }
            }
        }
    }

    @objc private func kbWillHide(_ notification: Notification) {
        guard let info = notification.userInfo,
              let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double else { return }
        kbHeight = 0
        if isTextMode {
            textInputBottomConstraint?.constant = 0
            if screenPanel.isOpen {
                UIView.animate(withDuration: duration) {
                    self.screenPanel.keyboardLift = 0
                }
            }
        }
    }

    @objc private func kbDidHide(_ notification: Notification) {
        // Keyboard dismissed externally (e.g. swipe down) while in text mode → go back to voice
        if isTextMode { hideTextInput() }
    }
}

extension ChatViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ tf: UITextField) -> Bool { sendTextTapped(); return true }
}

extension ChatViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { messages.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "c", for: indexPath) as! MessageCell
        cell.configure(messages[indexPath.row])
        return cell
    }
}

final class MessageCell: UITableViewCell {
    private let bubble = UIView()
    private let label = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear; selectionStyle = .none
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)

        label.font = .systemFont(ofSize: 16); label.textColor = .white; label.numberOfLines = 0
        bubble.layer.cornerRadius = 20
        bubble.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bubble)
        bubble.addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 11),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -11),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 15),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -15),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ msg: ChatMessage) {
        label.text = msg.text
        if msg.fromMe {
            bubble.backgroundColor = UIColor(red: 0.18, green: 0.35, blue: 0.87, alpha: 1) // messageBubble accent
            bubble.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner]
            bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18).isActive = true
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 60).isActive = true
            bubble.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
        } else {
            bubble.backgroundColor = UIColor(white: 0.16, alpha: 1) // surface
            bubble.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18).isActive = true
            bubble.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -60).isActive = true
            bubble.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
        }
    }
}

// MARK: - ChatHeaderBar, ChatInputBar, ScreenPanelView

final class ChatHeaderBar: UIView {
    var onBack: (() -> Void)?; var onMenu: (() -> Void)?; var onEngineering: (() -> Void)?
    private var tapCount = 0
    private var tapResetWork: DispatchWorkItem?
    private var engineeringCooldown = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.16, alpha: 1); layer.cornerRadius = 18
        let back = UIButton(type: .system)
        back.setImage(UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
        back.tintColor = UIColor(white: 0.7, alpha: 1); back.backgroundColor = UIColor(white: 0.2, alpha: 1); back.layer.cornerRadius = 20
        back.addTarget(self, action: #selector(tapBack), for: .touchUpInside)
        let app = UILabel(); app.font = .systemFont(ofSize: 22, weight: .bold); app.textColor = .white; app.tag = 1
        app.isUserInteractionEnabled = true
        let title = UILabel(); title.font = .systemFont(ofSize: 13); title.textColor = UIColor(white: 0.6, alpha: 1); title.tag = 2
        title.isUserInteractionEnabled = true

        // 5-tap engineering menu on title area
        [app, title].forEach { label in
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTitleTap))
            label.addGestureRecognizer(tap)
        }

        let menu = UIButton(type: .system)
        menu.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .bold)), for: .normal)
        menu.tintColor = UIColor(white: 0.7, alpha: 1); menu.backgroundColor = UIColor(white: 0.2, alpha: 1); menu.layer.cornerRadius = 20
        menu.addTarget(self, action: #selector(tapMenu), for: .touchUpInside)
        [back, app, title, menu].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), back.centerYAnchor.constraint(equalTo: centerYAnchor),
            back.widthAnchor.constraint(equalToConstant: 40), back.heightAnchor.constraint(equalToConstant: 40),
            app.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 12), app.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            app.trailingAnchor.constraint(lessThanOrEqualTo: menu.leadingAnchor, constant: -12),
            title.leadingAnchor.constraint(equalTo: app.leadingAnchor), title.topAnchor.constraint(equalTo: app.bottomAnchor, constant: 6),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            menu.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), menu.centerYAnchor.constraint(equalTo: centerYAnchor),
            menu.widthAnchor.constraint(equalToConstant: 40), menu.heightAnchor.constraint(equalToConstant: 40),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(app: String, title: String) { (viewWithTag(1) as? UILabel)?.text = app; (viewWithTag(2) as? UILabel)?.text = title }

    @objc private func handleTitleTap() {
        guard !engineeringCooldown else { return }
        tapCount += 1
        tapResetWork?.cancel()
        if tapCount >= 5 {
            tapCount = 0; engineeringCooldown = true
            onEngineering?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.engineeringCooldown = false }
        } else {
            let w = DispatchWorkItem { [weak self] in self?.tapCount = 0 }
            tapResetWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
        }
    }

    @objc private func tapBack() { onBack?() }
    @objc private func tapMenu() { onMenu?() }
}

final class ChatInputBar: UIView, UITextFieldDelegate, UIGestureRecognizerDelegate {
    var onSend: ((String) -> Void)?; var onAction: ((String) -> Void)?
    var onTextModeRequest: (() -> Void)?
    private let hintLabel = UILabel()

    var isDpadMode = false {
        didSet {
            guard isDpadMode != oldValue else { return }
            refreshDpadState()
        }
    }

    // D-pad directional tap zones (matches Android dpadViews)
    private var dpadZones: [UIView] = []
    // Grab handle corner dots (hidden in D-pad mode)
    private var grabDots: [UIView] = []
    private let composerPanel = UIView()
    private let deleteBtn = UIButton(type: .system)
    private let micBtn = UIButton(type: .system)
    private let returnBtn = UIButton(type: .system)
    // Progress rings for long-press (78pt, matching mic size)
    private let deleteRing = CAShapeLayer()
    private let returnRing = CAShapeLayer()
    private var deleteHoldWork: DispatchWorkItem?
    private var returnHoldWork: DispatchWorkItem?
    private var deletePressed = false
    private var returnPressed = false
    // Direction hints around mic
    private let dirUp = UIImageView(); private let dirDown = UIImageView()
    private let dirLeft = UIImageView(); private let dirRight = UIImageView()
    private let dotNear1 = UIView(); private let dotNear2 = UIView()
    private let dotFar1 = UIView(); private let dotFar2 = UIView()
    // Text mode (hidden initially)
    private let textPanel = UIView(); private let tf = UITextField()
    private let sendBtn = UIButton(type: .system); private let switchMicBtn = UIButton(type: .system)
    // Pull-up to text mode (matches Android: pullMax=96dp, threshold=0.55, lift=56dp)
    private let pullMax: CGFloat = 96
    private let composerLift: CGFloat = 56
    private var pullTriggered = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)

        // Hint
        hintLabel.text = "按住说话"; hintLabel.font = .systemFont(ofSize: 13)
        hintLabel.textColor = UIColor(white: 0.5, alpha: 1); hintLabel.textAlignment = .center

        // Composer panel (matches SwiftUI .panel(cornerRadius: 34))
        composerPanel.backgroundColor = UIColor(white: 0.16, alpha: 1)
        composerPanel.layer.cornerRadius = 34
        composerPanel.layer.borderWidth = 1
        composerPanel.layer.borderColor = UIColor(white: 0.22, alpha: 1).cgColor

        // Delete button (56x56, surfaceAlt bg)
        deleteBtn.setImage(UIImage(systemName: "delete.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)), for: .normal)
        deleteBtn.tintColor = UIColor(white: 0.7, alpha: 1)
        deleteBtn.backgroundColor = UIColor(white: 0.2, alpha: 1)
        deleteBtn.layer.cornerRadius = 28
        deleteBtn.addTarget(self, action: #selector(deleteTouchDown), for: .touchDown)
        deleteBtn.addTarget(self, action: #selector(deleteTouchUp), for: .touchUpInside)
        deleteBtn.addTarget(self, action: #selector(deleteTouchUp), for: .touchUpOutside)
        deleteBtn.addTarget(self, action: #selector(deleteTouchUp), for: .touchDragExit)

        // Progress ring (78pt around button)
        for (ring, btn) in [(deleteRing, deleteBtn), (returnRing, returnBtn)] {
            ring.path = UIBezierPath(arcCenter: .zero, radius: 39, startAngle: -.pi/2, endAngle: .pi*1.5, clockwise: true).cgPath
            ring.strokeColor = UIColor(red: 1, green: 0.58, blue: 0.22, alpha: 1).cgColor
            ring.fillColor = UIColor.clear.cgColor
            ring.lineWidth = 3.9; ring.strokeEnd = 0; ring.lineCap = .round
            ring.position = CGPoint(x: 28, y: 28) // button center in button's own frame
            btn.layer.addSublayer(ring)
        }

        // Mic button (78x78, accent orange)
        micBtn.setImage(UIImage(systemName: "mic.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold)), for: .normal)
        micBtn.tintColor = .white
        micBtn.backgroundColor = UIColor(red: 1, green: 0.58, blue: 0.22, alpha: 1)
        micBtn.layer.cornerRadius = 39
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleMicDrag(_:)))
        micBtn.addGestureRecognizer(pan)

        // Pull-up gesture on entire input bar (covers hint + composer, delegate filters button areas)
        let composerPull = UIPanGestureRecognizer(target: self, action: #selector(handleComposerPull(_:)))
        composerPull.delegate = self
        addGestureRecognizer(composerPull)

        // D-pad tap zones (added to self, positioned above composerPanel)
        for i in 0..<4 {
            let z = UIView()
            z.backgroundColor = .clear; z.isHidden = true
            let tap = UITapGestureRecognizer(target: self, action: #selector(dpadTapped(_:)))
            z.addGestureRecognizer(tap)
            z.tag = i  // 0=up, 1=down, 2=left, 3=right
            addSubview(z)
            dpadZones.append(z)
        }
        // Positioned in layoutSubviews via refreshDpadState

        // Text mode switching delegated to ChatViewController via onTextModeRequest

        // Return button (56x56, surfaceAlt bg)
        returnBtn.setImage(UIImage(systemName: "return", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)), for: .normal)
        returnBtn.tintColor = UIColor(white: 0.7, alpha: 1)
        returnBtn.backgroundColor = UIColor(white: 0.2, alpha: 1)
        returnBtn.layer.cornerRadius = 28
        returnBtn.addTarget(self, action: #selector(returnTouchDown), for: .touchDown)
        returnBtn.addTarget(self, action: #selector(returnTouchUp), for: .touchUpInside)
        returnBtn.addTarget(self, action: #selector(returnTouchUp), for: .touchUpOutside)
        returnBtn.addTarget(self, action: #selector(returnTouchUp), for: .touchDragExit)

        // Grab handle: 3-dot triangles at top corners (visual hint for pull-up)
        let grabDots = (0..<6).map { _ -> UIView in
            let v = UIView()
            v.backgroundColor = UIColor(white: 1, alpha: 0.3)
            v.layer.cornerRadius = 1.5; v.translatesAutoresizingMaskIntoConstraints = false
            composerPanel.addSubview(v); return v
        }
        let gTL = (a: grabDots[0], b: grabDots[1], c: grabDots[2])  // top-left triangle
        let gTR = (a: grabDots[3], b: grabDots[4], c: grabDots[5])  // top-right triangle
        self.grabDots = grabDots

        // Direction hints (chevrons + dots around mic)
        let tint = UIColor(red: 1, green: 0.58, blue: 0.22, alpha: 0.34)
        let chevronCfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        for (iv, name) in [(dirUp, "chevron.compact.up"), (dirDown, "chevron.compact.down"),
                           (dirLeft, "chevron.compact.left"), (dirRight, "chevron.compact.right")] {
            iv.image = UIImage(systemName: name, withConfiguration: chevronCfg)
            iv.tintColor = tint; iv.contentMode = .center
        }
        [dotNear1, dotNear2].forEach { $0.backgroundColor = tint; $0.layer.cornerRadius = 1.5 }
        [dotFar1, dotFar2].forEach { $0.backgroundColor = tint; $0.layer.cornerRadius = 1.5 }

        [deleteBtn, micBtn, returnBtn, composerPanel, hintLabel,
         dirUp, dirDown, dirLeft, dirRight,
         dotNear1, dotNear2, dotFar1, dotFar2].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(hintLabel)
        addSubview(composerPanel)
        composerPanel.addSubview(deleteBtn)
        composerPanel.addSubview(micBtn)
        composerPanel.addSubview(returnBtn)
        [dirUp, dirDown, dirLeft, dirRight, dotNear1, dotNear2, dotFar1, dotFar2].forEach {
            composerPanel.addSubview($0)
        }

        // Text panel (hidden)
        tf.placeholder = "输入文字…"; tf.font = .systemFont(ofSize: 16); tf.textColor = .white
        tf.backgroundColor = UIColor(white: 0.2, alpha: 1); tf.layer.cornerRadius = 14
        tf.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: 0)); tf.leftViewMode = .always
        tf.returnKeyType = .send; tf.delegate = self
        sendBtn.setImage(UIImage(systemName: "paperplane.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
        sendBtn.tintColor = .white; sendBtn.backgroundColor = UIColor(red: 1, green: 0.58, blue: 0.22, alpha: 1); sendBtn.layer.cornerRadius = 20; sendBtn.addTarget(self, action: #selector(sendText), for: .touchUpInside)
        switchMicBtn.setImage(UIImage(systemName: "mic.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
        switchMicBtn.tintColor = UIColor(red: 1, green: 0.58, blue: 0.22, alpha: 1); switchMicBtn.backgroundColor = UIColor(white: 0.2, alpha: 1); switchMicBtn.layer.cornerRadius = 20
        textPanel.translatesAutoresizingMaskIntoConstraints = false; textPanel.isHidden = true
        [switchMicBtn, tf, sendBtn].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; textPanel.addSubview($0) }
        addSubview(textPanel)

        NSLayoutConstraint.activate([
            hintLabel.topAnchor.constraint(equalTo: topAnchor),
            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),

            composerPanel.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 24),
            composerPanel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            composerPanel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            composerPanel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            // Grab triangle dots at rectangular corner positions
            gTL.a.leadingAnchor.constraint(equalTo: composerPanel.leadingAnchor),
            gTL.a.topAnchor.constraint(equalTo: composerPanel.topAnchor),
            gTL.a.widthAnchor.constraint(equalToConstant: 3), gTL.a.heightAnchor.constraint(equalToConstant: 3),
            gTL.b.leadingAnchor.constraint(equalTo: composerPanel.leadingAnchor, constant: 5),
            gTL.b.topAnchor.constraint(equalTo: composerPanel.topAnchor),
            gTL.b.widthAnchor.constraint(equalToConstant: 3), gTL.b.heightAnchor.constraint(equalToConstant: 3),
            gTL.c.leadingAnchor.constraint(equalTo: composerPanel.leadingAnchor),
            gTL.c.topAnchor.constraint(equalTo: composerPanel.topAnchor, constant: 5),
            gTL.c.widthAnchor.constraint(equalToConstant: 3), gTL.c.heightAnchor.constraint(equalToConstant: 3),

            gTR.a.trailingAnchor.constraint(equalTo: composerPanel.trailingAnchor),
            gTR.a.topAnchor.constraint(equalTo: composerPanel.topAnchor),
            gTR.a.widthAnchor.constraint(equalToConstant: 3), gTR.a.heightAnchor.constraint(equalToConstant: 3),
            gTR.b.trailingAnchor.constraint(equalTo: composerPanel.trailingAnchor, constant: -5),
            gTR.b.topAnchor.constraint(equalTo: composerPanel.topAnchor),
            gTR.b.widthAnchor.constraint(equalToConstant: 3), gTR.b.heightAnchor.constraint(equalToConstant: 3),
            gTR.c.trailingAnchor.constraint(equalTo: composerPanel.trailingAnchor),
            gTR.c.topAnchor.constraint(equalTo: composerPanel.topAnchor, constant: 5),
            gTR.c.widthAnchor.constraint(equalToConstant: 3), gTR.c.heightAnchor.constraint(equalToConstant: 3),

            deleteBtn.leadingAnchor.constraint(equalTo: composerPanel.leadingAnchor, constant: 20),
            deleteBtn.centerYAnchor.constraint(equalTo: composerPanel.centerYAnchor),
            deleteBtn.widthAnchor.constraint(equalToConstant: 56), deleteBtn.heightAnchor.constraint(equalToConstant: 56),

            micBtn.centerXAnchor.constraint(equalTo: composerPanel.centerXAnchor),
            micBtn.topAnchor.constraint(equalTo: composerPanel.topAnchor, constant: 3),
            micBtn.bottomAnchor.constraint(equalTo: composerPanel.bottomAnchor, constant: -3),
            micBtn.widthAnchor.constraint(equalToConstant: 78), micBtn.heightAnchor.constraint(equalToConstant: 78),

            // Direction hints around mic
            dirUp.centerXAnchor.constraint(equalTo: micBtn.centerXAnchor),
            dirUp.bottomAnchor.constraint(equalTo: micBtn.topAnchor, constant: -8),
            dirDown.centerXAnchor.constraint(equalTo: micBtn.centerXAnchor),
            dirDown.topAnchor.constraint(equalTo: micBtn.bottomAnchor, constant: 8),
            dirLeft.centerYAnchor.constraint(equalTo: micBtn.centerYAnchor),
            dirLeft.rightAnchor.constraint(equalTo: micBtn.centerXAnchor, constant: -(chevronOffset)),
            dirRight.centerYAnchor.constraint(equalTo: micBtn.centerYAnchor),
            dirRight.leftAnchor.constraint(equalTo: micBtn.centerXAnchor, constant: chevronOffset),
            // Near dots: midpoint between mic edge(39) and chevron(53)
            dotNear1.centerYAnchor.constraint(equalTo: micBtn.centerYAnchor),
            dotNear1.centerXAnchor.constraint(equalTo: micBtn.centerXAnchor, constant: -48),
            dotNear1.widthAnchor.constraint(equalToConstant: 3), dotNear1.heightAnchor.constraint(equalToConstant: 3),
            dotNear2.centerYAnchor.constraint(equalTo: micBtn.centerYAnchor),
            dotNear2.centerXAnchor.constraint(equalTo: micBtn.centerXAnchor, constant: 48),
            dotNear2.widthAnchor.constraint(equalToConstant: 3), dotNear2.heightAnchor.constraint(equalToConstant: 3),
            // Far dots: hidden initially (show when isContinuous)
            dotFar1.centerYAnchor.constraint(equalTo: micBtn.centerYAnchor),
            dotFar1.centerXAnchor.constraint(equalTo: micBtn.centerXAnchor, constant: -55),
            dotFar1.widthAnchor.constraint(equalToConstant: 3), dotFar1.heightAnchor.constraint(equalToConstant: 3),
            dotFar2.centerYAnchor.constraint(equalTo: micBtn.centerYAnchor),
            dotFar2.centerXAnchor.constraint(equalTo: micBtn.centerXAnchor, constant: 55),
            dotFar2.widthAnchor.constraint(equalToConstant: 3), dotFar2.heightAnchor.constraint(equalToConstant: 3),

            returnBtn.trailingAnchor.constraint(equalTo: composerPanel.trailingAnchor, constant: -20),
            returnBtn.centerYAnchor.constraint(equalTo: composerPanel.centerYAnchor),
            returnBtn.widthAnchor.constraint(equalToConstant: 56), returnBtn.heightAnchor.constraint(equalToConstant: 56),

            textPanel.topAnchor.constraint(equalTo: topAnchor), textPanel.leadingAnchor.constraint(equalTo: leadingAnchor),
            textPanel.trailingAnchor.constraint(equalTo: trailingAnchor), textPanel.bottomAnchor.constraint(equalTo: bottomAnchor),
            switchMicBtn.leadingAnchor.constraint(equalTo: textPanel.leadingAnchor, constant: 14), switchMicBtn.centerYAnchor.constraint(equalTo: textPanel.centerYAnchor),
            switchMicBtn.widthAnchor.constraint(equalToConstant: 40), switchMicBtn.heightAnchor.constraint(equalToConstant: 40),
            tf.leadingAnchor.constraint(equalTo: switchMicBtn.trailingAnchor, constant: 10), tf.topAnchor.constraint(equalTo: textPanel.topAnchor, constant: 10),
            tf.bottomAnchor.constraint(equalTo: textPanel.bottomAnchor, constant: -10),
            sendBtn.leadingAnchor.constraint(equalTo: tf.trailingAnchor, constant: 10), sendBtn.trailingAnchor.constraint(equalTo: textPanel.trailingAnchor, constant: -14),
            sendBtn.centerYAnchor.constraint(equalTo: textPanel.centerYAnchor), sendBtn.widthAnchor.constraint(equalToConstant: 40), sendBtn.heightAnchor.constraint(equalToConstant: 40),
        ])
        dotFar1.alpha = 0; dotFar2.alpha = 0
        // store chevron constraints for dynamic updates
        for c in composerPanel.constraints {
            if c.firstItem === dirLeft, c.secondItem === micBtn { chevronLeftConstraint = c }
            if c.firstItem === dirRight, c.secondItem === micBtn { chevronRightConstraint = c }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func tapDelete() { onAction?("backspace") }

    // Hold gesture handlers for side buttons
    override func layoutSubviews() { super.layoutSubviews(); positionDpadZones() }

    private let holdDuration: TimeInterval = 0.75

    // Delete button
    @objc private func deleteTouchDown() {
        if isDpadMode { return }
        beginHold(ring: deleteRing, btn: deleteBtn, work: &deleteHoldWork, onHold: { self.onAction?("clear") })
    }
    @objc private func deleteTouchUp() {
        if isDpadMode { UIImpactFeedbackGenerator(style: .light).impactOccurred(); onAction?("escape"); return }
        endHold(ring: deleteRing, btn: deleteBtn, work: &deleteHoldWork, onTap: { self.onAction?("backspace") })
    }

    // Return button
    @objc private func returnTouchDown() {
        if isDpadMode { return }
        beginHold(ring: returnRing, btn: returnBtn, work: &returnHoldWork, onHold: { self.onAction?("enter") })
    }
    @objc private func returnTouchUp() {
        if isDpadMode { UIImpactFeedbackGenerator(style: .light).impactOccurred(); onAction?("enter"); return }
        endHold(ring: returnRing, btn: returnBtn, work: &returnHoldWork, onTap: { self.onAction?("shiftEnter") })
    }

    private func beginHold(ring: CAShapeLayer, btn: UIButton, work: inout DispatchWorkItem?, onHold: @escaping () -> Void) {
        btn.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        ring.removeAnimation(forKey: "hold")
        let anim = CABasicAnimation(keyPath: "strokeEnd")
        anim.fromValue = 0; anim.toValue = 1; anim.duration = holdDuration
        anim.isRemovedOnCompletion = false; anim.fillMode = .forwards
        ring.add(anim, forKey: "hold")
        let w = DispatchWorkItem { [weak self] in
            guard self != nil else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onHold()
        }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration, execute: w)
    }

    private func endHold(ring: CAShapeLayer, btn: UIButton, work: inout DispatchWorkItem?, onTap: @escaping () -> Void) {
        let wasHold = work?.isCancelled ?? true
        work?.cancel(); work = nil
        btn.transform = .identity
        ring.removeAnimation(forKey: "hold"); ring.strokeEnd = 0
        if !wasHold { UIImpactFeedbackGenerator(style: .light).impactOccurred(); onTap() }
    }

    // MARK: - Mic drag (cursor mode)
    private enum CursorState { case idle, tracking, horizontal, vertical }
    private var cursorState: CursorState = .idle
    private var cursorLastStep = 0
    private var cursorAbsX: CGFloat = 0
    private var cursorBaseY: CGFloat = 0
    private var isContinuous = false
    private var repeatTimer: Timer?
    private var continuousThreshold: CGFloat = 96

    private let cursorActivation: CGFloat = 28
    private let cursorStep: CGFloat = 24
    private let verticalBias: CGFloat = 1.8
    private let swipeTrigger: CGFloat = 32
    private let repeatSlow: TimeInterval = 0.2
    private let repeatFast: TimeInterval = 0.04

    @objc private func tapMic() {}

    @objc private func tapReturn() { onAction?("enter") }

    // Chevron positions: 53 (near), 60 (far when continuous)
    private var chevronOffset: CGFloat = 53
    private var chevronLeftConstraint: NSLayoutConstraint?
    private var chevronRightConstraint: NSLayoutConstraint?

    @objc private func handleMicDrag(_ gesture: UIPanGestureRecognizer) {
        let trans = gesture.translation(in: micBtn)
        let absX = abs(trans.x)
        let absY = abs(trans.y)

        switch gesture.state {
        case .began:
            cursorState = .tracking; cursorLastStep = 0; isContinuous = false
            cursorAbsX = 0; cursorBaseY = 0
            stopRepeat()

        case .changed:
            switch cursorState {
            case .tracking:
                let dist = hypot(trans.x, trans.y)
                guard dist > cursorActivation else { return }
                if absY > absX * verticalBias {
                    cursorState = .vertical; cursorBaseY = trans.y
                    setHorizontalHints(visible: false)
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    hintLabel.text = "↑ 上滑松手切行 ↓"
                } else {
                    cursorState = .horizontal; cursorLastStep = Int((trans.x / cursorStep).rounded())
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    hintLabel.text = "← 拖动移动光标 →"
                }
                cursorAbsX = absX
            case .horizontal:
                let step = Int((trans.x / cursorStep).rounded())
                guard step != cursorLastStep else { break }
                let count = abs(step - cursorLastStep)
                let dir = step > cursorLastStep ? "cursorRight" : "cursorLeft"
                for _ in 0..<count { onAction?(dir); UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                cursorLastStep = step
                cursorAbsX = abs(trans.x)
                updateRepeat()
            case .vertical:
                let d = trans.y - cursorBaseY
                hintLabel.text = abs(d) >= swipeTrigger
                    ? (d > 0 ? "↓ 松手切到下一行" : "↑ 松手切到上一行")
                    : "↑ 上滑松手切行 ↓"
            case .idle: break
            }

        case .ended, .cancelled:
            if cursorState == .vertical {
                let d = trans.y - cursorBaseY
                if abs(d) >= swipeTrigger {
                    onAction?(d > 0 ? "cursorDown" : "cursorUp")
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
            }
            cursorState = .idle; stopRepeat()
            setContinuous(false, animated: true)
            setHorizontalHints(visible: true)
            hintLabel.text = "按住说话"

        default: break
        }
    }

    private func setContinuous(_ on: Bool, animated: Bool) {
        guard on != isContinuous else { return }
        isContinuous = on
        let offset: CGFloat = on ? 60 : 53
        chevronLeftConstraint?.constant = -(offset)
        chevronRightConstraint?.constant = offset
        let changes = {
            self.dotFar1.alpha = on ? 1 : 0; self.dotFar2.alpha = on ? 1 : 0
            self.composerPanel.layoutIfNeeded()
        }
        if animated { UIView.animate(withDuration: 0.2, animations: changes) } else { changes() }
    }

    private func setHorizontalHints(visible: Bool) {
        let alpha: CGFloat = visible ? 1 : 0
        dirLeft.alpha = alpha; dirRight.alpha = alpha
        dotNear1.alpha = alpha; dotNear2.alpha = alpha
        if !isContinuous { dotFar1.alpha = 0; dotFar2.alpha = 0 }
    }

    private func updateRepeat() {
        if cursorAbsX >= continuousThreshold {
            setContinuous(true, animated: true)
            if repeatTimer == nil { scheduleRepeat() }
        } else {
            if isContinuous { setContinuous(false, animated: true) }
            stopRepeat()
        }
    }

    private func scheduleRepeat() {
        let interval = cursorAbsX >= continuousThreshold + cursorStep * 8 ? repeatFast : repeatSlow
        repeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self, self.cursorState == .horizontal, self.cursorAbsX >= self.continuousThreshold else { return }
            self.onAction?(self.cursorLastStep > 0 ? "cursorRight" : "cursorLeft")
            self.scheduleRepeat()
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate(); repeatTimer = nil
    }
    @objc private func sendText() { guard let t = tf.text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; onSend?(t); tf.text = "" }

    // MARK: - Pull-up to text mode

    @objc private func handleComposerPull(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: composerPanel)
        switch gesture.state {
        case .began:
            pullTriggered = false
        case .changed:
            let pulled = max(0, -translation.y)
            if pulled > 0 { applyComposerPull(min(1, pulled / pullMax)) }
            if pulled > pullMax * 0.55, !pullTriggered {
                pullTriggered = true
                applyComposerPull(1)
                animateVoiceOut()
                onTextModeRequest?()
            }
        case .ended, .cancelled:
            if !pullTriggered {
                if translation.y > 8 {
                    // Dragged down: ignore
                } else if translation.y > -8 {
                    // Minimal movement: tap to open
                    animateVoiceOut()
                    onTextModeRequest?()
                } else {
                    // Pulled up but not enough: snap back
                    snapComposerBack()
                }
            }
            pullTriggered = false
        default: break
        }
    }

    /// Animate composer panel up + fade out (matches Android)
    func animateVoiceOut() {
        UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut) {
            self.composerPanel.transform = CGAffineTransform(translationX: 0, y: -self.composerLift)
            self.composerPanel.alpha = 0
            self.hintLabel.alpha = 0
        } completion: { _ in
            self.composerPanel.isHidden = true
            self.composerPanel.transform = .identity
            self.composerPanel.alpha = 1
            self.hintLabel.isHidden = true
            self.hintLabel.alpha = 1
        }
    }

    /// Animate composer panel back in from text mode
    func animateVoiceIn() {
        composerPanel.isHidden = false; hintLabel.isHidden = false
        composerPanel.transform = CGAffineTransform(translationX: 0, y: -composerLift)
        composerPanel.alpha = 0; hintLabel.alpha = 0
        UIView.animate(withDuration: 0.24, delay: 0.04, options: .curveEaseOut) {
            self.composerPanel.transform = .identity
            self.composerPanel.alpha = 1
            self.hintLabel.alpha = 1
        }
    }

    private func applyComposerPull(_ progress: CGFloat) {
        let p = min(1, max(0, progress))
        composerPanel.transform = CGAffineTransform(translationX: 0, y: -composerLift * p)
        let alpha = 1 - p
        composerPanel.alpha = alpha
        hintLabel.alpha = alpha
    }

    private func snapComposerBack() {
        UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut) {
            self.composerPanel.transform = .identity
            self.composerPanel.alpha = 1
            self.hintLabel.alpha = 1
        }
    }

    func textFieldShouldReturn(_ tf: UITextField) -> Bool { sendText(); return true }

    // MARK: - D-pad mode

    private func refreshDpadState() {
        let dp = isDpadMode
        // Icons: mic→dpad arrows, delete→escape (matching Android ic_dpad / ic_nav_esc)
        micBtn.setImage(UIImage(systemName: dp ? "arrow.up.and.down.and.arrow.left.and.right" : "mic.fill",
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: dp ? 20 : 30, weight: .semibold)), for: .normal)
        deleteBtn.setImage(UIImage(systemName: dp ? "escape" : "delete.left",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)), for: .normal)
        hintLabel.text = dp ? "↑↓←→ 移动光标" : "按住说话"
        // D-pad zones visible (on top of mic), direction dots + grab dots hidden
        dpadZones.forEach { $0.isHidden = !dp; if dp { bringSubviewToFront($0) } }
        [dotNear1, dotNear2, dotFar1, dotFar2].forEach { $0.isHidden = dp }
        grabDots.forEach { $0.isHidden = dp }
        // Mic button is decorative only in D-pad mode
        micBtn.isUserInteractionEnabled = !dp
        // Disable pull-up in d-pad mode (drag handle concept)
        if dp, let pullGesture = gestureRecognizers?.first(where: { $0 is UIPanGestureRecognizer && $0.delegate === self }) {
            pullGesture.isEnabled = false
        } else if !dp, let pullGesture = gestureRecognizers?.first(where: { $0 is UIPanGestureRecognizer && $0.delegate === self }) {
            pullGesture.isEnabled = true
        }
        // Position D-pad zones around mic button
        setNeedsLayout(); layoutIfNeeded()
    }

    @objc private func dpadTapped(_ sender: UITapGestureRecognizer) {
        let actions = ["cursorUp", "cursorDown", "cursorLeft", "cursorRight"]
        guard let v = sender.view, v.tag < actions.count else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onAction?(actions[v.tag])
    }

    // D-pad zone positions: 3×3 grid centered on mic, side = (panelH + 2*margin) / 3
    private func positionDpadZones() {
        guard dpadZones.count == 4 else { return }
        let margin: CGFloat = 24
        let side = (composerPanel.bounds.height + 2 * margin) / 3
        let h = side / 2
        let micCenter = micBtn.convert(CGPoint(x: micBtn.bounds.midX, y: micBtn.bounds.midY), to: self)
        let cy = micCenter.y; let cx = micCenter.x
        let gridTop = hintLabel.frame.maxY  // up zone top = hint bottom

        // 3×3 grid cells (row, col), only cross cells (up/down/left/right) are active
        // up:   (0,1)  center: (1,1) is mic    corners: empty
        // left: (1,0)  right:  (1,2)           down:  (2,1)
        let upFrame   = CGRect(x: cx - h,  y: gridTop,           width: side, height: side)
        let dnFrame   = CGRect(x: cx - h,  y: gridTop + 2 * side, width: side, height: side)
        let lfFrame   = CGRect(x: cx - h - side, y: gridTop + side, width: side, height: side)
        let rtFrame   = CGRect(x: cx + h,  y: gridTop + side, width: side, height: side)

        let frames = [upFrame, dnFrame, lfFrame, rtFrame]
        for i in 0..<4 { dpadZones[i].frame = frames[i] }
    }

    // MARK: - Hot zone visualization

    private var hotZoneOverlays: [UIView] = []

    func setHotZonesVisible(_ visible: Bool) {
        if visible && hotZoneOverlays.isEmpty { createHotZoneOverlays() }
        hotZoneOverlays.forEach { $0.isHidden = !visible }
        // D-pad zones: cycling colors matching Android (red/green/blue/yellow)
        let dpadColors: [UIColor] = [
            UIColor(red: 1, green: 0, blue: 0, alpha: 0.25),
            UIColor(red: 0, green: 1, blue: 0, alpha: 0.25),
            UIColor(red: 0, green: 0, blue: 1, alpha: 0.25),
            UIColor(red: 1, green: 1, blue: 0, alpha: 0.25),
        ]
        for i in 0..<min(dpadZones.count, dpadColors.count) {
            dpadZones[i].backgroundColor = visible ? dpadColors[i] : .clear
        }
    }

    private func createHotZoneOverlays() {
        let pullColor = UIColor(red: 0, green: 1, blue: 0, alpha: 0.25)    // green: pull-up
        let micColor  = UIColor(red: 1, green: 0, blue: 0, alpha: 0.25)    // red: mic cursor
        let btnColor  = UIColor(red: 1, green: 1, blue: 0, alpha: 0.25)    // yellow: buttons
        func makeZone(_ color: UIColor, _ parent: UIView) -> UIView {
            let v = UIView(); v.backgroundColor = color; v.layer.cornerRadius = 4; v.isUserInteractionEnabled = false
            v.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(v); return v
        }

        // Overflow margin = gap between hint bottom and composer panel top (24pt)
        let m: CGFloat = 24
        let excl: CGFloat = 70  // mic exclusion half-width

        // Pull-up zone: composerPanel ± margin on all 4 sides, split by mic exclusion
        let leftPull = makeZone(pullColor, self)
        NSLayoutConstraint.activate([
            leftPull.topAnchor.constraint(equalTo: composerPanel.topAnchor, constant: -m),
            leftPull.bottomAnchor.constraint(equalTo: composerPanel.bottomAnchor, constant: m),
            leftPull.leadingAnchor.constraint(equalTo: composerPanel.leadingAnchor, constant: -m),
            leftPull.trailingAnchor.constraint(equalTo: micBtn.centerXAnchor, constant: -excl),
        ])
        let rightPull = makeZone(pullColor, self)
        NSLayoutConstraint.activate([
            rightPull.topAnchor.constraint(equalTo: composerPanel.topAnchor, constant: -m),
            rightPull.bottomAnchor.constraint(equalTo: composerPanel.bottomAnchor, constant: m),
            rightPull.leadingAnchor.constraint(equalTo: micBtn.centerXAnchor, constant: excl),
            rightPull.trailingAnchor.constraint(equalTo: composerPanel.trailingAnchor, constant: m),
        ])

        // Mic exclusion zone (red): full panel height, ±70pt from mic center
        let micZone = makeZone(micColor, composerPanel)
        NSLayoutConstraint.activate([
            micZone.centerXAnchor.constraint(equalTo: micBtn.centerXAnchor),
            micZone.centerYAnchor.constraint(equalTo: micBtn.centerYAnchor),
            micZone.widthAnchor.constraint(equalToConstant: excl * 2),
            micZone.heightAnchor.constraint(equalTo: composerPanel.heightAnchor),
        ])

        // Delete & return button zones
        let deleteZone = makeZone(btnColor, composerPanel)
        NSLayoutConstraint.activate([
            deleteZone.centerXAnchor.constraint(equalTo: deleteBtn.centerXAnchor),
            deleteZone.centerYAnchor.constraint(equalTo: deleteBtn.centerYAnchor),
            deleteZone.widthAnchor.constraint(equalToConstant: 70),
            deleteZone.heightAnchor.constraint(equalToConstant: 70),
        ])
        let returnZone = makeZone(btnColor, composerPanel)
        NSLayoutConstraint.activate([
            returnZone.centerXAnchor.constraint(equalTo: returnBtn.centerXAnchor),
            returnZone.centerYAnchor.constraint(equalTo: returnBtn.centerYAnchor),
            returnZone.widthAnchor.constraint(equalToConstant: 70),
            returnZone.heightAnchor.constraint(equalToConstant: 70),
        ])

        hotZoneOverlays = [leftPull, rightPull, micZone, deleteZone, returnZone]
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let loc = touch.location(in: self)
        let blockedFrames = [micBtn, deleteBtn, returnBtn].map { $0.convert($0.bounds, to: self).insetBy(dx: -8, dy: -8) }
        // Also block the mic cursor zone (±70pt from mic center) to avoid conflicts
        let micCenter = micBtn.convert(CGPoint(x: micBtn.bounds.midX, y: micBtn.bounds.midY), to: self)
        if abs(loc.x - micCenter.x) < 70 { return false }
        for f in blockedFrames where f.contains(loc) { return false }
        return true
    }
}

final class ScreenPanelView: UIView {
    var screenState: ScreenState? {
        didSet {
            cancellable?.cancel()
            sync()
            cancellable = screenState?.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { self?.sync() }
            }
        }
    }
    var onViewportMove: ((Int, Int) -> Void)?
    var onViewportResize: ((Int, Int, Int, Int) -> Void)? // x, y, w, h — for scale changes
    var onPointerClick: ((Int, Int) -> Void)?
    var onPointerScroll: ((Int, Int) -> Void)?
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    private let videoView = RTCMTLVideoView(); private let minimap = MinimapUIView()
    private var videoTrack: RTCVideoTrack?
    private let loadingSpinner = UIActivityIndicatorView(style: .large)
    private let loadingLabel = UILabel()
    private let grabBar = UIView(); private let grabPill = UIView()
    private var panelHeight: CGFloat = 0
    private var baseOffset: CGFloat = 0
    private(set) var isOpen = false
    private var cancellable: AnyCancellable?
    private var panStartVPX: CGFloat = 0; private var panStartVPY: CGFloat = 0
    private var scrollBaseY: CGFloat = 0
    var curtainHeight: CGFloat { max(panelHeight, 1) }
    var videoBounds: CGRect { videoView.bounds }
    var visualOffset: CGFloat { curtainOffset + keyboardLift }
    var minimapVpW: CGFloat { minimap.vpW }
    var minimapVpH: CGFloat { minimap.vpH }
    private var displayScale: CGFloat = 1.0

    var curtainOffset: CGFloat = 0
    var keyboardLift: CGFloat = 0 { didSet { applyCombinedTransform() } }

    func applyCombinedTransform() {
        transform = CGAffineTransform(translationX: 0, y: visualOffset)
        onTransformChanged?(visualOffset)
    }

    var onTransformChanged: ((CGFloat) -> Void)?

    /// Partially reveal panel during header drag (offset: 0=hidden, curtainHeight=open)
    func reveal(_ offset: CGFloat) {
        isHidden = false
        curtainOffset = min(max(0, offset), curtainHeight) - curtainHeight
        applyCombinedTransform()
    }

    private var debugHotZones = false
    private var minimapAspect: NSLayoutConstraint?
    private var viewportInited = false
    // Minimap position constraints (swapped for position picker)
    private var mmLeading: NSLayoutConstraint?; private var mmTrailing: NSLayoutConstraint?
    private var mmTop: NSLayoutConstraint?; private var mmBottom: NSLayoutConstraint?
    private var mmCenterY: NSLayoutConstraint?

    private enum MMPos: String, CaseIterable {
        case topLeft = "左上"
        case bottomLeft = "左下"
        case left = "左侧中"
        case right = "右侧中"
        case bottomRight = "右下"
        case topRight = "右上"
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.12, green: 0.13, blue: 0.14, alpha: 1)
        videoView.videoContentMode = .scaleAspectFit; videoView.translatesAutoresizingMaskIntoConstraints = false; addSubview(videoView)

        // Grab bar (64pt tall overlay, matches Android screen_grab)
        grabBar.backgroundColor = .clear
        grabBar.translatesAutoresizingMaskIntoConstraints = false; addSubview(grabBar)
        grabPill.backgroundColor = UIColor(white: 1, alpha: 0.4)
        grabPill.layer.cornerRadius = 2.5; grabPill.translatesAutoresizingMaskIntoConstraints = false
        grabBar.addSubview(grabPill)
        let grabPan = UIPanGestureRecognizer(target: self, action: #selector(handleGrabDrag(_:)))
        grabBar.addGestureRecognizer(grabPan)

        // Minimap
        minimap.translatesAutoresizingMaskIntoConstraints = false; minimap.clipsToBounds = true
        minimap.layer.borderWidth = 1; minimap.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor; addSubview(minimap)
        minimap.onViewportMove = { [weak self] x, y in self?.onViewportMove?(x, y) }
        minimap.onLongPress = { [weak self] in self?.showMinimapPositionMenu() }

        // Video-area drag to pan viewport (single-finger only)
        let videoPan = UIPanGestureRecognizer(target: self, action: #selector(handleVideoPan(_:)))
        videoPan.maximumNumberOfTouches = 1
        videoView.addGestureRecognizer(videoPan)

        // Loading indicator (shown until video track arrives)
        loadingSpinner.color = .white; loadingSpinner.hidesWhenStopped = true
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false; addSubview(loadingSpinner)
        loadingLabel.text = "正在加载桌面…"; loadingLabel.font = .systemFont(ofSize: 14)
        loadingLabel.textColor = UIColor(white: 0.6, alpha: 1); loadingLabel.textAlignment = .center
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false; addSubview(loadingLabel)

        // Long-press on video for scale menu
        let videoLongPress = UILongPressGestureRecognizer(target: self, action: #selector(showScaleMenu(_:)))
        videoLongPress.minimumPressDuration = 0.5
        videoView.addGestureRecognizer(videoLongPress)

        // Tap on video → pointer click (fires on touch-up, matches Android ACTION_UP)
        let videoTap = UITapGestureRecognizer(target: self, action: #selector(handleVideoTap(_:)))
        videoTap.require(toFail: videoPan)
        videoTap.require(toFail: videoLongPress)
        videoView.addGestureRecognizer(videoTap)

        // Two-finger drag on video → pointer scroll
        let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        scrollPan.minimumNumberOfTouches = 2; scrollPan.maximumNumberOfTouches = 2
        videoView.addGestureRecognizer(scrollPan)

        NSLayoutConstraint.activate([
            // Grab bar at top
            grabBar.topAnchor.constraint(equalTo: topAnchor),
            grabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            grabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            grabBar.heightAnchor.constraint(equalToConstant: 64),
            grabPill.centerXAnchor.constraint(equalTo: grabBar.centerXAnchor),
            grabPill.centerYAnchor.constraint(equalTo: grabBar.centerYAnchor),
            grabPill.widthAnchor.constraint(equalToConstant: 36),
            grabPill.heightAnchor.constraint(equalToConstant: 5),

            // Video fills entire panel (shadow extends below)
            videoView.topAnchor.constraint(equalTo: topAnchor),
            videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoView.bottomAnchor.constraint(equalTo: bottomAnchor),

            minimap.widthAnchor.constraint(equalToConstant: 150),

        ])
        // Minimap position constraints (default: bottom-right)
        mmLeading = minimap.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16)
        mmTrailing = minimap.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        mmTop = minimap.topAnchor.constraint(equalTo: topAnchor, constant: 22)
        mmBottom = minimap.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22)
        mmCenterY = minimap.centerYAnchor.constraint(equalTo: centerYAnchor)
        mmTrailing?.isActive = true; mmBottom?.isActive = true

        // Loading indicator
        NSLayoutConstraint.activate([
            loadingSpinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            loadingLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingLabel.topAnchor.constraint(equalTo: loadingSpinner.bottomAnchor, constant: 12),
        ])

        // Minimap aspect ratio constraint (updated when window dimensions arrive)
        let ar = minimap.heightAnchor.constraint(equalTo: minimap.widthAnchor, multiplier: 110.0/150.0)
        ar.isActive = true; minimapAspect = ar
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        if h > 0 { panelHeight = h }
    }

    // MARK: - Open / Close

    func open(animated: Bool = true) {
        guard !isOpen else { return }
        isOpen = true
        if isHidden {
            isHidden = false
            curtainOffset = -curtainHeight
            applyCombinedTransform()
        }
        // Show spinner if no video track yet
        if videoTrack == nil { loadingSpinner.startAnimating(); loadingLabel.isHidden = false }
        let changes = { self.curtainOffset = 0; self.applyCombinedTransform() }
        if animated {
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: [], animations: changes)
        } else { changes() }
        onOpen?()
    }

    func close(animated: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        let h = max(panelHeight, 1)
        let changes = { self.curtainOffset = -h; self.applyCombinedTransform() }
        let finish = {
            self.isHidden = true; self.curtainOffset = 0; self.keyboardLift = 0
            self.applyCombinedTransform(); self.onClose?()
        }
        if animated {
            UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseIn, animations: changes) { _ in finish() }
        } else { changes(); finish() }
    }

    // MARK: - Grab bar drag (bidirectional)

    @objc private func handleGrabDrag(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: superview)
        switch gesture.state {
        case .began:
            baseOffset = curtainOffset
        case .changed:
            curtainOffset = min(0, baseOffset + translation.y)
            applyCombinedTransform()
        case .ended, .cancelled:
            let velocity = gesture.velocity(in: superview).y
            settle(velocityY: velocity)
        default: break
        }
    }

    @objc private func handleVideoPan(_ gesture: UIPanGestureRecognizer) {
        guard let ss = screenState, ss.metaW > 0, ss.metaH > 0 else { return }
        let dispScale = contentDispScale()
        guard dispScale > 0 else { return }
        let translation = gesture.translation(in: videoView)
        switch gesture.state {
        case .began:
            panStartVPX = minimap.vpX; panStartVPY = minimap.vpY
        case .changed:
            let nx = max(0, min(CGFloat(ss.metaWinW) - CGFloat(ss.metaW), panStartVPX - translation.x / dispScale))
            let ny = max(0, min(CGFloat(ss.metaWinH) - CGFloat(ss.metaH), panStartVPY - translation.y / dispScale))
            minimap.vpX = nx; minimap.vpY = ny
            onViewportMove?(Int(nx), Int(ny))
            minimap.setNeedsDisplay()
        default: break
        }
    }

    @objc private func handleVideoTap(_ gesture: UITapGestureRecognizer) {
        let pt = gesture.location(in: videoView)
        let (wx, wy) = rendererToWindow(pt.x, pt.y)
        onPointerClick?(wx, wy)
    }

    @objc private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        guard let ss = screenState, ss.metaW > 0 else { return }
        let dispScale = contentDispScale()
        guard dispScale > 0 else { return }
        let avgY = gesture.location(in: videoView).y
        switch gesture.state {
        case .began:
            scrollBaseY = avgY
        case .changed:
            let dy = scrollBaseY - avgY
            scrollBaseY = avgY
            if abs(dy) > 1 {
                let sdy = Int(dy / dispScale)
                if sdy != 0 { onPointerScroll?(0, sdy) }
            }
        default: break
        }
    }

    private func rendererToWindow(_ rx: CGFloat, _ ry: CGFloat) -> (Int, Int) {
        let cr = videoContentRect()
        guard cr.width > 0, cr.height > 0, let ss = screenState,
              ss.metaW > 0, ss.metaH > 0 else { return (0, 0) }
        let dispScale = min(cr.width / CGFloat(ss.metaW), cr.height / CGFloat(ss.metaH))
        let wx = Int(max(0, min(CGFloat(ss.metaW - 1), (rx - cr.minX) / dispScale)))
        let wy = Int(max(0, min(CGFloat(ss.metaH - 1), (ry - cr.minY) / dispScale)))
        return (Int(minimap.vpX) + wx, Int(minimap.vpY) + wy)
    }

    private func contentDispScale() -> CGFloat {
        let vw = videoView.bounds.width; let vh = videoView.bounds.height
        guard vw > 0, vh > 0, let ss = screenState,
              ss.metaW > 0, ss.metaH > 0 else { return 0 }
        return min(vw / CGFloat(ss.metaW), vh / CGFloat(ss.metaH))
    }

    private func videoContentRect() -> CGRect {
        let vw = videoView.bounds.width; let vh = videoView.bounds.height
        guard vw > 0, vh > 0, let ss = screenState, ss.metaW > 0, ss.metaH > 0 else { return .zero }
        let va = vw / vh; let ca = CGFloat(ss.metaW) / CGFloat(ss.metaH)
        if ca > va { let h = vw / ca; return CGRect(x: 0, y: (vh - h)/2, width: vw, height: h) }
        else { let w = vh * ca; return CGRect(x: (vw - w)/2, y: 0, width: w, height: vh) }
    }

    private func settle(velocityY: CGFloat) {
        let progress = 1 + curtainOffset / max(panelHeight, 1)
        let shouldOpen: Bool
        if velocityY > 800 { shouldOpen = true }
        else if velocityY < -800 { shouldOpen = false }
        else { shouldOpen = progress > 0.4 }
        if shouldOpen { open() } else { close() }
    }

    private func sync() {
        guard let ss = screenState else { return }
        if let t = ss.videoTrack, t !== videoTrack { videoTrack?.remove(videoView); t.add(videoView); videoTrack = t }
        // Loading indicator: shown until video track arrives
        if ss.videoTrack != nil { loadingSpinner.stopAnimating(); loadingLabel.isHidden = true }
        else if isOpen { loadingSpinner.startAnimating(); loadingLabel.isHidden = false }
        minimap.thumbnail = ss.thumbnail; minimap.winW = CGFloat(ss.metaWinW); minimap.winH = CGFloat(ss.metaWinH)
        minimap.vpW = CGFloat(ss.metaW); minimap.vpH = CGFloat(ss.metaH)
        if !minimap.isDragging { minimap.vpX = CGFloat(ss.metaX); minimap.vpY = CGFloat(ss.metaY) }
        // Update minimap aspect ratio to match thumbnail/desktop aspect
        if ss.metaWinW > 0, ss.metaWinH > 0 {
            let ratio = CGFloat(ss.metaWinH) / CGFloat(ss.metaWinW)
            if let ar = minimapAspect, abs(ar.multiplier - ratio) > 0.001 {
                ar.isActive = false
                let newAr = minimap.heightAnchor.constraint(equalTo: minimap.widthAnchor, multiplier: ratio)
                newAr.isActive = true; minimapAspect = newAr
            }
        }
        // Auto-position viewport to bottom-right on first meta
        if !viewportInited, ss.metaWinW > 0, ss.metaW > 0 {
            viewportInited = true
            let brX = max(0, ss.metaWinW - ss.metaW)
            let brY = max(0, ss.metaWinH - ss.metaH)
            minimap.vpX = CGFloat(brX); minimap.vpY = CGFloat(brY)
            onViewportResize?(brX, brY, ss.metaW, ss.metaH)
        }
        minimap.setNeedsDisplay()
    }

    // MARK: - Minimap position picker

    private func showMinimapPositionMenu() {
        let impact = UIImpactFeedbackGenerator(style: .medium); impact.impactOccurred()
        guard let vc = window?.rootViewController else { return }
        let a = UIAlertController(title: "缩略图位置", message: nil, preferredStyle: .actionSheet)
        for pos in MMPos.allCases {
            a.addAction(UIAlertAction(title: pos.rawValue, style: .default) { [weak self] _ in
                self?.applyMinimapPosition(pos)
            })
        }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        vc.present(a, animated: true)
    }

    private func applyMinimapPosition(_ pos: MMPos) {
        [mmLeading, mmTrailing, mmTop, mmBottom, mmCenterY].forEach { $0?.isActive = false }
        switch pos {
        case .topLeft:     mmLeading?.isActive = true; mmTop?.isActive = true
        case .topRight:    mmTrailing?.isActive = true; mmTop?.isActive = true
        case .left:        mmLeading?.isActive = true; mmCenterY?.isActive = true
        case .right:       mmTrailing?.isActive = true; mmCenterY?.isActive = true
        case .bottomLeft:  mmLeading?.isActive = true; mmBottom?.isActive = true
        case .bottomRight: mmTrailing?.isActive = true; mmBottom?.isActive = true
        }
        UIView.animate(withDuration: 0.25) { self.layoutIfNeeded() }
    }

    // MARK: - Scale menu

    @objc private func showScaleMenu(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let impact = UIImpactFeedbackGenerator(style: .medium); impact.impactOccurred()
        guard let vc = window?.rootViewController else { return }
        let a = UIAlertController(title: "显示缩放", message: nil, preferredStyle: .actionSheet)
        for scale in [1.0, 0.9, 0.8, 0.75] {
            let title = scale == 1.0 ? "1:1" : String(format: "%.2f", scale)
            let current = abs(displayScale - scale) < 0.001
            a.addAction(UIAlertAction(title: current ? "\(title) ✓" : title, style: .default) { [weak self] _ in
                self?.applyScale(CGFloat(scale))
            })
        }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        vc.present(a, animated: true)
    }

    private func applyScale(_ scale: CGFloat) {
        displayScale = scale
        guard let ss = screenState, ss.metaWinW > 0, ss.metaWinH > 0 else { return }
        let vw = videoView.bounds.width; let vh = videoView.bounds.height
        guard vw > 0, vh > 0 else { return }
        let rawW = max(1, Int(CGFloat(vw) / scale))
        let rawH = max(1, Int(CGFloat(vh) / scale))
        let fit = min(CGFloat(ss.metaWinW) / CGFloat(rawW), CGFloat(ss.metaWinH) / CGFloat(rawH), 1.0)
        let newW = max(1, min(ss.metaWinW, Int(CGFloat(rawW) * fit)))
        let newH = max(1, min(ss.metaWinH, Int(CGFloat(rawH) * fit)))
        let cx = minimap.vpX + minimap.vpW / 2; let cy = minimap.vpY + minimap.vpH / 2
        let newX = max(0, min(CGFloat(ss.metaWinW - newW), cx - CGFloat(newW) / 2))
        let newY = max(0, min(CGFloat(ss.metaWinH - newH), cy - CGFloat(newH) / 2))
        minimap.vpW = CGFloat(newW); minimap.vpH = CGFloat(newH)
        minimap.vpX = newX; minimap.vpY = newY
        onViewportResize?(Int(newX), Int(newY), newW, newH)
        minimap.setNeedsDisplay()
    }

    func setHotZonesVisible(_ visible: Bool) { debugHotZones = visible }
}
