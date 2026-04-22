//  GCDWebServer.h
//  GCDWebServer (vendored minimal subset)
//
//  A lightweight GCD-based HTTP server for iOS / macOS.
//  Supports GET, POST, DELETE with JSON and raw-data body handling.

#import <Foundation/Foundation.h>

@class GCDWebServerRequest;
@class GCDWebServerResponse;

NS_ASSUME_NONNULL_BEGIN

/// Block invoked for every matched request.  Return nil to send a 500 error.
typedef GCDWebServerResponse * _Nullable (^GCDWebServerProcessBlock)(GCDWebServerRequest *request);

@interface GCDWebServer : NSObject

/// The TCP port the server is listening on (valid after -start…).
@property (nonatomic, readonly) NSUInteger port;

/// YES while the server is accepting connections.
@property (nonatomic, readonly, getter=isRunning) BOOL running;

/// Register a handler for a given HTTP method and path.
/// @param method  HTTP method (e.g. @"GET", @"POST", @"DELETE").
/// @param path    Path prefix to match (e.g. @"/files/").  An exact prefix
///                match is performed — the path in the request must start with
///                this string.
/// @param requestClass  The GCDWebServerRequest subclass to instantiate for
///                      matched requests (e.g. [GCDWebServerDataRequest class]).
/// @param block   The handler block.
- (void)addHandlerForMethod:(NSString *)method
                       path:(NSString *)path
               requestClass:(Class)requestClass
                    handler:(GCDWebServerProcessBlock)block;

/// Start the server on the given port.  Returns YES on success.
- (BOOL)startWithPort:(NSUInteger)port bonjourName:(nullable NSString *)name;

/// Stop the server and close all listening sockets.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
