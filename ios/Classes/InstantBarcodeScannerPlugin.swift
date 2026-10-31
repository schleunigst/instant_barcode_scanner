import AVFoundation
import Flutter
import MLKitVision
import UIKit

public final class InstantBarcodeScannerPlugin: NSObject, FlutterPlugin {
  private var binaryMessenger: FlutterBinaryMessenger?
  private var textureRegistry: FlutterTextureRegistry?
  private var scannerApi: ScannerFlutterApi?
  private var mechanism: IosCameraMechanism?
  private var previewTexture: IosPreviewTexture?
  private var scanWindow: PlatformRect?
  private var observers: [NSObjectProtocol] = []
  private var orientationNotificationsStarted = false
  private var terminating = false

  private let textureLock = NSLock()
  private let frameLock = NSLock()
  private let lifecycleLock = NSLock()
  private let permission = IosCameraPermission()
  private var backgrounded = false
  private let selectionBox = IosCameraSelectionBox(
    IosCameraSelection(facing: .back, lensType: .any)
  )

  private var analyzedFrames: Int64 = 0
  private var scannerConfig = PlatformScannerConfig(
    facing: .back,
    lensType: .any,
    formats: [],
    torchEnabled: false,
    initialZoom: nil,
    targetWidth: nil,
    targetHeight: nil,
    detectionSpeed: .normal,
    detectionTimeoutMs: 250,
    invertImage: false
  )

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = InstantBarcodeScannerPlugin()
    let messenger = registrar.messenger()
    instance.binaryMessenger = messenger
    instance.textureRegistry = registrar.textures()
    instance.scannerApi = ScannerFlutterApi(binaryMessenger: messenger)
    ScannerHostApiSetup.setUp(binaryMessenger: messenger, api: instance)
    instance.installObservers()
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    terminating = true
    removeObservers()
    if let messenger = binaryMessenger {
      ScannerHostApiSetup.setUp(binaryMessenger: messenger, api: nil)
    }
    let current = mechanism
    mechanism = nil
    current?.shutdownSynchronously()
    releaseTexture()
    scannerApi = nil
    textureRegistry = nil
    binaryMessenger = nil
  }

  private func installObservers() {
    guard observers.isEmpty else {
      return
    }
    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.closeForBackground()
    })
    observers.append(center.addObserver(
      forName: UIApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self else {
        return
      }
      self.terminating = true
      self.mechanism?.shutdownSynchronously()
      self.releaseTexture()
    })
    observers.append(center.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.updateOrientation()
    })
    observers.append(center.addObserver(
      forName: UIDevice.orientationDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.setBackgrounded(false)
      self?.updateOrientation()
    })
    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    orientationNotificationsStarted = true
  }

  private func removeObservers() {
    let center = NotificationCenter.default
    for observer in observers {
      center.removeObserver(observer)
    }
    observers.removeAll()
    if orientationNotificationsStarted {
      UIDevice.current.endGeneratingDeviceOrientationNotifications()
      orientationNotificationsStarted = false
    }
  }

  private func updateOrientation() {
    guard let mechanism = mechanism else {
      return
    }
    mechanism.updateOrientation(IosCameraOrientation.current())
  }

  private func closeForBackground() {
    setBackgrounded(true)
    guard let mechanism = mechanism else {
      return
    }
    Task {
      _ = await mechanism.driveTo(.closed)
    }
  }

  private func setBackgrounded(_ value: Bool) {
    lifecycleLock.lock()
    backgrounded = value
    lifecycleLock.unlock()
  }

  private func isBackgrounded() -> Bool {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    return backgrounded
  }

  private func backgroundSnapshot() -> PlatformSnapshot {
    return PlatformSnapshot(
      state: .failed,
      errorCode: "backgrounded",
      errorMessage: "the app moved to the background"
    )
  }

  private func emitState(_ snapshot: PlatformSnapshot) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self,
            !self.terminating,
            let api = self.scannerApi else {
        return
      }
      Task { @MainActor in
        try? await api.onStateChanged(snapshot: snapshot)
      }
    }
  }

  private func emitPreviewMetrics(_ metrics: PlatformPreviewMetrics) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self,
            !self.terminating,
            let api = self.scannerApi else {
        return
      }
      Task { @MainActor in
        try? await api.onPreviewMetrics(metrics: metrics)
      }
    }
  }

  private func emitBarcodes(_ barcodes: [PlatformBarcode]) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self,
            !self.terminating,
            let api = self.scannerApi else {
        return
      }
      Task { @MainActor in
        try? await api.onBarcodes(barcodes: barcodes)
      }
    }
  }

  private func emitAnalysisFrame(_ frame: PlatformAnalysisFrame) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self,
            !self.terminating,
            let api = self.scannerApi else {
        return
      }
      Task { @MainActor in
        try? await api.onAnalysisFrame(frame: frame)
      }
    }
  }

  private func incrementAnalyzedFrames() {
    frameLock.lock()
    analyzedFrames += 1
    frameLock.unlock()
  }

  private func ensureMechanism() throws -> IosCameraMechanism {
    if let mechanism = mechanism {
      return mechanism
    }
    guard scannerApi != nil else {
      throw PigeonError(
        code: "detached",
        message: "plugin is not attached to a Flutter engine",
        details: nil
      )
    }

    let configuration = scannerConfig
    let selectionBox = selectionBox
    let created = IosCameraMechanism(
      configuration: configuration,
      interfaceOrientation: IosCameraOrientation.current(),
      initialScanWindow: scanWindow,
      selectionProvider: { selectionBox.get() },
      onStateChanged: { [weak self] snapshot in
        self?.emitState(snapshot)
      },
      onPreviewMetrics: { [weak self] metrics in
        self?.emitPreviewMetrics(metrics)
      },
      onPreviewBuffer: { [weak self] buffer in
        self?.pushPreviewBuffer(buffer)
      },
      onBarcodes: { [weak self] barcodes in
        self?.emitBarcodes(barcodes)
      },
      onAnalysisFrame: { [weak self] frame in
        self?.emitAnalysisFrame(frame)
      },
      onFrameAnalyzed: { [weak self] in
        self?.incrementAnalyzedFrames()
      }
    )
    mechanism = created
    return created
  }

  private func ensureTexture() throws -> Int64 {
    textureLock.lock()
    let existing = previewTexture
    textureLock.unlock()
    if let existing = existing, existing.id != 0 {
      return existing.id
    }

    guard let registry = textureRegistry else {
      throw PigeonError(
        code: "detached",
        message: "plugin is not attached to a Flutter engine",
        details: nil
      )
    }
    let texture = IosPreviewTexture(registry: registry)
    let id = registry.register(texture)
    guard id != 0 else {
      throw PigeonError(
        code: "texture_failed",
        message: "the preview texture could not be registered",
        details: nil
      )
    }
    texture.attach(id: id)
    textureLock.lock()
    previewTexture = texture
    textureLock.unlock()
    return id
  }

  private func pushPreviewBuffer(_ buffer: CVPixelBuffer) {
    textureLock.lock()
    let texture = previewTexture
    textureLock.unlock()
    texture?.push(buffer)
  }

  private func releaseTexture() {
    textureLock.lock()
    let texture = previewTexture
    previewTexture = nil
    textureLock.unlock()
    guard let texture = texture else {
      return
    }
    let id = texture.id
    texture.invalidate()
    if id != 0 {
      textureRegistry?.unregisterTexture(id)
    }
  }

  private func pigeonError(_ error: Error) -> PigeonError {
    if let error = error as? PigeonError {
      return error
    }
    if let error = error as? IosCameraError {
      return PigeonError(
        code: error.code,
        message: error.message,
        details: nil
      )
    }
    return PigeonError(
      code: "camera_error",
      message: error.localizedDescription,
      details: nil
    )
  }
}

