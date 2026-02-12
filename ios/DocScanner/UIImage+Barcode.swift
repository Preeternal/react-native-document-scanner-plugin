import UIKit
import Vision

// MARK: - Constantes do Barcode (as mesmas do Kotlin)
private let BARCODE_LARGURA_CORTE_PERCENTUAL: CGFloat = 25.0
private let BARCODE_ALTURA_CORTE_PERCENTUAL: CGFloat = 20.0
private let BARCODE_MARGEM_CANTO_PERCENTUAL: CGFloat = 3.0 / 100.0 // 2% em decimal

extension UIImage {
    
    /**
     * Função Síncrona que decodifica um código de barras ITF na área de interesse (canto superior direito).
     * @return O valor do código de barras (String) ou nil.
     */
    func findITFBarcodeInTopRightAreaSync() -> String? {
            
        let width = self.size.width
        let height = self.size.height

        // 1. Cálculo do Retângulo de Interesse (ROI) - Permanece o mesmo
        let larguraCorte = (width * BARCODE_LARGURA_CORTE_PERCENTUAL) / 100.0
        let alturaCorte = (height * BARCODE_ALTURA_CORTE_PERCENTUAL) / 100.0
        let posicaoX = width * BARCODE_MARGEM_CANTO_PERCENTUAL
        let posicaoY = height * BARCODE_MARGEM_CANTO_PERCENTUAL
        
        let rectX = width - larguraCorte - posicaoX
        let rectY = posicaoY
        let rectWidth = larguraCorte
        let rectHeight = alturaCorte
        
        let targetRect = CGRect(x: rectX, y: rectY, width: rectWidth, height: rectHeight)
        
        // 2. Crop Físico
        guard let cgImage = self.cgImage?.cropping(to: targetRect) else {
            return nil
        }
        
        let request = VNDetectBarcodesRequest()
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        do {
            try handler.perform([request])
            
            // 4. Processar resultados: Pegar a primeira observação decodificada
            // Garantimos que seja um array de observações de código de barras
            guard let observations = request.results as? [VNBarcodeObservation] else {
                return nil
            }
            
            // Pegamos o primeiro resultado válido
            // Opcional: Você pode querer verificar se o tipo é VNBarcodeSymbologyITF14
            // Mas, dado o crop, o primeiro resultado válido deve ser o seu código de barras.
            let firstDecodedBarcode = observations.first?.payloadStringValue
            
            return firstDecodedBarcode

        } catch {
            print("Vision barcode detection error: \(error.localizedDescription)")
            return nil
        }
    }
}
