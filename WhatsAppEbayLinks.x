#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "Common/Common.h"

// Resolve eBay's official shared short URLs only when a link is tapped.
static __thread BOOL RDBypass = NO;

static BOOL RDHostIs(NSString *host, NSString *domain) {
    return [host isEqualToString:domain] ||
           [host hasSuffix:[@"." stringByAppendingString:domain]];
}
static BOOL RDShortLink(NSURL *url) {
    return [url.scheme.lowercaseString isEqualToString:@"https"] &&
           RDHostIs(url.host.lowercaseString ?: @"", @"ebay.io");
}
static BOOL RDEbayWeb(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    for (NSString *domain in @[@"ebay.co.uk", @"ebay.com", @"ebay.de", @"ebay.fr",
                               @"ebay.it", @"ebay.es", @"ebay.ie", @"ebay.ca",
                               @"ebay.com.au", @"ebay.nl", @"ebay.us"]) {
        if (RDHostIs(host,domain)) return YES;
    }
    return NO;
}
static BOOL RDEnabled(void) {
    NSUserDefaults *p = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
    [p synchronize];
    return (![p objectForKey:kEnabledKey] || [p boolForKey:kEnabledKey]) &&
           (![p objectForKey:kAppLinksKey] || [p boolForKey:kAppLinksKey]);
}
static NSString *RDItemID(NSURL *url) {
    if (!RDEbayWeb(url)) return nil;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"/itm/(?:[^/]+/)?([0-9]{9,15})(?:/|$)"
              options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    NSString *path = url.path ?: @"";
    NSTextCheckingResult *match = [re firstMatchInString:path options:0
                                                  range:NSMakeRange(0,path.length)];
    if (match.numberOfRanges > 1) return [path substringWithRange:[match rangeAtIndex:1]];

    NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in parts.queryItems) {
        NSString *name = item.name.lowercaseString;
        if (![@[@"itemid",@"item_id",@"listingid",@"itm"] containsObject:name]) continue;
        NSString *value = item.value ?: @"";
        if (value.length < 9 || value.length > 15) continue;
        if ([value rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location
            == NSNotFound) return value;
    }
    return nil;
}
static NSURL *RDAppListing(NSURL *url) {
    NSString *item = RDItemID(url);
    if (!item) return nil;
    return [NSURL URLWithString:[NSString stringWithFormat:
        @"ebay://com.ebay.mobile/ebay/link/?nav=item.view&id=%@",item]];
}
static void RDResolveShortURL(NSURL *shortURL, void (^done)(NSURL *)) {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = 7;
    config.timeoutIntervalForResource = 10;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    __block void (^finish)(NSURL *) = [done copy];
    void (^complete)(NSURL *) = ^(NSURL *value) {
        void (^callback)(NSURL *) = finish;
        finish = nil;
        [session finishTasksAndInvalidate];
        if (callback) callback(value);
    };

    void (^request)(NSString *, BOOL) = ^(NSString *method, BOOL allowRetry) {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:shortURL
            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:7];
        req.HTTPMethod = method;
        [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_3 like Mac OS X)"
   forHTTPHeaderField:@"User-Agent"];

        NSURLSessionDataTask *task = [session dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                NSURL *finalURL = response.URL;
                NSURL *target = !error ? RDAppListing(finalURL) : nil;
                if (target) { complete(target); return; }
                if (allowRetry) {
                    // Some short-link services reject HEAD but accept GET.
                    NSMutableURLRequest *get = [req mutableCopy];
                    get.HTTPMethod = @"GET";
                    NSURLSessionDataTask *second = [session dataTaskWithRequest:get
                        completionHandler:^(NSData *body, NSURLResponse *res, NSError *err) {
                            NSURL *resolved = !err ? RDAppListing(res.URL) : nil;
                            if (!resolved && !err && RDEbayWeb(res.URL))
                                resolved = res.URL; // universal-link fallback
                            complete(resolved);
                        }];
                    [second resume];
                    return;
                }
                complete(nil);
            }];
        [task resume];
    };
    request(@"HEAD",YES);
}

%hook UIApplication
- (void)openURL:(NSURL *)url options:(NSDictionary *)options
 completionHandler:(void (^)(BOOL success))completion {
    if (RDBypass || !RDEnabled() || !RDShortLink(url)) { %orig; return; }

    RDResolveShortURL(url, ^(NSURL *target) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Redirect only to an eBay URL. Never send an unrelated redirect to an app.
            if (target) {
                [self openURL:target options:options completionHandler:^(BOOL ok) {
                    if (ok) { if (completion) completion(YES); return; }
                    RDBypass = YES;
                    [self openURL:url options:options completionHandler:completion];
                    RDBypass = NO;
                }];
            } else {
                RDBypass = YES;
                [self openURL:url options:options completionHandler:completion];
                RDBypass = NO;
            }
        });
    });
}

- (BOOL)openURL:(NSURL *)url {
    if (RDBypass || !RDEnabled() || !RDShortLink(url)) return %orig;
    RDResolveShortURL(url, ^(NSURL *target) {
        dispatch_async(dispatch_get_main_queue(), ^{
            RDBypass = YES;
            [[UIApplication sharedApplication] openURL:target ?: url
                options:@{} completionHandler:nil];
            RDBypass = NO;
        });
    });
    return YES;
}
%end
