import UIKit
import Combine

/// 首屏：未连接桌面时展示。大标题 + 描述 + 状态指示 + 历史连接 + 扫码按钮。
final class HomeViewController: UIViewController {
    private let connections: ConnectionManager
    private var cancellables = Set<AnyCancellable>()

    // Header (expanded mode)
    private let headerView = HomeHeaderView()

    // Scroll area
    private let scrollView = UIScrollView()
    private let recentTitle = UILabel()
    private let recentStack = UIStackView()

    // Bottom fixed
    private let hintContainer = UIView()
    private let hintLabel = UILabel()
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
        updateUI()
        connections.$sessions.receive(on: DispatchQueue.main).sink { [weak self] sessions in
            self?.updateUI()
            if !sessions.isEmpty, self?.navigationController?.topViewController == self {
                self?.navigationController?.pushViewController(
                    SessionListViewController(connections: self!.connections), animated: true)
            }
        }.store(in: &cancellables)
        connections.$status.receive(on: DispatchQueue.main).sink { [weak self] s in self?.headerView.update(status: s, connected: self?.connections.isConnected ?? false); self?.updateUI() }.store(in: &cancellables)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        hintContainer.layer.cornerRadius = hintContainer.bounds.height / 2
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateUI()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previous) else { return }
        headerView.layer.borderColor = Theme.line.cgColor
        updateUI()
    }

    private func setupViews() {
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.onStatusTap = { [weak self] in
            guard self?.connections.isConnected == true else { return }
            self?.navigationController?.pushViewController(
                SessionListViewController(connections: self!.connections), animated: true)
        }
        scrollView.addSubview(headerView)

        // Recent connections (bottom fixed area)
        recentTitle.text = "历史连接"
        recentTitle.font = .systemFont(ofSize: 13)
        recentTitle.textColor = Theme.textTertiary
        recentTitle.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(recentTitle)

        recentStack.axis = .vertical; recentStack.spacing = 8
        recentStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(recentStack)

        // Hint (capsule, fixed at bottom)
        hintContainer.backgroundColor = Theme.surfaceAlt
        hintContainer.clipsToBounds = true
        view.addSubview(hintContainer)
        hintContainer.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = .systemFont(ofSize: 15)
        hintLabel.textColor = Theme.textSecondary
        hintLabel.textAlignment = .center
        hintContainer.addSubview(hintLabel)
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        // Scan button (fixed at bottom)
        scanButton.setImage(UIImage(systemName: "qrcode.viewfinder",
                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)), for: .normal)
        scanButton.tintColor = Theme.onAccent
        scanButton.backgroundColor = Theme.accent
        scanButton.layer.cornerRadius = 29
        scanButton.layer.shadowColor = UIColor.black.cgColor
        scanButton.layer.shadowOffset = CGSize(width: 0, height: 4)
        scanButton.layer.shadowRadius = 8; scanButton.layer.shadowOpacity = 0.2
        scanButton.addTarget(self, action: #selector(openScanner), for: .touchUpInside)
        view.addSubview(scanButton)
        scanButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: recentTitle.topAnchor, constant: -24),

            headerView.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 14),
            headerView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 18),
            headerView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -18),
            headerView.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -36),

            recentTitle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 38),
            recentTitle.bottomAnchor.constraint(equalTo: recentStack.topAnchor, constant: -10),

            recentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            recentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),
            recentStack.bottomAnchor.constraint(equalTo: hintContainer.topAnchor, constant: -36),

            hintContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hintContainer.bottomAnchor.constraint(equalTo: scanButton.topAnchor, constant: -16),

            hintLabel.topAnchor.constraint(equalTo: hintContainer.topAnchor, constant: 13),
            hintLabel.bottomAnchor.constraint(equalTo: hintContainer.bottomAnchor, constant: -13),
            hintLabel.leadingAnchor.constraint(equalTo: hintContainer.leadingAnchor, constant: 22),
            hintLabel.trailingAnchor.constraint(equalTo: hintContainer.trailingAnchor, constant: -22),

            scanButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            scanButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            scanButton.widthAnchor.constraint(equalToConstant: 58),
            scanButton.heightAnchor.constraint(equalToConstant: 58),
        ])
    }

    private func updateUI() {
        headerView.update(status: connections.status, connected: connections.isConnected)

        let pairings = connections.recentPairings()
        let showRecent = !pairings.isEmpty && !connections.hasConnectionContext
        recentTitle.isHidden = !showRecent
        recentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for p in pairings {
            let row = RecentRowView(pairing: p, isConnecting: connections.isConnecting(connectionId: p.id))
            row.onReconnect = { [weak self] in self?.connections.pair(p.payload) }
            row.onDelete = { [weak self] in self?.connections.removeRecent(payload: p.payload); self?.updateUI() }
            recentStack.addArrangedSubview(row)
        }

        hintLabel.text = connections.sessions.isEmpty
            ? (connections.isConnecting ? "正在连接桌面…" : "扫码连接你的桌面")
            : "已连接，点击状态进入会话列表"
    }

    @objc private func openScanner() {
        let scanner = ScannerController()
        scanner.onCode = { [weak self] code in self?.dismiss(animated: true); do { try self?.connections.pair(rawPayload: code) } catch {} }
        scanner.onCancel = { [weak self] in self?.dismiss(animated: true) }
        scanner.modalPresentationStyle = .fullScreen
        present(scanner, animated: true)
    }
}

// MARK: - HomeHeaderView

final class HomeHeaderView: UIView {
    var onStatusTap: (() -> Void)?
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let descLabel = UILabel()
    private let statusButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.surface
        layer.cornerRadius = 18
        layer.borderWidth = 1; layer.borderColor = Theme.line.cgColor

        titleLabel.text = "ChatPUT"
        titleLabel.font = .systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = Theme.accent

        subtitleLabel.text = "Hi Agent! \u{1F44B}"
        subtitleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        subtitleLabel.textColor = Theme.textPrimary

        descLabel.text = "连接后，当前聚焦窗口会自动成为会话。"
        descLabel.font = .systemFont(ofSize: 14)
        descLabel.textColor = Theme.textSecondary

        statusButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .bold)
        statusButton.layer.cornerRadius = 15
        statusButton.contentEdgeInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        statusButton.addTarget(self, action: #selector(tapStatus), for: .touchUpInside)

        [titleLabel, subtitleLabel, descLabel, statusButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            descLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
            descLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            descLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            statusButton.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 16),
            statusButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
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
