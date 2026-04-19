import UIKit
import VisionKit

/**
 This class uses VisionKit to start a document scan and returns scanned images
 in base64 or file-path format.
 */
@available(iOS 13.0, *)
public class DocScanner: NSObject, VNDocumentCameraViewControllerDelegate {

  private var viewController: UIViewController?
  private var successHandler: ([[String: Any]]) -> Void
  private var errorHandler: (String) -> Void
  private var cancelHandler: () -> Void
  private var responseType: String
  private var croppedImageQuality: Int

  private func log(_ message: @autoclosure () -> String) {
    DocScannerDebugLog.log("DocScanner", message())
  }

  public init(
    _ viewController: UIViewController? = nil,
    successHandler: @escaping ([[String: Any]]) -> Void = { _ in },
    errorHandler: @escaping (String) -> Void = { _ in },
    cancelHandler: @escaping () -> Void = {},
    responseType: String = ResponseType.imageFilePath,
    croppedImageQuality: Int = 100
  ) {
    self.viewController = viewController
    self.successHandler = successHandler
    self.errorHandler = errorHandler
    self.cancelHandler = cancelHandler
    self.responseType = responseType
    self.croppedImageQuality = croppedImageQuality
  }

  public convenience override init() {
    self.init(nil)
  }

  public func startScan() {
    if !VNDocumentCameraViewController.isSupported {
      log("startScan unsupported device")
      self.errorHandler("Document scanning is not supported on this device")
      return
    }

    DispatchQueue.main.async {
      self.log("startScan presenting camera")
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
    croppedImageQuality: Int? = 100
  ) {
    self.viewController = viewController
    self.successHandler = successHandler
    self.errorHandler = errorHandler
    self.cancelHandler = cancelHandler
    self.responseType = responseType ?? ResponseType.imageFilePath
    self.croppedImageQuality = croppedImageQuality ?? 100
    log(
      "configure responseType=\(self.responseType) croppedImageQuality=\(self.croppedImageQuality)"
    )

    self.startScan()
  }

  public func documentCameraViewController(
    _ controller: VNDocumentCameraViewController,
    didFinishWith scan: VNDocumentCameraScan
  ) {
    var processedResults: [[String: Any]] = []
    log(
      "didFinishWith pageCount=\(scan.pageCount) responseType=\(responseType) quality=\(croppedImageQuality)"
    )

    for pageNumber in 0 ..< scan.pageCount {
      let scannedImage: UIImage = scan.imageOfPage(at: pageNumber)
      log(
        "page[\(pageNumber)] source size=\(Int(scannedImage.size.width))x\(Int(scannedImage.size.height)) scale=\(scannedImage.scale)"
      )

      guard let scannedDocumentImage: Data = scannedImage
        .jpegData(compressionQuality: CGFloat(self.croppedImageQuality) / CGFloat(100)) else {
        goBackToPreviousView(controller)
        log("page[\(pageNumber)] jpeg encode failed")
        self.errorHandler("Unable to get scanned document in jpeg format")
        return
      }
      log("page[\(pageNumber)] jpeg bytes=\(scannedDocumentImage.count)")

      let imageIdentifier: String
      switch responseType {
      case ResponseType.base64:
        imageIdentifier = scannedDocumentImage.base64EncodedString()
        log("page[\(pageNumber)] encoded as base64 length=\(imageIdentifier.count)")
      case ResponseType.imageFilePath:
        do {
          let croppedImageFilePath = FileUtil().createImageFile(pageNumber)
          try scannedDocumentImage.write(to: croppedImageFilePath)
          imageIdentifier = croppedImageFilePath.absoluteString
          log("page[\(pageNumber)] saved file=\(croppedImageFilePath.lastPathComponent)")
        } catch {
          goBackToPreviousView(controller)
          log("page[\(pageNumber)] save failed error=\(error.localizedDescription)")
          self.errorHandler("Unable to save scanned image: \(error.localizedDescription)")
          return
        }
      default:
        goBackToPreviousView(controller)
        log("page[\(pageNumber)] invalid responseType=\(responseType)")
        self.errorHandler("responseType must be base64 or imageFilePath")
        return
      }

      processedResults.append([
        "image": imageIdentifier
      ])
    }

    goBackToPreviousView(controller)
    log("didFinishWith resolved pages=\(processedResults.count)")
    self.successHandler(processedResults)
  }

  public func documentCameraViewControllerDidCancel(
    _ controller: VNDocumentCameraViewController
  ) {
    goBackToPreviousView(controller)
    log("documentCameraViewControllerDidCancel")
    self.cancelHandler()
  }

  public func documentCameraViewController(
    _ controller: VNDocumentCameraViewController,
    didFailWithError error: Error
  ) {
    goBackToPreviousView(controller)
    log("documentCameraViewController didFailWithError=\(error.localizedDescription)")
    self.errorHandler(error.localizedDescription)
  }

  private func goBackToPreviousView(_ controller: VNDocumentCameraViewController) {
    DispatchQueue.main.async {
      controller.dismiss(animated: true)
    }
  }
}