extension InstantBarcodeScannerPlugin: ScannerHostApi {
  func configure(config: PlatformScannerConfig) async throws {
    let current = mechanism
    mechanism = nil
    if let current = current {
      await current.dispose()
    }
    scannerConfig = config
    selectionBox.set(IosCameraSelection(
      facing: config.facing,
      lensType: config.lensType
    ))
    scanWindow = nil
    frameLock.lock()
    analyzedFrames = 0
    frameLock.unlock()
  }

  func getTextureId() async throws -> Int64 {
    return try await MainActor.run {
      try ensureTexture()
    }
  }

  func getCapabilities() async throws -> PlatformCapabilities {
    let selection = selectionBox.get()
    let resolved: IosResolvedCamera
    do {
      resolved = try IosCameraSelectionResolver.resolve(selection)
    } catch {
      throw pigeonError(error)
    }

    let device = resolved.device
    let maxWidth = max(1, Int(scannerConfig.targetWidth ?? 1280))
    let maxHeight = max(1, Int(scannerConfig.targetHeight ?? 720))
    let selectedFormat = IosCameraFormatSelection.select(
      for: device,
      maxWidth: maxWidth,
      maxHeight: maxHeight
    )
    let minZoom = 1.0
    let maxZoom = max(
      minZoom,
      Double(selectedFormat?.videoMaxZoomFactor
        ?? device.activeFormat.videoMaxZoomFactor)
    )
    return PlatformCapabilities(
      supportsPark: true,
      supportsTrueClose: true,
      supportsTorch: device.hasTorch && device.isTorchModeSupported(.on),
      supportsZoom: maxZoom > minZoom,
      minZoom: minZoom,
      maxZoom: maxZoom,
      cameraFacing: resolved.facing,
      cameraLensType: resolved.lensType,
      cameraId: device.uniqueID
    )
  }

  func getAnalyzedFrames() async throws -> Int64 {
    frameLock.lock()
    defer { frameLock.unlock() }
    return analyzedFrames
  }

