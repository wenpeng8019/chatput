import UIKit

// MARK: - SessionRowView

final class SessionRowView: UIView {
    var onTap: (() -> Void)?
    init(session: DesktopSession) {
        super.init(frame: .zero)
        backgroundColor = session.isActive ? Theme.surfaceActive : Theme.surface
        layer.cornerRadius = 18; clipsToBounds = true; layer.borderWidth = 1
        layer.borderColor = session.isActive ? Theme.accent.withAlphaComponent(0.3).cgColor : Theme.line.cgColor

        let bar = UIView(); bar.backgroundColor = session.isActive ? Theme.accent : .clear; bar.layer.cornerRadius = 2
        let app = UILabel(); app.text = session.displayApp; app.font = .systemFont(ofSize: 16, weight: .bold); app.textColor = Theme.textPrimary
        let title = UILabel(); title.text = session.displayTitle; title.font = .systemFont(ofSize: 13); title.textColor = Theme.textSecondary
        let dot = UIView(); dot.backgroundColor = session.isActive ? Theme.accent : .clear; dot.layer.cornerRadius = 4.5

        [bar, app, title, dot].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.widthAnchor.constraint(equalToConstant: 4), bar.heightAnchor.constraint(equalToConstant: 34),
            app.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 12), app.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            app.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -8),
            title.leadingAnchor.constraint(equalTo: app.leadingAnchor), title.topAnchor.constraint(equalTo: app.bottomAnchor, constant: 5),
            title.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -8), title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 9), dot.heightAnchor.constraint(equalToConstant: 9),
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previous) {
            layer.borderColor = (backgroundColor == Theme.surfaceActive ? Theme.accent.withAlphaComponent(0.3) : Theme.line).cgColor
        }
    }

    func refreshBorder() {
        layer.borderColor = Theme.line.cgColor  // SessionRowView overridden by traitCollectionDidChange for active
    }

    @objc private func tapped() { onTap?() }
}

// MARK: - RecentRowView

final class RecentRowView: UIView {
    var onReconnect: (() -> Void)?; var onDelete: (() -> Void)?
    init(pairing: Pairing, isConnecting: Bool) {
        super.init(frame: .zero)
        backgroundColor = Theme.surface; layer.cornerRadius = 18; clipsToBounds = true
        layer.borderWidth = 1; layer.borderColor = Theme.line.cgColor

        let delBtn = UIButton(type: .system)
        delBtn.setImage(UIImage(systemName: "trash", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15)), for: .normal)
        delBtn.tintColor = Theme.textTertiary; delBtn.isHidden = isConnecting
        delBtn.addTarget(self, action: #selector(del), for: .touchUpInside)

        let label = UILabel(); label.text = pairing.label; label.font = .systemFont(ofSize: 15, weight: .semibold); label.textColor = Theme.textPrimary
        let action = UILabel()
        if isConnecting {
            let sp = UIActivityIndicatorView(style: .medium); sp.color = Theme.accent
            sp.startAnimating(); sp.translatesAutoresizingMaskIntoConstraints = false; addSubview(sp)
            NSLayoutConstraint.activate([sp.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), sp.centerYAnchor.constraint(equalTo: centerYAnchor)])
        } else {
            action.text = "重新连接"; action.font = .systemFont(ofSize: 13, weight: .bold)
            action.textColor = Theme.accent
        }

        [delBtn, label, action].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            delBtn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), delBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            delBtn.widthAnchor.constraint(equalToConstant: 28), delBtn.heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: delBtn.trailingAnchor, constant: 12), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -8),
            action.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), action.centerYAnchor.constraint(equalTo: centerYAnchor),
            topAnchor.constraint(equalTo: label.topAnchor, constant: -12), bottomAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(reconnect)); addGestureRecognizer(tap)
        if isConnecting { tap.isEnabled = false }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previous) {
            layer.borderColor = Theme.line.cgColor
        }
    }

    func refreshBorder() { layer.borderColor = Theme.line.cgColor }

    @objc private func reconnect() { onReconnect?() }
    @objc private func del() { onDelete?() }
}
