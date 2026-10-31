import AVFoundation
import CoreMedia
import CoreVideo
import UIKit

struct IosCameraSelection {
  let facing: PlatformCameraFacing
  let lensType: PlatformCameraLensType
}

struct IosResolvedCamera {
  let device: AVCaptureDevice
  let facing: PlatformCameraFacing
  let lensType: PlatformCameraLensType
}

struct IosCameraError: Error {
  let code: String
  let message: String
}

final class IosCameraSelectionBox {
  private let lock = NSLock()
  private var selection: IosCameraSelection

  init(_ selection: IosCameraSelection) {
    self.selection = selection
  }

  func get() -> IosCameraSelection {
    lock.lock()
    defer { lock.unlock() }
    return selection
  }

  func set(_ selection: IosCameraSelection) {
    lock.lock()
    self.selection = selection
    lock.unlock()
  }
}

enum IosCameraSelectionResolver {
  private static var physicalDeviceTypes: [AVCaptureDevice.DeviceType] {
    var types: [AVCaptureDevice.DeviceType] = [
      .builtInWideAngleCamera,
      .builtInUltraWideCamera,
      .builtInTelephotoCamera,
    ]
    if #available(iOS 17.0, *) {
      types.append(.external)
    }
    return types
  }

  static func resolve(_ selection: IosCameraSelection) throws -> IosResolvedCamera {
    var candidates = devices(for: selection.facing)
    if candidates.isEmpty {
      candidates = devices(for: .back)
    }
    if candidates.isEmpty {
      candidates = allDevices()
    }
    guard !candidates.isEmpty else {
      throw IosCameraError(
        code: "camera_unavailable",
        message: "no camera is available"
      )
    }

    let resolved = choose(candidates, selection)
    return IosResolvedCamera(
      device: resolved.device,
      facing: facing(for: resolved.device),
      lensType: resolved.lensType
    )
  }

  private static func devices(for facing: PlatformCameraFacing) -> [AVCaptureDevice] {
    if facing == .external {
      if #available(iOS 17.0, *) {
        return AVCaptureDevice.DiscoverySession(
          deviceTypes: [.external],
          mediaType: .video,
          position: .unspecified
        ).devices
      }
      return []
    }

    let position: AVCaptureDevice.Position = facing == .front ? .front : .back
    return AVCaptureDevice.DiscoverySession(
      deviceTypes: physicalDeviceTypes,
      mediaType: .video,
      position: position
    ).devices.filter { $0.position == position }
  }

  private static func allDevices() -> [AVCaptureDevice] {
    return AVCaptureDevice.DiscoverySession(
      deviceTypes: physicalDeviceTypes,
      mediaType: .video,
      position: .unspecified
    ).devices
  }

  private static func choose(
    _ candidates: [AVCaptureDevice],
    _ selection: IosCameraSelection
  ) -> (device: AVCaptureDevice, lensType: PlatformCameraLensType) {
    let wide = candidates.first { $0.deviceType == .builtInWideAngleCamera }
    if selection.lensType == .any || candidates.count == 1 {
      return (wide ?? candidates[0], .any)
    }

    var desired: AVCaptureDevice.DeviceType?
    switch selection.lensType {
    case .normal:
      desired = .builtInWideAngleCamera
    case .wide:
      desired = .builtInUltraWideCamera
    case .zoom:
      desired = .builtInTelephotoCamera
    case .any:
      desired = nil
    }

    let chosen = desired.flatMap { type in
      candidates.first { $0.deviceType == type }
    } ?? wide ?? candidates[0]
    return (chosen, lensType(for: chosen.deviceType) ?? .any)
  }

  private static func facing(for device: AVCaptureDevice) -> PlatformCameraFacing {
    switch device.position {
    case .back:
      return .back
    case .front:
      return .front
    case .unspecified:
      if #available(iOS 17.0, *), device.deviceType == .external {
        return .external
      }
      return .back
    @unknown default:
      return .back
    }
  }

  private static func lensType(for type: AVCaptureDevice.DeviceType) -> PlatformCameraLensType? {
    switch type {
    case .builtInWideAngleCamera:
      return .normal
    case .builtInUltraWideCamera:
      return .wide
    case .builtInTelephotoCamera:
      return .zoom
    default:
      return nil
    }
  }
}

enum IosCameraFormatSelection {
  static func select(
    for device: AVCaptureDevice,
    maxWidth: Int,
    maxHeight: Int
  ) -> AVCaptureDevice.Format? {
    let candidates = device.formats.filter {
      !$0.videoSupportedFrameRateRanges.isEmpty
    }
    guard !candidates.isEmpty else {
      return nil
    }

    let withinBudget = candidates.filter { format in
      let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      return Int(dimensions.width) <= maxWidth && Int(dimensions.height) <= maxHeight
    }
    guard !withinBudget.isEmpty else {
      return candidates.min {
        area($0) < area($1)
      }
    }

    let videoRange = withinBudget.filter { format in
      CMFormatDescriptionGetMediaSubType(format.formatDescription)
        == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }
    let pool = videoRange.isEmpty ? withinBudget : videoRange
    return pool.max { area($0) < area($1) }
  }

  private static func area(_ format: AVCaptureDevice.Format) -> Int64 {
    let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    return Int64(dimensions.width) * Int64(dimensions.height)
  }
}

enum IosCameraOrientation {
  static func current() -> UIInterfaceOrientation {
    if Thread.isMainThread {
      return currentOnMainThread()
    }
    return DispatchQueue.main.sync {
      currentOnMainThread()
    }
  }

  private static func currentOnMainThread() -> UIInterfaceOrientation {
    let scenes = UIApplication.shared.connectedScenes.compactMap {
      $0 as? UIWindowScene
    }
    if let active = scenes.first(where: {
      $0.activationState == .foregroundActive
    }) {
      return active.interfaceOrientation
    }
    return scenes.first?.interfaceOrientation ?? .portrait
  }

  static func rotationAngle(for orientation: UIInterfaceOrientation) -> CGFloat {
    switch orientation {
    case .portrait:
      return 90
    case .portraitUpsideDown:
      return 270
    case .landscapeLeft:
      return 180
    case .landscapeRight:
      return 0
    @unknown default:
      return 90
    }
  }

  static func videoOrientation(
    for orientation: UIInterfaceOrientation
  ) -> AVCaptureVideoOrientation {
    switch orientation {
    case .portrait:
      return .portrait
    case .portraitUpsideDown:
      return .portraitUpsideDown
    case .landscapeLeft:
      return .landscapeLeft
    case .landscapeRight:
      return .landscapeRight
    @unknown default:
      return .portrait
    }
  }

  static func uprightDimensions(
    _ dimensions: CMVideoDimensions,
    rotation: CGFloat
  ) -> (width: Int, height: Int) {
    let normalized = (Int(rotation.rounded()) % 360 + 360) % 360
    if normalized == 90 || normalized == 270 {
      return (Int(dimensions.height), Int(dimensions.width))
    }
    return (Int(dimensions.width), Int(dimensions.height))
  }
}
