// UniversalUIInspector.m — read-only UIKit/runtime diagnostics.
// The manual collectors remain the source of truth; the coordinator only sequences them.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <zlib.h>
#import <errno.h>
#import <sys/stat.h>
#import <unistd.h>
#include <stdint.h>
#include <limits.h>
#include <math.h>
#import "LegacyCollectors.h"

static NSString * const kUIID = @"UniversalUIInspector";
static const NSUInteger kFullCaptureMaxDepth = 256;
static const NSUInteger kFullCaptureMaxNodes = 500000;
static const NSUInteger kSnapshotMaxDepth = 256;
static const NSUInteger kSnapshotMaxViews = 20000;
static const NSUInteger kSnapshotMaxControllers = 5000;

static NSString *UIIString(NSString *value) { return value.length ? value : @"NOT_AVAILABLE"; }
static NSString *UIICString(const char *value) { return value && *value ? [NSString stringWithUTF8String:value] : @"NOT_AVAILABLE"; }
static NSString *UIISanitize(NSString *value) {
    NSString *s = UIIString(value);
    return [[s stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"] stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
}
static NSString *UIIColor(UIColor *color) {
    if (!color) return @"NOT_AVAILABLE";
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if ([color getRed:&r green:&g blue:&b alpha:&a]) return [NSString stringWithFormat:@"rgba(%.3f, %.3f, %.3f, %.3f)", r, g, b, a];
    CGFloat white = 0;
    if ([color getWhite:&white alpha:&a]) return [NSString stringWithFormat:@"gray(%.3f, %.3f)", white, a];
    return UIISanitize(color.description);
}
static NSURL *UIIDocuments(void) {
    return [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
}
static NSURL *ReportsDirectory(void) {
    NSURL *dir = [UIIDocuments() URLByAppendingPathComponent:kUIID isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}
static void WriteTextURL(NSURL *url, NSString *text) {
    if (!url) return;
    [[text ?: @"" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:url options:NSDataWritingAtomic error:nil];
}
static void WriteJSONURL(NSURL *url, NSDictionary *object) {
    if (!url || !object) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:nil];
    if (data) [data writeToURL:url options:NSDataWritingAtomic error:nil];
}
static void WriteReport(NSString *name, NSString *text) {
    WriteTextURL([ReportsDirectory() URLByAppendingPathComponent:name], text);
}
static NSString *ReportPath(NSString *name) {
    return [[ReportsDirectory() URLByAppendingPathComponent:name] path];
}
static NSString *DateString(NSDate *date) {
    static ISO8601DateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ formatter = [ISO8601DateFormatter new]; });
    return [formatter stringFromDate:date ?: [NSDate date]];
}

#pragma mark - Small ZIP support for manual/small exports

static void ZipU16(NSMutableData *data, uint16_t value) { [data appendBytes:&value length:sizeof(value)]; }
static void ZipU32(NSMutableData *data, uint32_t value) { [data appendBytes:&value length:sizeof(value)]; }
static NSData *ZipData(NSDictionary<NSString *, NSData *> *files) {
    NSMutableData *zip = [NSMutableData data];
    NSMutableArray<NSData *> *central = [NSMutableArray array];
    for (NSString *name in [files.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSData *fileData = files[name] ?: [NSData data];
        NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
        uint32_t crc = (uint32_t)crc32(0, fileData.bytes, (uInt)MIN(fileData.length, UINT_MAX));
        uint32_t size = (uint32_t)MIN(fileData.length, UINT32_MAX);
        uint32_t offset = (uint32_t)MIN(zip.length, UINT32_MAX);
        ZipU32(zip, 0x04034b50); ZipU16(zip, 20); ZipU16(zip, 0x0800); ZipU16(zip, 0); ZipU16(zip, 0); ZipU16(zip, 0); ZipU32(zip, crc); ZipU32(zip, size); ZipU32(zip, size); ZipU16(zip, (uint16_t)nameData.length); ZipU16(zip, 0);
        [zip appendData:nameData]; [zip appendData:[fileData subdataWithRange:NSMakeRange(0, size)]];
        NSMutableData *entry = [NSMutableData data];
        ZipU32(entry, 0x02014b50); ZipU16(entry, 20); ZipU16(entry, 20); ZipU16(entry, 0x0800); ZipU16(entry, 0); ZipU16(entry, 0); ZipU16(entry, 0); ZipU32(entry, crc); ZipU32(entry, size); ZipU32(entry, size); ZipU16(entry, (uint16_t)nameData.length); ZipU16(entry, 0); ZipU16(entry, 0); ZipU16(entry, 0); ZipU16(entry, 0); ZipU32(entry, 0); ZipU32(entry, offset); [entry appendData:nameData];
        [central addObject:entry];
    }
    uint32_t centralOffset = (uint32_t)MIN(zip.length, UINT32_MAX);
    for (NSData *entry in central) [zip appendData:entry];
    uint32_t centralSize = (uint32_t)MIN(zip.length - centralOffset, UINT32_MAX);
    ZipU32(zip, 0x06054b50); ZipU16(zip, 0); ZipU16(zip, 0); ZipU16(zip, (uint16_t)MIN(central.count, UINT16_MAX)); ZipU16(zip, (uint16_t)MIN(central.count, UINT16_MAX)); ZipU32(zip, centralSize); ZipU32(zip, centralOffset); ZipU16(zip, 0);
    return zip;
}

static BOOL ValidateZipArchive(NSData *data, NSUInteger *fileCount, NSString **reason) {
    if (fileCount) *fileCount = 0;
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    if (!bytes || length < 22) { if (reason) *reason = @"archive shorter than EOCD"; return NO; }
    NSInteger eocd = -1;
    NSInteger start = (NSInteger)length - 22;
    NSInteger end = MAX(-1, (NSInteger)length - 65558);
    for (NSInteger i = start; i > end; i--) {
        uint32_t signature = 0; memcpy(&signature, bytes + i, sizeof(signature));
        if (signature == 0x06054b50) { eocd = i; break; }
    }
    if (eocd < 0) { if (reason) *reason = @"end-of-central-directory signature not found"; return NO; }
    uint16_t expected = 0; uint32_t size = 0, offset = 0;
    memcpy(&expected, bytes + eocd + 10, sizeof(expected)); memcpy(&size, bytes + eocd + 12, sizeof(size)); memcpy(&offset, bytes + eocd + 16, sizeof(offset));
    if ((NSUInteger)offset + (NSUInteger)size > (NSUInteger)eocd) { if (reason) *reason = @"central directory bounds invalid"; return NO; }
    NSUInteger position = offset, seen = 0;
    while (position < (NSUInteger)offset + (NSUInteger)size) {
        if (position + 46 > length) { if (reason) *reason = @"central directory entry truncated"; return NO; }
        uint32_t signature = 0; memcpy(&signature, bytes + position, sizeof(signature));
        if (signature != 0x02014b50) { if (reason) *reason = @"central directory entry invalid"; return NO; }
        uint16_t nameLength = 0, extraLength = 0, commentLength = 0;
        memcpy(&nameLength, bytes + position + 28, sizeof(nameLength)); memcpy(&extraLength, bytes + position + 30, sizeof(extraLength)); memcpy(&commentLength, bytes + position + 32, sizeof(commentLength));
        NSUInteger entryLength = 46 + nameLength + extraLength + commentLength;
        if (position + entryLength > length) { if (reason) *reason = @"central entry length invalid"; return NO; }
        position += entryLength; seen++;
    }
    if (seen != expected) { if (reason) *reason = [NSString stringWithFormat:@"entry count mismatch expected=%u seen=%lu", expected, (unsigned long)seen]; return NO; }
    if (fileCount) *fileCount = seen;
    return YES;
}

#pragma mark - Streaming ZIP for full sessions

static BOOL StreamFile(NSURL *fileURL, NSFileHandle *output, BOOL writeBytes, uint32_t *crcOut, uint64_t *sizeOut, NSString **errorOut) {
    NSFileHandle *input = [NSFileHandle fileHandleForReadingAtPath:fileURL.path];
    if (!input) { if (errorOut) *errorOut = [NSString stringWithFormat:@"cannot open %@", fileURL.path]; return NO; }
    uint32_t crc = 0; uint64_t size = 0; BOOL ok = YES;
    @try {
        while (YES) {
            NSData *chunk = [input readDataOfLength:1024 * 1024];
            if (!chunk.length) break;
            if (chunk.length > UINT_MAX || size > UINT64_MAX - chunk.length) { ok = NO; break; }
            crc = (uint32_t)crc32(crc, chunk.bytes, (uInt)chunk.length);
            size += chunk.length;
            if (writeBytes) [output writeData:chunk];
        }
    } @catch (NSException *exception) {
        ok = NO;
        if (errorOut) *errorOut = exception.reason ?: @"exception while streaming file";
    }
    [input closeFile];
    if (!ok && errorOut && !*errorOut) *errorOut = @"file streaming failed";
    if (crcOut) *crcOut = crc;
    if (sizeOut) *sizeOut = size;
    return ok;
}

static NSData *ZipLocalHeader(NSData *name, uint32_t crc, uint32_t size) {
    NSMutableData *header = [NSMutableData data];
    ZipU32(header, 0x04034b50); ZipU16(header, 20); ZipU16(header, 0x0800); ZipU16(header, 0); ZipU16(header, 0); ZipU16(header, 0); ZipU32(header, crc); ZipU32(header, size); ZipU32(header, size); ZipU16(header, (uint16_t)name.length); ZipU16(header, 0); [header appendData:name];
    return header;
}

static NSData *ZipCentralHeader(NSData *name, uint32_t crc, uint32_t size, uint32_t offset) {
    NSMutableData *header = [NSMutableData data];
    ZipU32(header, 0x02014b50); ZipU16(header, 20); ZipU16(header, 20); ZipU16(header, 0x0800); ZipU16(header, 0); ZipU16(header, 0); ZipU16(header, 0); ZipU32(header, crc); ZipU32(header, size); ZipU32(header, size); ZipU16(header, (uint16_t)name.length); ZipU16(header, 0); ZipU16(header, 0); ZipU16(header, 0); ZipU16(header, 0); ZipU32(header, 0); ZipU32(header, offset); [header appendData:name];
    return header;
}

static BOOL StreamZipDirectory(NSURL *directoryURL, NSURL *zipURL, NSUInteger *fileCount, NSString **errorOut) {
    if (fileCount) *fileCount = 0;
    NSFileManager *manager = [NSFileManager defaultManager];
    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    NSDirectoryEnumerator *enumerator = [manager enumeratorAtURL:directoryURL includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 errorHandler:^BOOL(NSURL *url, NSError *error) { return YES; }];
    for (NSURL *fileURL in enumerator) {
        NSNumber *isDirectory = nil;
        [fileURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        if (!isDirectory.boolValue) [files addObject:fileURL];
    }
    [files sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { return [a.path compare:b.path]; }];
    if (files.count > UINT16_MAX) { if (errorOut) *errorOut = @"ZIP file-count limit exceeded"; return NO; }
    [[NSFileManager defaultManager] removeItemAtURL:zipURL error:nil];
    if (![[NSFileManager defaultManager] createFileAtPath:zipURL.path contents:nil attributes:nil]) { if (errorOut) *errorOut = @"cannot create ZIP"; return NO; }
    NSFileHandle *output = [NSFileHandle fileHandleForWritingAtPath:zipURL.path];
    if (!output) { if (errorOut) *errorOut = @"cannot open ZIP for writing"; return NO; }
    NSMutableArray<NSData *> *central = [NSMutableArray arrayWithCapacity:files.count];
    BOOL success = YES;
    for (NSURL *fileURL in files) {
        @autoreleasepool {
            NSString *relative = [fileURL.path substringFromIndex:directoryURL.path.length + 1];
            NSData *name = [relative dataUsingEncoding:NSUTF8StringEncoding];
            if (!name.length || name.length > UINT16_MAX) { success = NO; if (errorOut) *errorOut = @"ZIP entry name too long"; return; }
            uint32_t crc = 0; uint64_t size64 = 0; NSString *streamError = nil;
            if (!StreamFile(fileURL, nil, NO, &crc, &size64, &streamError) || size64 > UINT32_MAX || output.offsetInFile > UINT32_MAX) {
                success = NO; if (errorOut) *errorOut = streamError ?: @"ZIP entry exceeds classic ZIP limits"; return;
            }
            uint32_t size = (uint32_t)size64;
            uint32_t offset = (uint32_t)output.offsetInFile;
            [output writeData:ZipLocalHeader(name, crc, size)];
            if (!StreamFile(fileURL, output, YES, NULL, NULL, &streamError)) { success = NO; if (errorOut) *errorOut = streamError ?: @"cannot write ZIP entry"; return; }
            [central addObject:ZipCentralHeader(name, crc, size, offset)];
            if (fileCount) (*fileCount)++;
        }
        if (!success) break;
    }
    if (success) {
        uint32_t centralOffset = (uint32_t)output.offsetInFile;
        for (NSData *entry in central) [output writeData:entry];
        uint32_t centralSize = (uint32_t)(output.offsetInFile - centralOffset);
        NSMutableData *end = [NSMutableData data];
        ZipU32(end, 0x06054b50); ZipU16(end, 0); ZipU16(end, 0); ZipU16(end, (uint16_t)central.count); ZipU16(end, (uint16_t)central.count); ZipU32(end, centralSize); ZipU32(end, centralOffset); ZipU16(end, 0);
        [output writeData:end];
    }
    [output closeFile];
    if (!success) [[NSFileManager defaultManager] removeItemAtURL:zipURL error:nil];
    return success;
}

#pragma mark - Session and phase utilities

static void AppendFileURL(NSURL *url, NSString *line) {
    if (!url || !line) return;
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:url.path];
    if (!handle) {
        WriteTextURL(url, line);
        return;
    }
    [handle seekToEndOfFile];
    [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [handle synchronizeFile];
    [handle closeFile];
}

static NSString *MemoryNote(void) {
    return [NSString stringWithFormat:@"mainThread=%@", NSThread.isMainThread ? @"YES" : @"NO"];
}

#pragma mark - Snapshot session (manual capture remains available)

@interface SessionCapture : NSObject
@property(nonatomic,strong) NSString *sessionID;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *snapshots;
@property(nonatomic,weak) UIWindow *hostWindow;
@property(nonatomic) BOOL active;
+ (instancetype)shared;
- (void)start:(UIWindow *)host;
- (void)capture:(UIWindow *)host label:(NSString *)label inspectorWindow:(UIWindow *)inspector;
- (void)stop;
- (NSURL *)stageSession:(UIWindow *)host error:(NSError **)error;
@end

static NSValue *SnapshotPointerKey(id object) { return [NSValue valueWithPointer:(__bridge const void *)(object)]; }
static NSArray<UIView *> *SnapshotSubviews(UIView *view) { @try { return [view.subviews copy] ?: @[]; } @catch (__unused NSException *exception) { return @[]; } }
static void SessionViewSnapshot(UIView *view, NSUInteger depth, NSUInteger *nodes, NSMutableArray *out, NSMutableSet *seen, BOOL *truncated) {
    if (!view) return;
    if (depth > kSnapshotMaxDepth || *nodes >= kSnapshotMaxViews) { if (truncated) *truncated = YES; return; }
    NSValue *key = SnapshotPointerKey(view);
    if ([seen containsObject:key]) return;
    [seen addObject:key]; (*nodes)++;
    NSMutableDictionary *record = [@{
        @"class": UIIString(NSStringFromClass(view.class)),
        @"superclass": UIIString(NSStringFromClass(view.superclass)),
        @"address": [NSString stringWithFormat:@"%p", view],
        @"frame": NSStringFromCGRect(view.frame),
        @"bounds": NSStringFromCGRect(view.bounds),
        @"center": NSStringFromCGPoint(view.center),
        @"transform": NSStringFromCGAffineTransform(view.transform),
        @"alpha": @(view.alpha), @"hidden": @(view.hidden), @"opaque": @(view.opaque),
        @"clipsToBounds": @(view.clipsToBounds), @"userInteractionEnabled": @(view.userInteractionEnabled),
        @"contentMode": @(view.contentMode), @"tag": @(view.tag),
        @"backgroundColor": UIIColor(view.backgroundColor), @"tintColor": UIIColor(view.tintColor),
        @"subviewCount": @(view.subviews.count), @"accessibilityIdentifier": UIISanitize(view.accessibilityIdentifier),
        @"accessibilityLabel": UIISanitize(view.accessibilityLabel), @"accessibilityValue": UIISanitize(view.accessibilityValue),
        @"window": view.window ? [NSString stringWithFormat:@"%p/%@", view.window, UIIString(NSStringFromClass(view.window.class))] : @"NOT_AVAILABLE",
        @"superview": view.superview ? [NSString stringWithFormat:@"%p/%@", view.superview, UIIString(NSStringFromClass(view.superview.class))] : @"NOT_AVAILABLE",
        @"layer": view.layer ? [NSString stringWithFormat:@"%p/%@", view.layer, UIIString(NSStringFromClass(view.layer.class))] : @"NOT_AVAILABLE"
    } mutableCopy];
    CALayer *layer = view.layer;
    if (layer) {
        record[@"layerFrame"] = NSStringFromCGRect(layer.frame); record[@"layerBounds"] = NSStringFromCGRect(layer.bounds);
        record[@"layerOpacity"] = @(layer.opacity); record[@"layerHidden"] = @(layer.hidden); record[@"cornerRadius"] = @(layer.cornerRadius);
        record[@"masksToBounds"] = @(layer.masksToBounds); record[@"zPosition"] = @(layer.zPosition); record[@"layerBackgroundColor"] = layer.backgroundColor ? UIIColor([UIColor colorWithCGColor:layer.backgroundColor]) : @"NOT_AVAILABLE";
    }
    if ([view isKindOfClass:UIScrollView.class]) {
        UIScrollView *scroll = (UIScrollView *)view; record[@"contentOffset"] = NSStringFromCGPoint(scroll.contentOffset); record[@"contentSize"] = NSStringFromCGSize(scroll.contentSize);
    }
    [out addObject:record];
    for (UIView *child in SnapshotSubviews(view)) SessionViewSnapshot(child, depth + 1, nodes, out, seen, truncated);
}
static void SessionControllerSnapshot(UIViewController *controller, NSUInteger depth, NSUInteger *nodes, NSMutableArray *out, NSMutableSet *seen, BOOL *truncated) {
    if (!controller) return;
    if (depth > kSnapshotMaxDepth || *nodes >= kSnapshotMaxControllers) { if (truncated) *truncated = YES; return; }
    NSValue *key = SnapshotPointerKey(controller);
    if ([seen containsObject:key]) return;
    [seen addObject:key]; (*nodes)++;
    NSMutableDictionary *record = [@{
        @"class": UIIString(NSStringFromClass(controller.class)), @"superclass": UIIString(NSStringFromClass(controller.superclass)),
        @"address": [NSString stringWithFormat:@"%p", controller], @"childCount": @(controller.childViewControllers.count),
        @"presented": controller.presentedViewController ? UIIString(NSStringFromClass(controller.presentedViewController.class)) : @"NOT_AVAILABLE",
        @"presenting": controller.presentingViewController ? UIIString(NSStringFromClass(controller.presentingViewController.class)) : @"NOT_AVAILABLE",
        @"viewLoaded": @(controller.isViewLoaded), @"view": controller.isViewLoaded ? [NSString stringWithFormat:@"%p/%@", controller.view, UIIString(NSStringFromClass(controller.view.class))] : @"NOT_AVAILABLE"
    } mutableCopy];
    if ([controller isKindOfClass:UINavigationController.class]) record[@"navigationStack"] = [[(UINavigationController *)controller viewControllers] valueForKeyPath:@"class.description"] ?: @[];
    if ([controller isKindOfClass:UITabBarController.class]) record[@"selectedTab"] = UIIString(NSStringFromClass(((UITabBarController *)controller).selectedViewController.class));
    if ([controller isKindOfClass:UISplitViewController.class]) record[@"splitControllers"] = [[(UISplitViewController *)controller viewControllers] valueForKeyPath:@"class.description"] ?: @[];
    [out addObject:record];
    for (UIViewController *child in controller.childViewControllers) SessionControllerSnapshot(child, depth + 1, nodes, out, seen, truncated);
    SessionControllerSnapshot(controller.presentedViewController, depth + 1, nodes, out, seen, truncated);
}

@implementation SessionCapture
+ (instancetype)shared { static SessionCapture *instance; static dispatch_once_t once; dispatch_once(&once, ^{ instance = [self new]; }); return instance; }
- (instancetype)init { if ((self = [super init])) _snapshots = [NSMutableArray array]; return self; }
- (void)sceneChanged:(NSNotification *)note { if (!self.active || !self.hostWindow) return; dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (self.active) [self capture:self.hostWindow label:@"scene-activation" inspectorWindow:nil]; }); }
- (void)start:(UIWindow *)host {
    self.hostWindow = host; self.sessionID = [NSUUID UUID].UUIDString; self.snapshots = [NSMutableArray array]; self.active = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sceneChanged:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [self capture:host label:@"session-start" inspectorWindow:nil];
}
- (void)capture:(UIWindow *)host label:(NSString *)label inspectorWindow:(UIWindow *)inspector {
    if (!NSThread.isMainThread || !host || !self.active) return;
    NSUInteger viewCount = 0, controllerCount = 0; BOOL truncated = NO;
    NSMutableArray *views = [NSMutableArray array], *controllers = [NSMutableArray array];
    SessionViewSnapshot(host, 0, &viewCount, views, [NSMutableSet set], &truncated);
    SessionControllerSnapshot(host.rootViewController, 0, &controllerCount, controllers, [NSMutableSet set], &truncated);
    NSMutableDictionary *snapshot = [@{ @"sessionID": self.sessionID ?: @"", @"captureID": [NSUUID UUID].UUIDString, @"timestamp": DateString([NSDate date]), @"label": label ?: @"", @"scene": host.windowScene.session.persistentIdentifier ?: @"", @"hostWindow": [NSString stringWithFormat:@"%p", host], @"views": views, @"controllers": controllers, @"truncated": @(truncated), @"viewCount": @(viewCount), @"controllerCount": @(controllerCount) } mutableCopy];
    @try {
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:host.bounds.size];
        UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) { [host drawViewHierarchyInRect:host.bounds afterScreenUpdates:NO]; }];
        snapshot[@"screenshotData"] = UIImagePNGRepresentation(image) ?: [NSData data];
    } @catch (__unused NSException *exception) {
        snapshot[@"screenshotData"] = [NSData data]; snapshot[@"screenshotError"] = @"NOT_AVAILABLE";
    }
    NSDictionary *last = self.snapshots.lastObject;
    if (last && [last[@"views"] isEqual:views] && [last[@"controllers"] isEqual:controllers] && [last[@"label"] isEqual:label]) return;
    [self.snapshots addObject:snapshot];
}
- (void)stop { self.active = NO; [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil]; }
- (NSURL *)stageSession:(UIWindow *)host error:(NSError **)error {
    if (NSThread.isMainThread && self.active) [self capture:host label:@"export" inspectorWindow:nil];
    NSURL *base = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:self.sessionID ?: [NSUUID UUID].UUIDString] isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:base withIntermediateDirectories:YES attributes:nil error:error];
    if (error && *error) return nil;
    NSURL *screens = [base URLByAppendingPathComponent:@"Screens" isDirectory:YES]; [[NSFileManager defaultManager] createDirectoryAtURL:screens withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray *index = [NSMutableArray array];
    for (NSDictionary *snapshot in self.snapshots) {
        NSString *captureID = snapshot[@"captureID"]; NSURL *dir = [screens URLByAppendingPathComponent:captureID isDirectory:YES]; [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableDictionary *copy = [snapshot mutableCopy]; NSData *png = copy[@"screenshotData"]; [copy removeObjectForKey:@"screenshotData"]; [copy removeObjectForKey:@"views"]; [copy removeObjectForKey:@"controllers"]; [index addObject:copy];
        NSData *viewData = [NSJSONSerialization dataWithJSONObject:snapshot[@"views"] ?: @[] options:NSJSONWritingPrettyPrinted error:nil]; if (viewData) [viewData writeToURL:[dir URLByAppendingPathComponent:@"views.json"] options:NSDataWritingAtomic error:nil];
        NSData *controllerData = [NSJSONSerialization dataWithJSONObject:snapshot[@"controllers"] ?: @[] options:NSJSONWritingPrettyPrinted error:nil]; if (controllerData) [controllerData writeToURL:[dir URLByAppendingPathComponent:@"controllers.json"] options:NSDataWritingAtomic error:nil];
        [png writeToURL:[dir URLByAppendingPathComponent:@"screenshot.png"] options:NSDataWritingAtomic error:nil];
    }
    NSData *indexData = [NSJSONSerialization dataWithJSONObject:@{ @"sessionID": self.sessionID ?: @"", @"snapshotCount": @(index.count), @"snapshots": index, @"coverage": @"Observed screens only; not 100% app coverage." } options:NSJSONWritingPrettyPrinted error:error];
    [indexData writeToURL:[base URLByAppendingPathComponent:@"SESSION_INDEX.json"] options:NSDataWritingAtomic error:error];
    WriteTextURL([base URLByAppendingPathComponent:@"COVERAGE_REPORT.txt"], @"This session records screens actually observed and captured. It does not claim full app coverage.\n");
    return base;
}
@end

#pragma mark - Inspector UI and coordinator

@class InspectorCore;
@interface InspectorWindow : UIWindow @end
@interface InspectorRootController : UIViewController
@property(nonatomic,weak) InspectorCore *core;
@end
@interface InspectorButton : UIButton
@property(nonatomic,weak) InspectorCore *core;
@end

@interface InspectorCore : NSObject <UIDocumentPickerDelegate>
@property(nonatomic,strong) InspectorWindow *window;
@property(nonatomic,strong) InspectorRootController *root;
@property(nonatomic,strong) InspectorButton *button;
@property(nonatomic,weak) UIWindow *hostWindow;
@property(nonatomic,weak) UIWindowScene *scene;
@property(nonatomic,strong) NSMutableString *startup;
@property(nonatomic) BOOL started;
@property(nonatomic,strong) NSURL *selectedFolder;
@property(nonatomic) BOOL collectionCancelled;
@property(nonatomic,strong) UIAlertController *collectionAlert;
@property(nonatomic) BOOL collectionRunning;
@property(nonatomic,strong) UIAlertController *inspectorPanel;
@property(nonatomic,strong) NSString *selectedClassName;
@property(nonatomic) BOOL sharePresented;
@property(nonatomic) BOOL capturePrepared;
@property(nonatomic) BOOL preparing;
@property(nonatomic) BOOL pendingExport;
@property(nonatomic) NSTimeInterval preparationStarted;
@property(nonatomic,strong) NSTimer *preparationTimer;
@property(nonatomic,strong) NSString *lastPhase;
@property(nonatomic,strong) NSURL *sessionDirectory;
@property(nonatomic,strong) NSString *sessionID;
@property(nonatomic,strong) NSDate *sessionStartDate;
@property(nonatomic,strong) NSDate *sessionEndDate;
@property(nonatomic,strong) NSMutableDictionary *phaseStatuses;
@property(nonatomic,strong) NSMutableArray *phasesCompleted;
@property(nonatomic,strong) NSMutableArray *phasesFailed;
@property(nonatomic,strong) NSMutableArray *phasesSkipped;
@property(nonatomic,strong) NSMutableArray *filesFailed;
@property(nonatomic,strong) NSMutableArray *warnings;
@property(nonatomic,strong) NSMutableArray *limitsReached;
@property(nonatomic,strong) NSMutableArray *caughtErrors;
@property(nonatomic,strong) NSString *zipStatus;
@property(nonatomic,strong) NSURL *zipURL;
@property(nonatomic) NSUInteger runtimeClassCount;
@property(nonatomic) NSUInteger protocolCount;
@property(nonatomic) NSUInteger loadedImageCount;
@property(nonatomic) NSUInteger windowCount;
@property(nonatomic) NSUInteger controllerCount;
@property(nonatomic) NSUInteger legacyViewCount;
@property(nonatomic) NSUInteger windowViewCount;
@property(nonatomic) NSUInteger controllerViewCount;
@property(nonatomic) NSUInteger visibleControllerViewCount;
@property(nonatomic) NSUInteger uniqueViewCount;
@property(nonatomic) NSUInteger maximumDepthObserved;
@property(nonatomic) NSUInteger objectSkips;
@property(nonatomic) NSUInteger duplicateSkips;

+ (instancetype)shared;
- (void)start;
- (void)showInspectorPanel;
- (void)showMenu;
- (void)exportReports;
- (void)exportSession;
- (void)runOneButtonCollection;
- (void)captureSnapshot;
- (void)prepareFullCapture:(BOOL)exportAfter;
- (void)showCaptureStatus;
- (void)cancelCurrentPhase;
- (void)hideOverlayForSystemUI;
- (void)restoreOverlayAfterSystemUI;
- (void)searchClass:(NSString *)query;
- (void)exportSelectedClass;
- (NSString *)hierarchy;
- (NSString *)controllers;
- (NSString *)classes;
- (NSData *)detailedRuntimeJSON;
- (NSString *)images;
- (NSString *)diagnostics;
@end

@implementation InspectorWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { UIView *hit = [super hitTest:point withEvent:event]; if (hit == self || hit == self.rootViewController.view) return nil; return hit; }
@end
@implementation InspectorButton
- (instancetype)initWithCore:(InspectorCore *)core {
    if ((self = [super initWithFrame:CGRectMake(0, 0, 56, 56)])) {
        _core = core; self.accessibilityLabel = @"Universal UI Inspector"; self.backgroundColor = [UIColor colorWithRed:.05 green:.25 blue:.85 alpha:.96]; self.layer.cornerRadius = 28; self.layer.borderWidth = 2; self.layer.borderColor = UIColor.whiteColor.CGColor; self.layer.shadowColor = UIColor.blackColor.CGColor; self.layer.shadowOpacity = .45; self.layer.shadowRadius = 5; [self setTitle:@"UI" forState:UIControlStateNormal]; [self setTitleColor:UIColor.whiteColor forState:UIControlStateNormal]; self.titleLabel.font = [UIFont boldSystemFontOfSize:15]; [self addTarget:self action:@selector(open:) forControlEvents:UIControlEventTouchUpInside]; [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
    }
    return self;
}
- (void)open:(id)sender { [self.core showInspectorPanel]; }
- (void)drag:(UIPanGestureRecognizer *)gesture { CGPoint translation = [gesture translationInView:self.superview]; if (gesture.state == UIGestureRecognizerStateChanged) { CGPoint center = self.center; center.x += translation.x; center.y += translation.y; UIEdgeInsets insets = self.superview.safeAreaInsets; center.x = MAX(insets.left + 28, MIN(self.superview.bounds.size.width - insets.right - 28, center.x)); center.y = MAX(insets.top + 28, MIN(self.superview.bounds.size.height - insets.bottom - 28, center.y)); self.center = center; [gesture setTranslation:CGPointZero inView:self.superview]; } }
@end
@implementation InspectorRootController
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; if (!self.core.button.superview) return; UIEdgeInsets insets = self.view.safeAreaInsets; if (CGRectIsEmpty(self.core.button.frame) || self.core.button.center.x < 1) self.core.button.frame = CGRectMake(self.view.bounds.size.width - insets.right - 70, insets.top + 24, 56, 56); else { CGPoint center = self.core.button.center; center.x = MAX(insets.left + 28, MIN(self.view.bounds.size.width - insets.right - 28, center.x)); center.y = MAX(insets.top + 28, MIN(self.view.bounds.size.height - insets.bottom - 28, center.y)); self.core.button.center = center; } }
@end

static UIWindow *FindHostWindow(UIWindowScene **sceneOut, NSString **evidenceOut) {
    UIApplication *application = UIApplication.sharedApplication; NSMutableString *evidence = [NSMutableString string]; UIWindow *best = nil; UIWindowScene *bestScene = nil;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        [evidence appendFormat:@"scene=%p state=%ld windows=%lu\n", windowScene, (long)windowScene.activationState, (unsigned long)windowScene.windows.count];
        if (windowScene.activationState != UISceneActivationStateForegroundActive && windowScene.activationState != UISceneActivationStateForegroundInactive) continue;
        for (UIWindow *window in windowScene.windows) {
            [evidence appendFormat:@"  window=%p hidden=%@ level=%.1f root=%@\n", window, window.hidden ? @"YES" : @"NO", window.windowLevel, window.rootViewController ? UIIString(NSStringFromClass(window.rootViewController.class)) : @"NOT_AVAILABLE"];
            if (!window.hidden && window.rootViewController && window.windowLevel == UIWindowLevelNormal && window.bounds.size.width > 0 && window.bounds.size.height > 0) { best = window; bestScene = windowScene; break; }
        }
        if (best) break;
    }
    if (sceneOut) *sceneOut = bestScene; if (evidenceOut) *evidenceOut = evidence; return best;
}

