#import <Foundation/Foundation.h>

static BOOL RDHostIs(NSString *host, NSString *domain) {
    return [host isEqualToString:domain] ||
        [host hasSuffix:[@"." stringByAppendingString:domain]];
}

static BOOL RDIsWeb(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    return [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"];
}

static BOOL RDIsEbayPage(NSURL *url) {
    if (!RDIsWeb(url)) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    for (NSString *domain in @[@"ebay.co.uk", @"ebay.com", @"ebay.de",
         @"ebay.fr", @"ebay.it", @"ebay.es", @"ebay.ie", @"ebay.ca",
         @"ebay.com.au", @"ebay.nl"]) {
        if (RDHostIs(host, domain)) return YES;
    }
    return NO;
}

static BOOL RDIsEbayShortLink(NSURL *url) {
    return [url.scheme.lowercaseString isEqualToString:@"https"] &&
           RDHostIs(url.host.lowercaseString ?: @"", @"ebay.io") &&
           [url.path hasPrefix:@"/m/"];
}

static BOOL RDIsAppLink(NSURL *url) {
    if (!RDIsWeb(url)) return NO;
    if (RDIsEbayPage(url) || RDIsEbayShortLink(url)) return YES;
    NSString *host = url.host.lowercaseString ?: @"";
    for (NSString *domain in @[@"instagram.com", @"instagr.am", @"reddit.com",
         @"redd.it", @"youtube.com", @"youtu.be", @"tiktok.com", @"twitter.com",
         @"x.com", @"facebook.com", @"fb.watch", @"open.spotify.com",
         @"pinterest.com", @"pin.it", @"twitch.tv", @"soundcloud.com"]) {
        if (RDHostIs(host, domain)) return YES;
    }
    return NO;
}

static NSString *RDValidItemID(NSString *candidate) {
    if (candidate.length < 9 || candidate.length > 15) return nil;
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    return [candidate rangeOfCharacterFromSet:digits.invertedSet].location ==
        NSNotFound ? candidate : nil;
}

static NSString *RDItemID(NSURL *url) {
    if (!RDIsEbayPage(url)) return nil;
    NSArray<NSString *> *parts = [url.path componentsSeparatedByString:@"/"];
    for (NSUInteger i = 0; i < parts.count; ++i) {
        if (![parts[i].lowercaseString isEqualToString:@"itm"]) continue;
        if (i + 1 < parts.count) {
            NSString *item = RDValidItemID(parts[i+1]);
            if (item) return item;
        }
        if (i + 2 < parts.count) {
            NSString *item = RDValidItemID(parts[i+2]);
            if (item) return item;
        }
    }
    NSURLComponents *components = [NSURLComponents componentsWithURL:url
                                             resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *part in components.queryItems) {
        if (![@[@"itemid", @"item_id", @"listingid", @"itm"]
              containsObject:part.name.lowercaseString ?: @""]) continue;
        NSString *item = RDValidItemID(part.value);
        if (item) return item;
    }
    return nil;
}

static NSURL *RDEbayListingURL(NSString *item) {
    if (!RDValidItemID(item)) return nil;
    // Verified in the supplied eBay 6.192.0 IPA.
    return [NSURL URLWithString:
        [NSString stringWithFormat:@"ebay://link?nav=item.view&id=%@", item]];
}
