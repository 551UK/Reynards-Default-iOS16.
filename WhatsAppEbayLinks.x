#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "Common/Common.h"

// Only eBay short links opened from WhatsApp are intercepted.
static __thread BOOL RDOpening = NO;

static BOOL RDHostIs(NSString *host, NSString *domain) {
    return [host isEqualToString:domain] ||
           [host hasSuffix:[@"." stringByAppendingString:domain]];
}
static BOOL RDEbayWeb(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    for (NSString *domain in @[@"ebay.co.uk", @"ebay.com", @"ebay.de",
        @"ebay.fr", @"ebay.it", @"ebay.es", @"ebay.ie", @"ebay.ca",
        @"ebay.com.au", @"ebay.nl"]) {
        if (RDHostIs(host,domain)) return YES;
    }
    return NO;
}
static BOOL RDShort(NSURL *url) {
    return [url.scheme.lowercaseString isEqualToString:@"https"] &&
           RDHostIs(url.host.lowercaseString ?: @"", @"ebay.io") &&
           [url.path hasPrefix:@"/m/"];
}
static BOOL RDEnabled(void) {
    NSUserDefaults *p = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
    [p synchronize];
    return (![p objectForKey:kEnabledKey] || [p boolForKey:kEnabledKey]) &&
           (![p objectForKey:kAppLinksKey] || [p boolForKey:kAppLinksKey]);
}
static NSString *RDNumericID(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length < 9 || s.length > 15)
        return nil;
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    return [s rangeOfCharacterFromSet:digits.invertedSet].location == NSNotFound ? s : nil;
}
static NSString *RDListingID(NSURL *url) {
    if (!RDEbayWeb(url)) return nil;
    static NSRegularExpression *r;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        r = [NSRegularExpression regularExpressionWithPattern:
            @"/itm/(?:[^/]+/)?([0-9]{9,15})(?:/|$)"
            options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    NSString *path = url.path ?: @"";
    NSTextCheckingResult *m = [r firstMatchInString:path options:0
                                             range:NSMakeRange(0,path.length)];
    if (m.numberOfRanges > 1)
        return [path substringWithRange:[m rangeAtIndex:1]];

    NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in parts.queryItems) {
        if (![@[@"itemid", @"item_id", @"listingid", @"itm"]
              containsObject:item.name.lowercaseString]) continue;
        NSString *idValue = RDNumericID(item.value);
        if (idValue) return idValue;
    }
    return nil;
}