@implementation InspectorCore
+ (instancetype)shared { static InspectorCore *instance; static dispatch_once_t once; dispatch_once(&once, ^{ instance = [self new]; }); return instance; }
- (instancetype)init { if ((self = [super init])) _startup = [NSMutableString stringWithFormat:@"UniversalUIInspector startup %@\n", DateString([NSDate date])]; return self; }
- (UIViewController *)presenter { UIViewController *controller = self.hostWindow.rootViewController; while (controller.presentedViewController) controller = controller.presentedViewController; return controller; }
- (NSURL *)sessionFile:(NSString *)name folder:(NSString *)folder { if (!self.sessionDirectory) return [ReportsDirectory() URLByAppendingPathComponent:name]; NSURL *directory = [self.sessionDirectory URLByAppendingPathComponent:folder isDirectory:YES]; [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil]; return [directory URLByAppendingPathComponent:name]; }
- (NSURL *)sessionRootFile:(NSString *)name { return self.sessionDirectory ? [self.sessionDirectory URLByAppendingPathComponent:name] : [ReportsDirectory() URLByAppendingPathComponent:name]; }
- (void)updateSessionState {
    if (!self.sessionDirectory) return;
    NSMutableDictionary *state = [@{ @"schemaVersion": @"2.0", @"sessionID": self.sessionID ?: @"", @"startTime": DateString(self.sessionStartDate), @"status": self.collectionRunning ? @"running" : (self.capturePrepared ? @"prepared" : @"preparing"), @"metadata": self.phaseStatuses[@"metadata"] ?: @"pending", @"loaded_images": self.phaseStatuses[@"loaded_images"] ?: @"pending", @"runtime_classes": self.phaseStatuses[@"runtime_classes"] ?: @"pending", @"protocols": self.phaseStatuses[@"protocols"] ?: @"pending", @"runtime_details": self.phaseStatuses[@"runtime_details"] ?: @"pending", @"controllers": self.phaseStatuses[@"controllers"] ?: @"pending", @"windows": self.phaseStatuses[@"windows"] ?: @"pending", @"view_legacy": self.phaseStatuses[@"view_legacy"] ?: @"pending", @"view_controller_roots": self.phaseStatuses[@"view_controller_roots"] ?: @"pending", @"diagnostics": self.phaseStatuses[@"diagnostics"] ?: @"pending", @"summary": self.phaseStatuses[@"summary"] ?: @"pending", @"zip": self.phaseStatuses[@"zip"] ?: @"pending", @"phases": self.phaseStatuses ?: @{}, @"warnings": self.warnings ?: @[], @"errors": self.caughtErrors ?: @[] } mutableCopy];
    WriteJSONURL([self sessionRootFile:@"SESSION_STATE.json"], state);
}
- (void)createSession {
    [[SessionCapture shared] start:self.hostWindow];
    self.sessionID = [SessionCapture shared].sessionID ?: [NSUUID UUID].UUIDString;
    self.sessionStartDate = [NSDate date];
    NSURL *sessions = [[ReportsDirectory() URLByAppendingPathComponent:@"Sessions" isDirectory:YES] URLByStandardizedURL];
    [[NSFileManager defaultManager] createDirectoryAtURL:sessions withIntermediateDirectories:YES attributes:nil error:nil];
    self.sessionDirectory = [sessions URLByAppendingPathComponent:self.sessionID isDirectory:YES];
    for (NSString *folder in @[@"00_METADATA", @"01_RUNTIME", @"02_IMAGES", @"03_CONTROLLERS", @"04_VIEWS", @"05_SNAPSHOTS", @"06_DIAGNOSTICS", @"07_LOGS"]) [[NSFileManager defaultManager] createDirectoryAtURL:[self.sessionDirectory URLByAppendingPathComponent:folder isDirectory:YES] withIntermediateDirectories:YES attributes:nil error:nil];
    self.phaseStatuses = [NSMutableDictionary dictionary]; self.phasesCompleted = [NSMutableArray array]; self.phasesFailed = [NSMutableArray array]; self.phasesSkipped = [NSMutableArray array]; self.filesFailed = [NSMutableArray array]; self.warnings = [NSMutableArray array]; self.limitsReached = [NSMutableArray array]; self.caughtErrors = [NSMutableArray array]; self.zipStatus = @"pending";
    WriteTextURL([self sessionFile:@"SESSION_INFO.txt" folder:@"00_METADATA"], [NSString stringWithFormat:@"UniversalUIInspector runtime session\nsession_id=%@\ncreated=%@\nminimum_warmup_seconds=60\nlegacy_collectors=YES\nstatus=preparing\n", self.sessionID, DateString(self.sessionStartDate)]);
    WriteJSONURL([self sessionFile:@"SESSION_INFO.json" folder:@"00_METADATA"], @{ @"schemaVersion": @"2.0", @"sessionID": self.sessionID, @"createdAt": DateString(self.sessionStartDate), @"minimumWarmupSeconds": @60, @"legacyCollectors": @YES, @"status": @"preparing" });
    WriteTextURL([self sessionFile:@"APP_INFO.txt" folder:@"00_METADATA"], [NSString stringWithFormat:@"bundleIdentifier=%@\nversion=%@\nbuild=%@\nmainImage=%@\n", UIIString(NSBundle.mainBundle.bundleIdentifier), UIIString([NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]), UIIString([NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]), UIICString(_dyld_get_image_name(0))]);
    WriteTextURL([self sessionFile:@"DEVICE_INFO.txt" folder:@"00_METADATA"], [NSString stringWithFormat:@"model=%@\nos=%@\nscreen=%@\n", UIIString(UIDevice.currentDevice.model), UIIString(UIDevice.currentDevice.systemVersion), NSStringFromCGRect(UIScreen.mainScreen.bounds)]);
    [self updateSessionState];
}
- (void)appendPhaseLog:(NSString *)phase line:(NSString *)line {
    AppendFileURL([self sessionFile:[phase stringByAppendingString:@".log"] folder:@"07_LOGS"], [line stringByAppendingString:@"\n"]);
    AppendFileURL([ReportsDirectory() URLByAppendingPathComponent:@"SESSION_PHASE_LOG.txt"], [line stringByAppendingString:@"\n"]);
}
- (void)beginPhase:(NSString *)phase message:(NSString *)message {
    self.lastPhase = phase; self.phaseStatuses[phase] = @"running"; self.collectionAlert.message = message;
    NSString *line = [NSString stringWithFormat:@"START timestamp=%@ phase=%@ progress=%@ %@", DateString([NSDate date]), phase, message ?: @"", MemoryNote()];
    [self appendPhaseLog:phase line:line]; [self updateSessionState];
}
- (void)endPhase:(NSString *)phase state:(NSString *)state count:(NSUInteger)count bytes:(NSUInteger)bytes warning:(NSString *)warning error:(NSString *)error {
    NSString *finalState = error.length ? @"failed" : state ?: @"complete"; self.phaseStatuses[phase] = finalState;
    if (error.length) { if (![self.phasesFailed containsObject:phase]) [self.phasesFailed addObject:phase]; [self.caughtErrors addObject:[NSString stringWithFormat:@"%@:%@", phase, error]]; [self.filesFailed addObject:phase]; }
    else if ([finalState isEqualToString:@"skipped"]) { if (![self.phasesSkipped containsObject:phase]) [self.phasesSkipped addObject:phase]; }
    else if (![self.phasesCompleted containsObject:phase]) [self.phasesCompleted addObject:phase];
    if (warning.length && ![self.warnings containsObject:warning]) [self.warnings addObject:warning];
    NSString *line = [NSString stringWithFormat:@"END timestamp=%@ phase=%@ state=%@ count=%lu bytes=%lu warning=%@ error=%@ %@", DateString([NSDate date]), phase, finalState, (unsigned long)count, (unsigned long)bytes, warning ?: @"-", error ?: @"-", MemoryNote()];
    [self appendPhaseLog:phase line:line]; [self updateSessionState];
}
- (void)mirrorReport:(NSString *)name from:(NSURL *)url {
    NSData *data = [NSData dataWithContentsOfURL:url]; if (data) [data writeToURL:[ReportsDirectory() URLByAppendingPathComponent:name] options:NSDataWritingAtomic error:nil];
}

