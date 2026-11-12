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

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)applicationIsInstalled:(NSString *)bid;
- (NSArray *)applicationsAvailableForOpeningURL:(NSURL *)url;
@end

static NSString *const kReynard = @"com.minh-ton.Reynard";
static char kSourceBrowser, kSourceURL;
static __thread BOOL changing;

static BOOL browser(NSString *bid) {
    return [@[@"com.apple.mobilesafari", @"org.mozilla.ios.Firefox",
        @"com.google.chrome.ios", @"com.brave.ios.browser",
        @"org.mozilla.ios.Focus", @"com.microsoft.msedge",
        @"com.duckduckgo.mobile.ios"] containsObject:bid];
}
static BOOL matches(NSString *host, NSString *domain) {
    return [host isEqualToString:domain] ||
        [host hasSuffix:[@"." stringByAppendingString:domain]];
}
static BOOL ebay(NSString *host) {
    for (NSString *site in @[@"ebay.co.uk", @"ebay.com", @"ebay.de",
        @"ebay.fr", @"ebay.it", @"ebay.es", @"ebay.ie",
        @"ebay.ca", @"ebay.com.au", @"ebay.nl"]) if (matches(host,site)) return YES;
    return NO;
}
static BOOL isWeb(NSURL *url) {
    return [url.scheme.lowercaseString isEqualToString:@"http"] ||
        [url.scheme.lowercaseString isEqualToString:@"https"];
}
static BOOL pref(NSString *key, BOOL fallback) {
    NSUserDefaults *settings = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
    [settings synchronize];
    id obj = [settings objectForKey:key];
    return obj ? [settings boolForKey:key] : fallback;
}
static LSApplicationWorkspace *workspace(void) {
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    return [cls respondsToSelector:@selector(defaultWorkspace)] ?
        [cls defaultWorkspace] : nil;
}
static BOOL installed(NSString *bid) {
    if (!bid.length) return NO;
    id ws = workspace();
    if (![ws respondsToSelector:@selector(applicationIsInstalled:)]) return NO;
    @try { return [ws applicationIsInstalled:bid]; }
    @catch (NSException *e) { return NO; }
}
static BOOL schemeSupported(NSURL *url, NSString *bid) {
    id ws = workspace();
    if (!url || ![ws respondsToSelector:@selector(applicationsAvailableForOpeningURL:)])
        return NO;
    @try {
        for (id app in [ws applicationsAvailableForOpeningURL:url])
            if ([app respondsToSelector:@selector(applicationIdentifier)] &&
                [[app applicationIdentifier] isEqualToString:bid]) return YES;
    } @catch (NSException *e) {}
    return NO;
}
static NSString *siteApp(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    if (ebay(host)) return @"com.ebay.iphone";
    if (matches(host,@"instagram.com")) return @"com.burbn.instagram";
    if (matches(host,@"reddit.com") || matches(host,@"redd.it")) return @"com.reddit.Reddit";
    if (matches(host,@"youtube.com") || matches(host,@"youtu.be")) return @"com.google.ios.youtube";
    if (matches(host,@"tiktok.com")) return @"com.zhiliaoapp.musically";
    if (matches(host,@"twitter.com") || matches(host,@"x.com")) return @"com.atebits.Tweetie2";
    if (matches(host,@"facebook.com") || matches(host,@"fb.watch")) return @"com.facebook.Facebook";
    if (matches(host,@"open.spotify.com")) return @"com.spotify.client";
    if (matches(host,@"pinterest.com") || matches(host,@"pin.it")) return @"pinterest";
    if (matches(host,@"twitch.tv")) return @"tv.twitch";
    if (matches(host,@"soundcloud.com")) return @"com.soundcloud.TouchApp";
    return nil;
}
static NSString *nativeHandler(NSURL *url) {
    id ws = workspace();
    if (![ws respondsToSelector:@selector(applicationsAvailableForOpeningURL:)]) return nil;
    @try {
        for (id app in [ws applicationsAvailableForOpeningURL:url]) {
            if (![app respondsToSelector:@selector(applicationIdentifier)]) continue;
            NSString *bid = [app applicationIdentifier];
            if (bid.length && !browser(bid) && ![bid isEqualToString:kReynard] &&
                installed(bid)) return bid;
        }
    } @catch (NSException *e) {}
    return nil;
}
static NSURL *appURL(NSURL *url, NSString *bid) {
    NSString *host = url.host.lowercaseString ?: @"";
    if ([bid isEqualToString:@"com.ebay.iphone"] && ebay(host)) {
        static NSRegularExpression *regex;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            regex = [NSRegularExpression regularExpressionWithPattern:
                @"/itm/(?:[^/]+/)?([0-9]{9,15})(?:/|$)" options:0 error:NULL];
        });
        NSString *path = url.path ?: @"";
        NSTextCheckingResult *found = [regex firstMatchInString:path options:0
            range:NSMakeRange(0,path.length)];
        if (found && found.numberOfRanges > 1) {
            NSString *item = [path substringWithRange:[found rangeAtIndex:1]];
            return [NSURL URLWithString:[NSString stringWithFormat:
                @"ebay://com.ebay.mobile/ebay/link/?nav=item.view&id=%@",item]];
        }
    }
    if ([bid isEqualToString:@"com.burbn.instagram"] &&
        matches(host,@"instagram.com")) {
        NSArray *parts = [url.path componentsSeparatedByString:@"/"];
        if (parts.count >= 2 && parts.count <= 3 && [parts[0] length] == 0 &&
            [parts[1] length] > 0 && (parts.count == 2 || [parts[2] length] == 0) &&
            ![@[@"p",@"reel",@"stories",@"explore",@"direct",@"accounts"]
              containsObject:[parts[1] lowercaseString]]) {
            NSString *username = [parts[1] stringByAddingPercentEncodingWithAllowedCharacters:
                [NSCharacterSet URLQueryAllowedCharacterSet]];
            return [NSURL URLWithString:
                [@"instagram://user?username=" stringByAppendingString:username]];
        }
    }
    if ([bid isEqualToString:@"com.reddit.Reddit"] &&
        (matches(host,@"reddit.com") || matches(host,@"redd.it"))) {
        NSRange r = [url.absoluteString rangeOfString:@"://"];
        if (r.location != NSNotFound) return [NSURL URLWithString:
            [@"reddit://" stringByAppendingString:
                [url.absoluteString substringFromIndex:NSMaxRange(r)]]];
    }
    return nil;
}
static NSURL *reynardURL(NSURL *url) {
    NSCharacterSet *safe = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    NSString *encoded = [url.absoluteString stringByAddingPercentEncodingWithAllowedCharacters:safe];
    return encoded.length ? [NSURL URLWithString:
        [@"reynard://open?url=" stringByAppendingString:encoded]] : nil;
}
static BOOL replaceURL(FBSystemServiceOpenApplicationRequest *request,
                       NSURL *oldURL, NSURL *newURL) {
    BOOL handled = NO;
    if ([request respondsToSelector:@selector(setURL:)] &&
        [request respondsToSelector:@selector(URL)]) {
        request.URL = newURL;
        handled = [request.URL isEqual:newURL];
    }
    FBSOpenApplicationOptions *options = [request respondsToSelector:@selector(options)]
        ? request.options : nil;
    NSDictionary *data = [options respondsToSelector:@selector(dictionary)] ?
        options.dictionary : nil;
    if ([data isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *changed = [data mutableCopy];
        BOOL found = NO;
        for (id key in data) {
            if ([data[key] isKindOfClass:[NSURL class]] && [data[key] isEqual:oldURL]) {
                changed[key] = newURL;
                found = YES;
            }
        }
        if (found && [[options class] respondsToSelector:@selector(optionsWithDictionary:)] &&
            [request respondsToSelector:@selector(setOptions:)]) {
            FBSOpenApplicationOptions *updated = [[options class] optionsWithDictionary:changed];
            if ([updated.url isEqual:newURL]) {
                request.options = updated;
                handled = YES;
            }
        }
    }
    return handled;
}
static void route(FBSystemServiceOpenApplicationRequest *req) {
    if (changing || !pref(kEnabledKey, YES)) return;
    if (!browser(objc_getAssociatedObject(req,&kSourceBrowser))) return;
    NSURL *source = objc_getAssociatedObject(req,&kSourceURL);
    if (!source && [req respondsToSelector:@selector(URL)]) source = req.URL;
    if (!source && [req respondsToSelector:@selector(options)] &&
        [req.options respondsToSelector:@selector(url)]) source = req.options.url;
    if (!isWeb(source)) return;
    NSString *target = nil;
    NSURL *destination = nil;
    if (pref(kAppLinksKey, YES)) {
        NSString *known = siteApp(source);
        if (known && installed(known)) {
            target = known;
            NSURL *special = appURL(source,known);
            destination = schemeSupported(special,known) ? special : source;
        } else {
            target = nativeHandler(source);
            if (target) destination = source;
        }
    }
    if (!target && installed(kReynard)) {
        target = kReynard;
        destination = reynardURL(source);
    }
    if (!target || !destination) return;
    changing = YES;
    if (([destination isEqual:source] || replaceURL(req,source,destination)) &&
        [req respondsToSelector:@selector(setBundleIdentifier:)])
        req.bundleIdentifier = target;
    changing = NO;
}

%hook FBSystemServiceOpenApplicationRequest
- (void)setBundleIdentifier:(NSString *)bid {
    if (changing) { %orig; return; }
    objc_setAssociatedObject(self,&kSourceBrowser,browser(bid)?bid:nil,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    %orig;
    route(self);
}
- (void)setURL:(NSURL *)url {
    if (changing) { %orig; return; }
    objc_setAssociatedObject(self,&kSourceURL,url,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
    route(self);
}
- (void)setOptions:(FBSOpenApplicationOptions *)opts {
    if (changing) { %orig; return; }
    if ([opts respondsToSelector:@selector(url)] && opts.url)
        objc_setAssociatedObject(self,&kSourceURL,opts.url,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
    route(self);
}
%end
