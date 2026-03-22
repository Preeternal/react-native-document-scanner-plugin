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
      self.errorHandler("Document scanning is not supported on this device")
      return
    }

    DispatchQueue.main.async {
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

    self.startScan()
  }

  public func documentCameraViewController(
    _ controller: VNDocumentCameraViewController,
    didFinishWith scan: VNDocumentCameraScan
  ) {
    var processedResults: [[String: Any]] = []

    for pageNumber in 0 ..< scan.pageCount {
      let scannedImage: UIImage = scan.imageOfPage(at: pageNumber)

      guard let scannedDocumentImage: Data = scannedImage
        .jpegData(compressionQuality: CGFloat(self.croppedImageQuality) / CGFloat(100)) else {
        goBackToPreviousView(controller)
        self.errorHandler("Unable to get scanned document in jpeg format")
        return
      }

      let imageIdentifier: String
      switch responseType {
      case ResponseType.base64:
        imageIdentifier = scannedDocumentImage.base64EncodedString()
      case ResponseType.imageFilePath:
        do {
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

      processedResults.append([
        "image": imageIdentifier
      ])
    }

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
    goBackToPreviousView(controller)
    self.errorHandler(error.localizedDescription)
  }

  private func goBackToPreviousView(_ controller: VNDocumentCameraViewController) {
    DispatchQueue.main.async {
      controller.dismiss(animated: true)
    }
  }
}