- (void)start {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self start]; }); return; }
    if (self.started && self.window.superview) return;
    UIWindowScene *scene = nil; NSString *evidence = nil; UIWindow *host = FindHostWindow(&scene, &evidence); [self.startup appendFormat:@"Discovery:\n%@", evidence ?: @"(none)" ];
    if (!host || !scene) { [self.startup appendString:@"ERROR: no foreground usable host window\n"]; [self writeStartupReports]; return; }
    self.hostWindow = host; self.scene = scene; self.started = YES; self.root = [InspectorRootController new]; self.root.core = self; self.window = [[InspectorWindow alloc] initWithWindowScene:scene]; self.window.frame = scene.coordinateSpace.bounds; self.window.windowLevel = UIWindowLevelAlert + 1; self.window.backgroundColor = UIColor.clearColor; self.window.opaque = NO; self.window.rootViewController = self.root; self.button = [[InspectorButton alloc] initWithCore:self]; [self.root.view addSubview:self.button]; self.window.hidden = NO; [self.root viewDidLayoutSubviews];
    [self.startup appendFormat:@"Host window: %p %@\nScene: %p state=%ld\nOverlay created: %p visible=%@ button=%@\n", host, UIIString(NSStringFromClass(host.class)), scene, (long)scene.activationState, self.window, self.window.hidden ? @"NO" : @"YES", self.button]; [self writeStartupReports];
}
- (void)writeStartupReports {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self writeStartupReports]; }); return; }
    NSURL *treeURL = [ReportsDirectory() URLByAppendingPathComponent:@"STARTUP_VIEW_TREE.txt"]; BOOL truncated = NO; NSUInteger nodes = LegacyWriteVisibleHierarchy(self.hostWindow, treeURL, kFullCaptureMaxDepth, kFullCaptureMaxNodes, &truncated);
    [self.startup appendFormat:@"Startup tree nodes: %lu max depth policy: %lu max nodes policy: %lu LIMIT_REACHED=%@\n", (unsigned long)nodes, (unsigned long)kFullCaptureMaxDepth, (unsigned long)kFullCaptureMaxNodes, truncated ? @"YES" : @"NO"];
    NSString *boot = self.startup.copy; NSString *runtime = [NSString stringWithFormat:@"Runtime report %@\nloaded images: %u\nmain image: %s\ninspector window: %p\nhost window: %p\nstartup tree nodes: %lu\n", DateString([NSDate date]), _dyld_image_count(), _dyld_get_image_name(0) ?: "NOT_AVAILABLE", self.window, self.hostWindow, (unsigned long)nodes];
    WriteReport(@"BOOT_DIAGNOSTICS.txt", boot); WriteReport(@"RUNTIME_STARTUP_REPORT.txt", runtime); if (truncated) WriteReport(@"STARTUP_WARNING.txt", @"LIMIT_REACHED in startup hierarchy; see SUMMARY and FINAL_LOG.\n");
}

