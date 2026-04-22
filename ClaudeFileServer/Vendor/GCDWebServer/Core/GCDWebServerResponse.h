//  GCDWebServerResponse.h
//  GCDWebServer (vendored minimal subset)
//
//  Lightweight HTTP response object.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GCDWebServerResponse : NSObject

@property (nonatomic) NSInteger statusCode;
@property (nonatomic, copy, nullable) NSString *contentType;
@property (nonatomic, readonly) NSDictionary<NSString *, NSString *> *additionalHeaders;
@property (nonatomic, copy, nullable) NSData *body;

+ (instancetype)responseWithStatusCode:(NSInteger)statusCode;
+ (instancetype)responseWithJSONObject:(id)jsonObject;
+ (instancetype)responseWithData:(NSData *)data contentType:(NSString *)contentType;
+ (instancetype)responseWithText:(NSString *)text;

- (void)setValue:(NSString *)value forAdditionalHeader:(NSString *)header;

/// Serializes the entire HTTP response (status line + headers + body) into raw bytes.
- (NSData *)serializedData;

@end

NS_ASSUME_NONNULL_END
