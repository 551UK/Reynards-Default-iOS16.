#import <Foundation/Foundation.h>
#import "Routing.h"

static void verify(NSString *url, NSString *item) {
    NSString *actual = RDItemID([NSURL URLWithString:url]);
    NSCAssert((!item && !actual) || [actual isEqualToString:item],
              @"Wrong eBay item for %@",url);
}
int main(void) {
    @autoreleasepool {
        NSCAssert(RDIsEbayShortLink([NSURL URLWithString:@"https://ebay.io/m/aat9ND"]),
                  @"Missing WhatsApp eBay short URL");
        NSCAssert(!RDIsEbayShortLink([NSURL URLWithString:@"https://fakeebay.io/m/a"]),
                  @"Unsafe short URL detection");
        verify(@"https://www.ebay.co.uk/itm/137168502434?mkcid=1", @"137168502434");
        verify(@"https://www.ebay.co.uk/itm/Mercedes-Part/318443804934?hash=x",
               @"318443804934");
        verify(@"https://www.ebay.com/itm/123456789012", @"123456789012");
        verify(@"https://www.ebay.co.uk/sch/i.html?itemId=137168502434",
               @"137168502434");
        verify(@"https://www.ebay.co.uk/", nil);
        verify(@"https://fakeebay.co.uk/itm/137168502434", nil);
        NSCAssert([[RDEbayListingURL(@"137168502434") absoluteString]
                     isEqualToString:@"ebay://link?nav=item.view&id=137168502434"],
                  @"Wrong native item handler");
        NSCAssert(RDEbayListingURL(@"bad") == nil, @"Invalid item accepted");
        NSCAssert(RDIsAppLink([NSURL URLWithString:
            @"https://www.instagram.com/reel/ABC123/?igsh=xyz"]),@"Instagram link");
        NSCAssert(RDIsAppLink([NSURL URLWithString:
            @"https://www.reddit.com/r/test/comments/abc123/thread/"]),@"Reddit link");
        NSCAssert(RDIsAppLink([NSURL URLWithString:
            @"https://youtu.be/ABC123"]),@"YouTube link");
        NSCAssert(!RDIsAppLink([NSURL URLWithString:
            @"https://notinstagram.com/p/123"]),@"Unrelated URL hijacked");
        NSLog(@"App-link item extraction and native eBay 6.192.0 scheme: OK");
    }
    return 0;
}
