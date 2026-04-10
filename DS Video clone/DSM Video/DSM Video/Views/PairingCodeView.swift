import AVFoundation
import SwiftUI

#if !os(tvOS)

struct PairingCodeView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  @State private var code: String = ""
  @State private var isScanning: Bool = false
  @State private var error: String?
  @State private var isSubmitting: Bool = false

  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        Text("Pair with Apple TV")
          .font(.title2)
          .foregroundStyle(.primary)

        Text("Enter the 6-digit code shown on your Apple TV")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal)

        TextField("000000", text: $code)
          .textContentType(.oneTimeCode)
          .keyboardType(.numberPad)
          .font(.system(.largeTitle, design: .monospaced, weight: .semibold))
          .multilineTextAlignment(.center)
          .padding()
          .background(.quaternary)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .padding(.horizontal)
          .accessibilityLabel("Pairing code field")
          .accessibilityHint("Enter the 6-digit code shown on your Apple TV")

        if let error {
          Text(error)
            .font(.footnote)
            .foregroundStyle(.red)
            .padding(.horizontal)
        }

        Button {
          Task { await submit() }
        } label: {
          if isSubmitting {
            ProgressView("Pairing")
              .tint(.white)
          } else {
            Text("Pair")
              .font(.headline)
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(code.count != 6 || isSubmitting)
        .padding()

        Divider()
          .padding(.vertical)

        Button {
          isScanning = true
        } label: {
          Label("Scan QR Code", systemImage: "qrcode.viewfinder")
        }
        .buttonStyle(.bordered)
      }
      .padding()
      .frame(maxWidth: 480)
      .frame(maxWidth: .infinity, alignment: .center)
      .navigationTitle("Pair Device")
      #if !os(tvOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
      .sheet(isPresented: $isScanning) {
        QRCodeScannerView { scannedCode in
          isScanning = false
          if scannedCode.count == 6 && scannedCode.allSatisfy(\.isNumber) {
            code = scannedCode
            AccessibilityNotification.Announcement("QR code scanned. Pairing in progress.").post()
            Task { await submit() }
          } else {
            error = "Invalid code format. Please enter a 6-digit number."
          }
        }
        .accessibilityLabel("Camera viewfinder. Point at QR code to scan.")
      }
    }
  }

  private func submit() async {
    guard code.count == 6 else { return }
    error = nil
    isSubmitting = true
    defer { isSubmitting = false }

    await appState.exchangePairingCode(code)
    if appState.sessionToken != nil {
      dismiss()
    } else {
      error = appState.loginError ?? "Invalid pairing code."
    }
  }
}

private struct QRCodeScannerView: UIViewControllerRepresentable {
  let onCodeScanned: (String) -> Void

  func makeUIViewController(context: Context) -> QRScannerViewController {
    QRScannerViewController(onCodeScanned: onCodeScanned)
  }

  func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

private class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
  let onCodeScanned: (String) -> Void
  var captureSession: AVCaptureSession?
  var previewLayer: AVCaptureVideoPreviewLayer?

  init(onCodeScanned: @escaping (String) -> Void) {
    self.onCodeScanned = onCodeScanned
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    let status = AVCaptureDevice.authorizationStatus(for: .video)
    if status == .denied || status == .restricted {
      showCameraPermissionError()
      return
    } else if status == .notDetermined {
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        DispatchQueue.main.async {
          if granted {
            self?.setupCapture()
          } else {
            self?.showCameraPermissionError()
          }
        }
      }
      return
    }
    // .authorized — proceed immediately
    setupCapture()
  }

  private func showCameraPermissionError() {
    let label = UILabel()
    label.text = "Camera access is required to scan QR codes.\nGo to Settings > DSM Video to enable."
    label.textColor = .white
    label.textAlignment = .center
    label.numberOfLines = 0
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
    ])
  }

  private func setupCapture() {
    let captureSession = AVCaptureSession()
    guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else { return }
    let videoInput: AVCaptureDeviceInput
    do {
      videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
    } catch {
      return
    }

    if captureSession.canAddInput(videoInput) {
      captureSession.addInput(videoInput)
    } else {
      return
    }

    let metadataOutput = AVCaptureMetadataOutput()
    if captureSession.canAddOutput(metadataOutput) {
      captureSession.addOutput(metadataOutput)
      metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
      metadataOutput.metadataObjectTypes = [.qr]
    } else {
      return
    }

    previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
    previewLayer?.frame = view.layer.bounds
    previewLayer?.videoGravity = .resizeAspectFill
    if let previewLayer {
      view.layer.addSublayer(previewLayer)
    }

    self.captureSession = captureSession
    DispatchQueue.global(qos: .userInitiated).async {
      captureSession.startRunning()
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    previewLayer?.frame = view.layer.bounds
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if captureSession?.isRunning == false {
      DispatchQueue.global(qos: .userInitiated).async {
        self.captureSession?.startRunning()
      }
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    if captureSession?.isRunning == true {
      captureSession?.stopRunning()
    }
  }

  func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
    if let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
       let stringValue = metadataObject.stringValue {
      captureSession?.stopRunning()
      onCodeScanned(stringValue)
    }
  }
}

#Preview {
  PairingCodeView()
    .environment(AppState())
}

#endif
