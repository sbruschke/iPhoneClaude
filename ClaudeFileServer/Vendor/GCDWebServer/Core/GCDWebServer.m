//  GCDWebServer.m
//  GCDWebServer (vendored minimal subset)
//
//  A minimal GCD-based HTTP/1.1 server.  Uses BSD sockets for the listening
//  socket and GCD dispatch sources / queues for asynchronous accept + I/O.

#import "GCDWebServer.h"
#import "GCDWebServerRequest.h"
#import "GCDWebServerResponse.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <fcntl.h>

// ---------------------------------------------------------------------------
#pragma mark - Handler entry (private)
// ---------------------------------------------------------------------------

@interface _GCDWebServerHandler : NSObject
@property (nonatomic, copy) NSString *method;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) Class requestClass;
@property (nonatomic, copy) GCDWebServerProcessBlock block;
@end

@implementation _GCDWebServerHandler
@end

// ---------------------------------------------------------------------------
#pragma mark - GCDWebServer
// ---------------------------------------------------------------------------

/// Maximum number of bytes we will read for a single HTTP request
/// (headers + body).  Bodies larger than this are rejected with 413.
static const NSUInteger kMaxBodySize = 100 * 1024 * 1024;  // 100 MB

/// Size of the stack buffer used when reading from the socket.
static const NSUInteger kReadBufferSize = 65536;

@interface GCDWebServer ()
@property (nonatomic, readwrite) NSUInteger port;
@property (nonatomic, readwrite, getter=isRunning) BOOL running;
@end

@implementation GCDWebServer {
    int _listenSocket;
    dispatch_source_t _acceptSource;
    dispatch_queue_t _serverQueue;      // serial – protects _handlers array
    dispatch_queue_t _connectionQueue;  // concurrent – handles I/O
    NSMutableArray<_GCDWebServerHandler *> *_handlers;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _listenSocket = -1;
        _handlers = [NSMutableArray array];
        _serverQueue = dispatch_queue_create("com.gcdwebserver.server", DISPATCH_QUEUE_SERIAL);
        _connectionQueue = dispatch_queue_create("com.gcdwebserver.connection",
                                                  DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (void)dealloc {
    if (self.isRunning) {
        [self stop];
    }
}

// ---------------------------------------------------------------------------
#pragma mark - Handler registration
// ---------------------------------------------------------------------------

- (void)addHandlerForMethod:(NSString *)method
                       path:(NSString *)path
               requestClass:(Class)requestClass
                    handler:(GCDWebServerProcessBlock)block {
    _GCDWebServerHandler *h = [[_GCDWebServerHandler alloc] init];
    h.method = [method uppercaseString];
    h.path   = path;
    h.requestClass = requestClass;
    h.block  = block;

    dispatch_sync(_serverQueue, ^{
        [self->_handlers addObject:h];
    });
}

// ---------------------------------------------------------------------------
#pragma mark - Start / Stop
// ---------------------------------------------------------------------------

- (BOOL)startWithPort:(NSUInteger)port bonjourName:(nullable NSString *)name {
    if (self.isRunning) {
        return NO;
    }

    // 1. Create socket
    int fd = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) {
        fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (fd < 0) {
            NSLog(@"[GCDWebServer] socket() failed: %s", strerror(errno));
            return NO;
        }
    }

    // Allow address reuse
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    // Try dual-stack for IPv6 socket (accept IPv4 too)
    int no = 0;
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof(no));

    // 2. Bind
    struct sockaddr_in6 addr6;
    memset(&addr6, 0, sizeof(addr6));
    addr6.sin6_len    = sizeof(addr6);
    addr6.sin6_family = AF_INET6;
    addr6.sin6_port   = htons((uint16_t)port);
    addr6.sin6_addr   = in6addr_any;

    if (bind(fd, (struct sockaddr *)&addr6, sizeof(addr6)) < 0) {
        // Fall back to IPv4
        struct sockaddr_in addr4;
        memset(&addr4, 0, sizeof(addr4));
        addr4.sin_len    = sizeof(addr4);
        addr4.sin_family = AF_INET;
        addr4.sin_port   = htons((uint16_t)port);
        addr4.sin_addr.s_addr = htonl(INADDR_ANY);

        close(fd);
        fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (fd < 0) {
            NSLog(@"[GCDWebServer] socket(AF_INET) failed: %s", strerror(errno));
            return NO;
        }
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

        if (bind(fd, (struct sockaddr *)&addr4, sizeof(addr4)) < 0) {
            NSLog(@"[GCDWebServer] bind() failed: %s", strerror(errno));
            close(fd);
            return NO;
        }
    }

    // 3. Listen
    if (listen(fd, SOMAXCONN) < 0) {
        NSLog(@"[GCDWebServer] listen() failed: %s", strerror(errno));
        close(fd);
        return NO;
    }

    // Determine actual port (in case 0 was passed for auto-assign)
    struct sockaddr_in6 boundAddr;
    socklen_t addrLen = sizeof(boundAddr);
    if (getsockname(fd, (struct sockaddr *)&boundAddr, &addrLen) == 0) {
        self.port = ntohs(boundAddr.sin6_port);
        if (self.port == 0) {
            // sockaddr_in case
            struct sockaddr_in *v4 = (struct sockaddr_in *)&boundAddr;
            self.port = ntohs(v4->sin_port);
        }
    } else {
        self.port = port;
    }

    _listenSocket = fd;

    // Set non-blocking so accept() returns EAGAIN when no connections pending.
    // Without this, the accept loop blocks _serverQueue and deadlocks route lookup.
    fcntl(fd, F_SETFL, O_NONBLOCK);

    // 4. Create dispatch source for accepting new connections
    _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
                                           (uintptr_t)fd,
                                           0,
                                           _serverQueue);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_acceptSource, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf _acceptPendingConnections];
    });

    dispatch_source_set_cancel_handler(_acceptSource, ^{
        close(fd);
    });

    dispatch_resume(_acceptSource);

    self.running = YES;
    NSLog(@"[GCDWebServer] Started on port %lu", (unsigned long)self.port);
    return YES;
}

