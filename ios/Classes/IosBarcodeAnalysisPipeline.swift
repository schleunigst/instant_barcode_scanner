import CoreVideo
import Foundation
import MLKitBarcodeScanning
import MLKitVision
import UIKit

final class IosBarcodeAnalysisPipeline {
  private let formats: [PlatformBarcodeFormat]
  private let detectionSpeed: PlatformDetectionSpeed
  private let detectionTimeoutMs: UInt64
  private let invertImage: Bool
  private let onBarcodes: ([PlatformBarcode]) -> Void
  private let onAnalysisFrame: (PlatformAnalysisFrame) -> Void
  private let onFrameAnalyzed: () -> Void

  private let lock = NSLock()
  private let queue = DispatchQueue(
    label: "dev.instantbarcode.ios-analysis",
    qos: .userInitiated
  )

  private var scanner: BarcodeScanner?
  private var live = false
  private var disposed = false
  private var busy = false
  private var generation: Int64 = 0
  private var lastAnalysisAt: UInt64 = 0
  private var lastRawValues: [String?]?
  private var scanWindow: PlatformRect?
  private var analysisFrame = PlatformAnalysisFrame(
    width: 0,
    height: 0,
    rotationDegrees: 0
  )

  init(
    formats: [PlatformBarcodeFormat],
    detectionSpeed: PlatformDetectionSpeed,
    detectionTimeoutMs: Int64,
    initialScanWindow: PlatformRect?,
    invertImage: Bool,
    onBarcodes: @escaping ([PlatformBarcode]) -> Void,
    onAnalysisFrame: @escaping (PlatformAnalysisFrame) -> Void,
    onFrameAnalyzed: @escaping () -> Void
  ) {
    self.formats = formats
    self.detectionSpeed = detectionSpeed
    self.detectionTimeoutMs = UInt64(max(0, detectionTimeoutMs))
    self.scanWindow = initialScanWindow
    self.invertImage = invertImage
    self.onBarcodes = onBarcodes
    self.onAnalysisFrame = onAnalysisFrame
    self.onFrameAnalyzed = onFrameAnalyzed
  }

  func setScanWindow(_ window: PlatformRect?) {
    lock.lock()
    scanWindow = window
    lock.unlock()
  }

  func updateAnalysisFrame(width: Int64, height: Int64) {
    guard width > 0, height > 0 else {
      return
    }
    let frame = PlatformAnalysisFrame(
      width: width,
      height: height,
      rotationDegrees: 0
    )
    lock.lock()
    guard analysisFrame != frame else {
      lock.unlock()
      return
    }
    analysisFrame = frame
    if live {
      generation += 1
    }
    lock.unlock()
    onAnalysisFrame(frame)
  }

  func beginGeneration() {
    lock.lock()
    live = true
    generation += 1
    lastAnalysisAt = 0
    lastRawValues = nil
    let frame = analysisFrame
    lock.unlock()
    if frame.width > 0 && frame.height > 0 {
      onAnalysisFrame(frame)
    }
  }

  func endGeneration() {
    lock.lock()
    live = false
    lock.unlock()
  }

  func shutdown() {
    lock.lock()
    disposed = true
    live = false
    busy = false
    scanner = nil
    lock.unlock()
  }

  func submit(_ sampleBuffer: CMSampleBuffer) {
    let now = DispatchTime.now().uptimeNanoseconds / 1_000_000
    lock.lock()
    guard !disposed, live else {
      lock.unlock()
      return
    }
    if detectionSpeed == .normal {
      let elapsed = now >= lastAnalysisAt ? now - lastAnalysisAt : UInt64.max
      guard elapsed >= detectionTimeoutMs else {
        lock.unlock()
        return
      }
    }
    guard !busy else {
      lock.unlock()
      return
    }
    busy = true
    if detectionSpeed == .normal {
      lastAnalysisAt = now
    }
    let frameGeneration = generation
    lock.unlock()

    queue.async { [weak self] in
      self?.process(sampleBuffer, generation: frameGeneration)
    }
  }

  private func process(_ sampleBuffer: CMSampleBuffer, generation: Int64) {
    guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
          isCurrent(generation) else {
      finish(nil, error: nil, generation: generation)
      return
    }

    let image: VisionImage
    if invertImage {
      // Documented cost: every analyzed frame is rendered through Core Image
      // into a UIImage because ML Kit cannot consume transformed YUV bytes.
      // Inversion therefore adds a full-frame conversion per decoded frame;
      // leave it off unless the symbols are white-on-black.
      guard let inverted = IosBarcodeImage.invertedLiveImage(from: buffer) else {
        finish(nil, error: nil, generation: generation)
        return
      }
      image = VisionImage(image: inverted)
    } else {
      image = VisionImage(buffer: sampleBuffer)
    }
    image.orientation = .up

    guard isCurrent(generation) else {
      finish(nil, error: nil, generation: generation)
      return
    }

    onFrameAnalyzed()
    scannerInstance().process(image) { [weak self] barcodes, error in
      self?.finish(barcodes, error: error, generation: generation)
    }
  }

  private func isCurrent(_ generation: Int64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return !disposed && live && generation == self.generation
  }

  private func scannerInstance() -> BarcodeScanner {
    lock.lock()
    if let scanner = scanner {
      lock.unlock()
      return scanner
    }
    let created = IosBarcodeMapping.scanner(for: formats)
    scanner = created
    lock.unlock()
    return created
  }

  private func finish(
    _ barcodes: [Barcode]?,
    error: Error?,
    generation: Int64
  ) {
    var deliver: [PlatformBarcode]?
    lock.lock()
    if !disposed, live, generation == self.generation, error == nil {
      let results = barcodes ?? []
      var deliverResults = true
      if detectionSpeed == .noDuplicates {
        let values = results.compactMap { $0.rawValue }.sorted()
        if values == lastRawValues {
          deliverResults = false
        } else if !values.isEmpty {
          lastRawValues = values
        }
      }
      if deliverResults {
        let mapped = results.compactMap(IosBarcodeMapping.map)
        let frame = analysisFrame
        if let window = scanWindow {
          let visible = mapped.filter {
            isInside($0, window: window, frame: frame)
          }
          if !visible.isEmpty {
            deliver = visible
          }
        } else if !mapped.isEmpty {
          deliver = mapped
        }
      }
    }
    busy = false
    let shouldDeliver = deliver != nil && live && !disposed
    lock.unlock()
    if shouldDeliver, let deliver = deliver {
      onBarcodes(deliver)
    }
  }

  private func isInside(
    _ barcode: PlatformBarcode,
    window: PlatformRect,
    frame: PlatformAnalysisFrame
  ) -> Bool {
    guard frame.width > 0, frame.height > 0 else {
      return false
    }
    let width = Double(frame.width)
    let height = Double(frame.height)
    let left = window.left * width
    let top = window.top * height
    let right = window.right * width
    let bottom = window.bottom * height

    if let corners = barcode.corners, !corners.isEmpty {
      return corners.allSatisfy {
        $0.x >= left && $0.x <= right && $0.y >= top && $0.y <= bottom
      }
    }
    guard let box = barcode.boundingBox else {
      return false
    }
    return box.left >= left && box.top >= top
      && box.right <= right && box.bottom <= bottom
  }
}