  func driveTo(target: PlatformState) async throws -> PlatformSnapshot {
    if target != .closed {
      if isBackgrounded() {
        return backgroundSnapshot()
      }
      let granted = await permission.request()
      if !granted {
        return PlatformSnapshot(
          state: .failed,
          errorCode: "permission_denied",
          errorMessage: "camera permission was not granted"
        )
      }
      if isBackgrounded() {
        return backgroundSnapshot()
      }
    }

    let current = try ensureMechanism()
    return await current.driveTo(target)
  }

  func switchCamera(
    facing: PlatformCameraFacing,
    lensType: PlatformCameraLensType
  ) async throws -> PlatformSnapshot {
    if isBackgrounded() {
      return backgroundSnapshot()
    }
    let previous = selectionBox.get()
    selectionBox.set(IosCameraSelection(facing: facing, lensType: lensType))

    guard let current = mechanism else {
      return PlatformSnapshot(state: .closed, errorCode: nil, errorMessage: nil)
    }

    let granted = await permission.request()
    if !granted {
      selectionBox.set(previous)
      return PlatformSnapshot(
        state: .failed,
        errorCode: "permission_denied",
        errorMessage: "camera permission was not granted"
      )
    }
    if isBackgrounded() {
      selectionBox.set(previous)
      return backgroundSnapshot()
    }

    let snapshot = await current.switchCamera()
    if snapshot.errorCode != nil {
      selectionBox.set(previous)
    }
    return snapshot
  }

  func setTorch(enabled: Bool) async throws {
    guard let current = mechanism else {
      throw PigeonError(
        code: "not_running",
        message: "the scanner is not open",
        details: nil
      )
    }
    do {
      try await current.setTorch(enabled)
    } catch {
      throw pigeonError(error)
    }
  }

  func setZoom(ratio: Double) async throws {
    let current = try ensureMechanism()
    do {
      try await current.setZoom(ratio)
    } catch {
      throw pigeonError(error)
    }
  }

  func updateScanWindow(window: PlatformRect?) async throws {
    scanWindow = window
    mechanism?.setScanWindow(window)
  }

  func analyzeImage(path: String) async throws -> [PlatformBarcode] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
          !isDirectory.boolValue else {
      throw PigeonError(
        code: "invalid_image",
        message: "no image file at \(path)",
        details: nil
      )
    }

    let config = scannerConfig
    let image = await withCheckedContinuation {
      (continuation: CheckedContinuation<UIImage?, Never>) in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: IosBarcodeImage.image(
          path: path,
          inverted: config.invertImage
        ))
      }
    }
    guard let image = image else {
      throw PigeonError(
        code: "analyze_failed",
        message: "the image could not be decoded",
        details: nil
      )
    }

    let visionImage = VisionImage(image: image)
    visionImage.orientation = .up
    let scanner = IosBarcodeMapping.scanner(for: config.formats)
    do {
      return try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<[PlatformBarcode], Error>) in
        scanner.process(visionImage) { [scanner] barcodes, error in
          _ = scanner
          if let error = error {
            continuation.resume(throwing: PigeonError(
              code: "analyze_failed",
              message: error.localizedDescription,
              details: nil
            ))
            return
          }
          continuation.resume(returning: (barcodes ?? []).compactMap(
            IosBarcodeMapping.map
          ))
        }
      }
    } catch let error as PigeonError {
      throw error
    } catch {
      throw PigeonError(
        code: "analyze_failed",
        message: error.localizedDescription,
        details: nil
      )
    }
  }

  func dispose() async throws {
    permission.cancelPending()
    let current = mechanism
    mechanism = nil
    if let current = current {
      await current.dispose()
    }
  }
}

private final class IosCameraPermission {
  private let lock = NSLock()
  private var waiters: [CheckedContinuation<Bool, Never>] = []
  private var requesting = false
  private var generation = 0

  func request() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      return true
    case .notDetermined:
      break
    default:
      return false
    }

    return await withCheckedContinuation { continuation in
      lock.lock()
      waiters.append(continuation)
      let shouldRequest = !requesting
      requesting = true
      let requestGeneration = generation
      lock.unlock()

      if shouldRequest {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
          self?.complete(granted, generation: requestGeneration)
        }
      }
    }
  }

  func cancelPending() {
    lock.lock()
    let pending = waiters
    waiters.removeAll()
    requesting = false
    generation += 1
    lock.unlock()
    for waiter in pending {
      waiter.resume(returning: false)
    }
  }

  private func complete(_ granted: Bool, generation requestGeneration: Int) {
    lock.lock()
    guard generation == requestGeneration else {
      lock.unlock()
      return
    }
    let pending = waiters
    waiters.removeAll()
    requesting = false
    generation += 1
    lock.unlock()
    for waiter in pending {
      waiter.resume(returning: granted)
    }
  }
}
