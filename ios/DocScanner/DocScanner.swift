import UIKit
import VisionKit

/**
 This class uses VisionKit to start a document scan. It returns scanned images in base64 or file-path format
 and can optionally attach barcode extraction results for each scanned page.
 */
@available(iOS 13.0, *)
public class DocScanner: NSObject, VNDocumentCameraViewControllerDelegate {

  private var viewController: UIViewController?
  private var successHandler: ([[String: Any]]) -> Void
  private var errorHandler: (String) -> Void
  private var cancelHandler: () -> Void
  private var responseType: String
  private var croppedImageQuality: Int
  private var extractBarcodes: Bool
  private var barcodeFormats: [String]

  public init(
    _ viewController: UIViewController? = nil,
    successHandler: @escaping ([[String: Any]]) -> Void = { _ in },
    errorHandler: @escaping (String) -> Void = { _ in },
    cancelHandler: @escaping () -> Void = {},
    responseType: String = ResponseType.imageFilePath,
    croppedImageQuality: Int = 100,
    extractBarcodes: Bool = false,
    barcodeFormats: [String] = []
  ) {
    self.viewController = viewController
    self.successHandler = successHandler
    self.errorHandler = errorHandler
    self.cancelHandler = cancelHandler
    self.responseType = responseType
    self.croppedImageQuality = croppedImageQuality
    self.extractBarcodes = extractBarcodes
    self.barcodeFormats = barcodeFormats
  }

  public convenience override init() {
    self.init(nil)
  }

  public func startScan() {
    // Make sure the device supports document scanning.
    if !VNDocumentCameraViewController.isSupported {
      self.errorHandler("Document scanning is not supported on this device")
      return
    }

    DispatchQueue.main.async {
      // Launch the native document scanner UI.
      let documentCameraViewController = VNDocumentCameraViewController()
      documentCameraViewController.delegate = self
      self.viewController?.present(documentCameraViewController, animated: true)
    }
  }

  public func startScan(
    _ viewController: UIViewController? = nil,
    successHandler: @escaping ([[String: Any]]) -> Void = { _ in },
    errorHandler: @escaping (String) -> Void = { _ in },
    cancelHandler: @escaping () -> Void = {},
    responseType: String? = ResponseType.imageFilePath,
    croppedImageQuality: Int? = 100,
    extractBarcodes: Bool = false,
    barcodeFormats: [String] = []
  ) {
    self.viewController = viewController
    self.successHandler = successHandler
    self.errorHandler = errorHandler
    self.cancelHandler = cancelHandler
    self.responseType = responseType ?? ResponseType.imageFilePath
    self.croppedImageQuality = croppedImageQuality ?? 100
    self.extractBarcodes = extractBarcodes
    self.barcodeFormats = barcodeFormats

    self.startScan()
  }

  public func documentCameraViewController(
    _ controller: VNDocumentCameraViewController,
    didFinishWith scan: VNDocumentCameraScan
  ) {
    var processedResults: [[String: Any]] = []

    // Process every scanned page and produce a normalized page payload.
    for pageNumber in 0 ..< scan.pageCount {
      let scannedImage: UIImage = scan.imageOfPage(at: pageNumber)

      // Convert UIImage to JPEG data based on requested quality.
      guard let scannedDocumentImage: Data = scannedImage
        .jpegData(compressionQuality: CGFloat(self.croppedImageQuality) / CGFloat(100)) else {
        goBackToPreviousView(controller)
        self.errorHandler("Unable to get scanned document in jpeg format")
        return
      }

      let imageIdentifier: String
      switch responseType {
      case ResponseType.base64:
        // Return page as base64.
        imageIdentifier = scannedDocumentImage.base64EncodedString()
      case ResponseType.imageFilePath:
        do {
          // Persist page to disk and return file URI.
          let croppedImageFilePath = FileUtil().createImageFile(pageNumber)
          try scannedDocumentImage.write(to: croppedImageFilePath)
          imageIdentifier = croppedImageFilePath.absoluteString
        } catch {
          goBackToPreviousView(controller)
          self.errorHandler("Unable to save scanned image: \(error.localizedDescription)")
          return
        }
      default:
        goBackToPreviousView(controller)
        self.errorHandler("responseType must be base64 or imageFilePath")
        return
      }

      var pageResult: [String: Any] = [
        "image": imageIdentifier
      ]

      if extractBarcodes {
        // Barcode extraction is optional and controlled by compile-time feature flags.
        if BarcodeFeatureFlags.isEnabled {
          #if DOCUMENT_SCANNER_ENABLE_BARCODE
          let extracted = BarcodeExtractor.extractFromImage(
            scannedImage,
            allowedFormats: barcodeFormats
          )
          pageResult["barcodes"] = extracted.map {
            [
              "value": $0.value,
              "format": $0.format
            ]
          }
          #else
          pageResult["barcodes"] = []
          #endif
        } else {
          pageResult["barcodes"] = []
        }
      }

      processedResults.append(pageResult)
    }

    // Exit scanner UI and return payload.
    goBackToPreviousView(controller)
    self.successHandler(processedResults)
  }

  public func documentCameraViewControllerDidCancel(
    _ controller: VNDocumentCameraViewController
  ) {
    goBackToPreviousView(controller)
    self.cancelHandler()
  }

  public func documentCameraViewController(
    _ controller: VNDocumentCameraViewController,
    didFailWithError error: Error
  ) {
    // Exit scanner UI and return the native error message.
    goBackToPreviousView(controller)
    self.errorHandler(error.localizedDescription)
  }

  private func goBackToPreviousView(_ controller: VNDocumentCameraViewController) {
    // Return to the screen that initiated scanning.
    DispatchQueue.main.async {
      controller.dismiss(animated: true)
    }
  }
}
