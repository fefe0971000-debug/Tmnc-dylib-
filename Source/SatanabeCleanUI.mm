#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>

static NSString * const SCUIPrefsKey = @"com.satanabe.cleanui.v5.8";
static const void *SCUIOriginalHiddenKey = &SCUIOriginalHiddenKey;
static const void *SCUIGlassOverlayKey = &SCUIGlassOverlayKey;
static const void *SCUIOriginalBorderWidthKey = &SCUIOriginalBorderWidthKey;
static const void *SCUIOriginalBorderColorKey = &SCUIOriginalBorderColorKey;
static const void *SCUIOriginalCornerRadiusKey = &SCUIOriginalCornerRadiusKey;

static NSMutableDictionary *SCUIPrefs(void) {
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:SCUIPrefsKey];
    NSMutableDictionary *p = [@{
        @"glass": @NO,
        @"videoEnabled": @YES,
        @"videoMode": @0,
        @"glassIntensity": @0.62,
        @"cardColor": @[@0.08,@0.08,@0.08,@0.58],
        @"accentColor": @[@1.0,@1.0,@1.0,@1.0],
        @"bubbleX": @0.92,
        @"bubbleY": @0.28,
        @"bubbleSize": @56.0,
        @"bubbleOpacity": @0.90,
        @"cardRadius": @20.0,
        @"borderWidth": @0.55,
        @"haptics": @YES,
        @"performanceMode": @NO,
        @"apiRoutingEnabled": @NO,
        @"apiProfile": @0,
        @"apiAURL": @"https://api-production-182c.up.railway.app",
        @"apiBURL": @"",
        @"apiCustomURL": @"",
        @"apiSourceHost": @"",
        @"apiPathFilter": @"/api/license/validate,/api/patches,/api/patches/external,/functions/v1/Validate-licenses,/functions/v1/validate-license",
        @"apiPreservePath": @YES,
        @"localLicenseBypass": @NO,
        @"apiLoggerEnabled": @YES,
        @"apiLoggerCaptureBodies": @YES
    } mutableCopy];
    if (saved) [p addEntriesFromDictionary:saved];
    return p;
}

static void SCUISave(NSDictionary *p) {
    [[NSUserDefaults standardUserDefaults] setObject:p forKey:SCUIPrefsKey];
}

static UIColor *SCUIColorFromArray(NSArray *a, UIColor *fallback) {
    if (![a isKindOfClass:NSArray.class] || a.count < 4) return fallback;
    return [UIColor colorWithRed:[a[0] doubleValue]
                           green:[a[1] doubleValue]
                            blue:[a[2] doubleValue]
                           alpha:[a[3] doubleValue]];
}

static NSArray *SCUIArrayFromColor(UIColor *color) {
    CGFloat r=0,g=0,b=0,a=1;
    UIColor *c = color ?: UIColor.whiteColor;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat w=0;
        if ([c getWhite:&w alpha:&a]) r=g=b=w;
    }
    return @[@(r),@(g),@(b),@(a)];
}

static NSArray<UIWindow *> *SCUIWindows(void) {
    NSMutableArray *result = [NSMutableArray array];
    UIApplication *app = UIApplication.sharedApplication;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        [result addObjectsFromArray:ws.windows];
    }
    return result;
}

@interface SCUICustomVideoLayer : AVPlayerLayer @end
@implementation SCUICustomVideoLayer @end

static void SCUIVisitLayers(CALayer *layer, void (^block)(CALayer *)) {
    if (!layer) return;
    block(layer);
    for (CALayer *child in [layer.sublayers copy]) SCUIVisitLayers(child, block);
}

