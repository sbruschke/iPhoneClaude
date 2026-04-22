//  GCDWebServerRequest.m
//  GCDWebServer (vendored minimal subset)

#import "GCDWebServerRequest.h"

@implementation GCDWebServerRequest

- (instancetype)initWithMethod:(NSString *)method
                           URL:(NSURL *)url
                       headers:(NSDictionary<NSString *, NSString *> *)headers
                          path:(NSString *)path
                         query:(NSDictionary<NSString *, NSString *> *)query {
    self = [super init];
    if (self) {
        _method  = [method copy];
        _URL     = [url copy];
        _headers = [headers copy];
        _path    = [path copy];
        _query   = [query copy];

        NSString *ct = headers[@"Content-Type"];
        if (!ct) ct = headers[@"content-type"];
        _contentType = [ct copy];

        NSString *cl = headers[@"Content-Length"];
        if (!cl) cl = headers[@"content-length"];
        _contentLength = cl ? (NSUInteger)[cl integerValue] : 0;
    }
    return self;
}

@end
