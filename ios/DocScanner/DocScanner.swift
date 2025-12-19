import UIKit
import VisionKit
import Vision

/**
 This class uses VisonKit to start a document scan. It returns an array of objects containing URI, Barcode and Success status.
 */
@available(iOS 13.0, *)
public class DocScanner: NSObject, VNDocumentCameraViewControllerDelegate {
    
    /** @property viewController the document scanner gets called from this view controller */
    private var viewController: UIViewController?
    
    /** @property successHandler a callback triggered when the user completes the document scan successfully */
    // MUDANÇA: Retorna array de objetos (Dicionários) em vez de array de Strings
    private var successHandler: ([[String: Any]]) -> Void
    
    /** @property errorHandler a callback triggered when there's an error */
    private var errorHandler: (String) -> Void
    
    /** @property cancelHandler a callback triggered when the user cancels the document scan */
    private var cancelHandler: () -> Void
    
    /** @property responseType determines the format response (base64 or file paths) */
    private var responseType: String

    /** @property croppedImageQuality the 0 - 100 quality of the cropped image */
    private var croppedImageQuality: Int
    
    /**
     constructor for DocScanner
     */
    public init(
        _ viewController: UIViewController? = nil,
        // MUDANÇA NA ASSINATURA: [[String: Any]]
        successHandler: @escaping ([[String: Any]]) -> Void = {_ in },
        errorHandler: @escaping (String) -> Void = {_ in },
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
    
    /**
     opens the camera, and starts the document scan
     */
    public func startScan() {
        if (!VNDocumentCameraViewController.isSupported) {
            self.errorHandler("Document scanning is not supported on this device")
            return
        }
        
        DispatchQueue.main.async {
            let documentCameraViewController = VNDocumentCameraViewController()
            documentCameraViewController.delegate = self
            self.viewController?.present(documentCameraViewController, animated: true)
        }
    }
    
    /**
     opens the camera, and starts the document scan (Overload)
     */
    public func startScan(
        _ viewController: UIViewController? = nil,
        // MUDANÇA NA ASSINATURA: [[String: Any]]
        successHandler: @escaping ([[String: Any]]) -> Void = {_ in },
        errorHandler: @escaping (String) -> Void = {_ in },
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
    
    /**
     This gets called on document scan success.
     */
    public func documentCameraViewController(
        _ controller: VNDocumentCameraViewController,
        didFinishWith scan: VNDocumentCameraScan
    ) {
        // Array de objetos para retorno
        var processedResults: [[String: Any]] = []
        
        // loop through all scanned pages
        for pageNumber in 0...scan.pageCount - 1 {
            
            let scannedImage: UIImage = scan.imageOfPage(at: pageNumber)
            
            // 1. Tenta na imagem original
            var barcodeValue = scannedImage.findITFBarcodeInTopRightAreaSync()

            // 2. Se não achou, tenta girar 90 graus (Simulando foto Landscape)
            if barcodeValue == nil {
                if let rotatedImage = scannedImage.rotate(radians: .pi/2) { // 90 graus
                    barcodeValue = rotatedImage.findITFBarcodeInTopRightAreaSync()
                    // Opcional: Se achou aqui, talvez você queira salvar a rotatedImage no lugar da scannedImage?
                    // scannedImage = rotatedImage (se for var)
                }
            }

            // 3. Se ainda não achou, tenta girar -90 graus (Lado oposto)
            if barcodeValue == nil {
                if let rotatedImage = scannedImage.rotate(radians: -.pi/2) { // -90 graus
                    barcodeValue = rotatedImage.findITFBarcodeInTopRightAreaSync()
                }
            }

            // 4. Se ainda não achou, tenta 180 graus (De ponta cabeça - acontece muito com guia na mesa)
            if barcodeValue == nil {
                if let rotatedImage = scannedImage.rotate(radians: .pi) { // 180 graus
                    barcodeValue = rotatedImage.findITFBarcodeInTopRightAreaSync()
                }
            }

            let barcodeSuccess = barcodeValue != nil
            
            // 2. Converter imagem
            guard let scannedDocumentImage: Data = scannedImage
                .jpegData(compressionQuality: CGFloat(self.croppedImageQuality) / CGFloat(100)) else {
                goBackToPreviousView(controller)
                self.errorHandler("Unable to get scanned document in jpeg format")
                return
            }
            
            var documentIdentifier: String = ""
            
            switch responseType {
                case ResponseType.base64:
                    documentIdentifier = scannedDocumentImage.base64EncodedString()
                case ResponseType.imageFilePath:
                    do {
                        let croppedImageFilePath = FileUtil().createImageFile(pageNumber)
                        try scannedDocumentImage.write(to: croppedImageFilePath)
                        documentIdentifier = croppedImageFilePath.absoluteString
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
            
            // 3. Adicionar ao array de objetos (Estrutura do Backup)
            processedResults.append([
                "uri": documentIdentifier,
                "barcode": barcodeValue as Any,
                "success": barcodeSuccess
            ])
            
        }
        
        // exit document scanner
        goBackToPreviousView(controller)
        
        // return scanned document results (Passa o array de objetos)
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

extension UIImage {
    func rotate(radians: Float) -> UIImage? {
        var newSize = CGRect(origin: CGPoint.zero, size: self.size).applying(CGAffineTransform(rotationAngle: CGFloat(radians))).integral.size
        // Garante que o tamanho seja inteiro
        newSize.width = floor(newSize.width);
        newSize.height = floor(newSize.height);

        UIGraphicsBeginImageContextWithOptions(newSize, false, self.scale)
        let context = UIGraphicsGetCurrentContext()!

        // Move a origem para o centro da imagem para girar
        context.translateBy(x: newSize.width/2, y: newSize.height/2)
        // Rotaciona
        context.rotate(by: CGFloat(radians))
        
        // Desenha a imagem antiga
        self.draw(in: CGRect(x: -self.size.width/2, y: -self.size.height/2, width: self.size.width, height: self.size.height))

        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return newImage
    }
}