static void SCUISetHostVideosHidden(UIWindow *window, BOOL hidden) {
    SCUIVisitLayers(window.layer, ^(CALayer *layer) {
        if (![layer isKindOfClass:AVPlayerLayer.class]) return;
        if ([layer isKindOfClass:SCUICustomVideoLayer.class]) return;
        NSNumber *stored = objc_getAssociatedObject(layer, SCUIOriginalHiddenKey);
        if (!stored) {
            objc_setAssociatedObject(layer, SCUIOriginalHiddenKey, @(layer.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            stored = @(layer.hidden);
        }
        layer.hidden = hidden ? YES : stored.boolValue;
    });
}

static BOOL SCUIIsExcludedView(UIView *v) {
    return [v isKindOfClass:UILabel.class] ||
           [v isKindOfClass:UIImageView.class] ||
           [v isKindOfClass:UIControl.class] ||
           [v isKindOfClass:UIVisualEffectView.class] ||
           [v isKindOfClass:UIStackView.class] ||
           [v isKindOfClass:UIScrollView.class] ||
           [v isKindOfClass:UIWindow.class];
}

static BOOL SCUILooksLikeCard(UIView *v, UIWindow *window) {
    if (!v || v.hidden || v.alpha < 0.05 || SCUIIsExcludedView(v)) return NO;
    if (v.window != window) return NO;
    CGRect r = [v convertRect:v.bounds toView:window];
    if (r.size.width < window.bounds.size.width * 0.70) return NO;
    if (r.size.height < 58 || r.size.height > 230) return NO;
    if (r.origin.y < window.safeAreaInsets.top + 70) return NO;
    NSString *name = NSStringFromClass(v.class);
    if ([name containsString:@"SCUI"]) return NO;
    CGFloat radius = v.layer.cornerRadius;
    UIColor *bg = v.backgroundColor;
    CGFloat alpha = CGColorGetAlpha(bg.CGColor ?: UIColor.clearColor.CGColor);
    return radius >= 12.0 || alpha >= 0.18;
}

static void SCUIRemoveGlassFromView(UIView *v) {
    UIView *overlay = objc_getAssociatedObject(v, SCUIGlassOverlayKey);
    if (overlay) {
        [overlay removeFromSuperview];
        objc_setAssociatedObject(v, SCUIGlassOverlayKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    NSNumber *bw = objc_getAssociatedObject(v, SCUIOriginalBorderWidthKey);
    id bc = objc_getAssociatedObject(v, SCUIOriginalBorderColorKey);
    if (bw) v.layer.borderWidth = bw.doubleValue;
    if ([bc isKindOfClass:UIColor.class]) v.layer.borderColor = ((UIColor *)bc).CGColor;
    else if (bc == NSNull.null) v.layer.borderColor = nil;
    NSNumber *cr = objc_getAssociatedObject(v, SCUIOriginalCornerRadiusKey);
    if (cr) v.layer.cornerRadius = cr.doubleValue;
}

static void SCUIApplyGlassToView(UIView *v, UIColor *cardColor, UIColor *accent, CGFloat intensity, CGFloat radius, CGFloat borderWidth) {
    if (objc_getAssociatedObject(v, SCUIGlassOverlayKey)) return;
    objc_setAssociatedObject(v, SCUIOriginalBorderWidthKey, @(v.layer.borderWidth), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (v.layer.borderColor) {
        UIColor *colorObj = [UIColor colorWithCGColor:v.layer.borderColor];
        objc_setAssociatedObject(v, SCUIOriginalBorderColorKey, colorObj, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        objc_setAssociatedObject(v, SCUIOriginalBorderColorKey, NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIBlurEffectStyle style = UIBlurEffectStyleSystemUltraThinMaterialDark;
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:style]];
    blur.userInteractionEnabled = NO;
    blur.frame = v.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.alpha = MAX(0.15, MIN(1.0, intensity));
    if (!objc_getAssociatedObject(v, SCUIOriginalCornerRadiusKey)) {
        objc_setAssociatedObject(v, SCUIOriginalCornerRadiusKey, @(v.layer.cornerRadius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    blur.layer.cornerRadius = MAX(radius, v.layer.cornerRadius);
    blur.clipsToBounds = YES;
    UIView *tint = [[UIView alloc] initWithFrame:blur.bounds];
    tint.userInteractionEnabled = NO;
    tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tint.backgroundColor = cardColor;
    [blur.contentView addSubview:tint];
    [v insertSubview:blur atIndex:0];
    v.layer.cornerRadius = MAX(radius, v.layer.cornerRadius);
    v.layer.borderWidth = MAX(0.0, MIN(3.0, borderWidth));
    v.layer.borderColor = [accent colorWithAlphaComponent:0.34].CGColor;
    objc_setAssociatedObject(v, SCUIGlassOverlayKey, blur, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void SCUIWalkViews(UIView *v, void (^block)(UIView *)) {
    if (!v) return;
    NSArray<UIView *> *children = [v.subviews copy];
    block(v);
    if ([v isKindOfClass:UIVisualEffectView.class]) return;
    for (UIView *child in children) {
        if ([child isKindOfClass:UIVisualEffectView.class]) continue;
        SCUIWalkViews(child, block);
    }
}

#pragma mark - API Logger

static BOOL SCUILocalLicenseBypassEnabled(void);
static BOOL SCUIIsLicenseValidationURL(NSURL *url);

static NSString * const SCUILoggerHandledKey = @"SCUIAPILoggerHandled";
static NSString * const SCUILoggerFileName = @"SCUI-API-Logger.jsonl";

static BOOL SCUIAPILoggerEnabled(void) {
    return [SCUIPrefs()[@"apiLoggerEnabled"] boolValue];
}

static BOOL SCUIAPILoggerCaptureBodies(void) {
    return [SCUIPrefs()[@"apiLoggerCaptureBodies"] boolValue];
}

static NSString *SCUILoggerPath(void) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (!dir.length) dir = NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:SCUILoggerFileName];
}

static NSString *SCUIStringFromData(NSData *data) {
    if (!data.length) return @"";
    NSUInteger max = MIN((NSUInteger)262144, data.length);
    NSData *slice = [data subdataWithRange:NSMakeRange(0, max)];
    NSString *text = [[NSString alloc] initWithData:slice encoding:NSUTF8StringEncoding];
    if (!text) return [NSString stringWithFormat:@"<binary %lu bytes>", (unsigned long)data.length];
    if (data.length > max) text = [text stringByAppendingFormat:@"\n<truncated: %lu total bytes>", (unsigned long)data.length];
    return text;
}

static NSDictionary *SCUISafeHeaders(NSDictionary *headers) {
    if (![headers isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    [headers enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        NSString *k = [key description] ?: @"";
        NSString *lower = k.lowercaseString;
        if ([lower containsString:@"authorization"] ||
            [lower containsString:@"cookie"] ||
            [lower containsString:@"token"] ||
            [lower containsString:@"secret"]) {
            out[k] = @"<redacted>";
        } else {
            out[k] = [obj description] ?: @"";
        }
    }];
    return out;
}

static void SCUIAppendAPILog(NSDictionary *entry) {
    if (!entry) return;
    NSMutableDictionary *record = [entry mutableCopy];
    record[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
    NSData *json = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    if (!json.length) return;
    NSMutableData *line = [json mutableCopy];
    [line appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];

    @synchronized(NSFileManager.defaultManager) {
        NSString *path = SCUILoggerPath();
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            [line writeToFile:path atomically:YES];
        } else {
            NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
            @try {
                [h seekToEndOfFile];
                [h writeData:line];
                [h closeFile];
            } @catch (__unused NSException *e) {
                [h closeFile];
            }
        }
    }
}

static NSArray<NSDictionary *> *SCUIReadAPILogs(void) {
    NSData *data = [NSData dataWithContentsOfFile:SCUILoggerPath()];
    if (!data.length) return @[];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (!line.length) continue;
        NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
        id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if ([obj isKindOfClass:NSDictionary.class]) [items addObject:obj];
    }
    return items;
}

static NSString *SCUIPrettyLog(NSDictionary *log) {
    if (!log) return @"";
    NSData *d = [NSJSONSerialization dataWithJSONObject:log options:NSJSONWritingPrettyPrinted error:nil];
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: [log description];
}

static void SCUICollectURLsFromFile(NSString *path, NSMutableOrderedSet<NSString *> *urls) {
    if (!path.length || !urls) return;
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
    if (!data.length) return;
    NSString *blob = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!blob.length) return;
    NSError *regexError = nil;
    NSRegularExpression *regex =
        [NSRegularExpression regularExpressionWithPattern:@"https?://[^\\\\x00\\\\s\\\"'<>]+"
                                                  options:NSRegularExpressionCaseInsensitive
                                                    error:&regexError];
    if (!regex || regexError) return;
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:blob options:0 range:NSMakeRange(0, blob.length)];
    for (NSTextCheckingResult *result in matches) {
        if (!result || result.range.location == NSNotFound) continue;
        NSString *value = [blob substringWithRange:result.range];
        while (value.length && ([value hasSuffix:@"."] || [value hasSuffix:@","] ||
               [value hasSuffix:@")"] || [value hasSuffix:@"]"] || [value hasSuffix:@"}"])) {
            value = [value substringToIndex:value.length - 1];
        }
        if (value.length) [urls addObject:value];
    }
}

static NSArray<NSString *> *SCUIStaticURLInventory(void) {
    NSMutableOrderedSet<NSString *> *urls = [NSMutableOrderedSet orderedSet];
    SCUICollectURLsFromFile(NSBundle.mainBundle.executablePath, urls);
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *path = [NSString stringWithUTF8String:name];
        if (path.length) SCUICollectURLsFromFile(path, urls);
    }
    return urls.array;
}

static void SCUILogStaticURLInventory(void) {
    NSArray<NSString *> *urls = SCUIStaticURLInventory();
    for (NSString *url in urls) {
        SCUIAppendAPILog(@{
            @"event": @"static_url", @"method": @"STATIC",
            @"url": url ?: @"", @"source": @"loaded_macho_inventory"
        });
    }
}

static NSString *SCUIFindStringForKeys(id obj, NSSet<NSString *> *wanted) {
    if (!obj || !wanted.count) return nil;
    if ([obj isKindOfClass:NSDictionary.class]) {
        for (id rawKey in [(NSDictionary *)obj allKeys]) {
            NSString *key = [[rawKey description] lowercaseString];
            id value = ((NSDictionary *)obj)[rawKey];
            if ([wanted containsObject:key] && [value isKindOfClass:NSString.class] && [value length]) return value;
            NSString *nested = SCUIFindStringForKeys(value, wanted);
            if (nested.length) return nested;
        }
    } else if ([obj isKindOfClass:NSArray.class]) {
        for (id value in (NSArray *)obj) {
            NSString *nested = SCUIFindStringForKeys(value, wanted);
            if (nested.length) return nested;
        }
    }
    return nil;
}

static NSString *SCUILicenseKeyFromRequest(NSURLRequest *request) {
    NSSet *wanted = [NSSet setWithArray:@[@"key", @"licensekey", @"license_key", @"license", @"code", @"activationkey", @"activation_key"]];
    if (request.HTTPBody.length) {
        id json = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:NULL];
        NSString *hit = SCUIFindStringForKeys(json, wanted);
        if (hit.length) return hit;
        NSString *body = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding];
        if (body.length) {
            NSURLComponents *fake = [NSURLComponents componentsWithString:[@"https://local.invalid/?" stringByAppendingString:body]];
            for (NSURLQueryItem *item in fake.queryItems ?: @[]) {
                if ([wanted containsObject:item.name.lowercaseString] && item.value.length) return item.value;
            }
        }
    }
    NSURLComponents *components = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        if ([wanted containsObject:item.name.lowercaseString] && item.value.length) return item.value;
    }
    NSDictionary *headers = request.allHTTPHeaderFields ?: @{};
    for (NSString *name in headers) {
        NSString *lower = name.lowercaseString;
        if ([wanted containsObject:lower] || [lower containsString:@"license-key"] || [lower containsString:@"activation-key"]) {
            NSString *value = [headers[name] description];
            if (value.length) return value;
        }
    }
    return nil;
}

static NSNumber *SCUIFindBoolForKeys(id obj, NSSet<NSString *> *wanted) {
    if (!obj || !wanted.count) return nil;
    if ([obj isKindOfClass:NSDictionary.class]) {
        for (id rawKey in [(NSDictionary *)obj allKeys]) {
            NSString *key = [[rawKey description] lowercaseString];
            id value = ((NSDictionary *)obj)[rawKey];
            if ([wanted containsObject:key] && [value respondsToSelector:@selector(boolValue)]) return @([value boolValue]);
            NSNumber *nested = SCUIFindBoolForKeys(value, wanted);
            if (nested) return nested;
        }
    } else if ([obj isKindOfClass:NSArray.class]) {
        for (id value in (NSArray *)obj) {
            NSNumber *nested = SCUIFindBoolForKeys(value, wanted);
            if (nested) return nested;
        }
    }
    return nil;
}

static NSString *SCUIValidationResultFromData(NSData *data, NSInteger statusCode) {
    if (data.length) {
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        NSNumber *valid = SCUIFindBoolForKeys(json, [NSSet setWithArray:@[@"valid", @"success", @"ok", @"authorized", @"active"]]);
        if (valid) return valid.boolValue ? @"VALID" : @"INVALID";
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].lowercaseString;
        if ([text containsString:@"invalid"] || [text containsString:@"inválid"] ||
            [text containsString:@"expired"] || [text containsString:@"expirad"] ||
            [text containsString:@"revoked"] || [text containsString:@"revogad"]) return @"INVALID";
        if ([text containsString:@"valid"] || [text containsString:@"ativad"] ||
            [text containsString:@"authorized"] || [text containsString:@"success"]) return @"VALID";
    }
    if (statusCode == 401 || statusCode == 403 || statusCode == 422) return @"INVALID";
    return nil;
}

static NSDictionary *SCUILatestAPILog(void) {
    return SCUIReadAPILogs().lastObject;
}

@interface SCUIAPILoggerProtocol : NSURLProtocol <NSURLSessionDataDelegate>
@property(nonatomic, strong) NSURLSession *forwardSession;
@property(nonatomic, strong) NSURLSessionDataTask *forwardTask;
@property(nonatomic, strong) NSMutableData *responseData;
@property(nonatomic, strong) NSURLResponse *capturedResponse;
@property(nonatomic, assign) NSTimeInterval startedAt;
@property(nonatomic, copy) NSString *requestID;
@end

@implementation SCUIAPILoggerProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!SCUIAPILoggerEnabled()) return NO;
    if ([NSURLProtocol propertyForKey:SCUILoggerHandledKey inRequest:request]) return NO;
    NSString *scheme = request.URL.scheme.lowercaseString ?: @"";
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

- (void)startLoading {
    self.startedAt = [NSDate date].timeIntervalSince1970;
    self.responseData = [NSMutableData data];
    self.requestID = NSUUID.UUID.UUIDString;
    NSMutableURLRequest *req = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:SCUILoggerHandledKey inRequest:req];
    NSMutableDictionary *requestLog = [NSMutableDictionary dictionary];
    requestLog[@"event"] = @"request";
    requestLog[@"method"] = req.HTTPMethod ?: @"GET";
    requestLog[@"url"] = req.URL.absoluteString ?: @"";
    requestLog[@"headers"] = SCUISafeHeaders(req.allHTTPHeaderFields ?: @{});
    requestLog[@"requestId"] = self.requestID ?: @"";
    NSString *licenseKey = SCUILicenseKeyFromRequest(req);
    if (licenseKey.length) requestLog[@"licenseKey"] = licenseKey;
    if (SCUIAPILoggerCaptureBodies() && req.HTTPBody.length) requestLog[@"body"] = SCUIStringFromData(req.HTTPBody);
    SCUIAppendAPILog(requestLog);
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.protocolClasses = @[];
    self.forwardSession = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    self.forwardTask = [self.forwardSession dataTaskWithRequest:req];
    [self.forwardTask resume];
}

- (void)stopLoading {
    [self.forwardTask cancel];
    [self.forwardSession invalidateAndCancel];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    self.capturedResponse = response;
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (data.length) {
        [self.responseData appendData:data];
        [self.client URLProtocol:self didLoadData:data];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSMutableDictionary *responseLog = [NSMutableDictionary dictionary];
    responseLog[@"event"] = @"response";
    responseLog[@"method"] = self.request.HTTPMethod ?: @"GET";
    responseLog[@"url"] = self.request.URL.absoluteString ?: @"";
    responseLog[@"elapsedMs"] = @((NSInteger)(([NSDate date].timeIntervalSince1970 - self.startedAt) * 1000.0));
    if ([self.capturedResponse isKindOfClass:NSHTTPURLResponse.class]) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)self.capturedResponse;
        responseLog[@"status"] = @(http.statusCode);
        responseLog[@"headers"] = SCUISafeHeaders(http.allHeaderFields ?: @{});
    }
    responseLog[@"requestId"] = self.requestID ?: @"";
    if (SCUIAPILoggerCaptureBodies() && self.responseData.length) responseLog[@"body"] = SCUIStringFromData(self.responseData);
    NSString *licenseKey = SCUILicenseKeyFromRequest(self.request);
    if (licenseKey.length) responseLog[@"licenseKey"] = licenseKey;
    if (SCUIAPILoggerCaptureBodies() && self.request.HTTPBody.length) {
        responseLog[@"requestBody"] = SCUIStringFromData(self.request.HTTPBody) ?: @"";
    }
    NSInteger statusCode = 0;
    if ([self.capturedResponse isKindOfClass:NSHTTPURLResponse.class]) {
        statusCode = ((NSHTTPURLResponse *)self.capturedResponse).statusCode;
    }
    NSString *validation = SCUIValidationResultFromData(self.responseData, statusCode);
    if (validation.length) responseLog[@"validationResult"] = validation;
    if (self.responseData.length) {
        id responseJSON = [NSJSONSerialization JSONObjectWithData:self.responseData options:0 error:NULL];
        if ([responseJSON isKindOfClass:NSDictionary.class]) {
            NSDictionary *dict = (NSDictionary *)responseJSON;
            id message = dict[@"message"] ?: dict[@"error"] ?: dict[@"detail"];
            if (message) responseLog[@"serverMessage"] = [message description];
        }
    }
    if (error) responseLog[@"error"] = error.localizedDescription ?: @"unknown";
    SCUIAppendAPILog(responseLog);
    if (error) [self.client URLProtocol:self didFailWithError:error];
    else [self.client URLProtocolDidFinishLoading:self];
    [self.forwardSession finishTasksAndInvalidate];
}
@end

