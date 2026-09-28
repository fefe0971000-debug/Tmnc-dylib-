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
        @"videoMode": @0,              // 0 = original, 1 = personalizado
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

    // IMPORTANT: snapshot BEFORE block(v). The block may insert/remove subviews.
    // Walking newly inserted UIVisualEffectView internals recursively can grow the
    // hierarchy indefinitely and eventually terminate the host app.
    NSArray<UIView *> *children = [v.subviews copy];
    block(v);

    // Never inspect Apple's private blur hierarchy or our injected blur descendants.
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

    NSData *data = [NSData dataWithContentsOfFile:path
                                          options:NSDataReadingMappedIfSafe
                                            error:NULL];
    if (!data.length) return;

    NSString *blob = [[NSString alloc] initWithData:data
                                           encoding:NSISOLatin1StringEncoding];
    if (!blob.length) return;

    NSError *regexError = nil;
    NSRegularExpression *regex =
        [NSRegularExpression regularExpressionWithPattern:@"https?://[^\\\\x00\\\\s\\\"'<>]+"
                                                  options:NSRegularExpressionCaseInsensitive
                                                    error:&regexError];
    if (!regex || regexError) return;

    NSArray<NSTextCheckingResult *> *matches =
        [regex matchesInString:blob options:0 range:NSMakeRange(0, blob.length)];

    for (NSTextCheckingResult *result in matches) {
        if (!result || result.range.location == NSNotFound) continue;
        NSString *value = [blob substringWithRange:result.range];
        while (value.length &&
               ([value hasSuffix:@"."] || [value hasSuffix:@","] ||
                [value hasSuffix:@")"] || [value hasSuffix:@"]"] ||
                [value hasSuffix:@"}"])) {
            value = [value substringToIndex:value.length - 1];
        }
        if (value.length) [urls addObject:value];
    }
}

static NSArray<NSString *> *SCUIStaticURLInventory(void) {
    NSMutableOrderedSet<NSString *> *urls = [NSMutableOrderedSet orderedSet];

    // Main executable.
    SCUICollectURLsFromFile(NSBundle.mainBundle.executablePath, urls);

    // Every Mach-O image currently loaded in the process (frameworks/dylibs included).
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
            @"event": @"static_url",
            @"method": @"STATIC",
            @"url": url ?: @"",
            @"source": @"loaded_macho_inventory"
        });
    }
}


static NSString *SCUIFindStringForKeys(id obj, NSSet<NSString *> *wanted) {
    if (!obj || !wanted.count) return nil;
    if ([obj isKindOfClass:NSDictionary.class]) {
        for (id rawKey in [(NSDictionary *)obj allKeys]) {
            NSString *key = [[rawKey description] lowercaseString];
            id value = ((NSDictionary *)obj)[rawKey];
            if ([wanted containsObject:key] && [value isKindOfClass:NSString.class] && [value length]) {
                return value;
            }
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
            if ([wanted containsObject:key] && [value respondsToSelector:@selector(boolValue)]) {
                return @([value boolValue]);
            }
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

    // HTTP status alone is not enough to call a key valid, but common auth failures
    // can safely be marked as an invalid/denied validation attempt.
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

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *marked = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"SCUILocalLicenseHandled" inRequest:marked];

    NSString *deviceID = SCUIDeviceIDFromRequest(self.request);
    NSDictionary *payload = @{
        @"valid": @YES,
        @"code": @"LOCAL_TEST",
        @"message": @"Local test mode enabled",
        @"package": @"local",
        @"expiresAt": @"2099-12-31T23:59:59.000Z",
        @"remainingUses": @999999,
        @"deviceId": deviceID,
        @"durationDays": @9999,
        @"durationMinutes": @0,
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
    // Preserve the app's path/query. This makes the same IPA usable against APIs
    // that expose compatible routes on different hosts.
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
@property(nonatomic) NSInteger documentPickerPurpose; // 0=video, 1=export patch/payload
@property(nonatomic, strong) NSURL *pendingExportSourceURL;
