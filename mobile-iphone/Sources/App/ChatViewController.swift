import UIKit
import WebRTC

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
        setupHeader(); setupMessages(); setupInput(); setupScreenPanel()
        reloadMessages()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        connections?.setScreenListener(connectionId: connectionId, listener: screenState)
    }

    private func setupHeader() {
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        headerBar.onBack = { [weak self] in self?.navigationController?.popViewController(animated: true) }
        headerBar.onMenu = { [weak self] in self?.showMenu() }
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
        inputBar.translatesAutoresizingMaskIntoConstraints = false
        inputBar.onSend = { [weak self] text in
            guard let self, let s = self.session else { return }
            self.connections?.sendText(session: s, text: text); self.reloadMessages()
        }
        inputBar.onAction = { [weak self] action in
            guard let self, let s = self.session else { return }
            self.connections?.sendAction(session: s, action: action)
        }
        view.addSubview(inputBar)
        NSLayoutConstraint.activate([
            inputBar.topAnchor.constraint(equalTo: messageList.bottomAnchor),
            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    private func setupScreenPanel() {
        screenPanel.isHidden = true; screenPanel.translatesAutoresizingMaskIntoConstraints = false
        screenPanel.onViewportMove = { [weak self] x, y in
            guard let self, let s = self.session, self.screenState.metaW > 0 else { return }
            self.connections?.sendViewport(session: s, x: x, y: y,
                                           w: self.screenState.metaW, h: self.screenState.metaH)
        }
        view.addSubview(screenPanel)
        NSLayoutConstraint.activate([
            screenPanel.topAnchor.constraint(equalTo: view.topAnchor),
            screenPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            screenPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            screenPanel.bottomAnchor.constraint(equalTo: inputBar.topAnchor),
        ])
    }

    private func showMenu() {
        let a = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        a.addAction(UIAlertAction(title: "查看屏幕", style: .default) { [weak self] _ in self?.openScreenPanel() })
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(a, animated: true)
    }

    private func openScreenPanel() {
        screenPanel.isHidden = false; screenPanel.screenState = screenState
        connections?.setScreenListener(connectionId: connectionId, listener: screenState)
        if let s = session {
            connections?.startScreen(session: s, viewportW: Int(view.bounds.width), viewportH: Int(screenPanel.bounds.height))
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
    var onBack: (() -> Void)?; var onMenu: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.16, alpha: 1); layer.cornerRadius = 18
        let back = UIButton(type: .system)
        back.setImage(UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
        back.tintColor = UIColor(white: 0.7, alpha: 1); back.backgroundColor = UIColor(white: 0.2, alpha: 1); back.layer.cornerRadius = 20
        back.addTarget(self, action: #selector(tapBack), for: .touchUpInside)
        let app = UILabel(); app.font = .systemFont(ofSize: 22, weight: .bold); app.textColor = .white; app.tag = 1
        let title = UILabel(); title.font = .systemFont(ofSize: 13); title.textColor = UIColor(white: 0.6, alpha: 1); title.tag = 2
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
    @objc private func tapBack() { onBack?() }
    @objc private func tapMenu() { onMenu?() }
}

final class ChatInputBar: UIView, UITextFieldDelegate {
    var onSend: ((String) -> Void)?; var onAction: ((String) -> Void)?
    private let hintLabel = UILabel()
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

        // Return button (56x56, surfaceAlt bg)
        returnBtn.setImage(UIImage(systemName: "return", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)), for: .normal)
        returnBtn.tintColor = UIColor(white: 0.7, alpha: 1)
        returnBtn.backgroundColor = UIColor(white: 0.2, alpha: 1)
        returnBtn.layer.cornerRadius = 28
        returnBtn.addTarget(self, action: #selector(returnTouchDown), for: .touchDown)
        returnBtn.addTarget(self, action: #selector(returnTouchUp), for: .touchUpInside)
        returnBtn.addTarget(self, action: #selector(returnTouchUp), for: .touchUpOutside)
        returnBtn.addTarget(self, action: #selector(returnTouchUp), for: .touchDragExit)

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
        switchMicBtn.tintColor = UIColor(red: 1, green: 0.58, blue: 0.22, alpha: 1); switchMicBtn.backgroundColor = UIColor(white: 0.2, alpha: 1); switchMicBtn.layer.cornerRadius = 20; switchMicBtn.addTarget(self, action: #selector(switchToVoice), for: .touchUpInside)
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
    override func layoutSubviews() { super.layoutSubviews() }

    private let holdDuration: TimeInterval = 0.75

    // Delete button
    @objc private func deleteTouchDown() { beginHold(ring: deleteRing, btn: deleteBtn, work: &deleteHoldWork, onHold: { self.onAction?("clear") }) }
    @objc private func deleteTouchUp() { endHold(ring: deleteRing, btn: deleteBtn, work: &deleteHoldWork, onTap: { self.onAction?("backspace") }) }

    // Return button
    @objc private func returnTouchDown() { beginHold(ring: returnRing, btn: returnBtn, work: &returnHoldWork, onHold: { self.onAction?("enter") }) }
    @objc private func returnTouchUp() { endHold(ring: returnRing, btn: returnBtn, work: &returnHoldWork, onTap: { self.onAction?("shiftEnter") }) }

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
    @objc private func switchToVoice() { composerPanel.isHidden = false; hintLabel.isHidden = false; textPanel.isHidden = true; tf.resignFirstResponder() }
    func textFieldShouldReturn(_ tf: UITextField) -> Bool { sendText(); return true }
}

final class ScreenPanelView: UIView {
    var screenState: ScreenState? { didSet { sync() } }
    var onViewportMove: ((Int, Int) -> Void)?
    private let videoView = RTCMTLVideoView(); private let minimap = MinimapUIView(); private var videoTrack: RTCVideoTrack?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.12, green: 0.13, blue: 0.14, alpha: 1)
        videoView.videoContentMode = .scaleAspectFit; videoView.translatesAutoresizingMaskIntoConstraints = false; addSubview(videoView)
        minimap.translatesAutoresizingMaskIntoConstraints = false; minimap.layer.cornerRadius = 10; minimap.clipsToBounds = true
        minimap.layer.borderWidth = 1; minimap.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor; addSubview(minimap)
        minimap.onViewportMove = { [weak self] x, y in self?.onViewportMove?(x, y) }
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: topAnchor), videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: trailingAnchor), videoView.bottomAnchor.constraint(equalTo: bottomAnchor),
            minimap.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            minimap.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
            minimap.widthAnchor.constraint(equalToConstant: 150), minimap.heightAnchor.constraint(equalToConstant: 110),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    private func sync() {
        guard let ss = screenState else { return }
        if let t = ss.videoTrack, t !== videoTrack { videoTrack?.remove(videoView); t.add(videoView); videoTrack = t }
        minimap.thumbnail = ss.thumbnail; minimap.winW = CGFloat(ss.metaWinW); minimap.winH = CGFloat(ss.metaWinH)
        minimap.vpW = CGFloat(ss.metaW); minimap.vpH = CGFloat(ss.metaH)
        if !minimap.isDragging { minimap.vpX = CGFloat(ss.metaX); minimap.vpY = CGFloat(ss.metaY) }
        minimap.setNeedsDisplay()
    }
}
