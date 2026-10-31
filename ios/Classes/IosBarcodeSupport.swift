import CoreImage
import Flutter
import Foundation
import MLKitBarcodeScanning
import UIKit

enum IosBarcodeMapping {
  static func options(for formats: [PlatformBarcodeFormat]) -> BarcodeScannerOptions? {
    var supported: BarcodeFormat = []
    for format in formats {
      if let mapped = barcodeFormat(format) {
        supported.formUnion(mapped)
      }
    }
    guard !supported.isEmpty else {
      return nil
    }
    return BarcodeScannerOptions(formats: supported)
  }

  static func scanner(for formats: [PlatformBarcodeFormat]) -> BarcodeScanner {
    if let options = options(for: formats) {
      return BarcodeScanner.barcodeScanner(options: options)
    }
    return BarcodeScanner.barcodeScanner()
  }

  static func map(_ barcode: Barcode) -> PlatformBarcode? {
    let rawData = barcode.rawData
    let text = barcode.rawValue
    guard rawData != nil || text != nil else {
      return nil
    }
    let frame = barcode.frame
    let corners = barcode.cornerPoints?.map { value in
      let point = value.cgPointValue
      return PlatformPoint(x: Double(point.x), y: Double(point.y))
    }
    return PlatformBarcode(
      format: mapFormat(barcode.format),
      rawBytes: rawData.map { FlutterStandardTypedData(bytes: $0) },
      text: text,
      displayValue: barcode.displayValue,
      valueType: mapValueType(barcode.valueType),
      boundingBox: PlatformRect(
        left: Double(frame.minX),
        top: Double(frame.minY),
        right: Double(frame.maxX),
        bottom: Double(frame.maxY)
      ),
      corners: corners
    )
  }

  private static func barcodeFormat(_ format: PlatformBarcodeFormat) -> BarcodeFormat? {
    switch format {
    case .aztec:
      return .aztec
    case .codabar:
      return .codaBar
    case .code39:
      return .code39
    case .code93:
      return .code93
    case .code128:
      return .code128
    case .dataMatrix:
      return .dataMatrix
    case .ean8:
      return .EAN8
    case .ean13:
      return .EAN13
    case .itf:
      return .ITF
    case .pdf417:
      return .PDF417
    case .qrCode:
      return .qrCode
    case .upcA:
      return .UPCA
    case .upcE:
      return .UPCE
    case .unknown:
      return nil
    }
  }

  private static func mapFormat(_ format: BarcodeFormat) -> PlatformBarcodeFormat {
    if format == .aztec {
      return .aztec
    }
    if format == .codaBar {
      return .codabar
    }
    if format == .code39 {
      return .code39
    }
    if format == .code93 {
      return .code93
    }
    if format == .code128 {
      return .code128
    }
    if format == .dataMatrix {
      return .dataMatrix
    }
    if format == .EAN8 {
      return .ean8
    }
    if format == .EAN13 {
      return .ean13
    }
    if format == .ITF {
      return .itf
    }
    if format == .PDF417 {
      return .pdf417
    }
    if format == .qrCode {
      return .qrCode
    }
    if format == .UPCA {
      return .upcA
    }
    if format == .UPCE {
      return .upcE
    }
    return .unknown
  }

  private static func mapValueType(_ valueType: BarcodeValueType) -> PlatformBarcodeValueType {
    switch valueType {
    case .contactInfo:
      return .contactInfo
    case .email:
      return .email
    case .ISBN:
      return .isbn
    case .phone:
      return .phone
    case .product:
      return .product
    case .SMS:
      return .sms
    case .text:
      return .text
    case .URL:
      return .url
    case .wiFi:
      return .wifi
    case .geographicCoordinates:
      return .geo
    case .calendarEvent:
      return .calendarEvent
    case .driversLicense:
      return .driverLicense
    default:
      return .unknown
    }
  }
}

enum IosBarcodeImage {
  private static let context = CIContext()

  static func image(path: String, inverted: Bool) -> UIImage? {
    let url = URL(fileURLWithPath: path)
    guard let source = CIImage(
      contentsOf: url,
      options: [.applyOrientationProperty: true]
    ) else {
      return nil
    }
    let output = inverted ? source.applyingFilter("CIColorInvert") : source
    return render(output)
  }

  /// Inverts a live capture buffer.
  ///
  /// ML Kit cannot read modified YUV bytes directly, so this renders the
  /// frame through Core Image into a `UIImage` before every decode. That is a
  /// full-frame color conversion per analyzed frame on top of the decode
  /// itself; only enable `invertImage` when white-on-black symbols require it.
  static func invertedLiveImage(from buffer: CVPixelBuffer) -> UIImage? {
    let source = CIImage(cvPixelBuffer: buffer)
    return render(source.applyingFilter("CIColorInvert"))
  }

  private static func render(_ image: CIImage) -> UIImage? {
    let extent = image.extent
    guard !extent.isInfinite, !extent.isEmpty else {
      return nil
    }
    guard let cgImage = context.createCGImage(image, from: extent) else {
      return nil
    }
    return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
  }
}
