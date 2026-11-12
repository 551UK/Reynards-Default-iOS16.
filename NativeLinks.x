#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "Common/Common.h"
#import "Routing.h"

// Intercept links only when opened. No polling or background activity.
static __thread BOOL gInternalOpen = NO;

static BOOL enabled(void) {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
    [prefs synchronize];
    id main = [prefs objectForKey:kEnabledKey];
    id links = [prefs objectForKey:kAppLinksKey];
    return (!main || [main boolValue]) && (!links || [links boolValue]);
}

static NSURL *reynardURL(NSURL *url) {
    NSCharacterSet *safe = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    NSString *encoded = [url.absoluteString stringByAddingPercentEncodingWithAllowedCharacters:safe];
    return encoded.length ? [NSURL URLWithString:
        [@"reynard://open?url=" stringByAppendingString:encoded]] : nil;
}

static void rawOpen(UIApplication *app, NSURL *url, NSDictionary *options,
                    void (^completion)(BOOL)) {
    if (!url) {
        if (completion) completion(NO);
        return;
    }
    gInternalOpen = YES;
    [app openURL:url options:options ?: @{} completionHandler:completion];
    gInternalOpen = NO;
}

static void openInBrowser(UIApplication *app, NSURL *url,
                          void (^completion)(BOOL)) {
    NSURL *wrapped = reynardURL(url);
    if (!wrapped) {
        rawOpen(app,url,@{},completion);
        return;
    }
    rawOpen(app,wrapped,@{},^(BOOL success) {
        if (success) {
            if (completion) completion(YES);
        } else {
            rawOpen(app,url,@{},completion);
        }
    });
}

static void openUniversalOrBrowser(UIApplication *app, NSURL *url,
                                   void (^completion)(BOOL)) {
    // The exact URL is handed to iOS, without substituting an app bundle ID.
    if (![url.scheme.lowercaseString isEqualToString:@"https"]) {
        openInBrowser(app,url,completion);
        return;
    }
    rawOpen(app,url,@{UIApplicationOpenURLOptionUniversalLinksOnly:@YES},
            ^(BOOL handled) {
        if (handled) {
            if (completion) completion(YES);
        } else {
            openInBrowser(app,url,completion);
        }
    });
}

static void openListing(UIApplication *app, NSString *item, NSURL *source,
                        void (^completion)(BOOL)) {
    NSURL *deeplink = RDEbayListingURL(item);
    if (!deeplink) {
        openUniversalOrBrowser(app,source,completion);
        return;
    }
    // eBay 6.192.0 has an explicit item.view handler for this scheme.
    rawOpen(app,deeplink,@{},^(BOOL launched) {
        if (launched) {
            if (completion) completion(YES);
        } else {
            openUniversalOrBrowser(app,source,completion);
        }
    });
}

static NSString *canonicalItemFromHTML(NSData *body) {
    if (!body.length) return nil;
    NSData *head = body.length > 393216 ?
        [body subdataWithRange:NSMakeRange(0,393216)] : body;
    NSString *html = [[NSString alloc] initWithData:head encoding:NSUTF8StringEncoding];
    if (!html.length) return nil;
    static NSRegularExpression *tagRegex;
    static NSRegularExpression *attributeRegex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tagRegex = [NSRegularExpression regularExpressionWithPattern:
            @"<(?:link|meta)\\b[^>]{0,2000}(?:canonical|og:url)[^>]{0,2000}>"
            options:NSRegularExpressionCaseInsensitive error:NULL];
        attributeRegex = [NSRegularExpression regularExpressionWithPattern:
            @"(?:href|content)\\s*=\\s*['\\\"]([^'\\\"]+)['\\\"]"
            options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    NSArray *tags = [tagRegex matchesInString:html options:0
                                       range:NSMakeRange(0,html.length)];
    for (NSTextCheckingResult *tag in tags) {
        NSString *value = [html substringWithRange:tag.range];
        NSArray *attrs = [attributeRegex matchesInString:value options:0
                                            range:NSMakeRange(0,value.length)];
        for (NSTextCheckingResult *attr in attrs) {
            if (attr.numberOfRanges < 2) continue;
            NSString *candidate = [[value substringWithRange:[attr rangeAtIndex:1]]
                stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
            NSString *item = RDItemID([NSURL URLWithString:candidate]);
            if (item) return item;
        }
    }
    return nil;
}

static void resolveShortLink(NSURL *url, void (^finished)(NSString *)) {
    NSURLSessionConfiguration *configuration =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 8;
    configuration.timeoutIntervalForResource = 12;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8];
    request.HTTPMethod = @"GET";
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_3 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1"
       forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSString *item = nil;
            if (!error) {
                item = RDItemID(response.URL);
                if (!item) item = canonicalItemFromHTML(data);
            }
            [session finishTasksAndInvalidate];
            dispatch_async(dispatch_get_main_queue(), ^{
                finished(item);
            });
        }];
    [task resume];
}

static void route(UIApplication *app, NSURL *url,
                  void (^completion)(BOOL)) {
    if (RDIsEbayShortLink(url)) {
        resolveShortLink(url,^(NSString *item) {
            if (item) openListing(app,item,url,completion);
            else openInBrowser(app,url,completion);
        });
        return;
    }
    NSString *item = RDItemID(url);
    if (item) {
        openListing(app,item,url,completion);
        return;
    }
    // Instagram/Reddit/YouTube etc. retain complete content URLs.
    openUniversalOrBrowser(app,url,completion);
}

%hook UIApplication

- (void)openURL:(NSURL *)url options:(NSDictionary *)options
 completionHandler:(void (^)(BOOL))completion {
    if (gInternalOpen || !enabled() || !RDIsAppLink(url) ||
        [options[UIApplicationOpenURLOptionUniversalLinksOnly] boolValue]) {
        %orig;
        return;
    }
    route(self,url,completion);
}

- (BOOL)openURL:(NSURL *)url {
    if (gInternalOpen || !enabled() || !RDIsAppLink(url)) return %orig;
    route(self,url,nil);
    return YES;
}

%end