- (void)stop {
    if (!self.isRunning) return;
    self.running = NO;

    if (_acceptSource) {
        dispatch_source_cancel(_acceptSource);
        _acceptSource = nil;
    }
    _listenSocket = -1;

    NSLog(@"[GCDWebServer] Stopped");
}

// ---------------------------------------------------------------------------
#pragma mark - Accept connections
// ---------------------------------------------------------------------------

- (void)_acceptPendingConnections {
    // The dispatch source may fire once for multiple pending connections.
    while (YES) {
        struct sockaddr_in6 clientAddr;
        socklen_t addrLen = sizeof(clientAddr);
        int clientFd = accept(_listenSocket, (struct sockaddr *)&clientAddr, &addrLen);
        if (clientFd < 0) {
            break;  // EAGAIN / EWOULDBLOCK — no more pending
        }
        // Handle connection asynchronously
        dispatch_async(_connectionQueue, ^{
            [self _handleConnection:clientFd];
        });
    }
}

// ---------------------------------------------------------------------------
#pragma mark - Connection handling
// ---------------------------------------------------------------------------

/// Read exactly `length` bytes from `fd` into `buffer`.
/// Returns YES on success.  On failure the caller must close the fd.
static BOOL _ReadExact(int fd, void *buffer, NSUInteger length) {
    NSUInteger totalRead = 0;
    uint8_t *dst = (uint8_t *)buffer;
    while (totalRead < length) {
        ssize_t n = read(fd, dst + totalRead, length - totalRead);
        if (n <= 0) {
            return NO;
        }
        totalRead += (NSUInteger)n;
    }
    return YES;
}

/// Send all bytes from `data` through `fd`.
static void _WriteAll(int fd, NSData *data) {
    const uint8_t *src = data.bytes;
    NSUInteger remaining = data.length;
    while (remaining > 0) {
        ssize_t n = write(fd, src, remaining);
        if (n <= 0) break;
        src += n;
        remaining -= (NSUInteger)n;
    }
}

