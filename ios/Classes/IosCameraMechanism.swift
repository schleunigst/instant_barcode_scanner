import AVFoundation
import CoreMedia
import CoreVideo
import UIKit

final class IosCameraMechanism: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  private static let queueKey = DispatchSpecificKey<Void>()

  private let configuration: PlatformScannerConfig
  private let selectionProvider: () -> IosCameraSelection
  private let onStateChanged: (PlatformSnapshot) -> Void
  private let onPreviewMetrics: (PlatformPreviewMetrics) -> Void
  private let onPreviewBuffer: (CVPixelBuffer) -> Void
  private let analysis: IosBarcodeAnalysisPipeline

  private let sessionQueue = DispatchQueue(
    label: "dev.instantbarcode.ios-camera",
    qos: .userInitiated
  )
  private let videoQueue = DispatchQueue(
    label: "dev.instantbarcode.ios-video",
    qos: .userInitiated
  )

  private var session: AVCaptureSession?
  private var input: AVCaptureDeviceInput?
  private var output: AVCaptureVideoDataOutput?
  private var device: AVCaptureDevice?
  private var resolvedCamera: IosResolvedCamera?
  private var interfaceOrientation: UIInterfaceOrientation
  private var scanWindow: PlatformRect?
  private var sessionObservers: [NSObjectProtocol] = []
  private var deviceObserver: NSObjectProtocol?
  private var accepting = true
  private var disposed = false
  private var lastEmitted: PlatformSnapshot?
  private var lastPreviewMetrics: PlatformPreviewMetrics?
  private var torchEnabled: Bool
  private var zoomMin: CGFloat = 1
  private var zoomMax: CGFloat = 1
  private var pendingZoomRatio: CGFloat?
  private var resetZoomOnOpen = false

  init(
    configuration: PlatformScannerConfig,
    interfaceOrientation: UIInterfaceOrientation,
    initialScanWindow: PlatformRect?,
    selectionProvider: @escaping () -> IosCameraSelection,
    onStateChanged: @escaping (PlatformSnapshot) -> Void,
    onPreviewMetrics: @escaping (PlatformPreviewMetrics) -> Void,
    onPreviewBuffer: @escaping (CVPixelBuffer) -> Void,
    onBarcodes: @escaping ([PlatformBarcode]) -> Void,
    onAnalysisFrame: @escaping (PlatformAnalysisFrame) -> Void,
    onFrameAnalyzed: @escaping () -> Void
  ) {
    self.configuration = configuration
    self.interfaceOrientation = interfaceOrientation
    self.scanWindow = initialScanWindow
    self.selectionProvider = selectionProvider
    self.onStateChanged = onStateChanged
    self.onPreviewMetrics = onPreviewMetrics
    self.onPreviewBuffer = onPreviewBuffer
    self.analysis = IosBarcodeAnalysisPipeline(
      formats: configuration.formats,
      detectionSpeed: configuration.detectionSpeed,
      detectionTimeoutMs: configuration.detectionTimeoutMs,
      initialScanWindow: initialScanWindow,
      invertImage: configuration.invertImage,
      onBarcodes: onBarcodes,
      onAnalysisFrame: onAnalysisFrame,
      onFrameAnalyzed: onFrameAnalyzed
    )
    self.torchEnabled = configuration.torchEnabled
    super.init()
    sessionQueue.setSpecific(key: Self.queueKey, value: Void())
  }

  deinit {
    let center = NotificationCenter.default
    for observer in sessionObservers {
      center.removeObserver(observer)
    }
    if let observer = deviceObserver {
      center.removeObserver(observer)
    }
  }

  func driveTo(_ target: PlatformState) async -> PlatformSnapshot {
    return await withCheckedContinuation { continuation in
      sessionQueue.async {
        guard self.accepting else {
          continuation.resume(returning: self.detachedSnapshot())
          return
        }
        continuation.resume(returning: self.convergeLocked(target))
      }
    }
  }

  func switchCamera() async -> PlatformSnapshot {
    return await withCheckedContinuation { continuation in
      sessionQueue.async {
        guard self.accepting else {
          continuation.resume(returning: self.detachedSnapshot())
          return
        }
        let restoreTarget = self.targetForState(self.currentStateLocked())
        self.closeLocked()
        self.torchEnabled = false
        self.pendingZoomRatio = nil
        self.resetZoomOnOpen = true
        continuation.resume(returning: self.convergeLocked(restoreTarget))
      }
    }
  }

  func setTorch(_ enabled: Bool) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      sessionQueue.async {
        guard self.accepting else {
          continuation.resume(throwing: IosCameraError(
            code: "disposed",
            message: "scanner has been disposed"
          ))
          return
        }
        if !enabled {
          self.torchEnabled = false
          if self.currentStateLocked() == .live {
            _ = self.setTorchLocked(false)
          }
          continuation.resume()
          return
        }
        guard let device = self.device else {
          continuation.resume(throwing: IosCameraError(
            code: "not_running",
            message: "the scanner is not open"
          ))
          return
        }
        guard device.hasTorch, device.isTorchModeSupported(.on) else {
          continuation.resume(throwing: IosCameraError(
            code: "unsupported",
            message: "the torch is not available"
          ))
          return
        }
        if self.currentStateLocked() == .live {
          if !device.isTorchAvailable {
            continuation.resume(throwing: IosCameraError(
              code: "unsupported",
              message: "the torch is not available"
            ))
            return
          }
          guard self.setTorchLocked(true) else {
            continuation.resume(throwing: IosCameraError(
              code: "torch_failed",
              message: "the torch command failed"
            ))
            return
          }
        }
        self.torchEnabled = true
        continuation.resume()
      }
    }
  }

  func setZoom(_ ratio: Double) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      sessionQueue.async {
        guard self.accepting else {
          continuation.resume(throwing: IosCameraError(
            code: "disposed",
            message: "scanner has been disposed"
          ))
          return
        }

        let requested = CGFloat(ratio)
        self.pendingZoomRatio = requested
        guard let device = self.device else {
          continuation.resume()
          return
        }

        let clamped = min(max(requested, self.zoomMin), self.zoomMax)
        do {
          try device.lockForConfiguration()
        } catch {
          continuation.resume(throwing: IosCameraError(
            code: "zoom_failed",
            message: "the camera could not be configured"
          ))
          return
        }
        device.videoZoomFactor = clamped
        device.unlockForConfiguration()
        self.pendingZoomRatio = clamped
        continuation.resume()
      }
    }
  }

  func setScanWindow(_ window: PlatformRect?) {
    sessionQueue.async {
      self.scanWindow = window
      self.analysis.setScanWindow(window)
    }
  }

  func updateOrientation(_ orientation: UIInterfaceOrientation) {
    sessionQueue.async {
      guard self.accepting else {
        return
      }
      self.interfaceOrientation = orientation
      guard self.output != nil,
            let connection = self.output?.connection(with: .video) else {
        return
      }
      self.configureConnectionLocked(connection)
      self.publishPreviewMetricsLocked()
    }
  }

  func dispose() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      sessionQueue.async {
        self.accepting = false
        self.shutdownLocked()
        continuation.resume()
      }
    }
  }

  func shutdownSynchronously() {
    let work: () -> Void = {
      self.accepting = false
      self.shutdownLocked()
    }
    if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
      work()
    } else {
      sessionQueue.sync(execute: work)
    }
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      return
    }
    onPreviewBuffer(buffer)
    analysis.submit(sampleBuffer)
  }

  private func convergeLocked(_ target: PlatformState) -> PlatformSnapshot {
    switch target {
    case .closed, .open, .parked, .live:
      break
    default:
      return PlatformSnapshot(
        state: currentStateLocked(),
        errorCode: "invalid_target",
        errorMessage: "cannot drive to \(target)"
      )
    }

    if target == .closed {
      if session != nil || device != nil || input != nil {
        emitChangedLocked(PlatformSnapshot(
          state: .closing,
          errorCode: nil,
          errorMessage: nil
        ))
      }
      closeLocked()
      return finishLocked(PlatformSnapshot(
        state: currentStateLocked(),
        errorCode: nil,
        errorMessage: nil
      ))
    }

    if session == nil || device == nil {
      emitChangedLocked(PlatformSnapshot(
        state: .opening,
        errorCode: nil,
        errorMessage: nil
      ))
      do {
        try openDeviceLocked()
      } catch let error as IosCameraError {
        return abortLocked(error.code, error.message)
      } catch {
        return abortLocked("open_failed", error.localizedDescription)
      }
    }

    do {
      switch target {
      case .open:
        try ensureOutputLocked(required: false)
        stopLocked()
      case .parked:
        try ensureOutputLocked(required: true)
        stopLocked()
      case .live:
        try ensureOutputLocked(required: true)
        try startLocked()
      default:
        break
      }
    } catch let error as IosCameraError {
      return abortLocked(error.code, error.message)
    } catch {
      return abortLocked("camera_failed", error.localizedDescription)
    }

    return finishLocked(PlatformSnapshot(
      state: currentStateLocked(),
      errorCode: nil,
      errorMessage: nil
    ))
  }

  private func openDeviceLocked() throws {
    let resolved = try IosCameraSelectionResolver.resolve(selectionProvider())
    try configureDeviceLocked(resolved.device)

    let deviceInput: AVCaptureDeviceInput
    do {
      deviceInput = try AVCaptureDeviceInput(device: resolved.device)
    } catch {
      throw IosCameraError(
        code: "open_failed",
        message: "camera input could not be created"
      )
    }

    let captureSession = AVCaptureSession()
    captureSession.beginConfiguration()
    captureSession.sessionPreset = .inputPriority
    guard captureSession.canAddInput(deviceInput) else {
      captureSession.commitConfiguration()
      throw IosCameraError(
        code: "open_failed",
        message: "camera input is not available"
      )
    }
    captureSession.addInput(deviceInput)
    captureSession.commitConfiguration()

    session = captureSession
    input = deviceInput
    device = resolved.device
    resolvedCamera = resolved
    installObserversLocked(session: captureSession, device: resolved.device)
  }

  private func configureDeviceLocked(_ device: AVCaptureDevice) throws {
    let maxWidth = max(1, Int(configuration.targetWidth ?? 1280))
    let maxHeight = max(1, Int(configuration.targetHeight ?? 720))
    let selectedFormat = IosCameraFormatSelection.select(
      for: device,
      maxWidth: maxWidth,
      maxHeight: maxHeight
    )

    do {
      try device.lockForConfiguration()
    } catch {
      throw IosCameraError(
        code: "configure_failed",
        message: "the camera could not be configured"
      )
    }
    defer { device.unlockForConfiguration() }

    if let selectedFormat = selectedFormat {
      device.activeFormat = selectedFormat
    }

    zoomMin = device.minAvailableVideoZoomFactor
    zoomMax = device.maxAvailableVideoZoomFactor

    let targetZoom: CGFloat?
    if resetZoomOnOpen {
      targetZoom = zoomMin
    } else if let pendingZoomRatio = pendingZoomRatio {
      targetZoom = pendingZoomRatio
    } else if let initialZoom = configuration.initialZoom {
      let fraction = CGFloat(min(max(initialZoom, 0), 1))
      targetZoom = zoomMin + fraction * (zoomMax - zoomMin)
    } else {
      targetZoom = nil
    }

    if let targetZoom = targetZoom {
      let clamped = min(max(targetZoom, zoomMin), zoomMax)
      device.videoZoomFactor = clamped
      pendingZoomRatio = clamped
    }
    resetZoomOnOpen = false
  }

  private func ensureOutputLocked(required: Bool) throws {
    if required {
      if output == nil {
        try addOutputLocked()
      }
      return
    }
    if output != nil {
      removeOutputLocked()
    }
  }

  private func addOutputLocked() throws {
    guard let session = session else {
      throw IosCameraError(
        code: "configure_failed",
        message: "camera session is not open"
      )
    }

    let videoOutput = AVCaptureVideoDataOutput()
    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String:
        preferredPixelFormat(for: videoOutput)
    ]
    videoOutput.setSampleBufferDelegate(self, queue: videoQueue)

    session.beginConfiguration()
    guard session.canAddOutput(videoOutput) else {
      session.commitConfiguration()
      throw IosCameraError(
        code: "configure_failed",
        message: "camera output is not available"
      )
    }
    session.addOutput(videoOutput)
    session.commitConfiguration()

    if let connection = videoOutput.connection(with: .video) {
      configureConnectionLocked(connection)
    }
    output = videoOutput
    publishPreviewMetricsLocked()
  }

  private func removeOutputLocked() {
    guard let session = session, let videoOutput = output else {
      return
    }
    if session.isRunning {
      session.stopRunning()
    }
    videoOutput.setSampleBufferDelegate(nil, queue: nil)
    session.beginConfiguration()
    session.removeOutput(videoOutput)
    session.commitConfiguration()
    output = nil
  }

  private func preferredPixelFormat(
    for output: AVCaptureVideoDataOutput
  ) -> OSType {
    let available = output.availableVideoPixelFormatTypes
    let preferred: [OSType] = [
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      kCVPixelFormatType_32BGRA,
    ]
    for format in preferred where available.contains(format) {
      return format
    }
    return available.first ?? kCVPixelFormatType_32BGRA
  }

  private func configureConnectionLocked(_ connection: AVCaptureConnection) {
    if connection.isVideoMirroringSupported {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = false
    }

    let videoOrientation = IosCameraOrientation.videoOrientation(
      for: interfaceOrientation
    )
    if #available(iOS 17.0, *) {
      let angle = IosCameraOrientation.rotationAngle(for: interfaceOrientation)
      if connection.isVideoRotationAngleSupported(angle) {
        connection.videoRotationAngle = angle
        return
      }
    }
    if connection.isVideoOrientationSupported {
      connection.videoOrientation = videoOrientation
    }
  }

  private func publishPreviewMetricsLocked() {
    guard let device = device, output != nil else {
      return
    }
    let dimensions = CMVideoFormatDescriptionGetDimensions(
      device.activeFormat.formatDescription
    )
    let rotation = IosCameraOrientation.rotationAngle(for: interfaceOrientation)
    let upright = IosCameraOrientation.uprightDimensions(
      dimensions,
      rotation: rotation
    )
    analysis.updateAnalysisFrame(
      width: Int64(upright.width),
      height: Int64(upright.height)
    )
    let metrics = PlatformPreviewMetrics(
      width: Int64(upright.width),
      height: Int64(upright.height),
      rotationDegrees: 0,
      mirrored: resolvedCamera?.facing == .front
    )
    if metrics == lastPreviewMetrics {
      return
    }
    lastPreviewMetrics = metrics
    onPreviewMetrics(metrics)
  }

  private func startLocked() throws {
    guard let session = session else {
      throw IosCameraError(
        code: "start_failed",
        message: "camera session is not open"
      )
    }
    guard output != nil else {
      throw IosCameraError(
        code: "start_failed",
        message: "camera output is not configured"
      )
    }

    if !session.isRunning {
      session.startRunning()
      guard session.isRunning else {
        throw IosCameraError(
          code: "start_failed",
          message: "camera session did not start"
        )
      }
    }
    analysis.beginGeneration()
    applyTorchLocked()
  }

  private func stopLocked() {
    analysis.endGeneration()
    if session?.isRunning == true {
      session?.stopRunning()
    }
    setTorchLocked(false)
    torchEnabled = false
  }

  private func applyTorchLocked() {
    guard let device = device, device.hasTorch else {
      torchEnabled = false
      return
    }
    if torchEnabled && !device.isTorchAvailable {
      torchEnabled = false
    }
    if !setTorchLocked(torchEnabled) {
      torchEnabled = false
    }
  }

  @discardableResult
  private func setTorchLocked(_ enabled: Bool) -> Bool {
    guard let device = device,
          device.hasTorch,
          device.isTorchModeSupported(enabled ? .on : .off) else {
      return false
    }
    if enabled && !device.isTorchAvailable {
      return false
    }
    do {
      try device.lockForConfiguration()
    } catch {
      return false
    }
    device.torchMode = enabled ? .on : .off
    device.unlockForConfiguration()
    return true
  }

  private func installObserversLocked(
    session: AVCaptureSession,
    device: AVCaptureDevice
  ) {
    let center = NotificationCenter.default

    sessionObservers.append(center.addObserver(
      forName: NSNotification.Name.AVCaptureSessionRuntimeError,
      object: session,
      queue: nil
    ) { [weak self] notification in
      let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
      let message = error?.localizedDescription
        ?? "the capture session encountered a runtime error"
      self?.sessionQueue.async {
        self?.handleUnexpectedLossLocked(
          code: "runtime_error",
          message: message
        )
      }
    })

    sessionObservers.append(center.addObserver(
      forName: NSNotification.Name.AVCaptureSessionWasInterrupted,
      object: session,
      queue: nil
    ) { [weak self] notification in
      let reason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey]
        as? NSNumber
      let backgroundReason = AVCaptureSession.InterruptionReason
        .videoDeviceNotAvailableInBackground.rawValue
      if let reason = reason, reason.intValue == backgroundReason {
        return
      }
      let message = reason.map {
        "the capture session was interrupted (reason \($0.intValue))"
      } ?? "the capture session was interrupted"
      self?.sessionQueue.async {
        self?.handleUnexpectedLossLocked(
          code: "interrupted",
          message: message
        )
      }
    })

    deviceObserver = center.addObserver(
      forName: NSNotification.Name.AVCaptureDeviceWasDisconnected,
      object: device,
      queue: nil
    ) { [weak self] _ in
      self?.sessionQueue.async {
        self?.handleUnexpectedLossLocked(
          code: "disconnected",
          message: "the camera device was disconnected"
        )
      }
    }
  }

  private func removeObserversLocked() {
    let center = NotificationCenter.default
    for observer in sessionObservers {
      center.removeObserver(observer)
    }
    sessionObservers.removeAll()
    if let observer = deviceObserver {
      center.removeObserver(observer)
      deviceObserver = nil
    }
  }

  private func handleUnexpectedLossLocked(code: String, message: String) {
    guard accepting, !disposed, session != nil else {
      return
    }
    closeLocked()
    _ = finishLocked(PlatformSnapshot(
      state: currentStateLocked(),
      errorCode: code,
      errorMessage: message
    ))
  }

  private func closeLocked() {
    analysis.endGeneration()
    removeObserversLocked()

    if session?.isRunning == true {
      session?.stopRunning()
    }
    setTorchLocked(false)
    torchEnabled = false

    if let session = session {
      session.beginConfiguration()
      if let videoOutput = output {
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
        session.removeOutput(videoOutput)
      }
      if let deviceInput = input {
        session.removeInput(deviceInput)
      }
      session.commitConfiguration()
    }

    session = nil
    input = nil
    output = nil
    device = nil
    resolvedCamera = nil
    zoomMin = 1
    zoomMax = 1
  }

  private func shutdownLocked() {
    guard !disposed else {
      return
    }
    disposed = true
    closeLocked()
    analysis.shutdown()
    _ = finishLocked(PlatformSnapshot(
      state: .closed,
      errorCode: nil,
      errorMessage: nil
    ))
  }

  private func currentStateLocked() -> PlatformState {
    guard let session = session, input != nil else {
      return .closed
    }
    guard output != nil else {
      return .open
    }
    return session.isRunning ? .live : .parked
  }

  private func targetForState(_ state: PlatformState) -> PlatformState {
    switch state {
    case .live:
      return .live
    case .parked:
      return .parked
    case .open:
      return .open
    default:
      return .closed
    }
  }

  private func detachedSnapshot() -> PlatformSnapshot {
    return PlatformSnapshot(
      state: .failed,
      errorCode: "disposed",
      errorMessage: "scanner has been disposed"
    )
  }

  private func abortLocked(_ code: String, _ message: String) -> PlatformSnapshot {
    closeLocked()
    return finishLocked(PlatformSnapshot(
      state: currentStateLocked(),
      errorCode: code,
      errorMessage: message
    ))
  }

  private func finishLocked(_ snapshot: PlatformSnapshot) -> PlatformSnapshot {
    emitChangedLocked(snapshot)
    return snapshot
  }

  private func emitChangedLocked(_ snapshot: PlatformSnapshot) {
    if let last = lastEmitted,
       last.state == snapshot.state,
       last.errorCode == snapshot.errorCode {
      return
    }
    lastEmitted = snapshot
    onStateChanged(snapshot)
  }
}
