import UIKit
import Combine

/// 会话列表：紧凑 header + 会话（底部锚定，向上延展）+ 扫码按钮。
final class SessionListViewController: UIViewController {
    private unowned var connections: ConnectionManager!
    private var cancellables = Set<AnyCancellable>()

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let headerView = SessionListHeaderView()
    private let sessionStack = UIStackView()
    private let spacerView = UIView()
    private let scanButton = UIButton(type: .system)

    init(connections: ConnectionManager) {
        self.connections = connections
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.bg
        setupViews()
        reload()
        connections.$sessions.receive(on: DispatchQueue.main).sink { [weak self] sessions in
            self?.reload()
            if sessions.isEmpty { self?.navigationController?.popToRootViewController(animated: true) }
        }.store(in: &cancellables)
        connections.$status.receive(on: DispatchQueue.main).sink { [weak self] s in self?.headerView.update(status: s, connected: self?.connections.isConnected ?? false) }.store(in: &cancellables)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bottomY = max(0, contentView.bounds.height - scrollView.bounds.height)
        if scrollView.contentOffset.y < bottomY - 1 {
            scrollView.contentOffset.y = bottomY
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let bottomY = max(0, contentView.bounds.height - scrollView.bounds.height)
        scrollView.contentOffset.y = bottomY
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previous) else { return }
        headerView.layer.borderColor = Theme.line.cgColor
        reload()
    }

    private func setupViews() {
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false

        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.onStatusTap = { [weak self] in
            guard self?.connections.isConnected == true else { return }
            let a = UIAlertController(title: self?.connections.connectionGroupLabel(), message: nil, preferredStyle: .actionSheet)
            for d in self?.connections.connectedDesktops() ?? [] {
                a.addAction(UIAlertAction(title: "关闭 \(d.label)", style: .destructive) { [weak self] _ in self?.connections.disconnect(d.id) })
            }
            a.addAction(UIAlertAction(title: "取消", style: .cancel))
            self?.present(a, animated: true)
        }
        contentView.addSubview(headerView)

        spacerView.setContentHuggingPriority(.defaultLow, for: .vertical)
        spacerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(spacerView)

        sessionStack.axis = .vertical; sessionStack.spacing = 10
        sessionStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(sessionStack)

        scanButton.setImage(UIImage(systemName: "qrcode.viewfinder",
                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)), for: .normal)
        scanButton.tintColor = .white
        scanButton.backgroundColor = Theme.accent
        scanButton.layer.cornerRadius = 29
        scanButton.addTarget(self, action: #selector(openScanner), for: .touchUpInside)
        view.addSubview(scanButton)
        scanButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: scanButton.topAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),

            headerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            headerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            headerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),

            spacerView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 10),
            spacerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            spacerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            spacerView.bottomAnchor.constraint(equalTo: sessionStack.topAnchor, constant: -10),

            sessionStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            sessionStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            sessionStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),

            scanButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            scanButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            scanButton.widthAnchor.constraint(equalToConstant: 58),
            scanButton.heightAnchor.constraint(equalToConstant: 58),
        ])
    }

    private func reload() {
        sessionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for s in connections.sessions.reversed() {
            let row = SessionRowView(session: s)
            row.onTap = { [weak self] in
                let chat = ChatViewController(connectionId: s.connectionId, sessionId: s.sessionId, connections: self?.connections)
                self?.navigationController?.pushViewController(chat, animated: true)
            }
            sessionStack.addArrangedSubview(row)
        }
        // scroll to bottom after layout
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let bottomY = max(0, self.contentView.bounds.height - self.scrollView.bounds.height)
            self.scrollView.contentOffset.y = bottomY
        }
    }

    @objc private func openScanner() {
        let scanner = ScannerController()
        scanner.onCode = { [weak self] code in self?.dismiss(animated: true); do { try self?.connections.pair(rawPayload: code) } catch {} }
        scanner.onCancel = { [weak self] in self?.dismiss(animated: true) }
        scanner.modalPresentationStyle = .fullScreen
        present(scanner, animated: true)
    }
}

// MARK: - SessionListHeaderView

final class SessionListHeaderView: UIView {
    var onStatusTap: (() -> Void)?
    private let titleLabel = UILabel()
    private let statusButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.surface; layer.cornerRadius = 22
        layer.borderWidth = 1; layer.borderColor = Theme.line.cgColor

        titleLabel.text = "ChatPUT"
        titleLabel.font = .systemFont(ofSize: 18, weight: .regular)
        titleLabel.textColor = Theme.accent

        statusButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .bold)
        statusButton.layer.cornerRadius = 15
        statusButton.contentEdgeInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        statusButton.addTarget(self, action: #selector(tapStatus), for: .touchUpInside)

        [titleLabel, statusButton].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusButton.leadingAnchor, constant: -8),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            statusButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            statusButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previous) {
            layer.borderColor = Theme.line.cgColor
        }
    }

    func update(status: String, connected: Bool) {
        statusButton.setTitle(status, for: .normal)
        if connected {
            statusButton.setTitleColor(Theme.statusConnectedText, for: .normal)
            statusButton.backgroundColor = Theme.statusConnectedBg
        } else {
            statusButton.setTitleColor(Theme.statusIdleText, for: .normal)
            statusButton.backgroundColor = Theme.statusIdleBg
        }
    }

    @objc private func tapStatus() { onStatusTap?() }
}