#pragma mark - Manual actions, backed by the same legacy collectors

- (NSString *)hierarchy {
    NSURL *url = [ReportsDirectory() URLByAppendingPathComponent:@"CURRENT_VIEW_HIERARCHY.txt"]; BOOL truncated = NO; LegacyWriteVisibleHierarchy(self.hostWindow, url, kFullCaptureMaxDepth, kFullCaptureMaxNodes, &truncated); return [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil] ?: @"CURRENT_VIEW_HIERARCHY.txt\n";
}
- (NSString *)controllers {
    NSURL *controllersURL = [ReportsDirectory() URLByAppendingPathComponent:@"CURRENT_CONTROLLERS.txt"]; NSURL *treeURL = [ReportsDirectory() URLByAppendingPathComponent:@"CONTROLLER_TREE.txt"]; NSURL *mapURL = [ReportsDirectory() URLByAppendingPathComponent:@"CONTROLLER_VIEW_MAP.txt"]; BOOL truncated = NO; NSUInteger duplicates = 0, depth = 0; LegacyWriteControllers(self.hostWindow, controllersURL, treeURL, mapURL, kFullCaptureMaxDepth, kFullCaptureMaxNodes, &truncated, &duplicates, &depth); return [NSString stringWithContentsOfURL:controllersURL encoding:NSUTF8StringEncoding error:nil] ?: @"CURRENT_CONTROLLERS.txt\n";
}
- (NSString *)classes {
    NSURL *jsonl = [ReportsDirectory() URLByAppendingPathComponent:@"RUNTIME_CLASSES.jsonl"]; NSURL *text = [ReportsDirectory() URLByAppendingPathComponent:@"RUNTIME_CLASSES.txt"]; NSURL *summary = [ReportsDirectory() URLByAppendingPathComponent:@"RUNTIME_CLASSES_SUMMARY.json"]; NSUInteger count = LegacyWriteRuntimeClassIndex(jsonl, text, summary); return [NSString stringWithFormat:@"RUNTIME_CLASSES.txt\ncomplete_index_count=%lu\njsonl=%@\n", (unsigned long)count, text.path];
}
- (NSData *)detailedRuntimeJSON {
    NSURL *jsonl = [ReportsDirectory() URLByAppendingPathComponent:@"RUNTIME_CLASSES_DETAILED.jsonl"]; NSURL *text = [ReportsDirectory() URLByAppendingPathComponent:@"RUNTIME_CLASSES_DETAILED.txt"]; NSURL *summary = [ReportsDirectory() URLByAppendingPathComponent:@"RUNTIME_CLASSES_DETAILED_SUMMARY.json"]; LegacyWriteRuntimeDetails(jsonl, text, summary); return [NSData dataWithContentsOfURL:summary] ?: [NSData data];
}
- (NSString *)images {
    NSURL *text = [ReportsDirectory() URLByAppendingPathComponent:@"LOADED_IMAGES.txt"]; NSURL *jsonl = [ReportsDirectory() URLByAppendingPathComponent:@"LOADED_IMAGES.jsonl"]; NSURL *summary = [ReportsDirectory() URLByAppendingPathComponent:@"LOADED_IMAGES_SUMMARY.json"]; LegacyWriteLoadedImages(text, jsonl, summary); return [NSString stringWithContentsOfURL:text encoding:NSUTF8StringEncoding error:nil] ?: @"LOADED_IMAGES.txt\n";
}
- (NSString *)diagnostics {
    return [NSString stringWithFormat:@"DIAGNOSTICS.txt\nmain thread=%@\nstarted=%@\nhost=%p\noverlay=%p hidden=%@\nreports=%@\nsession=%@\nlast phase=%@\n", NSThread.isMainThread ? @"YES" : @"NO", self.started ? @"YES" : @"NO", self.hostWindow, self.window, self.window.hidden ? @"YES" : @"NO", ReportsDirectory().path, self.sessionID ?: @"NOT_AVAILABLE", self.lastPhase ?: @"NOT_AVAILABLE"];
}
- (void)manualDumpHierarchy { NSURL *url = [ReportsDirectory() URLByAppendingPathComponent:@"CURRENT_VIEW_HIERARCHY.txt"]; BOOL truncated = NO; NSUInteger count = LegacyWriteVisibleHierarchy(self.hostWindow, url, kFullCaptureMaxDepth, kFullCaptureMaxNodes, &truncated); if (self.sessionDirectory) { NSData *data = [NSData dataWithContentsOfURL:url]; [data writeToURL:[self sessionFile:@"VIEW_TREE_LEGACY.txt" folder:@"04_VIEWS"] options:NSDataWritingAtomic error:nil]; } WriteReport(@"CURRENT_VIEW_HIERARCHY_STATUS.txt", [NSString stringWithFormat:@"nodes=%lu LIMIT_REACHED=%@\n", (unsigned long)count, truncated ? @"YES" : @"NO"]); }
- (void)manualDumpControllers { NSURL *c = [ReportsDirectory() URLByAppendingPathComponent:@"CURRENT_CONTROLLERS.txt"]; NSURL *t = [ReportsDirectory() URLByAppendingPathComponent:@"CONTROLLER_TREE.txt"]; NSURL *m = [ReportsDirectory() URLByAppendingPathComponent:@"CONTROLLER_VIEW_MAP.txt"]; BOOL truncated = NO; NSUInteger duplicate = 0, depth = 0; LegacyWriteControllers(self.hostWindow, c, t, m, kFullCaptureMaxDepth, kFullCaptureMaxNodes, &truncated, &duplicate, &depth); }
- (void)manualDumpRuntimeDetails { NSURL *jsonl = [ReportsDirectory() URLByAppendingPathComponent:@"RUNTIME_CLASSES_DETAILED.jsonl"]; NSURL *text = [ReportsDirectory() URLByAppendingPathComponent:@"RUNTIME_CLASSES_DETAILED.txt"]; NSURL *summary = [ReportsDirectory() URLByAppendingPathComponent:@"RUNTIME_CLASSES_DETAILED_SUMMARY.json"]; LegacyWriteRuntimeDetails(jsonl, text, summary); }
- (void)manualDumpImages { NSURL *text = [ReportsDirectory() URLByAppendingPathComponent:@"LOADED_IMAGES.txt"]; NSURL *jsonl = [ReportsDirectory() URLByAppendingPathComponent:@"LOADED_IMAGES.jsonl"]; NSURL *summary = [ReportsDirectory() URLByAppendingPathComponent:@"LOADED_IMAGES_SUMMARY.json"]; LegacyWriteLoadedImages(text, jsonl, summary); }