static void SCUIAddLoggerProtocolToConfiguration(NSURLSessionConfiguration *cfg) {
    if (!cfg) return;
    NSMutableArray *classes = [cfg.protocolClasses mutableCopy] ?: [NSMutableArray array];
    if (![classes containsObject:SCUIAPILoggerProtocol.class]) [classes addObject:SCUIAPILoggerProtocol.class];
    cfg.protocolClasses = classes;
}

#pragma mark - Local License Test Mode

static BOOL SCUILocalLicenseBypassEnabled(void) {
    return [SCUIPrefs()[@"localLicenseBypass"] boolValue];
}

static BOOL SCUIIsLicenseValidationURL(NSURL *url) {
    if (!url) return NO;
    NSString *path = url.path.lowercaseString ?: @"";
    return [path isEqualToString:@"/api/license/validate"] || [path hasSuffix:@"/api/license/validate"];
}

static NSString *SCUIDeviceIDFromRequest(NSURLRequest *request) {
    NSData *body = request.HTTPBody;
    if (body.length) {
        id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
        if ([json isKindOfClass:NSDictionary.class]) {
            id value = ((NSDictionary *)json)[@"deviceId"] ?: ((NSDictionary *)json)[@"deviceID"];
            if ([value isKindOfClass:NSString.class] && [value length]) return value;
        }
    }
    return UIDevice.currentDevice.identifierForVendor.UUIDString ?: @"LOCAL-DEVICE";
}

@interface SCUILocalLicenseProtocol : NSURLProtocol
@end

@implementation SCUILocalLicenseProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!SCUILocalLicenseBypassEnabled()) return NO;
    if ([NSURLProtocol propertyForKey:@"SCUILocalLicenseHandled" inRequest:request]) return NO;
    return SCUIIsLicenseValidationURL(request.URL);
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

- (void)startLoading {
    NSMutableURLRequest *marked = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"SCUILocalLicenseHandled" inRequest:marked];
    NSString *deviceID = SCUIDeviceIDFromRequest(self.request);
    NSDictionary *payload = @{
        @"valid": @YES, @"code": @"LOCAL_TEST", @"message": @"Local test mode enabled",
        @"package": @"local", @"expiresAt": @"2099-12-31T23:59:59.000Z",
        @"remainingUses": @999999, @"deviceId": deviceID,
        @"durationDays": @9999, @"durationMinutes": @0,
        @"activatedAt": @"2026-09-28T00:00:00.000Z"
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil] ?: [NSData data];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
        statusCode:200 HTTPVersion:@"HTTP/1.1"
        headerFields:@{@"Content-Type": @"application/json", @"X-SCUI-Local": @"1"}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end

@interface NSURLSessionConfiguration (SCUILocalLicense)
+ (NSURLSessionConfiguration *)scui_defaultSessionConfiguration;
+ (NSURLSessionConfiguration *)scui_ephemeralSessionConfiguration;
@end

@implementation NSURLSessionConfiguration (SCUILocalLicense)
+ (NSURLSessionConfiguration *)scui_defaultSessionConfiguration {
    NSURLSessionConfiguration *cfg = [self scui_defaultSessionConfiguration];
    SCUIAddLoggerProtocolToConfiguration(cfg);
    return cfg;
}
+ (NSURLSessionConfiguration *)scui_ephemeralSessionConfiguration {
    NSURLSessionConfiguration *cfg = [self scui_ephemeralSessionConfiguration];
    SCUIAddLoggerProtocolToConfiguration(cfg);
    return cfg;
}
@end

static void SCUISwizzleClassMethod(Class cls, SEL original, SEL replacement) {
    Method a = class_getClassMethod(cls, original);
    Method b = class_getClassMethod(cls, replacement);
    if (a && b) method_exchangeImplementations(a, b);
}

static void SCUIInstallAPILogger(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [NSURLProtocol registerClass:SCUIAPILoggerProtocol.class];
        SCUISwizzleClassMethod(NSURLSessionConfiguration.class,
                              @selector(defaultSessionConfiguration),
                              @selector(scui_defaultSessionConfiguration));
        SCUISwizzleClassMethod(NSURLSessionConfiguration.class,
                              @selector(ephemeralSessionConfiguration),
                              @selector(scui_ephemeralSessionConfiguration));
    });
}

#pragma mark - Backend Router

static NSString *SCUITrim(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return @"";
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *SCUIActiveAPIBaseURL(void) {
    NSDictionary *p = SCUIPrefs();
    NSInteger profile = [p[@"apiProfile"] integerValue];
    NSString *value = profile == 0 ? p[@"apiAURL"] : (profile == 1 ? p[@"apiBURL"] : p[@"apiCustomURL"]);
    return SCUITrim(value);
}

static BOOL SCUIPathMatchesFilter(NSString *path, NSString *filterText) {
    NSString *filter = SCUITrim(filterText);
    if (filter.length == 0) return YES;
    for (NSString *raw in [filter componentsSeparatedByString:@","]) {
        NSString *prefix = SCUITrim(raw);
        if (prefix.length && [path hasPrefix:prefix]) return YES;
    }
    return NO;
}

static NSURL *SCUIRewriteURL(NSURL *original) {
    if (!original) return original;
    NSDictionary *p = SCUIPrefs();
    if (![p[@"apiRoutingEnabled"] boolValue]) return original;
    NSString *baseText = SCUIActiveAPIBaseURL();
    NSURLComponents *base = [NSURLComponents componentsWithString:baseText];
    if (!base || base.scheme.length == 0 || base.host.length == 0) return original;
    NSURLComponents *source = [NSURLComponents componentsWithURL:original resolvingAgainstBaseURL:NO];
    if (!source || source.host.length == 0) return original;
    NSString *sourceHost = SCUITrim(p[@"apiSourceHost"]);
    if (sourceHost.length && [source.host caseInsensitiveCompare:sourceHost] != NSOrderedSame) return original;
    if (!SCUIPathMatchesFilter(source.path ?: @"/", p[@"apiPathFilter"])) return original;
    BOOL preservePath = [p[@"apiPreservePath"] boolValue];
    if (!preservePath) return base.URL ?: original;
    source.scheme = base.scheme;
    source.host = base.host;
    source.port = base.port;
    return source.URL ?: original;
}

static NSURLRequest *SCUIRewriteRequest(NSURLRequest *request) {
    if (!request.URL) return request;
    NSURL *rewritten = SCUIRewriteURL(request.URL);
    if (!rewritten || [rewritten isEqual:request.URL]) return request;
    NSMutableURLRequest *copy = [request mutableCopy];
    copy.URL = rewritten;
    return copy;
}

@interface NSURLSession (SCUIBackendRouter)
- (NSURLSessionDataTask *)scui_dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler;
- (NSURLSessionDataTask *)scui_dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler;
- (NSURLSessionDownloadTask *)scui_downloadTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))completionHandler;
- (NSURLSessionUploadTask *)scui_uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler;
@end

@implementation NSURLSession (SCUIBackendRouter)
- (NSURLSessionDataTask *)scui_dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    return [self scui_dataTaskWithURL:SCUIRewriteURL(url) completionHandler:completionHandler];
}
- (NSURLSessionDataTask *)scui_dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    return [self scui_dataTaskWithRequest:SCUIRewriteRequest(request) completionHandler:completionHandler];
}
- (NSURLSessionDownloadTask *)scui_downloadTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))completionHandler {
    return [self scui_downloadTaskWithRequest:SCUIRewriteRequest(request) completionHandler:completionHandler];
}
- (NSURLSessionUploadTask *)scui_uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    return [self scui_uploadTaskWithRequest:SCUIRewriteRequest(request) fromData:bodyData completionHandler:completionHandler];
}
@end

static void SCUISwizzle(Class cls, SEL original, SEL replacement) {
    Method a = class_getInstanceMethod(cls, original);
    Method b = class_getInstanceMethod(cls, replacement);
    if (a && b) method_exchangeImplementations(a, b);
}

static void SCUIInstallBackendRouter(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = NSURLSession.class;
        SCUISwizzle(cls, @selector(dataTaskWithURL:completionHandler:), @selector(scui_dataTaskWithURL:completionHandler:));
        SCUISwizzle(cls, @selector(dataTaskWithRequest:completionHandler:), @selector(scui_dataTaskWithRequest:completionHandler:));
        SCUISwizzle(cls, @selector(downloadTaskWithRequest:completionHandler:), @selector(scui_downloadTaskWithRequest:completionHandler:));
        SCUISwizzle(cls, @selector(uploadTaskWithRequest:fromData:completionHandler:), @selector(scui_uploadTaskWithRequest:fromData:completionHandler:));
    });
}

@class SCUIOverlay;

@interface SCUIManager : NSObject
@property(nonatomic, strong) NSMutableDictionary *prefs;
@property(nonatomic, strong) NSHashTable<SCUIOverlay *> *overlays;
@property(nonatomic, strong) AVQueuePlayer *customPlayer;
@property(nonatomic, strong) AVPlayerLooper *customLooper;
@property(nonatomic, strong) NSHashTable<SCUICustomVideoLayer *> *customLayers;
@property(nonatomic, strong) NSTimer *timer;
+ (instancetype)shared;
- (void)install;
- (void)apply;
- (void)reloadCustomVideo;
- (NSURL *)customVideoURL;
@end

@interface SCUIOverlay : UIView <UIDocumentPickerDelegate, UIColorPickerViewControllerDelegate>
@property(nonatomic, strong) UIButton *bubble;
@property(nonatomic, strong) UIVisualEffectView *panel;
@property(nonatomic, strong) UIStackView *stack;
@property(nonatomic, strong) UISwitch *glassSwitch;
@property(nonatomic, strong) UISwitch *videoSwitch;
@property(nonatomic, strong) UISegmentedControl *videoMode;
@property(nonatomic, strong) UISlider *glassSlider;
@property(nonatomic, strong) UISlider *radiusSlider;
@property(nonatomic, strong) UISlider *borderSlider;
@property(nonatomic, strong) UISlider *bubbleSizeSlider;
@property(nonatomic, strong) UISlider *bubbleOpacitySlider;
@property(nonatomic, strong) UISwitch *hapticsSwitch;
@property(nonatomic, strong) UISwitch *apiRoutingSwitch;
@property(nonatomic, strong) UISegmentedControl *apiProfileControl;
@property(nonatomic, strong) UISwitch *apiPreservePathSwitch;
@property(nonatomic, strong) UISwitch *localLicenseBypassSwitch;
@property(nonatomic, strong) UISwitch *apiLoggerSwitch;
@property(nonatomic) NSInteger colorTarget;
@property(nonatomic) NSInteger documentPickerPurpose;
@property(nonatomic, strong) NSURL *pendingExportSourceURL;
- (void)refreshControls;
- (void)showInstalledPatchExporter;
- (void)showAPIEditor;
- (void)testActiveAPI;
- (void)localLicenseBypassChanged:(UISwitch *)sender;
- (void)apiLoggerChanged:(UISwitch *)sender;
- (void)showAPILogs;
- (void)clearAPILogs;
- (void)shareAllAPILogs;
- (void)scanStaticAPIURLs;
- (void)shareLogDictionary:(NSDictionary *)log;
@end

