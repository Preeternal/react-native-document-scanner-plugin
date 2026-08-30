#import <Foundation/Foundation.h>
#import <DocumentScannerSpec/DocumentScannerSpec.h>

// Thin React Native adapter; implementation lives in the Swift target.
@interface DocumentScanner : NSObject <NativeDocumentScannerSpec>

@end
