//  GCDWebServerResponse.m
//  GCDWebServer (vendored minimal subset)

#import "GCDWebServerResponse.h"

@implementation GCDWebServerResponse {
    NSMutableDictionary<NSString *, NSString *> *_mutableAdditionalHeaders;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _statusCode = 200;
        _mutableAdditionalHeaders = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSDictionary<NSString *, NSString *> *)additionalHeaders {
    return [_mutableAdditionalHeaders copy];
}

#pragma mark - Convenience constructors

+ (instancetype)responseWithStatusCode:(NSInteger)statusCode {
    GCDWebServerResponse *r = [[self alloc] init];
    r.statusCode = statusCode;
    return r;
}

+ (instancetype)responseWithJSONObject:(id)jsonObject {
    GCDWebServerResponse *r = [[self alloc] init];
    r.statusCode = 200;
    r.contentType = @"application/json; charset=utf-8";
    if (jsonObject) {
        NSError *err = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:jsonObject
                                                       options:0
                                                         error:&err];
        if (data && !err) {
            r.body = data;
        }
    }
    return r;
}

+ (instancetype)responseWithData:(NSData *)data contentType:(NSString *)contentType {
    GCDWebServerResponse *r = [[self alloc] init];
    r.statusCode = 200;
    r.contentType = contentType;
    r.body = data;
    return r;
}

+ (instancetype)responseWithText:(NSString *)text {
    GCDWebServerResponse *r = [[self alloc] init];
    r.statusCode = 200;
    r.contentType = @"text/plain; charset=utf-8";
    r.body = [text dataUsingEncoding:NSUTF8StringEncoding];
    return r;
}

#pragma mark - Additional headers

- (void)setValue:(NSString *)value forAdditionalHeader:(NSString *)header {
    _mutableAdditionalHeaders[header] = value;
}

#pragma mark - Serialization

- (NSData *)serializedData {
    NSString *reason = [self reasonPhraseForCode:self.statusCode];
    NSMutableString *head = [NSMutableString stringWithFormat:@"HTTP/1.1 %ld %@\r\n",
                             (long)self.statusCode, reason];

    if (self.contentType) {
        [head appendFormat:@"Content-Type: %@\r\n", self.contentType];
    }

    NSUInteger bodyLen = self.body ? self.body.length : 0;
    [head appendFormat:@"Content-Length: %lu\r\n", (unsigned long)bodyLen];

    // Connection: close — we don't do keep-alive.
    [head appendString:@"Connection: close\r\n"];

    for (NSString *key in _mutableAdditionalHeaders) {
        [head appendFormat:@"%@: %@\r\n", key, _mutableAdditionalHeaders[key]];
    }

    [head appendString:@"\r\n"];

    NSMutableData *result = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    if (self.body) {
        [result appendData:self.body];
    }
    return [result copy];
}

- (NSString *)reasonPhraseForCode:(NSInteger)code {
    switch (code) {
        case 200: return @"OK";
        case 201: return @"Created";
        case 204: return @"No Content";
        case 301: return @"Moved Permanently";
        case 302: return @"Found";
        case 304: return @"Not Modified";
        case 400: return @"Bad Request";
        case 401: return @"Unauthorized";
        case 403: return @"Forbidden";
        case 404: return @"Not Found";
        case 405: return @"Method Not Allowed";
        case 409: return @"Conflict";
        case 413: return @"Payload Too Large";
        case 500: return @"Internal Server Error";
        case 503: return @"Service Unavailable";
        default:  return @"Unknown";
    }
}

@end
