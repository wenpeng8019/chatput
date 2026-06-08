import UIKit

// MARK: - SessionRowView

final class SessionRowView: UIView {
    var onTap: (() -> Void)?
    init(session: DesktopSession) {
        super.init(frame: .zero)
        backgroundColor = session.isActive ? UIColor(white: 0.2, alpha: 1) : UIColor(white: 0.16, alpha: 1)
        layer.cornerRadius = 18; clipsToBounds = true; layer.borderWidth = 1
        layer.borderColor = session.isActive ? UIColor(red: 1, green: 0.58, blue: 0.22, alpha: 0.3).cgColor : UIColor(white: 0.22, alpha: 1).cgColor

        let bar = UIView(); bar.backgroundColor = session.isActive ? UIColor(red: 1, green: 0.58, blue: 0.22, alpha: 1) : .clear; bar.layer.cornerRadius = 2
        let app = UILabel(); app.text = session.displayApp; app.font = .systemFont(ofSize: 16, weight: .bold); app.textColor = .white
        let title = UILabel(); title.text = session.displayTitle; title.font = .systemFont(ofSize: 13); title.textColor = UIColor(white: 0.6, alpha: 1)
        let dot = UIView(); dot.backgroundColor = session.isActive ? UIColor(red: 1, green: 0.58, blue: 0.22, alpha: 1) : .clear; dot.layer.cornerRadius = 4.5

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
    @objc private func tapped() { onTap?() }
}

// MARK: - RecentRowView

final class RecentRowView: UIView {
    var onReconnect: (() -> Void)?; var onDelete: (() -> Void)?
    init(pairing: Pairing, isConnecting: Bool) {
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.16, alpha: 1); layer.cornerRadius = 18; clipsToBounds = true
        layer.borderWidth = 1; layer.borderColor = UIColor(white: 0.22, alpha: 1).cgColor

        let delBtn = UIButton(type: .system)
        delBtn.setImage(UIImage(systemName: "trash", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17)), for: .normal)
        delBtn.tintColor = UIColor(white: 0.6, alpha: 1); delBtn.isHidden = isConnecting
        delBtn.addTarget(self, action: #selector(del), for: .touchUpInside)

        let label = UILabel(); label.text = pairing.label; label.font = .systemFont(ofSize: 15, weight: .semibold); label.textColor = .white
        let action = UILabel()
        if isConnecting {
            let sp = UIActivityIndicatorView(style: .medium); sp.color = UIColor(red: 1, green: 0.58, blue: 0.22, alpha: 1)
            sp.startAnimating(); sp.translatesAutoresizingMaskIntoConstraints = false; addSubview(sp)
            NSLayoutConstraint.activate([sp.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), sp.centerYAnchor.constraint(equalTo: centerYAnchor)])
        } else {
            action.text = "重新连接"; action.font = .systemFont(ofSize: 13, weight: .bold)
            action.textColor = UIColor(red: 1, green: 0.58, blue: 0.22, alpha: 1)
        }

        [delBtn, label, action].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            delBtn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), delBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            delBtn.widthAnchor.constraint(equalToConstant: 44), delBtn.heightAnchor.constraint(equalToConstant: 44),
            label.leadingAnchor.constraint(equalTo: delBtn.trailingAnchor, constant: 12), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -8),
            action.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), action.centerYAnchor.constraint(equalTo: centerYAnchor),
            topAnchor.constraint(equalTo: label.topAnchor, constant: -12), bottomAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(reconnect)); addGestureRecognizer(tap)
        if isConnecting { tap.isEnabled = false }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func reconnect() { onReconnect?() }
    @objc private func del() { onDelete?() }
}