- (void)_handleConnection:(int)fd {
    @autoreleasepool {
        // ---------------------------------------------------------------
        // 1.  Read header block (up to a double CRLF)
        // ---------------------------------------------------------------
        NSMutableData *rawHeader = [NSMutableData dataWithCapacity:4096];
        uint8_t buf[kReadBufferSize];
        NSRange headerEnd = NSMakeRange(NSNotFound, 0);

        while (headerEnd.location == NSNotFound) {
            ssize_t n = read(fd, buf, sizeof(buf));
            if (n <= 0) {
                close(fd);
                return;
            }
            [rawHeader appendBytes:buf length:(NSUInteger)n];

            // Search for \r\n\r\n in the accumulated data.
            if (rawHeader.length >= 4) {
                const uint8_t *bytes = rawHeader.bytes;
                for (NSUInteger i = 0; i <= rawHeader.length - 4; i++) {
                    if (bytes[i] == '\r' && bytes[i+1] == '\n' &&
                        bytes[i+2] == '\r' && bytes[i+3] == '\n') {
                        headerEnd = NSMakeRange(i, 4);
                        break;
                    }
                }
            }
            // Safety: reject unreasonably large headers
            if (rawHeader.length > 64 * 1024) {
                [self _sendErrorResponse:fd statusCode:431 message:@"Request Header Fields Too Large"];
                close(fd);
                return;
            }
        }

        // Split into header portion and any leftover body bytes already read.
        NSUInteger headerLength = headerEnd.location + headerEnd.length;
        NSData *headerData = [rawHeader subdataWithRange:NSMakeRange(0, headerEnd.location)];
        NSData *extraBody  = nil;
        if (rawHeader.length > headerLength) {
            extraBody = [rawHeader subdataWithRange:NSMakeRange(headerLength,
                                                                 rawHeader.length - headerLength)];
        }

        // ---------------------------------------------------------------
        // 2.  Parse request line
        // ---------------------------------------------------------------
        NSString *headerString = [[NSString alloc] initWithData:headerData
                                                        encoding:NSUTF8StringEncoding];
        if (!headerString) {
            [self _sendErrorResponse:fd statusCode:400 message:@"Bad Request"];
            close(fd);
            return;
        }

        NSArray<NSString *> *lines = [headerString componentsSeparatedByString:@"\r\n"];
        if (lines.count < 1) {
            [self _sendErrorResponse:fd statusCode:400 message:@"Bad Request"];
            close(fd);
            return;
        }

        NSString *requestLine = lines[0];
        NSArray<NSString *> *parts = [requestLine componentsSeparatedByString:@" "];
        if (parts.count < 2) {
            [self _sendErrorResponse:fd statusCode:400 message:@"Bad Request"];
            close(fd);
            return;
        }

        NSString *method   = [parts[0] uppercaseString];
        NSString *rawURI   = parts[1];

        // ---------------------------------------------------------------
        // 3.  Parse path + query string
        // ---------------------------------------------------------------
        NSString *path = rawURI;
        NSMutableDictionary<NSString *, NSString *> *queryDict = [NSMutableDictionary dictionary];

        NSRange qmark = [rawURI rangeOfString:@"?"];
        if (qmark.location != NSNotFound) {
            path = [rawURI substringToIndex:qmark.location];
            NSString *qs = [rawURI substringFromIndex:qmark.location + 1];
            for (NSString *pair in [qs componentsSeparatedByString:@"&"]) {
                NSArray<NSString *> *kv = [pair componentsSeparatedByString:@"="];
                if (kv.count >= 2) {
                    NSString *key = [kv[0] stringByRemovingPercentEncoding];
                    NSString *val = [kv[1] stringByRemovingPercentEncoding];
                    if (key && val) queryDict[key] = val;
                } else if (kv.count == 1) {
                    NSString *key = [kv[0] stringByRemovingPercentEncoding];
                    if (key) queryDict[key] = @"";
                }
            }
        }

        // Percent-decode the path
        path = [path stringByRemovingPercentEncoding] ?: path;

        // ---------------------------------------------------------------
        // 4.  Parse headers
        // ---------------------------------------------------------------
        NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
        for (NSUInteger i = 1; i < lines.count; i++) {
            NSString *line = lines[i];
            if (line.length == 0) continue;
            NSRange colon = [line rangeOfString:@":"];
            if (colon.location == NSNotFound) continue;
            NSString *name  = [[line substringToIndex:colon.location]
                               stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString *value = [[line substringFromIndex:colon.location + 1]
                               stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            headers[name] = value;
        }

        // ---------------------------------------------------------------
        // 5.  Read body (Content-Length based)
        // ---------------------------------------------------------------
        NSString *clHeader = headers[@"Content-Length"];
        if (!clHeader) clHeader = headers[@"content-length"];
        NSUInteger contentLength = clHeader ? (NSUInteger)[clHeader integerValue] : 0;

        NSMutableData *bodyData = nil;
        if (contentLength > 0) {
            if (contentLength > kMaxBodySize) {
                [self _sendErrorResponse:fd statusCode:413 message:@"Payload Too Large"];
                close(fd);
                return;
            }
            bodyData = [NSMutableData dataWithCapacity:contentLength];
            if (extraBody.length > 0) {
                [bodyData appendData:extraBody];
            }
            NSUInteger remaining = contentLength - bodyData.length;
            if (remaining > 0) {
                void *tmp = malloc(remaining);
                if (!tmp) {
                    [self _sendErrorResponse:fd statusCode:500 message:@"Internal Server Error"];
                    close(fd);
                    return;
                }
                BOOL ok = _ReadExact(fd, tmp, remaining);
                if (!ok) {
                    free(tmp);
                    close(fd);
                    return;
                }
                [bodyData appendBytes:tmp length:remaining];
                free(tmp);
            }
        }

        // Build a URL (mainly for the request object)
        NSURLComponents *comp = [[NSURLComponents alloc] init];
        comp.scheme = @"http";
        comp.host   = @"localhost";
        comp.port   = @(self.port);
        comp.path   = path;
        if (queryDict.count > 0) {
            NSMutableArray *items = [NSMutableArray array];
            for (NSString *k in queryDict) {
                [items addObject:[NSURLQueryItem queryItemWithName:k value:queryDict[k]]];
            }
            comp.queryItems = items;
        }
        NSURL *url = comp.URL ?: [NSURL URLWithString:rawURI];

        // ---------------------------------------------------------------
        // 6.  Route to a handler
        // ---------------------------------------------------------------
        __block _GCDWebServerHandler *matchedHandler = nil;
        dispatch_sync(_serverQueue, ^{
            // Find the best (longest path prefix) match.
            NSUInteger bestLen = 0;
            for (_GCDWebServerHandler *h in self->_handlers) {
                if (![h.method isEqualToString:method]) continue;
                if ([path hasPrefix:h.path] && h.path.length > bestLen) {
                    bestLen = h.path.length;
                    matchedHandler = h;
                }
            }
        });

        if (!matchedHandler) {
            [self _sendErrorResponse:fd statusCode:405 message:@"Method Not Allowed"];
            close(fd);
            return;
        }

        // Instantiate the request object using the handler's requestClass.
        GCDWebServerRequest *request =
            [[matchedHandler.requestClass alloc] initWithMethod:method
                                                            URL:url
                                                        headers:headers
                                                           path:path
                                                          query:queryDict];
        if (bodyData) {
            request.body = bodyData;
        }

        // ---------------------------------------------------------------
        // 7.  Invoke handler and send response
        // ---------------------------------------------------------------
        GCDWebServerResponse *response = matchedHandler.block(request);
        if (!response) {
            response = [GCDWebServerResponse responseWithStatusCode:500];
        }

        NSData *responseData = [response serializedData];
        _WriteAll(fd, responseData);
        close(fd);
    }
}

// ---------------------------------------------------------------------------
#pragma mark - Error helper
// ---------------------------------------------------------------------------

- (void)_sendErrorResponse:(int)fd statusCode:(NSInteger)code message:(NSString *)message {
    GCDWebServerResponse *r = [GCDWebServerResponse responseWithStatusCode:code];
    r.contentType = @"text/plain; charset=utf-8";
    r.body = [message dataUsingEncoding:NSUTF8StringEncoding];
    NSData *data = [r serializedData];
    _WriteAll(fd, data);
}

@end
