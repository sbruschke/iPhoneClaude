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
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <fcntl.h>
#import <signal.h>

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

/// Maximum number of bytes we will read for a single HTTP request body.
/// Bodies larger than this are rejected with 413.
static const NSUInteger kMaxBodySize = 100 * 1024 * 1024;  // 100 MB

/// Size of the heap buffer used when reading headers from the socket.
static const NSUInteger kHeaderReadBufSize = 4096;

/// Maximum allowed header size (before the body).
static const NSUInteger kMaxHeaderSize = 64 * 1024;

/// Read timeout for client sockets (seconds).
static const int kReadTimeoutSecs = 30;

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
        // Ignore SIGPIPE globally so broken connections don't crash the process
        signal(SIGPIPE, SIG_IGN);
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

        // Prevent SIGPIPE on this socket (belt-and-suspenders with the global ignore)
        int nosig = 1;
        setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, sizeof(nosig));

        // CRITICAL: Darwin's accept() inherits the listen socket's non-blocking
        // flag onto the client fd (unlike Linux, which always returns blocking
        // fds). With O_NONBLOCK on the client fd, read() returns EAGAIN
        // immediately whenever the kernel's receive buffer is momentarily
        // empty — and SO_RCVTIMEO has no effect. That was the bug behind the
        // "~16 KB cliff": once the initial TCP segment was drained, the next
        // read() happened before the next segment arrived, EAGAIN fired, and
        // the body handler bailed. Clear the flag so read() blocks properly
        // (respecting SO_RCVTIMEO set below).
        int flags = fcntl(clientFd, F_GETFL, 0);
        if (flags >= 0) {
            fcntl(clientFd, F_SETFL, flags & ~O_NONBLOCK);
        }

        // Set a receive timeout so we don't block GCD threads forever on dead clients
        struct timeval tv;
        tv.tv_sec = kReadTimeoutSecs;
        tv.tv_usec = 0;
        setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        // Disable Nagle's algorithm for lower-latency responses
        int nodelay = 1;
        setsockopt(clientFd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));

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
/// Returns YES on success. Retries on EINTR. Logs errno + partial count on
/// failure so body-size regressions don't vanish as "Empty reply from server".
static BOOL _ReadExact(int fd, void *buffer, NSUInteger length) {
    NSUInteger totalRead = 0;
    uint8_t *dst = (uint8_t *)buffer;
    while (totalRead < length) {
        ssize_t n = read(fd, dst + totalRead, length - totalRead);
        if (n < 0) {
            if (errno == EINTR) continue;
            NSLog(@"[GCDWebServer] _ReadExact read() failed: errno=%d (%s), got %lu/%lu bytes",
                  errno, strerror(errno),
                  (unsigned long)totalRead, (unsigned long)length);
            return NO;
        }
        if (n == 0) {
            NSLog(@"[GCDWebServer] _ReadExact peer closed mid-body: got %lu/%lu bytes",
                  (unsigned long)totalRead, (unsigned long)length);
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

/// Case-insensitive header lookup.
static NSString *_HeaderValue(NSDictionary<NSString *, NSString *> *headers, NSString *name) {
    // Try exact match first (fast path)
    NSString *val = headers[name];
    if (val) return val;
    // Fall back to case-insensitive scan
    for (NSString *key in headers) {
        if ([key caseInsensitiveCompare:name] == NSOrderedSame) {
            return headers[key];
        }
    }
    return nil;
}

- (void)_handleConnection:(int)fd {
    @autoreleasepool {
        @try {
            [self _handleConnectionInner:fd];
        } @catch (NSException *exception) {
            NSLog(@"[GCDWebServer] Exception in connection handler: %@ — %@",
                  exception.name, exception.reason);
            // Try to send an error response before closing
            @try {
                [self _sendErrorResponse:fd statusCode:500 message:@"Internal Server Error"];
            } @catch (NSException *ignored) {}
        } @finally {
            close(fd);
        }
    }
}

- (void)_handleConnectionInner:(int)fd {
    // ---------------------------------------------------------------
    // 1.  Read header block (up to a double CRLF)
    // ---------------------------------------------------------------
    NSMutableData *rawHeader = [NSMutableData dataWithCapacity:4096];
    uint8_t *buf = malloc(kHeaderReadBufSize);
    if (!buf) {
        [self _sendErrorResponse:fd statusCode:500 message:@"Internal Server Error"];
        return;
    }

    NSRange headerEnd = NSMakeRange(NSNotFound, 0);
    while (headerEnd.location == NSNotFound) {
        ssize_t n = read(fd, buf, kHeaderReadBufSize);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
            if (n < 0) {
                NSLog(@"[GCDWebServer] header read() failed: errno=%d (%s)",
                      errno, strerror(errno));
            }
            free(buf);
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
        if (rawHeader.length > kMaxHeaderSize) {
            free(buf);
            [self _sendErrorResponse:fd statusCode:431 message:@"Request Header Fields Too Large"];
            return;
        }
    }
    free(buf);

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
        return;
    }

    NSArray<NSString *> *lines = [headerString componentsSeparatedByString:@"\r\n"];
    if (lines.count < 1) {
        [self _sendErrorResponse:fd statusCode:400 message:@"Bad Request"];
        return;
    }

    NSString *requestLine = lines[0];
    NSArray<NSString *> *parts = [requestLine componentsSeparatedByString:@" "];
    if (parts.count < 2) {
        [self _sendErrorResponse:fd statusCode:400 message:@"Bad Request"];
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
    NSString *clHeader = _HeaderValue(headers, @"Content-Length");
    NSUInteger contentLength = clHeader ? (NSUInteger)[clHeader integerValue] : 0;

    NSMutableData *bodyData = nil;
    if (contentLength > 0) {
        if (contentLength > kMaxBodySize) {
            [self _sendErrorResponse:fd statusCode:413 message:@"Payload Too Large"];
            return;
        }

        // Handle "Expect: 100-continue" — client won't send body until we respond.
        // Bug fix: [nil caseInsensitiveCompare:] returns 0 == NSOrderedSame, so
        // without the nil guard we sent an unsolicited 100 Continue on every
        // request that had a body, which confused some clients once the body
        // crossed the initial TCP receive window.
        NSString *expectHeader = _HeaderValue(headers, @"Expect");
        if (expectHeader &&
            [expectHeader caseInsensitiveCompare:@"100-continue"] == NSOrderedSame) {
            const char *cont = "HTTP/1.1 100 Continue\r\n\r\n";
            write(fd, cont, strlen(cont));
        }

        bodyData = [NSMutableData dataWithCapacity:contentLength];

        // Append any body bytes already read during header parsing
        if (extraBody.length > 0) {
            // Guard: don't append more than contentLength bytes
            NSUInteger toCopy = MIN(extraBody.length, contentLength);
            [bodyData appendData:[extraBody subdataWithRange:NSMakeRange(0, toCopy)]];
        }

        // Read remaining body bytes
        if (bodyData.length < contentLength) {
            NSUInteger remaining = contentLength - bodyData.length;
            void *tmp = malloc(remaining);
            if (!tmp) {
                [self _sendErrorResponse:fd statusCode:500 message:@"Internal Server Error"];
                return;
            }
            BOOL ok = _ReadExact(fd, tmp, remaining);
            if (!ok) {
                free(tmp);
                // Previously we just `return;` here, producing "Empty reply from
                // server" with zero diagnostics. Send an actual error response
                // so the client can see + log what happened.
                int savedErrno = errno;
                NSString *msg = [NSString stringWithFormat:
                    @"Body read failed after %lu/%lu bytes (errno=%d %s)",
                    (unsigned long)bodyData.length, (unsigned long)contentLength,
                    savedErrno, strerror(savedErrno)];
                [self _sendErrorResponse:fd statusCode:400 message:msg];
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
    // fd is closed by the caller (_handleConnection's @finally)
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