@implementation SCUIManager

+ (instancetype)shared {
    static SCUIManager *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [SCUIManager new]; });
    return m;
}

- (instancetype)init {
    if ((self = [super init])) {
        _prefs = SCUIPrefs();
        _overlays = [NSHashTable weakObjectsHashTable];
        _customLayers = [NSHashTable weakObjectsHashTable];
    }
    return self;
}

- (NSURL *)customVideoURL {
    NSURL *dir = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
    dir = [dir URLByAppendingPathComponent:@"SatanabeCleanUI" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir URLByAppendingPathComponent:@"background.mp4"];
}

- (void)install {
    for (UIWindow *window in SCUIWindows()) {
        if (window.hidden || window.windowLevel != UIWindowLevelNormal) continue;
        BOOL found = NO;
        for (UIView *v in window.subviews) {
            if ([v isKindOfClass:SCUIOverlay.class]) { found = YES; [window bringSubviewToFront:v]; break; }
        }
        if (!found) {
            SCUIOverlay *o = [[SCUIOverlay alloc] initWithFrame:window.bounds];
            o.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [window addSubview:o];
            [self.overlays addObject:o];
        }
    }
    [self apply];
}

- (void)reloadCustomVideo {
    [self.customPlayer pause];
    self.customPlayer = nil;
    self.customLooper = nil;
    NSURL *url = [self customVideoURL];
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) { [self apply]; return; }
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    AVQueuePlayer *player = [AVQueuePlayer queuePlayerWithItems:@[]];
    player.muted = YES;
    self.customPlayer = player;
    self.customLooper = [AVPlayerLooper playerLooperWithPlayer:player templateItem:item];
    [player play];
    [self apply];
}

- (void)apply {
    BOOL glass = [self.prefs[@"glass"] boolValue];
    BOOL videoEnabled = [self.prefs[@"videoEnabled"] boolValue];
    NSInteger videoMode = [self.prefs[@"videoMode"] integerValue];
    CGFloat intensity = [self.prefs[@"glassIntensity"] doubleValue];
    CGFloat radius = [self.prefs[@"cardRadius"] doubleValue];
    CGFloat borderWidth = [self.prefs[@"borderWidth"] doubleValue];
    UIColor *card = SCUIColorFromArray(self.prefs[@"cardColor"], [UIColor colorWithWhite:0.08 alpha:0.58]);
    UIColor *accent = SCUIColorFromArray(self.prefs[@"accentColor"], UIColor.whiteColor);

    for (UIWindow *window in SCUIWindows()) {
        if (window.hidden || window.windowLevel != UIWindowLevelNormal) continue;
        BOOL hideHostVideo = !videoEnabled || videoMode == 1;
        SCUISetHostVideosHidden(window, hideHostVideo);
        SCUICustomVideoLayer *custom = nil;
        for (CALayer *l in self.customLayers) if (l.superlayer == window.layer) { custom = l; break; }
        if (videoEnabled && videoMode == 1 && self.customPlayer) {
            if (!custom) {
                custom = [SCUICustomVideoLayer playerLayerWithPlayer:self.customPlayer];
                custom.videoGravity = AVLayerVideoGravityResizeAspectFill;
                [window.layer insertSublayer:custom atIndex:0];
                [self.customLayers addObject:custom];
            }
            custom.frame = window.bounds;
            custom.hidden = NO;
            if (self.customPlayer.timeControlStatus != AVPlayerTimeControlStatusPlaying) [self.customPlayer play];
        } else {
            custom.hidden = YES;
        }
        SCUIWalkViews(window, ^(UIView *v) {
            for (SCUIOverlay *overlay in self.overlays) {
                if (v == overlay || [v isDescendantOfView:overlay]) return;
            }
            if (glass && SCUILooksLikeCard(v, window)) {
                SCUIApplyGlassToView(v, card, accent, intensity, radius, borderWidth);
            } else if (!glass) {
                SCUIRemoveGlassFromView(v);
            }
        });
    }
    for (SCUIOverlay *o in self.overlays) [o refreshControls];
}

@end

#pragma mark - Local 3105 / PatchProject exporter

@interface SCUIPatchCandidate : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *subtitle;
@property(nonatomic, strong) NSURL *url;
@property(nonatomic) NSInteger kind;
@end
@implementation SCUIPatchCandidate @end

@interface SCUIPatchExportController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) NSArray<SCUIPatchCandidate *> *items;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *selectedRows;
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, copy) void (^exportHandler)(NSArray<SCUIPatchCandidate *> *items);
@end

@implementation SCUIPatchExportController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Patches instalados";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.selectedRows = [NSMutableSet set];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(closePressed)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Exportar" style:UIBarButtonItemStyleDone target:self action:@selector(exportPressed)];
    self.navigationItem.rightBarButtonItem.enabled = NO;
    UITableView *tv = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.dataSource = self;
    tv.delegate = self;
    tv.allowsMultipleSelection = YES;
    [self.view addSubview:tv];
    self.tableView = tv;
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
}

- (void)closePressed { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)exportPressed {
    NSMutableArray<SCUIPatchCandidate *> *chosen = [NSMutableArray array];
    NSArray<NSNumber *> *ordered = [[self.selectedRows allObjects] sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *n in ordered) {
        NSInteger i = n.integerValue;
        if (i >= 0 && i < (NSInteger)self.items.count) [chosen addObject:self.items[(NSUInteger)i]];
    }
    if (!chosen.count) return;
    void (^handler)(NSArray<SCUIPatchCandidate *> *) = self.exportHandler;
    [self dismissViewControllerAnimated:YES completion:^{ if (handler) handler(chosen); }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section; return (NSInteger)self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *rid = @"SCUIPatchCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:rid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:rid];
    SCUIPatchCandidate *item = self.items[(NSUInteger)indexPath.row];
    cell.textLabel.text = item.title.length ? item.title : @"Patch";
    cell.detailTextLabel.text = item.subtitle ?: @"";
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryType = [self.selectedRows containsObject:@(indexPath.row)] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSNumber *key = @(indexPath.row);
    if ([self.selectedRows containsObject:key]) [self.selectedRows removeObject:key];
    else [self.selectedRows addObject:key];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    self.navigationItem.rightBarButtonItem.enabled = self.selectedRows.count > 0;
}

@end

@implementation SCUIOverlay

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = YES;
        _bubble = [UIButton buttonWithType:UIButtonTypeCustom];
        [_bubble setTitle:@"S" forState:UIControlStateNormal];
        [_bubble setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        _bubble.titleLabel.font = [UIFont boldSystemFontOfSize:20];
        _bubble.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.78];
        _bubble.layer.cornerRadius = 28;
        _bubble.layer.borderWidth = 0.8;
        _bubble.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.75].CGColor;
        _bubble.layer.shadowColor = UIColor.blackColor.CGColor;
        _bubble.layer.shadowOpacity = 0.28;
        _bubble.layer.shadowRadius = 8;
        [_bubble addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
        [_bubble addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
        [self addSubview:_bubble];
    }
    return self;
}

- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e {
    if ([self.bubble pointInside:[self.bubble convertPoint:p fromView:self] withEvent:e]) return YES;
    if (self.panel && !self.panel.hidden &&
        [self.panel pointInside:[self.panel convertPoint:p fromView:self] withEvent:e]) return YES;
    return NO;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (!self.bubble.superview) return;
    SCUIManager *m = SCUIManager.shared;
    CGFloat d = MAX(42.0, MIN(82.0, [m.prefs[@"bubbleSize"] doubleValue]));
    self.bubble.alpha = MAX(0.35, MIN(1.0, [m.prefs[@"bubbleOpacity"] doubleValue]));
    if (CGRectIsEmpty(self.bubble.frame) || fabs(self.bubble.bounds.size.width - d) > 0.5) {
        CGFloat nx = MAX(0.0, MIN(1.0, [m.prefs[@"bubbleX"] doubleValue]));
        CGFloat ny = MAX(0.0, MIN(1.0, [m.prefs[@"bubbleY"] doubleValue]));
        CGFloat x = 8 + nx * MAX(1.0, self.bounds.size.width - d - 16);
        CGFloat minY = self.safeAreaInsets.top + 8;
        CGFloat maxY = self.bounds.size.height - self.safeAreaInsets.bottom - d - 8;
        CGFloat y = minY + ny * MAX(1.0, maxY - minY);
        self.bubble.frame = CGRectMake(x, y, d, d);
    }
    self.bubble.layer.cornerRadius = d/2;
}

- (UILabel *)label:(NSString *)text size:(CGFloat)size {
    UILabel *l = [UILabel new];
    l.text = text;
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:size weight:UIFontWeightMedium];
    l.numberOfLines = 0;
    [self.stack addArrangedSubview:l];
    return l;
}

- (UIView *)rowWithTitle:(NSString *)title control:(UIView *)control {
    UILabel *l = [UILabel new];
    l.text = title;
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[l, control]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.distribution = UIStackViewDistributionEqualSpacing;
    [self.stack addArrangedSubview:row];
    return row;
}

- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    b.layer.cornerRadius = 12;
    b.layer.borderWidth = 0.5;
    b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
    [b.heightAnchor constraintEqualToConstant:42].active = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)buildPanel {
    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
    self.panel = [[UIVisualEffectView alloc] initWithEffect:effect];
    self.panel.layer.cornerRadius = 24;
    self.panel.clipsToBounds = YES;
    self.panel.layer.borderWidth = 0.65;
    self.panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
    [self addSubview:self.panel];

    CGFloat w = MIN(360, self.bounds.size.width - 28);
    CGFloat h = MIN(590, self.bounds.size.height - self.safeAreaInsets.top - self.safeAreaInsets.bottom - 50);
    self.panel.frame = CGRectMake((self.bounds.size.width-w)/2, self.safeAreaInsets.top + 18, w, h);

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectInset(self.panel.bounds, 16, 16)];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.panel.contentView addSubview:scroll];

    self.stack = [UIStackView new];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 13;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:self.stack];
    [NSLayoutConstraint activateConstraints:@[
        [self.stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [self.stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [self.stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [self.stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]
    ]];

    UILabel *title = [self label:@"SATANABE • VISUAL" size:20];
    title.font = [UIFont boldSystemFontOfSize:20];
    UILabel *sub = [self label:@"Visual + patches + conexão de teste." size:11];
    sub.textColor = [UIColor colorWithWhite:1 alpha:0.58];

    self.glassSwitch = [UISwitch new];
    [self.glassSwitch addTarget:self action:@selector(glassChanged:) forControlEvents:UIControlEventValueChanged];
    [self rowWithTitle:@"Liquid Glass" control:self.glassSwitch];

    self.glassSlider = [UISlider new];
    self.glassSlider.minimumValue = 0.15;
    self.glassSlider.maximumValue = 1.0;
    [self.glassSlider addTarget:self action:@selector(glassIntensityChanged:) forControlEvents:UIControlEventValueChanged];
    [self label:@"Intensidade do Glass" size:13];
    [self.stack addArrangedSubview:self.glassSlider];

    [self label:@"Arredondamento dos cards" size:13];
    self.radiusSlider = [UISlider new];
    self.radiusSlider.minimumValue = 8; self.radiusSlider.maximumValue = 36;
    [self.radiusSlider addTarget:self action:@selector(radiusChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:self.radiusSlider];

    [self label:@"Espessura das bordas" size:13];
    self.borderSlider = [UISlider new];
    self.borderSlider.minimumValue = 0; self.borderSlider.maximumValue = 2.0;
    [self.borderSlider addTarget:self action:@selector(borderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:self.borderSlider];

    [self.stack addArrangedSubview:[self button:@"Cor dos cards" action:@selector(pickCardColor)]];
    [self.stack addArrangedSubview:[self button:@"Cor do destaque / bordas" action:@selector(pickAccentColor)]];

    self.videoSwitch = [UISwitch new];
    [self.videoSwitch addTarget:self action:@selector(videoChanged:) forControlEvents:UIControlEventValueChanged];
    [self rowWithTitle:@"Vídeo de fundo" control:self.videoSwitch];

    [self label:@"Fonte do vídeo" size:13];
    self.videoMode = [[UISegmentedControl alloc] initWithItems:@[@"Original", @"Personalizado"]];
    [self.videoMode addTarget:self action:@selector(videoModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:self.videoMode];

    [self.stack addArrangedSubview:[self button:@"Escolher / trocar vídeo" action:@selector(chooseVideo)]];

    [self label:@"Ferramentas de patch" size:13];
    [self.stack addArrangedSubview:[self button:@"Exportar patches instalados" action:@selector(showInstalledPatchExporter)]];
    [self.stack addArrangedSubview:[self button:@"Exportar arquivo manualmente" action:@selector(choosePatchForExport)]];

    [self label:@"API Logger — somente diagnóstico" size:13];
    self.apiLoggerSwitch = [UISwitch new];
    [self.apiLoggerSwitch addTarget:self action:@selector(apiLoggerChanged:) forControlEvents:UIControlEventValueChanged];
    [self rowWithTitle:@"Registrar HTTP/HTTPS" control:self.apiLoggerSwitch];
    [self label:@"Registra URL, método, status e correlação de key/resultado. Não altera requisições." size:11];
    [self.stack addArrangedSubview:[self button:@"Ver logs da API" action:@selector(showAPILogs)]];
    [self.stack addArrangedSubview:[self button:@"Mapear URLs do binário" action:@selector(scanStaticAPIURLs)]];
    [self.stack addArrangedSubview:[self button:@"Compartilhar todos os logs" action:@selector(shareAllAPILogs)]];
    [self.stack addArrangedSubview:[self button:@"Limpar logs da API" action:@selector(clearAPILogs)]];

    [self label:@"Tamanho do botão flutuante" size:13];
    self.bubbleSizeSlider = [UISlider new];
    self.bubbleSizeSlider.minimumValue = 42; self.bubbleSizeSlider.maximumValue = 82;
    [self.bubbleSizeSlider addTarget:self action:@selector(bubbleSizeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:self.bubbleSizeSlider];

    [self label:@"Opacidade do botão flutuante" size:13];
    self.bubbleOpacitySlider = [UISlider new];
    self.bubbleOpacitySlider.minimumValue = 0.35; self.bubbleOpacitySlider.maximumValue = 1.0;
    [self.bubbleOpacitySlider addTarget:self action:@selector(bubbleOpacityChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:self.bubbleOpacitySlider];

    self.hapticsSwitch = [UISwitch new];
    [self.hapticsSwitch addTarget:self action:@selector(hapticsChanged:) forControlEvents:UIControlEventValueChanged];
    [self rowWithTitle:@"Feedback tátil" control:self.hapticsSwitch];

    [self.stack addArrangedSubview:[self button:@"Copiar configuração" action:@selector(copyConfiguration)]];
    [self.stack addArrangedSubview:[self button:@"Restaurar visual original" action:@selector(resetVisual)]];

    UIButton *close = [self button:@"Fechar" action:@selector(togglePanel)];
    [self.stack addArrangedSubview:close];

    [self refreshControls];
}

- (void)refreshControls {
    SCUIManager *m = SCUIManager.shared;
    self.glassSwitch.on = [m.prefs[@"glass"] boolValue];
    self.videoSwitch.on = [m.prefs[@"videoEnabled"] boolValue];
    self.videoMode.selectedSegmentIndex = [m.prefs[@"videoMode"] integerValue];
    self.glassSlider.value = [m.prefs[@"glassIntensity"] floatValue];
    self.radiusSlider.value = [m.prefs[@"cardRadius"] floatValue];
    self.borderSlider.value = [m.prefs[@"borderWidth"] floatValue];
    self.bubbleSizeSlider.value = [m.prefs[@"bubbleSize"] floatValue];
    self.bubbleOpacitySlider.value = [m.prefs[@"bubbleOpacity"] floatValue];
    self.hapticsSwitch.on = [m.prefs[@"haptics"] boolValue];
    self.apiLoggerSwitch.on = [m.prefs[@"apiLoggerEnabled"] boolValue];
    self.localLicenseBypassSwitch.on = [m.prefs[@"localLicenseBypass"] boolValue];
    self.apiRoutingSwitch.on = [m.prefs[@"apiRoutingEnabled"] boolValue];
    self.apiProfileControl.selectedSegmentIndex = [m.prefs[@"apiProfile"] integerValue];
    self.apiPreservePathSwitch.on = [m.prefs[@"apiPreservePath"] boolValue];
    UIColor *accent = SCUIColorFromArray(m.prefs[@"accentColor"], UIColor.whiteColor);
    self.bubble.layer.borderColor = [accent colorWithAlphaComponent:self.panel && !self.panel.hidden ? 1.0 : 0.72].CGColor;
    self.bubble.layer.borderWidth = self.panel && !self.panel.hidden ? 1.15 : 0.75;
}

- (void)togglePanel {
    if ([SCUIManager.shared.prefs[@"haptics"] boolValue]) {
        UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [g impactOccurred];
    }
    if (!self.panel) { [self buildPanel]; self.panel.hidden = YES; }
    self.panel.hidden = !self.panel.hidden;
    [self refreshControls];
    if (!self.panel.hidden) [self bringSubviewToFront:self.panel];
}

- (void)drag:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self];
    CGPoint c = self.bubble.center;
    c.x += t.x; c.y += t.y;
    CGFloat r = self.bubble.bounds.size.width/2;
    c.x = MAX(r+8, MIN(self.bounds.size.width-r-8, c.x));
    c.y = MAX(self.safeAreaInsets.top+r+8, MIN(self.bounds.size.height-self.safeAreaInsets.bottom-r-8, c.y));
    self.bubble.center = c;
    [g setTranslation:CGPointZero inView:self];
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        CGFloat d = self.bubble.bounds.size.width;
        CGFloat nx = (self.bubble.frame.origin.x - 8) / MAX(1.0, self.bounds.size.width - d - 16);
        CGFloat minY = self.safeAreaInsets.top + 8;
        CGFloat maxY = self.bounds.size.height - self.safeAreaInsets.bottom - d - 8;
        CGFloat ny = (self.bubble.frame.origin.y - minY) / MAX(1.0, maxY - minY);
        SCUIManager.shared.prefs[@"bubbleX"] = @(MAX(0.0, MIN(1.0, nx)));
        SCUIManager.shared.prefs[@"bubbleY"] = @(MAX(0.0, MIN(1.0, ny)));
        SCUISave(SCUIManager.shared.prefs);
    }
}

- (void)radiusChanged:(UISlider *)s {
    SCUIManager.shared.prefs[@"cardRadius"] = @(s.value); SCUISave(SCUIManager.shared.prefs);
    for (UIWindow *w in SCUIWindows()) SCUIWalkViews(w, ^(UIView *v){ SCUIRemoveGlassFromView(v); });
    [SCUIManager.shared apply];
}
- (void)borderChanged:(UISlider *)s {
    SCUIManager.shared.prefs[@"borderWidth"] = @(s.value); SCUISave(SCUIManager.shared.prefs);
    for (UIWindow *w in SCUIWindows()) SCUIWalkViews(w, ^(UIView *v){ SCUIRemoveGlassFromView(v); });
    [SCUIManager.shared apply];
}
- (void)bubbleSizeChanged:(UISlider *)s {
    SCUIManager.shared.prefs[@"bubbleSize"] = @(s.value); SCUISave(SCUIManager.shared.prefs);
    self.bubble.frame = CGRectZero; [self setNeedsLayout];
}
- (void)bubbleOpacityChanged:(UISlider *)s {
    SCUIManager.shared.prefs[@"bubbleOpacity"] = @(s.value); SCUISave(SCUIManager.shared.prefs);
    self.bubble.alpha = s.value;
}
- (void)hapticsChanged:(UISwitch *)s { SCUIManager.shared.prefs[@"haptics"] = @(s.on); SCUISave(SCUIManager.shared.prefs); }
- (void)copyConfiguration {
    NSError *e = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:SCUIManager.shared.prefs options:NSJSONWritingPrettyPrinted error:&e];
    if (!e && d) UIPasteboard.generalPasteboard.string = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

- (void)glassChanged:(UISwitch *)s {
    SCUIManager.shared.prefs[@"glass"] = @(s.on);
    SCUISave(SCUIManager.shared.prefs);
    [SCUIManager.shared apply];
}
- (void)glassIntensityChanged:(UISlider *)s {
    SCUIManager.shared.prefs[@"glassIntensity"] = @(s.value);
    SCUISave(SCUIManager.shared.prefs);
    for (UIWindow *w in SCUIWindows()) {
        SCUIWalkViews(w, ^(UIView *v){ SCUIRemoveGlassFromView(v); });
    }
    [SCUIManager.shared apply];
}
- (void)videoChanged:(UISwitch *)s {
    SCUIManager.shared.prefs[@"videoEnabled"] = @(s.on);
    SCUISave(SCUIManager.shared.prefs);
    [SCUIManager.shared apply];
}
- (void)videoModeChanged:(UISegmentedControl *)s {
    SCUIManager.shared.prefs[@"videoMode"] = @(s.selectedSegmentIndex);
    SCUISave(SCUIManager.shared.prefs);
    if (s.selectedSegmentIndex == 1) [SCUIManager.shared reloadCustomVideo];
    else [SCUIManager.shared apply];
}

- (void)pickCardColor { self.colorTarget = 0; [self showColorPickerForKey:@"cardColor"]; }
- (void)pickAccentColor { self.colorTarget = 1; [self showColorPickerForKey:@"accentColor"]; }

- (void)showColorPickerForKey:(NSString *)key {
    UIColorPickerViewController *picker = [UIColorPickerViewController new];
    picker.delegate = self;
    picker.supportsAlpha = YES;
    picker.selectedColor = SCUIColorFromArray(SCUIManager.shared.prefs[key], UIColor.whiteColor);
    UIViewController *vc = self.window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    [vc presentViewController:picker animated:YES completion:nil];
}

- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)viewController {
    NSString *key = self.colorTarget == 0 ? @"cardColor" : @"accentColor";
    SCUIManager.shared.prefs[key] = SCUIArrayFromColor(viewController.selectedColor);
    SCUISave(SCUIManager.shared.prefs);
    if (self.colorTarget == 0) {
        for (UIWindow *w in SCUIWindows()) SCUIWalkViews(w, ^(UIView *v){ SCUIRemoveGlassFromView(v); });
    }
    [SCUIManager.shared apply];
}

- (void)chooseVideo {
    self.documentPickerPurpose = 0;
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeMovie, UTTypeMPEG4Movie] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    UIViewController *vc = self.window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    [vc presentViewController:picker animated:YES completion:nil];
}

- (NSString *)scuiDisplayLocationForURL:(NSURL *)url {
    NSString *path = url.path ?: @"";
    NSString *bundle = NSBundle.mainBundle.bundlePath ?: @"";
    NSString *home = NSHomeDirectory() ?: @"";
    if (bundle.length && [path hasPrefix:bundle]) return [@"IPA/" stringByAppendingString:[path substringFromIndex:bundle.length]];
    if (home.length && [path hasPrefix:home]) return [@"Sandbox/" stringByAppendingString:[path substringFromIndex:home.length]];
    return path;
}

- (BOOL)scuiFileHas3105Magic:(NSURL *)url {
    NSNumber *size = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if (size && size.unsignedLongLongValue > (256ULL * 1024ULL * 1024ULL)) return NO;
    NSFileHandle *h = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!h) return NO;
    NSData *d = [h readDataOfLength:9];
    [h closeFile];
    if (d.length != 9) return NO;
    const char magic[9] = {'3','1','0','5','P','A','T','C','H'};
    return memcmp(d.bytes, magic, 9) == 0;
}

- (NSString *)scuiFirstStringForKeys:(NSArray<NSString *> *)keys inObject:(id)obj {
    if ([obj isKindOfClass:NSDictionary.class]) {
        NSDictionary *d = (NSDictionary *)obj;
        for (NSString *k in keys) {
            id v = d[k];
            if ([v isKindOfClass:NSString.class] && [v length]) return v;
        }
        for (id v in d.allValues) {
            NSString *hit = [self scuiFirstStringForKeys:keys inObject:v];
            if (hit.length) return hit;
        }
    } else if ([obj isKindOfClass:NSArray.class]) {
        for (id v in (NSArray *)obj) {
            NSString *hit = [self scuiFirstStringForKeys:keys inObject:v];
            if (hit.length) return hit;
        }
    }
    return nil;
}

- (void)scuiCollectPathHintsFromObject:(id)obj prefix:(NSString *)prefix output:(NSMutableArray<NSString *> *)out {
    if ([obj isKindOfClass:NSDictionary.class]) {
        NSDictionary *d = (NSDictionary *)obj;
        for (id rawKey in d) {
            NSString *key = [rawKey isKindOfClass:NSString.class] ? rawKey : [rawKey description];
            id v = d[rawKey];
            NSString *lower = key.lowercaseString;
            BOOL interesting = [lower containsString:@"path"] || [lower containsString:@"relative"] ||
                               [lower containsString:@"target"] || [lower containsString:@"bundle"] ||
                               [lower containsString:@"package"] || [lower containsString:@"file"] ||
                               [lower containsString:@"name"];
            if (interesting && [v isKindOfClass:NSString.class] && [v length]) {
                [out addObject:[NSString stringWithFormat:@"%@: %@", key, v]];
            }
            [self scuiCollectPathHintsFromObject:v prefix:key output:out];
        }
    } else if ([obj isKindOfClass:NSArray.class]) {
        for (id v in (NSArray *)obj) [self scuiCollectPathHintsFromObject:v prefix:prefix output:out];
    }
}

- (NSArray<SCUIPatchCandidate *> *)scuiDiscoverPatchCandidates {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSURL *> *roots = [NSMutableArray array];
    if (NSBundle.mainBundle.bundleURL) [roots addObject:NSBundle.mainBundle.bundleURL];
    NSString *home = NSHomeDirectory();
    if (home.length) {
        for (NSString *sub in @[@"Documents", @"Library", @"tmp"]) {
            NSURL *u = [NSURL fileURLWithPath:[home stringByAppendingPathComponent:sub] isDirectory:YES];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:u.path isDirectory:&isDir] && isDir) [roots addObject:u];
        }
    }
    NSMutableArray<SCUIPatchCandidate *> *found = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSArray *keys = @[NSURLIsRegularFileKey, NSURLIsDirectoryKey, NSURLNameKey, NSURLFileSizeKey];
    for (NSURL *root in roots) {
        NSDirectoryEnumerator *en = [fm enumeratorAtURL:root includingPropertiesForKeys:keys
            options:0 errorHandler:^BOOL(NSURL *url, NSError *error) { (void)url; (void)error; return YES; }];
        for (NSURL *u in en) {
            NSNumber *isRegular = nil;
            [u getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:nil];
            if (!isRegular.boolValue) continue;
            NSString *name = u.lastPathComponent ?: @"";
            NSString *canonical = u.URLByStandardizingPath.path ?: u.path;
            if (!canonical.length) continue;
            if ([name isEqualToString:@".3105-project.plist"]) {
                NSURL *dir = [u URLByDeletingLastPathComponent];
                NSString *projectKey = [@"project:" stringByAppendingString:(dir.URLByStandardizingPath.path ?: dir.path ?: @"")];
                if ([seen containsObject:projectKey]) continue;
                NSDictionary *plist = [NSDictionary dictionaryWithContentsOfURL:u];
                NSString *title = [self scuiFirstStringForKeys:@[@"displayName", @"name", @"title"] inObject:plist];
                if (!title.length) title = dir.lastPathComponent ?: @"Patch importado";
                SCUIPatchCandidate *c = [SCUIPatchCandidate new];
                c.title = title;
                c.subtitle = [NSString stringWithFormat:@"Projeto 3105 • %@", [self scuiDisplayLocationForURL:dir]];
                c.url = dir;
                c.kind = 1;
                [seen addObject:projectKey];
                [found addObject:c];
                continue;
            }
            BOOL ext3105 = [[u.pathExtension lowercaseString] isEqualToString:@"3105"];
            BOOL magic3105 = ext3105 ? YES : [self scuiFileHas3105Magic:u];
            if (!magic3105) continue;
            NSString *fileKey = [@"file:" stringByAppendingString:canonical];
            if ([seen containsObject:fileKey]) continue;
            SCUIPatchCandidate *c = [SCUIPatchCandidate new];
            NSString *title = u.lastPathComponent.length ? u.lastPathComponent : @"Patch.3105";
            if (!ext3105) title = [[title stringByDeletingPathExtension] stringByAppendingPathExtension:@"3105"];
            c.title = title;
            c.subtitle = [NSString stringWithFormat:@"Pacote 3105 • %@", [self scuiDisplayLocationForURL:u]];
            c.url = u;
            c.kind = 0;
            [seen addObject:fileKey];
            [found addObject:c];
        }
    }
    [found sortUsingComparator:^NSComparisonResult(SCUIPatchCandidate *a, SCUIPatchCandidate *b) {
        return [(a.title ?: @"") localizedCaseInsensitiveCompare:(b.title ?: @"")];
    }];
    return found;
}

