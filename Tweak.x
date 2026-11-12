#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "Common/Common.h"

@interface FBSOpenApplicationOptions : NSObject
@property (nonatomic, readonly) NSURL *url;
@property (nonatomic, readonly) NSDictionary *dictionary;
+ (instancetype)optionsWithDictionary:(NSDictionary *)data;
@end

@interface FBSystemServiceOpenApplicationRequest : NSObject
@property (nonatomic, copy) NSURL *URL;
@property (nonatomic, copy) NSString *bundleIdentifier;
@property (nonatomic, copy) FBSOpenApplicationOptions *options;
@end

static NSString *const kReynardID = @"com.minh-ton.Reynard";
static char kOriginalBrowserKey, kOriginalURLKey;
static __thread BOOL gRewriting = NO;

static BOOL isBrowser(NSString *bid) {
    return [@[@"com.apple.mobilesafari", @"org.mozilla.ios.Firefox",
              @"org.mozilla.ios.Focus", @"com.google.chrome.ios",
              @"com.brave.ios.browser", @"com.microsoft.msedge",
              @"com.duckduckgo.mobile.ios"] containsObject:bid];
}

static BOOL isHTTPURL(NSURL *url) {
    return [url.scheme.lowercaseString isEqualToString:@"https"] ||
           [url.scheme.lowercaseString isEqualToString:@"http"];
}

static BOOL enabled(void) {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
    [prefs synchronize];
    id value = [prefs objectForKey:kEnabledKey];
    return value ? [prefs boolForKey:kEnabledKey] : YES;
}

static NSURL *wrappedURL(NSURL *original) {
    if (!isHTTPURL(original)) return nil;
    NSCharacterSet *safe = [NSCharacterSet characterSetWithCharactersInString:
         @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    NSString *value = [original.absoluteString stringByAddingPercentEncodingWithAllowedCharacters:safe];
    if (!value.length) return nil;
    return [NSURL URLWithString:[@"reynard://open?url=" stringByAppendingString:value]];
}

static BOOL setRequestURL(FBSystemServiceOpenApplicationRequest *req,
                          NSURL *oldURL, NSURL *newURL) {
    BOOL changedURL = NO;

    FBSOpenApplicationOptions *options =
       [req respondsToSelector:@selector(options)] ? req.options : nil;
    NSDictionary *payload =
       [options respondsToSelector:@selector(dictionary)] ? options.dictionary : nil;

    if ([payload isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *newPayload = [payload mutableCopy];
        BOOL found = NO;
        for (id key in payload) {
            id current = payload[key];
            if ([current isKindOfClass:[NSURL class]] && [current isEqual:oldURL]) {
                newPayload[key] = newURL;
                found = YES;
            }
        }
        if (found && [[options class] respondsToSelector:@selector(optionsWithDictionary:)] &&
            [req respondsToSelector:@selector(setOptions:)]) {
            FBSOpenApplicationOptions *replacement =
                [[options class] optionsWithDictionary:newPayload];
            if ([replacement.url isEqual:newURL]) {
                req.options = replacement;
                changedURL = YES;
            }
        }
    }

    if ([req respondsToSelector:@selector(setURL:)] &&
        [req respondsToSelector:@selector(URL)] && req.URL) {
        req.URL = newURL;
        changedURL = [req.URL isEqual:newURL] || changedURL;
    }

    return changedURL;
}

static void route(FBSystemServiceOpenApplicationRequest *req) {
    if (gRewriting || !enabled()) return;
    NSString *requestedBrowser = objc_getAssociatedObject(req, &kOriginalBrowserKey);
    if (!isBrowser(requestedBrowser)) return;

    NSURL *original = objc_getAssociatedObject(req, &kOriginalURLKey);
    if (!original && [req respondsToSelector:@selector(URL)]) original = req.URL;
    if (!original && [req respondsToSelector:@selector(options)] &&
        [req.options respondsToSelector:@selector(url)]) original = req.options.url;
    NSURL *newURL = wrappedURL(original);
    if (!newURL) return;

    // Never force another app to open by bundle ID. Its URL handler, not the
    // application launch, must decide whether it can show the exact content.
    gRewriting = YES;
    if (setRequestURL(req, original, newURL) &&
        [req respondsToSelector:@selector(setBundleIdentifier:)]) {
        req.bundleIdentifier = kReynardID;
    }
    gRewriting = NO;
}

%hook FBSystemServiceOpenApplicationRequest

- (void)setBundleIdentifier:(NSString *)bid {
    if (gRewriting) { %orig; return; }
    objc_setAssociatedObject(self, &kOriginalBrowserKey, isBrowser(bid) ? bid : nil,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    %orig;
    route(self);
}

- (void)setURL:(NSURL *)url {
    if (gRewriting) { %orig; return; }
    objc_setAssociatedObject(self, &kOriginalURLKey, url,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
    route(self);
}

- (void)setOptions:(FBSOpenApplicationOptions *)options {
    if (gRewriting) { %orig; return; }
    NSURL *url = [options respondsToSelector:@selector(url)] ? options.url : nil;
    if (url) objc_setAssociatedObject(self, &kOriginalURLKey, url,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
    route(self);
}

%end
