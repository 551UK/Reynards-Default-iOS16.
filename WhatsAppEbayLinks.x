#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "Common/Common.h"

// Preserve the full content URL. Let iOS verify the destination app.
static __thread BOOL gOpeningFromRouter = NO;

static BOOL isHost(NSString *host, NSString *domain) {
    return [host isEqualToString:domain] ||
        [host hasSuffix:[@"." stringByAppendingString:domain]];
}

static BOOL isEbaySite(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    for (NSString *site in @[@"ebay.co.uk", @"ebay.com", @"ebay.de",
        @"ebay.fr", @"ebay.it", @"ebay.es", @"ebay.ie", @"ebay.ca",
        @"ebay.com.au", @"ebay.nl"]) {
        if (isHost(host, site)) return YES;
    }
    return NO;
}

static BOOL isEbayShortURL(NSURL *url) {
    return [url.scheme.lowercaseString isEqualToString:@"https"] &&
           isHost(url.host.lowercaseString ?: @"", @"ebay.io") &&
           [url.path hasPrefix:@"/m/"];
}

static BOOL isSupportedLink(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if (![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"])
        return NO;

    NSString *host = url.host.lowercaseString ?: @"";
    if (isEbaySite(url) || isEbayShortURL(url)) return YES;

    for (NSString *site in @[@"instagram.com", @"instagr.am",
        @"reddit.com", @"redd.it", @"youtube.com", @"youtu.be",
        @"tiktok.com", @"vm.tiktok.com", @"twitter.com", @"x.com",
        @"facebook.com", @"fb.watch", @"open.spotify.com",
        @"pinterest.com", @"pin.it", @"twitch.tv", @"soundcloud.com"]) {
        if (isHost(host, site)) return YES;
    }
    return NO;
}

static BOOL isEnabled(void) {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
    [prefs synchronize];
    id general = [prefs objectForKey:kEnabledKey];
    id appLinks = [prefs objectForKey:kAppLinksKey];
    return (!general || [prefs boolForKey:kEnabledKey]) &&
           (!appLinks || [prefs boolForKey:kAppLinksKey]);
}

static NSString *itemID(NSURL *url) {
    if (!isEbaySite(url)) return nil;

    static NSRegularExpression *itemRegex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        itemRegex = [NSRegularExpression regularExpressionWithPattern:
            @"/itm/(?:[^/]+/)?([0-9]{9,15})(?:/|$)"
            options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    NSString *path = url.path ?: @"";
    NSTextCheckingResult *match = [itemRegex firstMatchInString:path
        options:0 range:NSMakeRange(0, path.length)];
    if (match.numberOfRanges > 1)
        return [path substringWithRange:[match rangeAtIndex:1]];

    NSURLComponents *components = [NSURLComponents componentsWithURL:url
        resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *param in components.queryItems) {
        if (![@[@"itemid", @"item_id", @"listingid", @"itm"]
              containsObject:param.name.lowercaseString ?: @""]) continue;
        NSString *value = param.value ?: @"";
        if (value.length >= 9 && value.length <= 15 &&
            [value rangeOfCharacterFromSet:
                NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound)
            return value;
    }
    return nil;
}

// Some redirects finish at an HTML page with a canonical eBay listing.
static NSURL *canonicalFromHTML(NSData *body) {
    if (!body.length) return nil;
    NSData *first = body.length <= 524288 ? body :
       [body subdataWithRange:NSMakeRange(0, 524288)];
    NSString *html = [[NSString alloc] initWithData:first encoding:NSUTF8StringEncoding];
    if (!html.length) return nil;

    static NSRegularExpression *tags;
    static NSRegularExpression *attributes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tags = [NSRegularExpression regularExpressionWithPattern:
          @"<(?:link|meta)\\b[^>]{0,2400}(?:canonical|og:url)[^>]{0,2400}>"
          options:NSRegularExpressionCaseInsensitive error:NULL];
        attributes = [NSRegularExpression regularExpressionWithPattern:
          @"(?:href|content)\\s*=\\s*['\\\"]([^'\\\"]+)['\\\"]"
          options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    NSArray *matches = [tags matchesInString:html options:0
        range:NSMakeRange(0,html.length)];
    for (NSTextCheckingResult *tag in matches) {
        NSString *chunk = [html substringWithRange:tag.range];
        NSArray *found = [attributes matchesInString:chunk options:0
            range:NSMakeRange(0,chunk.length)];
        for (NSTextCheckingResult *attr in found) {
            if (attr.numberOfRanges < 2) continue;
            NSString *raw = [[chunk substringWithRange:[attr rangeAtIndex:1]]
                stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
            NSURL *canonical = [NSURL URLWithString:raw];
            if (itemID(canonical)) return canonical;
        }
    }
    return nil;
}

static void resolveEbayShortURL(NSURL *url, void (^finished)(NSURL *)) {
    NSURLSessionConfiguration *config =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = 8;
    config.timeoutIntervalForResource = 10;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
        timeoutInterval:8];
    request.HTTPMethod = @"GET";
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_3 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1"
        forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
        completionHandler:^(NSData *body, NSURLResponse *response, NSError *error) {
            NSURL *resolved = nil;
            if (!error) {
                if (itemID(response.URL)) resolved = response.URL;
                if (!resolved && isEbaySite(response.URL))
                    resolved = canonicalFromHTML(body);
            }
            [session finishTasksAndInvalidate];
            dispatch_async(dispatch_get_main_queue(), ^{ finished(resolved); });
        }];
    [task resume];
}

static NSURL *reynardURL(NSURL *url) {
    NSCharacterSet *safe = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    NSString *encoded = [url.absoluteString stringByAddingPercentEncodingWithAllowedCharacters:safe];
    return encoded.length ? [NSURL URLWithString:
        [@"reynard://open?url=" stringByAppendingString:encoded]] : nil;
}

static void callOriginalOpen(UIApplication *app, NSURL *url,
                             NSDictionary *options, void (^done)(BOOL)) {
    gOpeningFromRouter = YES;
    [app openURL:url options:options ?: @{} completionHandler:done];
    gOpeningFromRouter = NO;
}

static void openInBrowser(UIApplication *app, NSURL *url,
                          NSDictionary *options, void (^done)(BOOL)) {
    NSURL *browserURL = reynardURL(url);
    if (!browserURL) {
        callOriginalOpen(app,url,options,done);
        return;
    }
    callOriginalOpen(app,browserURL,@{},^(BOOL launched) {
        if (launched) {
            if (done) done(YES);
        } else {
            // When Reynard isn't installed, keep the original URL usable.
            callOriginalOpen(app,url,options,done);
        }
    });
}

static void openContent(UIApplication *app, NSURL *url,
                        NSDictionary *options, void (^done)(BOOL)) {
    NSMutableDictionary *universal = [options mutableCopy] ?: [NSMutableDictionary dictionary];
    universal[UIApplicationOpenURLOptionUniversalLinksOnly] = @YES;
    callOriginalOpen(app,url,universal,^(BOOL handled) {
        if (handled) {
            // iOS has handed the exact content URL to its associated app.
            if (done) done(YES);
        } else {
            // Don't launch the app by bundle ID or send a bare app:// URL:
            // both can open an app home page rather than the content.
            openInBrowser(app,url,options,done);
        }
    });
}

static void routeLink(UIApplication *app, NSURL *url, NSDictionary *options,
                      void (^done)(BOOL)) {
    if (isEbayShortURL(url)) {
        resolveEbayShortURL(url,^(NSURL *resolved) {
            if (resolved) {
                openContent(app,resolved,options,done);
            } else {
                // Keep the original short link in a browser, not eBay's home.
                openInBrowser(app,url,options,done);
            }
        });
    } else {
        // Instagram posts, Reddit threads, YouTube videos etc: original path
        // and query are preserved, including tracking and content identifiers.
        openContent(app,url,options,done);
    }
}

%hook UIApplication

- (void)openURL:(NSURL *)url options:(NSDictionary *)options
 completionHandler:(void (^)(BOOL success))completion {
    if (gOpeningFromRouter || !isEnabled() || !isSupportedLink(url) ||
        [options[UIApplicationOpenURLOptionUniversalLinksOnly] boolValue]) {
        %orig;
        return;
    }
    routeLink(self,url,options,completion);
}

- (BOOL)openURL:(NSURL *)url {
    if (gOpeningFromRouter || !isEnabled() || !isSupportedLink(url))
        return %orig;
    routeLink(self,url,@{},nil);
    return YES;
}

%end