- (NSURL *)scuiPrepareCandidateForSharing:(SCUIPatchCandidate *)item error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!item.url) return nil;
    if (item.kind == 0) {
        if ([[item.url.pathExtension lowercaseString] isEqualToString:@"3105"]) return item.url;
        NSString *rawTitle = item.title ?: @"Patch.3105";
        NSString *safe = [[rawTitle lastPathComponent] stringByDeletingPathExtension];
        NSURL *dst = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[safe stringByAppendingPathExtension:@"3105"]];
        [fm removeItemAtURL:dst error:nil];
        if (![fm copyItemAtURL:item.url toURL:dst error:error]) return nil;
        return dst;
    }
    NSString *rawBase = item.title ?: @"PatchProject";
    NSString *base = [[rawBase lastPathComponent] stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    if (!base.length) base = @"PatchProject";
    NSURL *stage = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[@"SCUI-" stringByAppendingString:[[NSUUID UUID] UUIDString]] isDirectory:YES];
    NSURL *projectCopy = [stage URLByAppendingPathComponent:base isDirectory:YES];
    [fm removeItemAtURL:stage error:nil];
    if (![fm createDirectoryAtURL:stage withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    if (![fm copyItemAtURL:item.url toURL:projectCopy error:error]) return nil;
    NSURL *manifest = [projectCopy URLByAppendingPathComponent:@".3105-project.plist"];
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfURL:manifest];
    NSMutableArray<NSString *> *hints = [NSMutableArray array];
    if (plist) [self scuiCollectPathHintsFromObject:plist prefix:@"" output:hints];
    NSMutableString *report = [NSMutableString stringWithFormat:@"3105 PATCH PROJECT EXPORT\nNome: %@\nOrigem: %@\n\n", item.title ?: @"Patch", item.url.path ?: @"-"];
    if (hints.count) {
        [report appendString:@"CAMINHOS/METADADOS ENCONTRADOS:\n"];
        for (NSString *line in hints) [report appendFormat:@"%@\n", line];
    } else {
        [report appendString:@"O manifesto não expôs caminhos legíveis. A pasta do projeto foi preservada integralmente.\n"];
    }
    [report writeToURL:[stage URLByAppendingPathComponent:@"PATCH_PATH.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    __block NSURL *zipURL = nil;
    __block NSError *coordError = nil;
    [coordinator coordinateReadingItemAtURL:stage options:NSFileCoordinatorReadingForUploading error:&coordError byAccessor:^(NSURL *newURL) {
        NSString *zipName = [base stringByAppendingString:@"-3105-project.zip"];
        NSURL *out = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:zipName];
        [fm removeItemAtURL:out error:nil];
        NSError *copyError = nil;
        if ([fm copyItemAtURL:newURL toURL:out error:&copyError]) zipURL = out;
        else coordError = copyError;
    }];
    if (!zipURL && error) *error = coordError;
    return zipURL;
}

- (void)showInstalledPatchExporter {
    NSArray<SCUIPatchCandidate *> *patches = [self scuiDiscoverPatchCandidates];
    if (!patches.count) {
        [self showExportError:@"Nenhum pacote 3105 nem projeto importado foi encontrado. Esta versão também procura arquivos com assinatura 3105PATCH e projetos .3105-project.plist, inclusive arquivos ocultos do sandbox."];
        return;
    }
    SCUIPatchExportController *list = [SCUIPatchExportController new];
    list.items = patches;
    __weak SCUIOverlay *weakOverlay = self;
    list.exportHandler = ^(NSArray<SCUIPatchCandidate *> *items) {
        SCUIOverlay *overlay = weakOverlay;
        if (!overlay || !items.count) return;
        NSMutableArray<NSURL *> *shareURLs = [NSMutableArray array];
        NSMutableArray<NSString *> *errors = [NSMutableArray array];
        for (SCUIPatchCandidate *item in items) {
            NSError *e = nil;
            NSURL *prepared = [overlay scuiPrepareCandidateForSharing:item error:&e];
            if (prepared) [shareURLs addObject:prepared];
            else [errors addObject:[NSString stringWithFormat:@"%@: %@", item.title ?: @"Patch", e.localizedDescription ?: @"falha ao preparar"]];
        }
        if (!shareURLs.count) {
            [overlay showExportError:errors.count ? [errors componentsJoinedByString:@"\n"] : @"Não foi possível preparar os patches."];
            return;
        }
        UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:shareURLs applicationActivities:nil];
        if (share.popoverPresentationController) {
            share.popoverPresentationController.sourceView = overlay.bubble;
            share.popoverPresentationController.sourceRect = overlay.bubble.bounds;
        }
        [[overlay scuiTopController] presentViewController:share animated:YES completion:nil];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:list];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [[self scuiTopController] presentViewController:nav animated:YES completion:nil];
}