#pragma mark - UI actions

- (void)hideOverlayForSystemUI { self.sharePresented = YES; self.window.hidden = YES; }
- (void)restoreOverlayAfterSystemUI { self.sharePresented = NO; if (self.started) self.window.hidden = NO; }
- (void)showInspectorPanel {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self showInspectorPanel]; }); return; }
    if (self.inspectorPanel.presentingViewController || self.collectionRunning) return;
    self.inspectorPanel = [UIAlertController alertControllerWithTitle:@"Universal UI Inspector" message:@"Legacy collectors with safe sequential export. Navigate normally during the 60-second warm-up." preferredStyle:UIAlertControllerStyleActionSheet];
    [self.inspectorPanel addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Target Class / Search"; field.text = self.selectedClassName ?: @""; }];
    __weak typeof(self) weakSelf = self;
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"PREPARE FULL CAPTURE" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf prepareFullCapture:NO]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"CAPTURE CURRENT SCREEN" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf captureSnapshot]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"EXPORT ALL RUNTIME" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf runOneButtonCollection]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"VIEW CAPTURE STATUS" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf showCaptureStatus]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"CANCEL CURRENT PHASE" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) { [weakSelf cancelCurrentPhase]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"SEARCH CLASS" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf searchClass:weakSelf.inspectorPanel.textFields.firstObject.text]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"EXPORT SELECTED CLASS" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf exportSelectedClass]; }]];
    [self.inspectorPanel addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = self.inspectorPanel.popoverPresentationController; popover.sourceView = self.button; popover.sourceRect = self.button.bounds; popover.permittedArrowDirections = UIPopoverArrowDirectionAny; [[self presenter] presentViewController:self.inspectorPanel animated:YES completion:nil];
}
- (void)showMenu {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self showMenu]; }); return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Universal UI Inspector" message:@"Read-only diagnostics" preferredStyle:UIAlertControllerStyleActionSheet]; __weak typeof(self) weakSelf = self;
    NSArray *items = @[ @[ @"Prepare Full Capture", ^{ [weakSelf prepareFullCapture:NO]; } ], @[ @"Capture Current Screen", ^{ [weakSelf captureSnapshot]; } ], @[ @"Stop Capture", ^{ [weakSelf cancelCurrentPhase]; } ], @[ @"Export Session", ^{ [weakSelf exportSession]; } ], @[ @"Choose Export Folder", ^{ [weakSelf chooseExportFolder]; } ], @[ @"Dump Visible Hierarchy", ^{ [weakSelf manualDumpHierarchy]; } ], @[ @"View Controllers", ^{ [weakSelf manualDumpControllers]; } ], @[ @"Runtime Classes (Detailed)", ^{ [weakSelf manualDumpRuntimeDetails]; } ], @[ @"Loaded Images", ^{ [weakSelf manualDumpImages]; } ], @[ @"Diagnostics", ^{ WriteReport(@"DIAGNOSTICS.txt", [weakSelf diagnostics]); } ] ];
    for (NSArray *item in items) [alert addAction:[UIAlertAction actionWithTitle:item[0] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { ((void (^)(void))item[1])(); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]]; UIPopoverPresentationController *popover = alert.popoverPresentationController; popover.sourceView = self.button; popover.sourceRect = self.button.bounds; [[self presenter] presentViewController:alert animated:YES completion:nil];
}
- (void)searchClass:(NSString *)query {
    if (!query.length) return;
    int count = objc_getClassList(NULL, 0); Class *classes = count > 0 ? (Class *)calloc((size_t)count, sizeof(Class)) : NULL; count = classes ? objc_getClassList(classes, count) : 0; NSMutableArray *matches = [NSMutableArray array]; NSString *needle = query.lowercaseString;
    for (int i = 0; i < count && matches.count < 200; i++) { NSString *name = UIIString(NSStringFromClass(classes[i])); if ([name.lowercaseString rangeOfString:needle].location != NSNotFound) [matches addObject:@{ @"name": name, @"superclass": UIIString(NSStringFromClass(class_getSuperclass(classes[i]))) }]; } free(classes);
    UIAlertController *result = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Matches: %lu", (unsigned long)matches.count] message:@"Runtime class names are process-wide; no unknown selectors are invoked." preferredStyle:UIAlertControllerStyleActionSheet]; __weak typeof(self) weakSelf = self;
    for (NSDictionary *match in matches) [result addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ : %@", match[@"name"], match[@"superclass"]] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { weakSelf.selectedClassName = match[@"name"]; }]];
    [result addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]]; [[self presenter] presentViewController:result animated:YES completion:nil];
}
- (void)captureSnapshot {
    if (!self.capturePrepared) { UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Preparation required" message:@"Run PREPARE FULL CAPTURE first; a minimum 60-second warm-up is required." preferredStyle:UIAlertControllerStyleAlert]; [alert addAction:[UIAlertAction actionWithTitle:@"PREPARE FULL CAPTURE" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self prepareFullCapture:NO]; }]]; [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]]; [[self presenter] presentViewController:alert animated:YES completion:nil]; return; }
    if (![SessionCapture shared].active) [SessionCapture shared].active = YES; NSTimeInterval started = CACurrentMediaTime(); [[SessionCapture shared] capture:self.hostWindow label:self.selectedClassName ?: [NSString stringWithFormat:@"screen-%@", DateString([NSDate date])] inspectorWindow:self.window]; self.lastPhase = @"snapshot"; [self appendPhaseLog:@"snapshot" line:[NSString stringWithFormat:@"END timestamp=%@ count=%lu elapsed_ms=%.1f", DateString([NSDate date]), (unsigned long)[SessionCapture shared].snapshots.count, (CACurrentMediaTime() - started) * 1000.0]]; UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Snapshot captured" message:[NSString stringWithFormat:@"Snapshots: %lu\nNavigate manually and capture again to accumulate screens.", (unsigned long)[SessionCapture shared].snapshots.count] preferredStyle:UIAlertControllerStyleAlert]; [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [[self presenter] presentViewController:alert animated:YES completion:nil];
}
- (void)prepareFullCapture:(BOOL)exportAfter {
    if (self.preparing || self.collectionRunning) return;
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self prepareFullCapture:exportAfter]; }); return; }
    self.preparing = YES; self.pendingExport = exportAfter; self.capturePrepared = NO; self.preparationStarted = CACurrentMediaTime(); self.lastPhase = @"warm-up"; [[SessionCapture shared] stop]; [self createSession];
    WriteJSONURL([self sessionRootFile:@"SESSION_STATE.json"], @{ @"sessionID": self.sessionID, @"status": @"preparing", @"minimumWarmupSeconds": @60, @"warmupStarted": DateString(self.sessionStartDate) });
    self.collectionAlert = [UIAlertController alertControllerWithTitle:@"Preparing runtime" message:@"00:00 / 01:00 — safe observation only\nNavigate through the app to load more modules." preferredStyle:UIAlertControllerStyleAlert]; [self.collectionAlert addAction:[UIAlertAction actionWithTitle:@"CANCEL CURRENT PHASE" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) { [self cancelCurrentPhase]; }]]; [[self presenter] presentViewController:self.collectionAlert animated:YES completion:nil]; self.preparationTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(preparationTick) userInfo:nil repeats:YES]; [self preparationTick];
}
- (void)preparationTick {
    if (!self.preparing) return;
    NSTimeInterval elapsed = CACurrentMediaTime() - self.preparationStarted; BOOL hostReady = self.hostWindow && self.hostWindow.rootViewController;
    self.collectionAlert.message = [NSString stringWithFormat:@"%02.0f:%02.0f / 01:00 — %@\nHost window/root: %@\nNavigate normally; no application navigation is forced.", floor(elapsed / 60.0), fmod(elapsed, 60.0), elapsed < 60.0 ? @"warming up" : @"warm-up complete", hostReady ? @"available" : @"waiting"];
    if (elapsed >= 60.0 && hostReady) {
        [self.preparationTimer invalidate]; self.preparationTimer = nil; self.preparing = NO; self.capturePrepared = YES; [[SessionCapture shared] capture:self.hostWindow label:@"BASELINE" inspectorWindow:self.window]; self.phaseStatuses[@"warmup"] = @"complete"; WriteJSONURL([self sessionRootFile:@"SESSION_INFO.json"], @{ @"schemaVersion": @"2.0", @"sessionID": self.sessionID, @"createdAt": DateString(self.sessionStartDate), @"warmupElapsedSeconds": @(elapsed), @"minimumWarmupSeconds": @60, @"status": @"prepared", @"baselineSnapshot": @YES }); [self updateSessionState]; if (self.collectionAlert.presentingViewController) { [self.collectionAlert dismissViewControllerAnimated:YES completion:^{ if (self.pendingExport) { self.pendingExport = NO; [self runOneButtonCollection]; } }]; } else if (self.pendingExport) { self.pendingExport = NO; [self runOneButtonCollection]; }
    }
}
- (void)showCaptureStatus {
    NSString *message = [NSString stringWithFormat:@"prepared=%@\npreparing=%@\nsession=%@\nsnapshots=%lu\nlast phase=%@\nelapsed=%.1fs\npartial session is preserved at %@", self.capturePrepared ? @"YES" : @"NO", self.preparing ? @"YES" : @"NO", self.sessionID ?: @"NOT_AVAILABLE", (unsigned long)[SessionCapture shared].snapshots.count, self.lastPhase ?: @"NOT_AVAILABLE", self.preparationStarted > 0 ? CACurrentMediaTime() - self.preparationStarted : 0, self.sessionDirectory.path ?: @"NOT_AVAILABLE"]; UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Capture status" message:message preferredStyle:UIAlertControllerStyleAlert]; [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [[self presenter] presentViewController:alert animated:YES completion:nil];
}
- (void)cancelCurrentPhase {
    self.collectionCancelled = YES; self.pendingExport = NO; [self.preparationTimer invalidate]; self.preparationTimer = nil; self.preparing = NO; self.lastPhase = @"cancelled"; [self appendPhaseLog:@"job" line:[NSString stringWithFormat:@"CANCEL timestamp=%@ phase=%@", DateString([NSDate date]), self.lastPhase]]; [self updateSessionState]; if (self.collectionAlert.presentingViewController) [self.collectionAlert dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Selected class/manual session export

- (void)exportSelectedClass {
    NSString *name = self.selectedClassName; if (!name.length) return; Class cls = NSClassFromString(name); if (!cls) return;
    NSMutableString *text = [NSMutableString stringWithFormat:@"SELECTED_CLASS.txt\nclass=%@\nsuperclass=%@\nimage=%s\n", name, UIIString(NSStringFromClass(class_getSuperclass(cls))), class_getImageName(cls) ?: "NOT_AVAILABLE"];
    unsigned methodCount = 0; Method *methods = class_copyMethodList(cls, &methodCount); for (unsigned i = 0; i < methodCount; i++) [text appendFormat:@"declared instance %@ %s %p\n", UIIString(NSStringFromSelector(method_getName(methods[i]))), method_getTypeEncoding(methods[i]) ?: "NOT_AVAILABLE", method_getImplementation(methods[i])]; free(methods);
    NSURL *stage = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString] isDirectory:YES]; [[NSFileManager defaultManager] createDirectoryAtURL:stage withIntermediateDirectories:YES attributes:nil error:nil]; WriteTextURL([stage URLByAppendingPathComponent:@"SELECTED_CLASS.txt"], text); WriteJSONURL([stage URLByAppendingPathComponent:@"SELECTED_CLASS.json"], @{ @"class": name, @"superclass": UIIString(NSStringFromClass(class_getSuperclass(cls))), @"metadataScope": @"declared Objective-C runtime metadata" }); WriteTextURL([stage URLByAppendingPathComponent:@"SURFACE_ANALYSIS.txt"], @"Analysis only; no application changes were made.\n");
    NSMutableDictionary *files = [NSMutableDictionary dictionary]; for (NSURL *url in [[NSFileManager defaultManager] contentsOfDirectoryAtURL:stage includingPropertiesForKeys:nil options:0 error:nil]) { NSData *data = [NSData dataWithContentsOfURL:url]; if (data) files[url.lastPathComponent] = data; } NSData *zip = ZipData(files); NSURL *url = [stage URLByAppendingPathComponent:@"SelectedClass.zip"]; [zip writeToURL:url options:NSDataWritingAtomic error:nil]; [self hideOverlayForSystemUI]; UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil]; share.completionWithItemsHandler = ^(__unused UIActivityType activity, __unused BOOL completed, __unused NSArray *items, __unused NSError *error) { [self restoreOverlayAfterSystemUI]; }; [[self presenter] presentViewController:share animated:YES completion:nil];
}
- (void)exportSession {
    dispatch_async(dispatch_get_main_queue(), ^{ NSError *error = nil; NSURL *stage = [[SessionCapture shared] stageSession:self.hostWindow error:&error]; if (!stage) { WriteReport(@"SESSION_EXPORT_ERROR.txt", error.localizedDescription ?: @"Unknown error"); return; } NSURL *zipURL = [stage URLByAppendingPathComponent:@"UniversalUIInspector-Session.zip"]; NSUInteger count = 0; NSString *why = nil; if (!StreamZipDirectory(stage, zipURL, &count, &why)) { WriteReport(@"SESSION_EXPORT_ERROR.txt", why ?: @"ZIP creation failed"); return; } [self hideOverlayForSystemUI]; UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[zipURL] applicationActivities:nil]; share.completionWithItemsHandler = ^(__unused UIActivityType activity, __unused BOOL completed, __unused NSArray *items, __unused NSError *error) { [self restoreOverlayAfterSystemUI]; }; [[self presenter] presentViewController:share animated:YES completion:nil]; });
}
- (void)chooseExportFolder { UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.folder"] inMode:UIDocumentPickerModeOpen]; picker.delegate = self; [self hideOverlayForSystemUI]; [[self presenter] presentViewController:picker animated:YES completion:nil]; }
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { [self restoreOverlayAfterSystemUI]; }
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls { NSURL *url = urls.firstObject; if (url && [url startAccessingSecurityScopedResource]) { self.selectedFolder = url; [self.startup appendFormat:@"Selected export folder: %@\n", url.path]; } [self restoreOverlayAfterSystemUI]; }
- (void)exportReports {
    NSArray *names = @[@"BOOT_DIAGNOSTICS.txt", @"RUNTIME_STARTUP_REPORT.txt", @"STARTUP_VIEW_TREE.txt", @"CURRENT_VIEW_HIERARCHY.txt", @"CURRENT_CONTROLLERS.txt", @"RUNTIME_CLASSES.txt", @"LOADED_IMAGES.txt", @"DIAGNOSTICS.txt"]; NSMutableDictionary *files = [NSMutableDictionary dictionary]; for (NSString *name in names) { NSData *data = [NSData dataWithContentsOfFile:ReportPath(name)]; if (data) files[name] = data; } NSData *zip = ZipData(files); NSURL *url = [ReportsDirectory() URLByAppendingPathComponent:@"UniversalUIInspector-Reports.zip"]; [zip writeToURL:url options:NSDataWritingAtomic error:nil]; [self hideOverlayForSystemUI]; UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil]; share.completionWithItemsHandler = ^(__unused UIActivityType activity, __unused BOOL completed, __unused NSArray *items, __unused NSError *error) { [self restoreOverlayAfterSystemUI]; }; [[self presenter] presentViewController:share animated:YES completion:nil];
}

