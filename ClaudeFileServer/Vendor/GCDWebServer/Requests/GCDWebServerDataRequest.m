//  GCDWebServerDataRequest.m
//  GCDWebServer (vendored minimal subset)

#import "GCDWebServerDataRequest.h"

@implementation GCDWebServerDataRequest

- (void)setBody:(NSData *)body {
    [super setBody:body];
    [self _parseJSONIfNeeded];
}

- (void)_parseJSONIfNeeded {
    _jsonObject = nil;
    NSData *data = self.body;
    if (!data || data.length == 0) {
        return;
    }
    NSString *ct = self.contentType;
    if (!ct) {
        return;
    }
    // Match "application/json" anywhere in the content-type (ignores charset etc.)
    if ([ct rangeOfString:@"application/json" options:NSCaseInsensitiveSearch].location == NSNotFound) {
        return;
    }
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:&err];
    if (obj && !err) {
        _jsonObject = obj;
    }
}

@end