- (void)choosePatchForExport {
    self.documentPickerPurpose = 1;
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    UIViewController *vc = self.window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    [vc presentViewController:picker animated:YES completion:nil];
}

- (UIViewController *)scuiTopController {
    UIViewController *vc = self.window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

- (NSString *)scuiSanitizedRelativePath:(NSString *)input {
    NSString *p = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    p = [p stringByReplacingOccurrencesOfString:@"\\\\" withString:@"/"];
    while ([p hasPrefix:@"/"]) p = [p substringFromIndex:1];
    NSMutableArray<NSString *> *safe = [NSMutableArray array];
    for (NSString *part in [p componentsSeparatedByString:@"/"]) {
        if (!part.length || [part isEqualToString:@"."]) continue;
        if ([part isEqualToString:@".."]) continue;
        [safe addObject:part];
    }
    return [safe componentsJoinedByString:@"/"];
}

- (void)askExportPathForURL:(NSURL *)src {
    self.pendingExportSourceURL = src;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Exportar patch"
        message:@"Informe a pasta de destino usada pelo patch. O ZIP terá essa mesma estrutura e também um PATCH_PATH.txt."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = @"com.dts.freefireth/Documents/...";
        f.text = @"com.dts.freefireth/Documents/";
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = @"Nome final (opcional)";
        f.text = src.lastPathComponent ?: @"patch.bin";
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak SCUIOverlay *weakSelf = self;
    __weak UIAlertController *weakAlert = a;
    [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Gerar ZIP" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        SCUIOverlay *strongSelf = weakSelf;
        UIAlertController *strongAlert = weakAlert;
        if (!strongSelf || !strongAlert) return;
        NSString *folder = strongAlert.textFields.firstObject.text ?: @"";
        NSString *name = strongAlert.textFields.count > 1 ? strongAlert.textFields[1].text : @"";
        [strongSelf createPatchExportFromURL:src targetFolder:folder finalName:name];
    }]];
    [[self scuiTopController] presentViewController:a animated:YES completion:nil];
}

- (void)showExportError:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Exportação"
        message:message ?: @"Falha desconhecida."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [[self scuiTopController] presentViewController:a animated:YES completion:nil];
}

- (void)createPatchExportFromURL:(NSURL *)src targetFolder:(NSString *)folder finalName:(NSString *)finalName {
    if (!src) { [self showExportError:@"Arquivo de origem não encontrado."]; return; }
    NSString *safeFolder = [self scuiSanitizedRelativePath:folder ?: @""];
    NSString *safeName = [finalName lastPathComponent];
    if (!safeName.length) safeName = src.lastPathComponent ?: @"patch.bin";
    if (!safeFolder.length) { [self showExportError:@"Informe o caminho de destino."]; return; }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *stamp = [NSString stringWithFormat:@"%.0f", NSDate.date.timeIntervalSince1970];
    NSURL *root = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:[@"SatanabePatchExport-" stringByAppendingString:stamp] isDirectory:YES];
    [fm removeItemAtURL:root error:nil];
    NSError *error = nil;
    if (![fm createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:&error]) {
        [self showExportError:error.localizedDescription]; return;
    }
    NSURL *targetDir = [root URLByAppendingPathComponent:safeFolder isDirectory:YES];
    if (![fm createDirectoryAtURL:targetDir withIntermediateDirectories:YES attributes:nil error:&error]) {
        [self showExportError:error.localizedDescription]; return;
    }
    NSURL *payloadDst = [targetDir URLByAppendingPathComponent:safeName];
    [fm removeItemAtURL:payloadDst error:nil];
    BOOL access = [src startAccessingSecurityScopedResource];
    BOOL copied = [fm copyItemAtURL:src toURL:payloadDst error:&error];
    if (access) [src stopAccessingSecurityScopedResource];
    if (!copied) { [self showExportError:error.localizedDescription]; return; }
    NSString *fullTarget = [safeFolder stringByAppendingPathComponent:safeName];
    NSString *txt = [NSString stringWithFormat:
        @"SATANABE PATCH EXPORT\\n\\nCaminho destino:\\n/%@\\n\\nArquivo final:\\n%@\\n\\nArquivo de origem:\\n%@\\n",
        fullTarget, safeName, src.lastPathComponent ?: @"-"];
    [txt writeToURL:[root URLByAppendingPathComponent:@"PATCH_PATH.txt"]
        atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    __block NSURL *zipURL = nil;
    __block NSError *coordError = nil;
    [coordinator coordinateReadingItemAtURL:root options:NSFileCoordinatorReadingForUploading
        error:&coordError byAccessor:^(NSURL *newURL) {
            NSURL *out = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
                URLByAppendingPathComponent:@"Satanabe-Patch-Export.zip"];
            [fm removeItemAtURL:out error:nil];
            NSError *copyError = nil;
            if ([fm copyItemAtURL:newURL toURL:out error:&copyError]) zipURL = out;
            else coordError = copyError;
        }];
    if (!zipURL) { [self showExportError:coordError.localizedDescription ?: @"Não foi possível gerar o ZIP."]; return; }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[zipURL] applicationActivities:nil];
    if (share.popoverPresentationController) {
        share.popoverPresentationController.sourceView = self.bubble;
        share.popoverPresentationController.sourceRect = self.bubble.bounds;
    }
    [[self scuiTopController] presentViewController:share animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *src = urls.firstObject;
    if (!src) return;
    if (self.documentPickerPurpose == 1) {
        [self askExportPathForURL:src];
        return;
    }
    NSURL *dst = [SCUIManager.shared customVideoURL];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtURL:dst error:nil];
    NSError *error = nil;
    BOOL access = [src startAccessingSecurityScopedResource];
    [fm copyItemAtURL:src toURL:dst error:&error];
    if (access) [src stopAccessingSecurityScopedResource];
    if (!error) {
        SCUIManager.shared.prefs[@"videoMode"] = @1;
        SCUIManager.shared.prefs[@"videoEnabled"] = @YES;
        SCUISave(SCUIManager.shared.prefs);
        [SCUIManager.shared reloadCustomVideo];
    }
    (void)controller;
}

- (void)apiLoggerChanged:(UISwitch *)sender {
    SCUIManager.shared.prefs[@"apiLoggerEnabled"] = @(sender.on);
    SCUISave(SCUIManager.shared.prefs);
}

- (void)shareItems:(NSArray *)items fromView:(UIView *)view {
    if (!items.count) return;
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    if (share.popoverPresentationController) {
        share.popoverPresentationController.sourceView = view ?: self.window;
        share.popoverPresentationController.sourceRect = view ? view.bounds : self.window.bounds;
    }
    [[self scuiTopController] presentViewController:share animated:YES completion:nil];
}

- (void)shareLogDictionary:(NSDictionary *)log {
    [self shareItems:@[SCUIPrettyLog(log) ?: @""] fromView:self.window];
}

- (void)showAPILogAtIndex:(NSInteger)index logs:(NSArray<NSDictionary *> *)logs {
    if (!logs.count || index < 0 || index >= (NSInteger)logs.count) return;
    NSDictionary *log = logs[(NSUInteger)index];
    NSString *event = [log[@"event"] description] ?: @"log";
    NSString *method = [log[@"method"] description] ?: @"";
    NSString *url = [log[@"url"] description] ?: @"";
    NSString *status = log[@"status"] ? [NSString stringWithFormat:@"HTTP %@", log[@"status"]] : @"";
    NSString *validation = [log[@"validationResult"] description] ?: @"";
    NSString *licenseKey = [log[@"licenseKey"] description] ?: @"";
    NSString *serverMessage = [log[@"serverMessage"] description] ?: @"";
    NSString *body = [log[@"body"] description] ?: @"";
    if (body.length > 1600) body = [[body substringToIndex:1600] stringByAppendingString:@"…"];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"%@ %@", event.uppercaseString, method]];
    if (url.length) [lines addObject:url];
    if (status.length) [lines addObject:status];
    if (validation.length) [lines addObject:[NSString stringWithFormat:@"VALIDAÇÃO: %@", validation]];
    if (licenseKey.length) [lines addObject:[NSString stringWithFormat:@"KEY: %@", licenseKey]];
    if (serverMessage.length) [lines addObject:[NSString stringWithFormat:@"SERVIDOR: %@", serverMessage]];
    if (body.length) { [lines addObject:@""]; [lines addObject:body]; }
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:
            [NSString stringWithFormat:@"API Log %ld/%lu", (long)(index + 1), (unsigned long)logs.count]
                                            message:[lines componentsJoinedByString:@"\n"]
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Compartilhar este log" style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) { [self shareLogDictionary:log]; }]];
    if (index > 0) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Anterior" style:UIAlertActionStyleDefault
                                               handler:^(__unused UIAlertAction *action) { [self showAPILogAtIndex:index - 1 logs:logs]; }]];
    }
    if (index + 1 < (NSInteger)logs.count) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Próximo" style:UIAlertActionStyleDefault
                                               handler:^(__unused UIAlertAction *action) { [self showAPILogAtIndex:index + 1 logs:logs]; }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Fechar" style:UIAlertActionStyleCancel handler:nil]];
    [[self scuiTopController] presentViewController:alert animated:YES completion:nil];
}

