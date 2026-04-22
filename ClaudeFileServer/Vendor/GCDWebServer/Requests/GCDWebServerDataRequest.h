//  GCDWebServerDataRequest.h
//  GCDWebServer (vendored minimal subset)
//
//  Request subclass that parses a JSON body.

#import "GCDWebServerRequest.h"

NS_ASSUME_NONNULL_BEGIN

@interface GCDWebServerDataRequest : GCDWebServerRequest

/// The parsed JSON object from the request body, or nil if parsing failed or
/// the content type is not application/json.
@property (nonatomic, readonly, nullable) id jsonObject;

@end

NS_ASSUME_NONNULL_END
