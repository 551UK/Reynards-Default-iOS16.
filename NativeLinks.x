#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "Common/Common.h"
#import "Routing.h"

// Shared by UIApplication and FrontBoard interceptors.
static __thread BOOL gBypassing = NO;
static char kHandledOptionsKey;

@interface FBSOpenApplicationOptions : NSObject
@property (nonatomic, readonly) NSURL *url;
@property (nonatomic, readonly) NSDictionary *dictionary;
+ (instancetype)optionsWithDictionary:(NSDictionary *)dictionary;
@end

@interface FBSOpenApplicationService : NSObject
- (void)openApplication:(NSString *)bid
           withOptions:(FBSOpenApplicationOptions *)options
            completion:(id)completion;
- (void)openApplication:(NSString *)bid
           withOptions:(FBSOpenApplicationOptions *)options
          clientHandle:(id)client
            completion:(id)completion;
@end

static BOOL RDEnabled(void) {
    NSUserDefaults *p = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
    [p synchronize];
    id enabled = [p objectForKey:kEnabledKey];
    id links = [p objectForKey:kAppLinksKey];
    return (!enabled || [enabled boolValue]) && (!links || [links boolValue]);
}
static BOOL RDBrowser(NSString *bid) {
    return [@[@"com.apple.mobilesafari", @"org.mozilla.ios.Firefox",
        @"com.google.chrome.ios", @"com.brave.ios.browser",
        @"com.microsoft.msedge", @"org.mozilla.ios.Focus",
        @"com.minh-ton.Reynard",
        @"com.duckduckgo.mobile.ios"] containsObject:bid];
}
// Some requests arrive after the SpringBoard redirect has wrapped them.
static NSURL *RDSourceURL(NSURL *url) {
    if (!url) return nil;
    if ([url.scheme.lowercaseString isEqualToString:@"reynard"] &&
        [url.host.lowercaseString isEqualToString:@"open"]) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:url
                                             resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem *item in components.queryItems) {
            if (![item.name isEqualToString:@"url"]) continue;
            NSURL *decoded = [NSURL URLWithString:item.value ?: @""];
            if (RDIsEbayShortLink(decoded)) return decoded;
        }
    }
    return url;
}

static BOOL RDHasEbayShortLink(NSURL *url) {
    return RDIsEbayShortLink(RDSourceURL(url));
}

static NSURL *RDReynardURL(NSURL *url) {
    NSCharacterSet *safe = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    NSString *encoded = [url.absoluteString stringByAddingPercentEncodingWithAllowedCharacters:safe];
    return encoded.length ?
        [NSURL URLWithString:[@"reynard://open?url=" stringByAppendingString:encoded]] : nil;
}

// Read the first HTTP redirect without needing to load an eBay webpage.
// eBay's short-link service redirects directly to /itm/<listing-id>.
@interface RDShortResolver : NSObject <NSURLSessionTaskDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, copy) void (^finished)(NSString *);
@property (atomic, assign) BOOL didFinish;
@end

@implementation RDShortResolver
- (void)finish:(NSString *)item {
    @synchronized (self) {
        if (_didFinish) return;
        _didFinish = YES;
    }
    void (^callback)(NSString *) = self.finished;
    self.finished = nil;
    [self.session invalidateAndCancel];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (callback) callback(item);
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completion {
    NSString *item = RDItemID(request.URL);
    if (item) {
        // Stop before loading a possibly blocked 403 listing page.
        completion(nil);
        [self finish:item];
        return;
    }
    completion(request);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    NSString *item = RDItemID(task.response.URL);
    [self finish:item];
}
@end

static void RDResolve(NSURL *url, void (^completion)(NSString *)) {
    if (!RDIsEbayShortLink(url)) {
        if (completion) completion(nil);
        return;
    }
    RDShortResolver *resolver = [RDShortResolver new];
    resolver.finished = completion;
    NSURLSessionConfiguration *config =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = 7;
    config.timeoutIntervalForResource = 10;
    resolver.session = [NSURLSession sessionWithConfiguration:config
                        delegate:resolver delegateQueue:nil];
    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:7];
    request.HTTPMethod = @"GET";
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_3 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1"
  forHTTPHeaderField:@"User-Agent"];
    [[resolver.session dataTaskWithRequest:request] resume];
}

// Modifies a verified FBS URL payload while preserving all launch options.
static FBSOpenApplicationOptions *RDOptionsForItem(FBSOpenApplicationOptions *old,
                                                   NSURL *newURL) {
    if (!old || !newURL || ![old respondsToSelector:@selector(dictionary)])
        return nil;
    NSDictionary *original = old.dictionary;
    if (![original isKindOfClass:[NSDictionary class]]) return nil;
    NSMutableDictionary *updated = [original mutableCopy];
    BOOL replaced = NO;
    for (id key in original) {
        id value = original[key];
        if ([value isKindOfClass:[NSURL class]] && RDHasEbayShortLink(value)) {
            updated[key] = newURL;
            replaced = YES;
        }
    }
    if (!replaced && old.url && RDHasEbayShortLink(old.url)) {
        // Private FBS payload key used by iOS 15/16.
        updated[@"__PayloadURL"] = newURL;
        replaced = YES;
    }
    if (!replaced) return nil;
    Class cls = [old class];
    if (![cls respondsToSelector:@selector(optionsWithDictionary:)]) return nil;
    FBSOpenApplicationOptions *replacement = [cls optionsWithDictionary:updated];
    return [replacement.url isEqual:newURL] ? replacement : nil;
}