- (void)showAPILogs {
    NSArray<NSDictionary *> *allLogs = SCUIReadAPILogs();
    if (!allLogs.count) {
        UIAlertController *empty = [UIAlertController alertControllerWithTitle:@"API Logger"
            message:@"Nenhuma requisição HTTP/HTTPS registrada ainda." preferredStyle:UIAlertControllerStyleAlert];
        [empty addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [[self scuiTopController] presentViewController:empty animated:YES completion:nil];
        return;
    }
    NSArray<NSDictionary *> *logs = allLogs.count > 20 ? [allLogs subarrayWithRange:NSMakeRange(allLogs.count - 20, 20)] : allLogs;
    [self showAPILogAtIndex:(NSInteger)logs.count - 1 logs:logs];
}

- (void)scanStaticAPIURLs {
    NSArray<NSString *> *urls = SCUIStaticURLInventory();
    SCUILogStaticURLInventory();
    NSString *message = urls.count
        ? [NSString stringWithFormat:@"%lu URL(s) HTTP/HTTPS hardcoded(s) encontradas no executável e adicionadas ao log.", (unsigned long)urls.count]
        : @"Nenhuma URL HTTP/HTTPS hardcoded foi encontrada no executável principal.";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Mapa de URLs" message:message preferredStyle:UIAlertControllerStyleAlert];
    if (urls.count) {
        [a addAction:[UIAlertAction actionWithTitle:@"Compartilhar URLs" style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
            NSString *text = [urls componentsJoinedByString:@"\n"];
            [self shareItems:@[text ?: @""] fromView:self.window];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [[self scuiTopController] presentViewController:a animated:YES completion:nil];
}

- (void)clearAPILogs {
    [NSFileManager.defaultManager removeItemAtPath:SCUILoggerPath() error:nil];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"API Logger" message:@"Logs apagados." preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [[self scuiTopController] presentViewController:a animated:YES completion:nil];
}

- (void)shareAllAPILogs {
    NSString *path = SCUILoggerPath();
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) { [self showAPILogs]; return; }
    [self shareItems:@[[NSURL fileURLWithPath:path]] fromView:self.window];
}

- (void)localLicenseBypassChanged:(UISwitch *)sender {
    SCUIManager.shared.prefs[@"localLicenseBypass"] = @(sender.on);
    SCUISave(SCUIManager.shared.prefs);
    NSString *msg = sender.on
        ? @"Modo local ativado. A rota /api/license/validate será respondida localmente para testes. Feche e abra a tela de key e valide novamente."
        : @"Modo local desativado. A validação volta a usar a API configurada/original.";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Bypass local" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [[self scuiTopController] presentViewController:a animated:YES completion:nil];
}

- (void)apiRoutingChanged:(UISwitch *)sender {
    SCUIManager.shared.prefs[@"apiRoutingEnabled"] = @(sender.on);
    SCUISave(SCUIManager.shared.prefs);
}

- (void)apiProfileChanged:(UISegmentedControl *)sender {
    SCUIManager.shared.prefs[@"apiProfile"] = @(sender.selectedSegmentIndex);
    SCUISave(SCUIManager.shared.prefs);
}

- (void)apiPreservePathChanged:(UISwitch *)sender {
    SCUIManager.shared.prefs[@"apiPreservePath"] = @(sender.on);
    SCUISave(SCUIManager.shared.prefs);
}

- (void)showAPIEditor {
    SCUIManager *m = SCUIManager.shared;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Conexão / API"
        message:@"API A/B/Custom são perfis locais. Host original vazio = filtrar apenas pelas rotas abaixo."
        preferredStyle:UIAlertControllerStyleAlert];
    NSArray *keys = @[@"apiAURL", @"apiBURL", @"apiCustomURL", @"apiSourceHost", @"apiPathFilter"];
    NSArray *placeholders = @[@"API A — https://servidor.com", @"API B — https://servidor.com", @"Custom — https://servidor.com", @"Host original (opcional)", @"Rotas separadas por vírgula"];
    for (NSInteger i=0; i<keys.count; i++) {
        [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
            f.placeholder = placeholders[i];
            f.text = [m.prefs[keys[i]] isKindOfClass:NSString.class] ? m.prefs[keys[i]] : @"";
            f.autocapitalizationType = UITextAutocapitalizationTypeNone;
            f.autocorrectionType = UITextAutocorrectionTypeNo;
            f.keyboardType = (i < 3) ? UIKeyboardTypeURL : UIKeyboardTypeDefault;
        }];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Salvar" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        for (NSInteger i=0; i<keys.count; i++) {
            m.prefs[keys[i]] = SCUITrim(a.textFields[i].text ?: @"");
        }
        SCUISave(m.prefs);
        [self refreshControls];
    }]];
    [[self scuiTopController] presentViewController:a animated:YES completion:nil];
}

- (void)testActiveAPI {
    NSString *baseText = SCUIActiveAPIBaseURL();
    NSURL *url = [NSURL URLWithString:baseText];
    if (!url || url.scheme.length == 0 || url.host.length == 0) {
        UIAlertController *bad = [UIAlertController alertControllerWithTitle:@"API inválida" message:@"Configure uma URL completa começando com http:// ou https://." preferredStyle:UIAlertControllerStyleAlert];
        [bad addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [[self scuiTopController] presentViewController:bad animated:YES completion:nil];
        return;
    }
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.timeoutIntervalForRequest = 8.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    [req setValue:@"Satanabe-Backend-Lab/1.0" forHTTPHeaderField:@"User-Agent"];
    [[session dataTaskWithRequest:req completionHandler:^(__unused NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *message = nil;
            if (error) message = [NSString stringWithFormat:@"Falha: %@", error.localizedDescription ?: @"erro desconhecido"];
            else if ([response isKindOfClass:NSHTTPURLResponse.class]) {
                NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
                message = [NSString stringWithFormat:@"Servidor respondeu HTTP %ld. Mesmo 401/404 confirma que o host respondeu.", (long)status];
            } else message = @"Servidor respondeu.";
            UIAlertController *ok = [UIAlertController alertControllerWithTitle:@"Teste da API" message:message preferredStyle:UIAlertControllerStyleAlert];
            [ok addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [[self scuiTopController] presentViewController:ok animated:YES completion:nil];
        });
    }] resume];
}

- (void)resetVisual {
    SCUIManager *m = SCUIManager.shared;
    m.prefs[@"glass"] = @NO;
    m.prefs[@"videoEnabled"] = @YES;
    m.prefs[@"videoMode"] = @0;
    m.prefs[@"glassIntensity"] = @0.62;
    m.prefs[@"cardRadius"] = @20.0;
    m.prefs[@"borderWidth"] = @0.55;
    m.prefs[@"bubbleSize"] = @56.0;
    m.prefs[@"bubbleOpacity"] = @0.90;
    m.prefs[@"haptics"] = @YES;
    m.prefs[@"apiLoggerEnabled"] = @YES;
    m.prefs[@"localLicenseBypass"] = @NO;
    m.prefs[@"apiRoutingEnabled"] = @NO;
    m.prefs[@"apiProfile"] = @0;
    m.prefs[@"apiPreservePath"] = @YES;
    SCUISave(m.prefs);
    for (UIWindow *w in SCUIWindows()) {
        SCUIWalkViews(w, ^(UIView *v){ SCUIRemoveGlassFromView(v); });
        SCUISetHostVideosHidden(w, NO);
    }
    [m apply];
}

@end

#pragma mark - Share latest API log from pop-ups

@interface UIViewController (SCUIAPILogShare)
- (void)scui_presentViewController:(UIViewController *)viewControllerToPresent
                          animated:(BOOL)flag
                        completion:(void (^)(void))completion;
@end

@implementation UIViewController (SCUIAPILogShare)
- (void)scui_presentViewController:(UIViewController *)viewControllerToPresent
                          animated:(BOOL)flag
                        completion:(void (^)(void))completion {
    if ([viewControllerToPresent isKindOfClass:UIAlertController.class] && SCUIAPILoggerEnabled()) {
        UIAlertController *alert = (UIAlertController *)viewControllerToPresent;
        BOOL exists = NO;
        for (UIAlertAction *action in alert.actions) {
            if ([action.title isEqualToString:@"Compartilhar log"]) { exists = YES; break; }
        }
        NSDictionary *latest = SCUILatestAPILog();
        if (!exists && latest) {
            [alert addAction:[UIAlertAction actionWithTitle:@"Compartilhar log"
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(__unused UIAlertAction *action) {
                NSDictionary *currentLog = SCUILatestAPILog() ?: latest;
                NSString *text = SCUIPrettyLog(currentLog);
                UIActivityViewController *share = [[UIActivityViewController alloc]
                    initWithActivityItems:@[text ?: @""] applicationActivities:nil];
                UIViewController *top = self;
                while (top.presentedViewController) top = top.presentedViewController;
                if (share.popoverPresentationController) {
                    share.popoverPresentationController.sourceView = top.view;
                    share.popoverPresentationController.sourceRect = top.view.bounds;
                }
                [top presentViewController:share animated:YES completion:nil];
            }]];
        }
    }
    [self scui_presentViewController:viewControllerToPresent animated:flag completion:completion];
}
@end

static void SCUIInstallAlertShareHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method a = class_getInstanceMethod(UIViewController.class, @selector(presentViewController:animated:completion:));
        Method b = class_getInstanceMethod(UIViewController.class, @selector(scui_presentViewController:animated:completion:));
        if (a && b) method_exchangeImplementations(a, b);
    });
}

__attribute__((constructor))
static void SCUIStart(void) {
    SCUIInstallAlertShareHook();
    SCUIInstallAPILogger();

    dispatch_async(dispatch_get_main_queue(), ^{
        SCUIManager *m = SCUIManager.shared;
        [m install];

        for (NSNotificationName n in @[UIApplicationDidBecomeActiveNotification,
                                      UIWindowDidBecomeKeyNotification,
                                      UISceneDidActivateNotification]) {
            [[NSNotificationCenter defaultCenter] addObserverForName:n object:nil
                queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                    [m install];
                }];
        }

        m.timer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES block:^(__unused NSTimer *timer) {
            for (UIWindow *window in SCUIWindows()) {
                if (window.hidden || window.windowLevel != UIWindowLevelNormal) continue;
                BOOL found = NO;
                for (UIView *v in window.subviews) {
                    if ([v isKindOfClass:SCUIOverlay.class]) {
                        found = YES;
                        [window bringSubviewToFront:v];
                        break;
                    }
                }
                if (!found) {
                    SCUIOverlay *o = [[SCUIOverlay alloc] initWithFrame:window.bounds];
                    o.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                    [window addSubview:o];
                    [m.overlays addObject:o];
                }
            }
        }];

        if ([m.prefs[@"videoMode"] integerValue] == 1) [m reloadCustomVideo];
    });
}
