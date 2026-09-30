#import <UIKit/UIKit.h>
#import <objc/runtime.h>

NSUInteger LegacyWriteRuntimeClassIndex(NSURL *jsonlURL, NSURL *textURL, NSURL *summaryURL);
NSUInteger LegacyWriteVisibleHierarchy(UIWindow *host, NSURL *url, NSUInteger maxDepth, NSUInteger maxNodes, BOOL *truncated);
