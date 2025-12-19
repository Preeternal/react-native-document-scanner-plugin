import Foundation
import UIKit
import React

@objc(DocumentScannerImpl)
public class DocumentScannerImpl: NSObject {
  private var docScanner: DocScanner?

  @objc static func requiresMainQueueSetup() -> Bool { true }

  @objc(scanDocument:resolve:reject:)
  public func scanDocument(
    _ options: NSDictionary,
    resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    guard #available(iOS 13.0, *) else {
      reject("unsupported_ios", "iOS 13.0 or higher required", nil)
      return
    }

    // 1. Configuração das opções (Logica do Fork)
    let opts = options as? [String: Any] ?? [:]
    let responseType = opts["responseType"] as? String
    let quality = opts["croppedImageQuality"] as? Int
    let isBase64Response = responseType?.lowercased() == "base64"

    DispatchQueue.main.async {
      self.docScanner = DocScanner()
      
      // 2. Inicia o Scan
      self.docScanner?.startScan(
        RCTPresentedViewController(),
        
        // 3. Handler de Sucesso MODIFICADO
        // Agora recebe [[String: Any]] (Array de Objetos do seu Backup)
        successHandler: { (scannedData: [[String: Any]]) in
          
          let fm = FileManager.default
          
          // 4. Sanitização (Lógica do Fork adaptada para Objetos)
          // Filtra os resultados para garantir que o arquivo realmente foi criado
          let sanitized: [[String: Any]] = scannedData.compactMap { item -> [String: Any]? in
            
            // Tenta pegar a URI do objeto
            guard let uri = item["uri"] as? String else { return nil }
            let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            
            // Se for arquivo (não base64), verifica se existe no disco (Segurança do Fork)
            if !isBase64Response {
              let path: String
              if let url = URL(string: trimmed), url.isFileURL {
                path = url.path
              } else {
                path = trimmed
              }
              if !fm.fileExists(atPath: path) {
                return nil // Arquivo não encontrado, descarta
              }
            }
            
            // Se passou na validação, retorna o objeto COMPLETO (com barcode)
            // Se precisar atualizar a URI "trimmada", recriamos o objeto
            var validItem = item
            validItem["uri"] = trimmed
            return validItem
          }
          
          // 5. Retorna para o JS
          resolve([
            "status": "success",
            "scannedImages": sanitized // Array de Objetos {uri, barcode, success}
          ])
          self.docScanner = nil
        },
        
        errorHandler: { msg in
          reject("document_scan_error", msg, nil)
          self.docScanner = nil
        },
        
        cancelHandler: {
          resolve([
            "status": "cancel",
            "scannedImages": []
          ])
          self.docScanner = nil
        },
        
        responseType: responseType,
        croppedImageQuality: quality
      )
    }
  }
}
