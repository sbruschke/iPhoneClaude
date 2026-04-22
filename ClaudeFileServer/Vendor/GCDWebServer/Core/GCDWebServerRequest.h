//  GCDWebServerRequest.h
//  GCDWebServer (vendored minimal subset)
//
//  Lightweight HTTP request object.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GCDWebServerRequest : NSObject

@property (nonatomic, readonly, copy) NSString *method;
@property (nonatomic, readonly, copy) NSURL *URL;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *query;
@property (nonatomic, readonly, copy, nullable) NSString *contentType;
@property (nonatomic, readonly) NSUInteger contentLength;
@property (nonatomic, copy, nullable) NSData *body;

- (instancetype)initWithMethod:(NSString *)method
                           URL:(NSURL *)url
                       headers:(NSDictionary<NSString *, NSString *> *)headers
                          path:(NSString *)path
                         query:(NSDictionary<NSString *, NSString *> *)query;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
