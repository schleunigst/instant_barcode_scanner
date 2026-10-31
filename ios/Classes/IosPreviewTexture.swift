import CoreVideo
import Flutter
import Foundation

final class IosPreviewTexture: NSObject, FlutterTexture {
  private weak var registry: FlutterTextureRegistry?
  private let lock = NSLock()
  private var latestBuffer: CVPixelBuffer?
  private var currentId: Int64 = 0
  private var notificationPending = false
  private var invalidated = false

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
    super.init()
  }

  var id: Int64 {
    lock.lock()
    defer { lock.unlock() }
    return currentId
  }

  func attach(id: Int64) {
    lock.lock()
    currentId = id
    invalidated = false
    lock.unlock()
  }

  func push(_ buffer: CVPixelBuffer) {
    lock.lock()
    guard !invalidated, currentId != 0 else {
      lock.unlock()
      return
    }
    latestBuffer = buffer
    if notificationPending {
      lock.unlock()
      return
    }
    notificationPending = true
    let scheduledId = currentId
    lock.unlock()

    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        return
      }
      self.lock.lock()
      self.notificationPending = false
      let valid = !self.invalidated
      let currentId = self.currentId
      self.lock.unlock()

      guard valid, currentId == scheduledId, currentId != 0 else {
        return
      }
      self.registry?.textureFrameAvailable(currentId)
    }
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard !invalidated, let buffer = latestBuffer else {
      return nil
    }
    return Unmanaged<CVPixelBuffer>.passRetained(buffer)
  }

  func invalidate() {
    lock.lock()
    invalidated = true
    currentId = 0
    latestBuffer = nil
    notificationPending = false
    lock.unlock()
  }

  func onTextureUnregistered(_ texture: FlutterTexture) {
    invalidate()
  }
}
