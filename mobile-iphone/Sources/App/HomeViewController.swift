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
        view.backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        setupViews()
        updateUI()
        connections.$sessions.receive(on: DispatchQueue.main).sink { [weak self] sessions in
            self?.updateUI()
            if !sessions.isEmpty, self?.navigationController?.topViewController == self {
                self?.navigationController?.pushViewController(
                    SessionListViewController(connections: self!.connections), animated: true)
            }
        }.store(in: &cancellables)
        connections.$status.receive(on: DispatchQueue.main).sink { [weak self] s in self?.headerView.update(status: s, connected: self?.connections.isConnected ?? false) }.store(in: &cancellables)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        hintContainer.layer.cornerRadius = hintContainer.bounds.height / 2
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
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
        recentTitle.textColor = UIColor(white: 0.6, alpha: 1)
        recentTitle.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(recentTitle)

        recentStack.axis = .vertical; recentStack.spacing = 8
        recentStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(recentStack)

        // Hint (capsule, fixed at bottom)
        hintContainer.backgroundColor = UIColor(white: 0.2, alpha: 1)
        hintContainer.clipsToBounds = true
        view.addSubview(hintContainer)
        hintContainer.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = .systemFont(ofSize: 15)
        hintLabel.textColor = UIColor(white: 0.6, alpha: 1)
        hintLabel.textAlignment = .center
        hintContainer.addSubview(hintLabel)
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        // Scan button (fixed at bottom)
        scanButton.setImage(UIImage(systemName: "qrcode.viewfinder",
                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)), for: .normal)
        scanButton.tintColor = .white
        scanButton.backgroundColor = UIColor(red: 1, green: 0.58, blue: 0.22, alpha: 1)
        scanButton.layer.cornerRadius = 29
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
            recentStack.bottomAnchor.constraint(equalTo: hintContainer.topAnchor, constant: -24),

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
            row.onDelete = { [weak self] in self?.connections.removeRecent(payload: p.payload) }
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
        backgroundColor = UIColor(white: 0.16, alpha: 1)
        layer.cornerRadius = 18

        titleLabel.text = "ChatPUT"
        titleLabel.font = .systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = UIColor(red: 1, green: 0.58, blue: 0.22, alpha: 1)

        subtitleLabel.text = "把桌面输入做得更自然"
        subtitleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        subtitleLabel.textColor = .white

        descLabel.text = "连接后，当前聚焦窗口会自动成为会话。"
        descLabel.font = .systemFont(ofSize: 14)
        descLabel.textColor = UIColor(white: 0.6, alpha: 1)

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

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            descLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 6),
            descLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            descLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            statusButton.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 12),
            statusButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(status: String, connected: Bool) {
        statusButton.setTitle(status, for: .normal)
        if connected {
            statusButton.setTitleColor(UIColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1), for: .normal)
            statusButton.backgroundColor = UIColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 0.15)
        } else {
            statusButton.setTitleColor(UIColor(white: 0.6, alpha: 1), for: .normal)
            statusButton.backgroundColor = UIColor(white: 0.2, alpha: 1)
        }
    }

    @objc private func tapStatus() { onStatusTap?() }
}
