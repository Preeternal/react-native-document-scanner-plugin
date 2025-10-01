#import <React/RCTBridgeModule.h>

#if RCT_NEW_ARCH_ENABLED
#import <DocumentScannerSpec/DocumentScannerSpec.h>

@interface DocumentScanner : NSObject <NativeDocumentScannerSpec>
#else
@interface DocumentScanner : NSObject <RCTBridgeModule>
#endif

@end
