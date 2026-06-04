import AVFoundation
import CoreImage
import SwiftUI
import UIKit

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        controller.onCancel = onCancel
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "chatput.qr-scanner.session")
    private var preview: AVCaptureVideoPreviewLayer?
    private var didEmit = false
    private var shouldRunSession = false
    private lazy var qrDetector = CIDetector(
        ofType: CIDetectorTypeQRCode,
        context: nil,
        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
    )

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configure()
        addCancelButton()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        shouldRunSession = true
        sessionQueue.async { [weak self] in
            guard let self, self.shouldRunSession, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    deinit {
        shouldRunSession = false
        if session.isRunning { session.stopRunning() }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            showPasteFallback()
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showPasteFallback()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        self.preview = preview
    }

    private func showPasteFallback() {
        let title = UILabel()
        title.text = "无法使用摄像头"
        title.textColor = .white
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = UILabel()
        subtitle.text = "在模拟器里可以复制桌面端二维码图片或二维码内容，然后点下方按钮配对。"
        subtitle.textColor = UIColor.white.withAlphaComponent(0.72)
        subtitle.font = .systemFont(ofSize: 15)
        subtitle.numberOfLines = 0
        subtitle.textAlignment = .center
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let paste = UIButton(type: .system)
        var configuration = UIButton.Configuration.filled()
        configuration.title = "粘贴二维码"
        configuration.baseForegroundColor = .white
        configuration.baseBackgroundColor = UIColor(red: 45 / 255, green: 108 / 255, blue: 223 / 255, alpha: 1)
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 22, bottom: 12, trailing: 22)
        paste.configuration = configuration
        paste.translatesAutoresizingMaskIntoConstraints = false
        paste.addTarget(self, action: #selector(pastePairingPayload), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, subtitle, paste])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func addCancelButton() {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "xmark"), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        button.layer.cornerRadius = 20
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 40),
            button.heightAnchor.constraint(equalToConstant: 40),
            button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            button.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18)
        ])
    }

    @objc private func cancel() { onCancel?() }

    @objc private func pastePairingPayload() {
        if let value = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            emit(value)
            return
        }

        if let image = UIPasteboard.general.image ?? UIPasteboard.general.images?.first,
           let value = decodeQRCode(from: image) {
            emit(value)
            return
        }

        showPasteError("剪贴板里没有可识别的二维码")
    }

    private func decodeQRCode(from image: UIImage) -> String? {
        guard let ciImage = CIImage(image: image),
              let features = qrDetector?.features(in: ciImage) as? [CIQRCodeFeature] else { return nil }
        return features.compactMap(\.messageString).first { !$0.isEmpty }
    }

    private func emit(_ value: String) {
        guard !didEmit else { return }
        didEmit = true
        stopSession()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onCode?(value)
    }

    private func stopSession() {
        shouldRunSession = false
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func showPasteError(_ message: String) {
        let alert = UIAlertController(title: "无法配对", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !didEmit,
              let item = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = item.stringValue else { return }
        emit(value)
    }
}