#pragma mark - FINAL_LOG and sequential coordinator

- (NSArray *)generatedFiles {
    if (!self.sessionDirectory) return @[]; NSMutableArray *files = [NSMutableArray array]; NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtURL:self.sessionDirectory includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 errorHandler:^BOOL(NSURL *url, NSError *error) { return YES; }]; for (NSURL *url in enumerator) { NSNumber *isDirectory = nil; [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil]; if (!isDirectory.boolValue) [files addObject:[url.path substringFromIndex:self.sessionDirectory.path.length + 1]]; } return [files sortedArrayUsingSelector:@selector(compare:)];
}
- (void)writeFinalLogs:(NSString *)overallStatus {
    self.sessionEndDate = [NSDate date]; NSArray *files = [self generatedFiles]; NSTimeInterval duration = self.sessionStartDate ? [self.sessionEndDate timeIntervalSinceDate:self.sessionStartDate] : 0;
    NSDictionary *json = @{ @"schemaVersion": @"2.0", @"sessionID": self.sessionID ?: @"", @"startTime": DateString(self.sessionStartDate), @"endTime": DateString(self.sessionEndDate), @"durationSeconds": @(duration), @"appBundleIdentifier": UIIString(NSBundle.mainBundle.bundleIdentifier), @"appVersion": UIIString([NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]), @"device": UIIString(UIDevice.currentDevice.model), @"os": UIIString(UIDevice.currentDevice.systemVersion), @"runtimeClassCount": @(self.runtimeClassCount), @"protocolCount": @(self.protocolCount), @"loadedImageCount": @(self.loadedImageCount), @"windowCount": @(self.windowCount), @"controllerCount": @(self.controllerCount), @"viewCounts": @{ @"legacy": @(self.legacyViewCount), @"windows": @(self.windowViewCount), @"controllers": @(self.controllerViewCount), @"visibleController": @(self.visibleControllerViewCount) }, @"uniqueViewCount": @(self.uniqueViewCount), @"maximumDepthObserved": @(self.maximumDepthObserved), @"snapshotCount": @([SessionCapture shared].snapshots.count), @"filesGenerated": files ?: @[], @"filesFailed": self.filesFailed ?: @[], @"phasesCompleted": self.phasesCompleted ?: @[], @"phasesFailed": self.phasesFailed ?: @[], @"phasesSkipped": self.phasesSkipped ?: @[], @"limitsReached": self.limitsReached ?: @[], @"objectsSkipped": @(self.objectSkips), @"cycleDuplicateSkips": @(self.duplicateSkips), @"caughtErrorsExceptions": self.caughtErrors ?: @[], @"warnings": self.warnings ?: @[], @"timeouts": @[], @"zipStatus": self.zipStatus ?: @"pending", @"overallStatus": overallStatus ?: @"PARTIAL" };
    NSMutableString *text = [NSMutableString stringWithFormat:@"FINAL_LOG.txt\noverall_status=%@\nsession_id=%@\nstart_time=%@\nend_time=%@\nduration_seconds=%.3f\napp_bundle_identifier=%@\napp_version=%@\ndevice=%@\nos=%@\nruntime_class_count=%lu\nprotocol_count=%lu\nloaded_image_count=%lu\nwindow_count=%lu\ncontroller_count=%lu\nlegacy_view_count=%lu\nwindow_view_count=%lu\ncontroller_view_count=%lu\nvisible_controller_view_count=%lu\nunique_view_count=%lu\nmaximum_depth_observed=%lu\nsnapshot_count=%lu\nzip_status=%@\nobjects_skipped=%lu\ncycle_duplicate_skips=%lu\n", overallStatus ?: @"PARTIAL", self.sessionID ?: @"", DateString(self.sessionStartDate), DateString(self.sessionEndDate), duration, UIIString(NSBundle.mainBundle.bundleIdentifier), UIIString([NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]), UIIString(UIDevice.currentDevice.model), UIIString(UIDevice.currentDevice.systemVersion), (unsigned long)self.runtimeClassCount, (unsigned long)self.protocolCount, (unsigned long)self.loadedImageCount, (unsigned long)self.windowCount, (unsigned long)self.controllerCount, (unsigned long)self.legacyViewCount, (unsigned long)self.windowViewCount, (unsigned long)self.controllerViewCount, (unsigned long)self.visibleControllerViewCount, (unsigned long)self.uniqueViewCount, (unsigned long)self.maximumDepthObserved, (unsigned long)[SessionCapture shared].snapshots.count, self.zipStatus ?: @"pending", (unsigned long)self.objectSkips, (unsigned long)self.duplicateSkips];
    for (NSString *key in @[@"phasesCompleted", @"phasesFailed", @"phasesSkipped", @"limitsReached", @"filesFailed", @"warnings", @"caughtErrorsExceptions"]) [text appendFormat:@"%@=%@\n", key, [json[key] componentsJoinedByString:@" | "] ?: @"NONE"];
    [text appendFormat:@"files_generated=%@\n", [files componentsJoinedByString:@" | "] ?: @"NONE"];
    WriteTextURL([self sessionRootFile:@"FINAL_LOG.txt"], text); WriteJSONURL([self sessionRootFile:@"FINAL_LOG.json"], json); WriteReport(@"FINAL_LOG.txt", text); WriteJSONURL([ReportsDirectory() URLByAppendingPathComponent:@"FINAL_LOG.json"], json);
}
- (void)sanityCheck {
    if (self.runtimeClassCount > 0 && self.runtimeClassCount < 1000) { NSString *warning = [NSString stringWithFormat:@"WARNING_RUNTIME_CLASS_REGRESSION: captured only %lu classes; historical complex targets were on the order of 100k entries.", (unsigned long)self.runtimeClassCount]; if (![self.warnings containsObject:warning]) [self.warnings addObject:warning]; }
    NSUInteger totalViews = self.legacyViewCount + self.windowViewCount + self.controllerViewCount; if (totalViews > 0 && totalViews < 50) { NSString *warning = [NSString stringWithFormat:@"WARNING_VIEW_DUMP_SUSPICIOUSLY_SMALL: combined raw view collector count is %lu; inspect independent reports and LIMIT_REACHED.", (unsigned long)totalViews]; if (![self.warnings containsObject:warning]) [self.warnings addObject:warning]; }
    if (self.limitsReached.count) [self.warnings addObject:@"One or more high configurable safety limits were reached; output is marked partial/suspicious."];
}
- (void)runOneButtonCollection {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self runOneButtonCollection]; }); return; }
    if (self.collectionRunning || self.preparing) return;
    if (!self.capturePrepared || !self.sessionDirectory) { [self prepareFullCapture:YES]; return; }
    self.collectionRunning = YES; self.collectionCancelled = NO; self.zipStatus = @"pending";
    self.collectionAlert = [UIAlertController alertControllerWithTitle:@"EXPORT ALL RUNTIME" message:@"Phase 1/12 — Metadata" preferredStyle:UIAlertControllerStyleAlert]; __weak typeof(self) weakSelf = self; [self.collectionAlert addAction:[UIAlertAction actionWithTitle:@"CANCEL CURRENT PHASE" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) { weakSelf.collectionCancelled = YES; }]]; [[self presenter] presentViewController:self.collectionAlert animated:YES completion:nil]; dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self phaseMetadata]; });
}
- (BOOL)phaseCancelled { return self.collectionCancelled; }
- (void)phaseMetadata {
    if ([self phaseCancelled]) { [self finishCollectionWithError:@"cancelled before metadata"]; return; }
    [self beginPhase:@"metadata" message:@"Phase 1/12 — Session/app/device metadata"]; NSDate *now = [NSDate date]; WriteJSONURL([self sessionFile:@"SESSION_INFO.json" folder:@"00_METADATA"], @{ @"schemaVersion": @"2.0", @"sessionID": self.sessionID, @"startTime": DateString(self.sessionStartDate), @"metadataTime": DateString(now), @"warmupSeconds": @60, @"legacyCollectors": @YES }); self.phaseStatuses[@"metadata"] = @"complete"; [self endPhase:@"metadata" state:@"complete" count:1 bytes:0 warning:nil error:nil]; [self phaseLoadedImages];
}
- (void)phaseLoadedImages {
    if ([self phaseCancelled]) { [self finishCollectionWithError:@"cancelled before loaded images"]; return; }
    [self beginPhase:@"loaded_images" message:@"Phase 2/12 — Loaded Images / dyld"]; NSURL *text = [self sessionFile:@"LOADED_IMAGES.txt" folder:@"02_IMAGES"]; NSURL *jsonl = [self sessionFile:@"LOADED_IMAGES.jsonl" folder:@"02_IMAGES"]; NSURL *summary = [self sessionFile:@"LOADED_IMAGES_SUMMARY.json" folder:@"02_IMAGES"]; __weak typeof(self) weakSelf = self; dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ @autoreleasepool { @try { NSUInteger count = LegacyWriteLoadedImages(text, jsonl, summary); dispatch_async(dispatch_get_main_queue(), ^{ weakSelf.loadedImageCount = count; [weakSelf mirrorReport:@"LOADED_IMAGES.txt" from:text]; [weakSelf endPhase:@"loaded_images" state:@"complete" count:count bytes:(NSUInteger)[[[NSFileManager defaultManager] attributesOfItemAtPath:text.path error:nil][NSFileSize] unsignedLongLongValue] warning:nil error:nil]; [weakSelf phaseRuntimeIndex]; }); } @catch (NSException *exception) { dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf endPhase:@"loaded_images" state:@"failed" count:0 bytes:0 warning:nil error:exception.reason ?: @"exception"]; [weakSelf phaseRuntimeIndex]; }); } } });
}
- (void)phaseRuntimeIndex {
    if ([self phaseCancelled]) { [self finishCollectionWithError:@"cancelled before runtime class index"]; return; }
    [self beginPhase:@"runtime_classes" message:@"Phase 3/12 — Runtime Classes (complete index)"]; NSURL *jsonl = [self sessionFile:@"ALL_CLASSES.jsonl" folder:@"01_RUNTIME"]; NSURL *text = [self sessionFile:@"ALL_CLASSES.txt" folder:@"01_RUNTIME"]; NSURL *summary = [self sessionFile:@"CLASS_INDEX_SUMMARY.json" folder:@"01_RUNTIME"]; __weak typeof(self) weakSelf = self; dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ @autoreleasepool { @try { NSUInteger count = LegacyWriteRuntimeClassIndex(jsonl, text, summary); dispatch_async(dispatch_get_main_queue(), ^{ weakSelf.runtimeClassCount = count; [weakSelf mirrorReport:@"ALL_CLASSES.txt" from:text]; [weakSelf endPhase:@"runtime_classes" state:@"complete" count:count bytes:(NSUInteger)[[[NSFileManager defaultManager] attributesOfItemAtPath:text.path error:nil][NSFileSize] unsignedLongLongValue] warning:nil error:nil]; [weakSelf phaseProtocols]; }); } @catch (NSException *exception) { dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf endPhase:@"runtime_classes" state:@"failed" count:0 bytes:0 warning:@"WARNING_RUNTIME_CLASS_REGRESSION" error:exception.reason ?: @"exception"]; [weakSelf phaseProtocols]; }); } } });
}
- (void)phaseProtocols {
    if ([self phaseCancelled]) { [self finishCollectionWithError:@"cancelled before protocols"]; return; }
    [self beginPhase:@"protocols" message:@"Phase 4/12 — Protocol enumeration"]; NSURL *text = [self sessionFile:@"PROTOCOLS.txt" folder:@"01_RUNTIME"]; NSURL *jsonl = [self sessionFile:@"PROTOCOLS.jsonl" folder:@"01_RUNTIME"]; NSURL *summary = [self sessionFile:@"PROTOCOLS_SUMMARY.json" folder:@"01_RUNTIME"]; __weak typeof(self) weakSelf = self; dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ @autoreleasepool { @try { NSUInteger count = LegacyWriteProtocols(text, jsonl, summary); dispatch_async(dispatch_get_main_queue(), ^{ weakSelf.protocolCount = count; [weakSelf endPhase:@"protocols" state:@"complete" count:count bytes:0 warning:nil error:nil]; [weakSelf phaseRuntimeDetails]; }); } @catch (NSException *exception) { dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf endPhase:@"protocols" state:@"failed" count:0 bytes:0 warning:nil error:exception.reason ?: @"exception"]; [weakSelf phaseRuntimeDetails]; }); } } });
}
- (void)phaseRuntimeDetails {
    if ([self phaseCancelled]) { [self finishCollectionWithError:@"cancelled before runtime detail pass"]; return; }
    [self beginPhase:@"runtime_details" message:@"Phase 5/12 — Detailed Runtime Metadata (streamed)"]; NSURL *jsonl = [self sessionFile:@"DETAILED_CLASSES.jsonl" folder:@"01_RUNTIME"]; NSURL *text = [self sessionFile:@"DETAILED_CLASSES.txt" folder:@"01_RUNTIME"]; NSURL *summary = [self sessionFile:@"DETAILED_CLASSES_SUMMARY.json" folder:@"01_RUNTIME"]; __weak typeof(self) weakSelf = self; dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ @autoreleasepool { @try { NSUInteger count = LegacyWriteRuntimeDetails(jsonl, text, summary); dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf endPhase:@"runtime_details" state:@"complete" count:count bytes:0 warning:nil error:nil]; [weakSelf phaseControllers]; }); } @catch (NSException *exception) { dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf endPhase:@"runtime_details" state:@"failed" count:0 bytes:0 warning:@"Detailed enrichment failed; complete class index is preserved." error:exception.reason ?: @"exception"]; [weakSelf phaseControllers]; }); } } });
}
- (void)phaseControllers {
    if ([self phaseCancelled]) { [self finishCollectionWithError:@"cancelled before controllers"]; return; }
    [self beginPhase:@"controllers" message:@"Phase 6/12 — UIViewController enumeration"]; NSURL *controllers = [self sessionFile:@"CONTROLLERS.txt" folder:@"03_CONTROLLERS"]; NSURL *tree = [self sessionFile:@"CONTROLLER_TREE.txt" folder:@"03_CONTROLLERS"]; NSURL *map = [self sessionFile:@"CONTROLLER_VIEW_MAP.txt" folder:@"03_CONTROLLERS"]; __weak typeof(self) weakSelf = self; dispatch_async(dispatch_get_main_queue(), ^{ @try { BOOL truncated = NO; NSUInteger duplicates = 0, depth = 0; NSUInteger count = LegacyWriteControllers(weakSelf.hostWindow, controllers, tree, map, kFullCaptureMaxDepth, kFullCaptureMaxNodes, &truncated, &duplicates, &depth); weakSelf.controllerCount = count; weakSelf.duplicateSkips += duplicates; weakSelf.maximumDepthObserved = MAX(weakSelf.maximumDepthObserved, depth); if (truncated) [weakSelf.limitsReached addObject:@"controllers"]; [weakSelf endPhase:@"controllers" state:truncated ? @"partial" : @"complete" count:count bytes:0 warning:truncated ? @"LIMIT_REACHED controllers" : nil error:nil]; [weakSelf phaseWindows]; } @catch (NSException *exception) { [weakSelf endPhase:@"controllers" state:@"failed" count:0 bytes:0 warning:nil error:exception.reason ?: @"exception"]; [weakSelf phaseWindows]; } });
}
- (void)phaseWindows {
    if ([self phaseCancelled]) { [self finishCollectionWithError:@"cancelled before windows"]; return; }
    [self beginPhase:@"windows" message:@"Phase 7/12 — UIWindow scenes and recursive windows"]; NSURL *url = [self sessionFile:@"VIEW_TREE_WINDOWS.txt" folder:@"04_VIEWS"]; __weak typeof(self) weakSelf = self; dispatch_async(dispatch_get_main_queue(), ^{ @try { BOOL truncated = NO; NSUInteger windows = 0, duplicates = 0, depth = 0; NSUInteger count = LegacyWriteWindowHierarchy(url, kFullCaptureMaxDepth, kFullCaptureMaxNodes, &truncated, &windows, &duplicates, &depth); weakSelf.windowCount = windows; weakSelf.windowViewCount = count; weakSelf.duplicateSkips += duplicates; weakSelf.maximumDepthObserved = MAX(weakSelf.maximumDepthObserved, depth); if (truncated) [weakSelf.limitsReached addObject:@"windows"]; [weakSelf endPhase:@"windows" state:truncated ? @"partial" : @"complete" count:count bytes:0 warning:truncated ? @"LIMIT_REACHED windows" : nil error:nil]; [weakSelf phaseLegacyView]; } @catch (NSException *exception) { [weakSelf endPhase:@"windows" state:@"failed" count:0 bytes:0 warning:nil error:exception.reason ?: @"exception"]; [weakSelf phaseLegacyView]; } });
}
- (void)phaseLegacyView {
    if ([self phaseCancelled]) { [self finishCollectionWithError:@"cancelled before legacy view hierarchy"]; return; }
    [self beginPhase:@"view_legacy" message:@"Phase 8/12 — Legacy visible hierarchy"]; NSURL *url = [self sessionFile:@"VIEW_TREE_LEGACY.txt" folder:@"04_VIEWS"]; __weak typeof(self) weakSelf = self; dispatch_async(dispatch_get_main_queue(), ^{ @try { BOOL truncated = NO; NSUInteger count = LegacyWriteVisibleHierarchy(weakSelf.hostWindow, url, kFullCaptureMaxDepth, kFullCaptureMaxNodes, &truncated); weakSelf.legacyViewCount = count; weakSelf.uniqueViewCount = MAX(weakSelf.uniqueViewCount, count); if (truncated) [weakSelf.limitsReached addObject:@"view_legacy"]; [weakSelf mirrorReport:@"VIEW_TREE_LEGACY.txt" from:url]; [weakSelf endPhase:@"view_legacy" state:truncated ? @"partial" : @"complete" count:count bytes:0 warning:count < 50 ? @"WARNING_VIEW_DUMP_SUSPICIOUSLY_SMALL" : (truncated ? @"LIMIT_REACHED view_legacy" : nil) error:nil]; [weakSelf phaseSecondaryViews]; } @catch (NSException *exception) { [weakSelf endPhase:@"view_legacy" state:@"failed" count:0 bytes:0 warning:@"WARNING_VIEW_DUMP_SUSPICIOUSLY_SMALL" error:exception.reason ?: @"exception"]; [weakSelf phaseSecondaryViews]; } });
}
- (void)phaseSecondaryViews {
    if ([self phaseCancelled]) { [self finishCollectionWithError:@"cancelled before secondary view captures"]; return; }
    [self beginPhase:@"view_controller_roots" message:@"Phase 9/12 — Controller-root and visible-controller hierarchies"]; NSURL *controllerTree = [self sessionFile:@"VIEW_TREE_CONTROLLERS.txt" folder:@"04_VIEWS"]; NSURL *visibleTree = [self sessionFile:@"VIEW_TREE_VISIBLE_CONTROLLER.txt" folder:@"04_VIEWS"]; __weak typeof(self) weakSelf = self; dispatch_async(dispatch_get_main_queue(), ^{ @try { BOOL truncated = NO; NSUInteger duplicates = 0, depth = 0; NSUInteger count = LegacyWriteControllerViewHierarchy(weakSelf.hostWindow, controllerTree, kFullCaptureMaxDepth, kFullCaptureMaxNodes, &truncated, &duplicates, &depth); weakSelf.controllerViewCount = count; weakSelf.visibleControllerViewCount = count; weakSelf.duplicateSkips += duplicates; weakSelf.maximumDepthObserved = MAX(weakSelf.maximumDepthObserved, depth); [[NSFileManager defaultManager] removeItemAtURL:visibleTree error:nil]; [[NSFileManager defaultManager] copyItemAtURL:controllerTree toURL:visibleTree error:nil]; if (truncated) [weakSelf.limitsReached addObject:@"view_controller_roots"]; [weakSelf endPhase:@"view_controller_roots" state:truncated ? @"partial" : @"complete" count:count bytes:0 warning:truncated ? @"LIMIT_REACHED view_controller_roots" : nil error:nil]; [weakSelf phaseDiagnostics]; } @catch (NSException *exception) { [weakSelf endPhase:@"view_controller_roots" state:@"failed" count:0 bytes:0 warning:nil error:exception.reason ?: @"exception"]; [weakSelf phaseDiagnostics]; } });
}
- (void)phaseDiagnostics {
    if ([self phaseCancelled]) { [self finishCollectionWithError:@"cancelled before diagnostics"]; return; }
    [self beginPhase:@"diagnostics" message:@"Phase 10/12 — Diagnostics and sanity checks"]; [self sanityCheck]; NSString *warnings = self.warnings.count ? [self.warnings componentsJoinedByString:@"\n"] : @"NONE"; WriteTextURL([self sessionFile:@"WARNINGS.txt" folder:@"06_DIAGNOSTICS"], warnings); WriteTextURL([self sessionFile:@"BOOT_DIAGNOSTICS.txt" folder:@"06_DIAGNOSTICS"], [self.startup copy]); WriteTextURL([self sessionFile:@"RUNTIME_STARTUP_REPORT.txt" folder:@"06_DIAGNOSTICS"], [NSString stringWithFormat:@"runtimeClassCount=%lu\nloadedImageCount=%lu\nwindowCount=%lu\ncontrollerCount=%lu\n", (unsigned long)self.runtimeClassCount, (unsigned long)self.loadedImageCount, (unsigned long)self.windowCount, (unsigned long)self.controllerCount]); WriteTextURL([self sessionFile:@"STARTUP_VIEW_TREE.txt" folder:@"06_DIAGNOSTICS"], [NSString stringWithContentsOfURL:[ReportsDirectory() URLByAppendingPathComponent:@"STARTUP_VIEW_TREE.txt"] encoding:NSUTF8StringEncoding error:nil] ?: @"NOT_AVAILABLE\n"); WriteTextURL([self sessionFile:@"DIAGNOSTICS.txt" folder:@"06_DIAGNOSTICS"], [self diagnostics]); [self endPhase:@"diagnostics" state:@"complete" count:self.warnings.count bytes:0 warning:self.warnings.count ? @"Warnings recorded; inspect WARNINGS.txt" : nil error:nil]; [self phaseSummary];
}
- (void)phaseSummary {
    [self beginPhase:@"summary" message:@"Phase 11/12 — Summary and final logs"]; [self writeFinalLogs:self.phasesFailed.count ? @"PARTIAL" : @"PARTIAL"]; [self endPhase:@"summary" state:@"complete" count:self.generatedFiles.count bytes:0 warning:nil error:nil]; [self phaseZip];
}
- (void)phaseZip {
    if ([self phaseCancelled]) { [self finishCollectionWithError:@"cancelled before ZIP creation"]; return; }
    [self beginPhase:@"zip" message:@"Phase 12/12 — Creating RuntimeDump ZIP (streaming)"]; NSURL *directory = self.sessionDirectory; NSURL *parent = [directory URLByDeletingLastPathComponent]; NSURL *zipURL = [parent URLByAppendingPathComponent:[NSString stringWithFormat:@"RuntimeDump_%@.zip", self.sessionID]]; __weak typeof(self) weakSelf = self; dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ @autoreleasepool { NSString *errorText = nil; NSUInteger fileCount = 0; weakSelf.zipStatus = @"creating"; [weakSelf writeFinalLogs:weakSelf.phasesFailed.count ? @"PARTIAL" : @"PARTIAL"]; BOOL firstPass = StreamZipDirectory(directory, zipURL, &fileCount, &errorText); if (firstPass) { weakSelf.zipStatus = @"complete"; [weakSelf writeFinalLogs:weakSelf.phasesFailed.count ? @"PARTIAL" : @"COMPLETE"]; errorText = nil; firstPass = StreamZipDirectory(directory, zipURL, &fileCount, &errorText); } dispatch_async(dispatch_get_main_queue(), ^{ weakSelf.zipURL = firstPass ? zipURL : nil; weakSelf.zipStatus = firstPass ? @"complete" : @"failed"; [weakSelf endPhase:@"zip" state:firstPass ? @"complete" : @"failed" count:fileCount bytes:0 warning:nil error:firstPass ? nil : (errorText ?: @"ZIP creation failed")]; if (firstPass) { NSUInteger verifiedCount = 0; NSString *reason = nil; NSData *zipData = [NSData dataWithContentsOfURL:zipURL]; BOOL valid = ValidateZipArchive(zipData, &verifiedCount, &reason); [weakSelf endPhase:@"zip" state:valid ? @"complete" : @"partial" count:verifiedCount bytes:zipData.length warning:valid ? nil : @"ZIP verification failed" error:valid ? nil : reason]; [weakSelf finishCollectionWithURL:zipURL error:valid ? nil : reason]; } else { [weakSelf finishCollectionWithURL:nil error:errorText ?: @"ZIP creation failed"]; } }); } });
}
- (void)finishCollectionWithError:(NSString *)error { [self finishCollectionWithURL:nil error:error]; }
- (void)finishCollectionWithURL:(NSURL *)url error:(NSString *)error {
    if (error.length) { [self.caughtErrors addObject:error]; self.zipStatus = url ? self.zipStatus : @"failed"; }
    self.collectionRunning = NO; self.sessionEndDate = [NSDate date]; [self writeFinalLogs:error.length ? @"PARTIAL" : @"COMPLETE"]; [self updateSessionState];
    if (self.collectionAlert.presentingViewController) { NSString *message = error.length ? [NSString stringWithFormat:@"Partial session preserved.\n%@\n%@", error, self.sessionDirectory.path] : [NSString stringWithFormat:@"Export complete.\n%@\nZIP: %@", self.sessionDirectory.path, url.path]; [self.collectionAlert dismissViewControllerAnimated:YES completion:^{ if (url) { [self hideOverlayForSystemUI]; UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil]; share.completionWithItemsHandler = ^(__unused UIActivityType activity, __unused BOOL completed, __unused NSArray *items, __unused NSError *shareError) { [self restoreOverlayAfterSystemUI]; }; [[self presenter] presentViewController:share animated:YES completion:nil]; } else { UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Partial capture preserved" message:message preferredStyle:UIAlertControllerStyleAlert]; [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [[self presenter] presentViewController:alert animated:YES completion:nil]; } }]; }
}
@end

static void UniversalUIInspectorInit(void) { dispatch_async(dispatch_get_main_queue(), ^{ InspectorCore *core = InspectorCore.shared; for (NSNumber *delay in @[@0.5, @1.0, @2.0, @4.0]) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (!core.started) [core start]; }); }); }
__attribute__((constructor)) static void UniversalUIInspectorConstructor(void) { UniversalUIInspectorInit(); }