// HTML fallback is limited to a canonical or OpenGraph listing URL.
// Never extract arbitrary product suggestions from the body.
static NSString *RDListingIDInHTML(NSData *body) {
    if (body.length == 0) return nil;
    NSData *shortBody = body.length > 524288 ? [body subdataWithRange:NSMakeRange(0,524288)] : body;
    NSString *html = [[NSString alloc] initWithData:shortBody encoding:NSUTF8StringEncoding];
    if (!html.length) return nil;
    static NSRegularExpression *canonical;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        canonical = [NSRegularExpression regularExpressionWithPattern:
          @"<(?:link|meta)\\b[^>]{0,1200}(?:rel\\s*=\\s*['\\\"]canonical['\\\"]|property\\s*=\\s*['\\\"]og:url['\\\"])[^>]{0,1200}>"
          options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    NSArray *tags = [canonical matchesInString:html options:0
                                         range:NSMakeRange(0,html.length)];
    static NSRegularExpression *href;
    static dispatch_once_t onceHref;
    dispatch_once(&onceHref, ^{
        href = [NSRegularExpression regularExpressionWithPattern:
            @"(?:href|content)\\s*=\\s*['\\\"]([^'\\\"]+)['\\\"]"
            options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    for (NSTextCheckingResult *tag in tags) {
        NSString *text = [html substringWithRange:tag.range];
        NSArray *attrs = [href matchesInString:text options:0
                                         range:NSMakeRange(0,text.length)];
        for (NSTextCheckingResult *attr in attrs) {
            if (attr.numberOfRanges < 2) continue;
            NSString *s = [[text substringWithRange:[attr rangeAtIndex:1]]
                stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
            NSString *item = RDListingID([NSURL URLWithString:s]);
            if (item) return item;
        }
    }
    return nil;
}

static void RDResolve(NSURL *shortURL, void (^completion)(NSString *)) {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = 7;
    config.timeoutIntervalForResource = 10;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:shortURL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8];
    request.HTTPMethod = @"GET";
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_3 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1"
 forHTTPHeaderField:@"User-Agent"];

    [[session dataTaskWithRequest:request completionHandler:
        ^(NSData *data, NSURLResponse *response, NSError *error) {
            NSString *item = nil;
            if (!error) {
                item = RDListingID(response.URL);
                if (!item && RDEbayWeb(response.URL))
                    item = RDListingIDInHTML(data);
            }
            [session finishTasksAndInvalidate];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(item);
            });
        }] resume];
}

// A Universal Link carries the item path directly to eBay on supported installs.
static NSURL *RDCanonicalItemURL(NSString *item) {
    return [NSURL URLWithString:
        [@"https://www.ebay.co.uk/itm/" stringByAppendingString:item]];
}
static NSURL *RDModernLink(NSString *item) {
    return [NSURL URLWithString:[NSString stringWithFormat:
        @"ebay://com.ebay.mobile/ebay/link/?nav=item.view&id=%@",item]];
}
static NSURL *RDLegacyLink(NSString *item) {
    return [NSURL URLWithString:[@"ebay://launch?itm=" stringByAppendingString:item]];
}
static BOOL RDOlderEbayVersion(void) {
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL factory = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (![proxyClass respondsToSelector:factory]) return NO;
    // Dynamic lookup: versions in recent iOS differ in which proxy properties are exposed.
    id (*lookup)(id,SEL,id) = (void *)objc_msgSend;
    id proxy = lookup(proxyClass, factory, @"com.ebay.iphone");
    SEL getter = NSSelectorFromString(@"shortVersionString");
    if (![proxy respondsToSelector:getter]) return NO;
    id (*read)(id,SEL) = (void *)objc_msgSend;
    NSString *version = read(proxy,getter);
    if (![version isKindOfClass:[NSString class]]) return NO;
    NSArray *parts = [version componentsSeparatedByString:@"."];
    if (parts.count < 2) return NO;
    NSInteger major = [parts[0] integerValue];
    NSInteger minor = [parts[1] integerValue];
    // eBay changed its public listing scheme after the older 6.x releases.
    return major == 6 && minor < 120;
}

static void RDDirectOriginal(UIApplication *app, NSURL *original,
                             NSDictionary *options, void (^completion)(BOOL)) {
    RDOpening = YES;
    [app openURL:original options:options ?: @{}
 completionHandler:completion];
    RDOpening = NO;
}
static void RDOpenListing(UIApplication *app, NSString *item, NSURL *original,
                          NSDictionary *options, void (^completion)(BOOL)) {
    if (!item.length) {
        RDDirectOriginal(app,original,options,completion);
        return;
    }
    NSURL *canonical = RDCanonicalItemURL(item);
    NSMutableDictionary *universal = [options mutableCopy] ?: [NSMutableDictionary new];
    universal[UIApplicationOpenURLOptionUniversalLinksOnly] = @YES;

    // Crucial: first ask iOS to open the actual listing as a Universal Link.
    RDOpening = YES;
    [app openURL:canonical options:universal completionHandler:^(BOOL didOpen) {
        if (didOpen) {
            if (completion) completion(YES);
            return;
        }
        // The app version determines which item-specific scheme to try.
        NSURL *deeplink = RDOlderEbayVersion() ? RDLegacyLink(item) : RDModernLink(item);
        RDOpening = YES;
        [app openURL:deeplink options:@{} completionHandler:^(BOOL opened) {
            if (opened) {
                if (completion) completion(YES);
                return;
            }
            // Never launch eBay home as the fallback: keep the listing URL.
            RDDirectOriginal(app,canonical,options,completion);
        }];
        RDOpening = NO;
    }];
    RDOpening = NO;
}

%hook UIApplication

- (void)openURL:(NSURL *)url options:(NSDictionary *)options
 completionHandler:(void (^)(BOOL success))completion {
    if (RDOpening || !RDEnabled() || !RDShort(url)) {
        %orig;
        return;
    }
    RDResolve(url, ^(NSString *item) {
        RDOpenListing(self,item,url,options,completion);
    });
}

- (BOOL)openURL:(NSURL *)url {
    if (RDOpening || !RDEnabled() || !RDShort(url))
        return %orig;
    RDResolve(url, ^(NSString *item) {
        RDOpenListing(self,item,url,@{},nil);
    });
    return YES;
}

%end