static NSURL *RDRequestURL(FBSOpenApplicationOptions *options) {
    if ([options respondsToSelector:@selector(url)] && options.url)
        return RDSourceURL(options.url);
    if (![options respondsToSelector:@selector(dictionary)]) return nil;
    for (id value in options.dictionary.allValues)
        if ([value isKindOfClass:[NSURL class]] && RDHasEbayShortLink(value))
            return RDSourceURL(value);
    return nil;
}

static BOOL RDShouldRouteFBS(NSString *bid, FBSOpenApplicationOptions *options) {
    return !gBypassing && RDEnabled() && RDBrowser(bid) &&
           !objc_getAssociatedObject(options, &kHandledOptionsKey) &&
           RDIsEbayShortLink(RDRequestURL(options));
}

static void RDPrepareFallback(FBSOpenApplicationOptions *options) {
    if (options)
        objc_setAssociatedObject(options, &kHandledOptionsKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void RDSystemOpen(UIApplication *app, NSURL *url,
                          NSDictionary *options, void (^completion)(BOOL)) {
    if (!url) {
        if (completion) completion(NO);
        return;
    }
    gBypassing = YES;
    [app openURL:url options:options ?: @{} completionHandler:completion];
    gBypassing = NO;
}

static void RDOpenBrowser(UIApplication *app, NSURL *url,
                           void (^completion)(BOOL)) {
    NSURL *reynard = RDReynardURL(url);
    RDSystemOpen(app,reynard ?: url,@{},completion);
}

static void RDOpenUniversal(UIApplication *app, NSURL *url,
                             void (^completion)(BOOL)) {
    if (![url.scheme.lowercaseString isEqualToString:@"https"]) {
        RDOpenBrowser(app,url,completion);
        return;
    }
    RDSystemOpen(app,url,@{UIApplicationOpenURLOptionUniversalLinksOnly:@YES},
                 ^(BOOL handled) {
        if (handled) {
            if (completion) completion(YES);
        } else {
            RDOpenBrowser(app,url,completion);
        }
    });
}

static void RDOpenListing(UIApplication *app, NSString *item, NSURL *source,
                           void (^completion)(BOOL)) {
    NSURL *listing = RDEbayListingURL(item);
    if (!listing) {
        RDOpenBrowser(app,source,completion);
        return;
    }
    RDSystemOpen(app,listing,@{},^(BOOL opened) {
        if (opened) {
            if (completion) completion(YES);
        } else {
            RDOpenBrowser(app,source,completion);
        }
    });
}

static void RDOpenLink(UIApplication *app, NSURL *url,
                        void (^completion)(BOOL)) {
    if (RDIsEbayShortLink(url)) {
        RDResolve(url,^(NSString *item) {
            RDOpenListing(app,item,url,completion);
        });
    } else {
        NSString *item = RDItemID(url);
        if (item) RDOpenListing(app,item,url,completion);
        else RDOpenUniversal(app,url,completion);
    }
}

// Catch standard UIKit link openings.
%hook UIApplication
- (void)openURL:(NSURL *)url options:(NSDictionary *)options
 completionHandler:(void (^)(BOOL success))completion {
    if (gBypassing || !RDEnabled() || !RDIsAppLink(url) ||
        [options[UIApplicationOpenURLOptionUniversalLinksOnly] boolValue]) {
        %orig;
        return;
    }
    RDOpenLink(self,url,completion);
}
- (BOOL)openURL:(NSURL *)url {
    if (gBypassing || !RDEnabled() || !RDIsAppLink(url)) return %orig;
    RDOpenLink(self,url,nil);
    return YES;
}
%end

// Catch the lower-level app-opening path used by some messaging apps.
// Only eBay short URLs are intercepted here; every other launch passes through.
%hook FBSOpenApplicationService
- (void)openApplication:(NSString *)bid
           withOptions:(FBSOpenApplicationOptions *)options
            completion:(id)completion {
    if (!RDShouldRouteFBS(bid,options)) { %orig; return; }
    NSURL *original = RDRequestURL(options);
    RDResolve(original, ^(NSString *item) {
        FBSOpenApplicationOptions *replacement =
            RDOptionsForItem(options,RDEbayListingURL(item));
        gBypassing = YES;
        if (replacement) {
            [self openApplication:@"com.ebay.iphone"
                     withOptions:replacement completion:completion];
        } else {
            RDPrepareFallback(options);
            [self openApplication:bid withOptions:options completion:completion];
        }
        gBypassing = NO;
    });
}

- (void)openApplication:(NSString *)bid
           withOptions:(FBSOpenApplicationOptions *)options
          clientHandle:(id)client
            completion:(id)completion {
    if (!RDShouldRouteFBS(bid,options)) { %orig; return; }
    NSURL *original = RDRequestURL(options);
    RDResolve(original, ^(NSString *item) {
        FBSOpenApplicationOptions *replacement =
            RDOptionsForItem(options,RDEbayListingURL(item));
        gBypassing = YES;
        if (replacement) {
            [self openApplication:@"com.ebay.iphone" withOptions:replacement
                    clientHandle:client completion:completion];
        } else {
            RDPrepareFallback(options);
            [self openApplication:bid withOptions:options
                    clientHandle:client completion:completion];
        }
        gBypassing = NO;
    });
}
%end

%ctor {
    // Ensure FrontBoard's client class exists before Logos installs the hook.
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
    %init;
}
