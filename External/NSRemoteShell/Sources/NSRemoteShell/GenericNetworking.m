//
//  GenericNetworking.m
//
//
//  Created by Lakr Aream on 2022/2/5.
//

#import "GenericNetworking.h"

/*
 waits for a non-blocking connect() to settle on a socket
 select is retried on EINTR against an absolute deadline so a signal
 can not stretch the wait past the requested timeout
 */
static BOOL NSRWaitForSocketWritable(int sock, double timeoutSeconds) {
    if (timeoutSeconds <= 0) { timeoutSeconds = GENERIC_SOCKET_CONNECT_TIMEOUT; }
    struct timeval deadline;
    gettimeofday(&deadline, NULL);
    deadline.tv_sec += (time_t)timeoutSeconds;
    deadline.tv_usec += (suseconds_t)((timeoutSeconds - (double)(time_t)timeoutSeconds) * 1000000);
    if (deadline.tv_usec >= 1000000) {
        deadline.tv_sec += 1;
        deadline.tv_usec -= 1000000;
    }
    while (true) {
        struct timeval now;
        gettimeofday(&now, NULL);
        struct timeval tv;
        tv.tv_sec = deadline.tv_sec - now.tv_sec;
        tv.tv_usec = deadline.tv_usec - now.tv_usec;
        if (tv.tv_usec < 0) {
            tv.tv_sec -= 1;
            tv.tv_usec += 1000000;
        }
        if (tv.tv_sec < 0) { return NO; }
        fd_set wset;
        FD_ZERO(&wset);
        FD_SET(sock, &wset);
        int rc = select(sock + 1, NULL, &wset, NULL, &tv);
        if (rc > 0) { break; }
        if (rc < 0 && errno == EINTR) { continue; }
        return NO;
    }
    int socketError = 0;
    socklen_t socketErrorLength = sizeof(socketError);
    if (getsockopt(sock, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) != 0) {
        return NO;
    }
    return socketError == 0;
}

/// The running subprocess and stderr reader for one proxy-command socket.
/// The child's stdin and stdout are the other end of libssh2's AF_UNIX
/// socketpair, so bytes flow between libssh2 and the child in the kernel with
/// no userspace relay threads.
@interface NSRProxyTask : NSObject
@property (nonatomic, strong) NSTask *task;
@property (nonatomic, assign) int errorFd;
@property (nonatomic, strong, nullable) dispatch_source_t errorSource;
@property (nonatomic, strong) NSMutableData *errorOutput;
- (instancetype)initWithTask:(NSTask *)task errorFd:(int)errorFd;
- (void)drainErrors;
- (nullable NSString *)failureReason;
- (void)stop;
@end

@implementation NSRProxyTask

- (instancetype)initWithTask:(NSTask *)task errorFd:(int)errorFd {
    if (self = [super init]) {
        _task = task;
        _errorFd = errorFd;
        _errorOutput = [NSMutableData data];
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
                                                          (uintptr_t)errorFd,
                                                          0,
                                                          dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
        if (source) {
            __weak typeof(self) weakSelf = self;
            dispatch_source_set_event_handler(source, ^{
                [weakSelf drainErrors];
            });
            dispatch_resume(source);
            _errorSource = source;
        }
    }
    return self;
}

- (void)drainErrors {
    BOOL reachedEnd = NO;
    @synchronized (self) {
        if (self.errorFd < 0) { return; }
        char scratch[1024];
        while (true) {
            ssize_t count = read(self.errorFd, scratch, sizeof(scratch));
            if (count > 0) {
                if (self.errorOutput.length < 8192) {
                    NSUInteger room = 8192 - self.errorOutput.length;
                    NSUInteger kept = (NSUInteger)count < room ? (NSUInteger)count : room;
                    [self.errorOutput appendBytes:scratch length:kept];
                }
            } else {
                if (count == 0) { reachedEnd = YES; }
                break;
            }
        }
    }
    if (reachedEnd && self.errorSource) {
        dispatch_source_cancel(self.errorSource);
    }
}

- (nullable NSString *)failureReason {
    // When the child closes stdout as it exits, libssh2 sees EOF a moment
    // before waitpid marks the task finished; wait briefly so its stderr and
    // exit status are in place.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.1];
    while ([deadline timeIntervalSinceNow] > 0 && self.task.isRunning) {
        [self drainErrors];
        usleep(5000);
    }
    if (!self.task.isRunning) {
        [self.task waitUntilExit];
    }
    [self drainErrors];
    NSData *captured = nil;
    @synchronized (self) {
        captured = [self.errorOutput copy];
    }
    NSString *reason = [[NSString alloc] initWithData:captured encoding:NSUTF8StringEncoding];
    reason = [reason stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (reason.length > 0) { return reason; }
    if (!self.task.isRunning) {
        return [NSString stringWithFormat:@"The proxy command stopped (exit %d) before connecting.", self.task.terminationStatus];
    }
    return nil;
}

- (void)stop {
    if (self.errorSource) {
        dispatch_source_cancel(self.errorSource);
        self.errorSource = nil;
    }
    @synchronized (self) {
        if (self.errorFd >= 0) {
            close(self.errorFd);
            self.errorFd = -1;
        }
    }
    if (self.task.isRunning) {
        [self.task terminate];
    }
}

@end

@implementation GenericNetworking

+ (NSArray *)resolveIpAddressesFor:(NSString*)candidateHost
{
    if (!candidateHost) return [[NSArray alloc] init];
    NSArray<NSData*> *candidateHostData = [[NSArray alloc] init];
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = PF_UNSPEC;        // PF_INET if you want only IPv4 addresses
    hints.ai_protocol = IPPROTO_TCP;
    struct addrinfo *addrs = NULL, *addr;
    int rc = getaddrinfo([candidateHost UTF8String], NULL, &hints, &addrs);
    if (rc != 0) {
        NSRLog(@"resolving host %@ failed: %s", candidateHost, gai_strerror(rc));
        return [[NSArray alloc] init];
    }
    for (addr = addrs; addr; addr = addr->ai_next) {
        char host[NI_MAXHOST];
        getnameinfo(addr->ai_addr, addr->ai_addrlen, host, sizeof(host), NULL, 0, NI_NUMERICHOST);
        if (strlen(host) <= 0) { continue; }
        NSString *hostStr = [[NSString alloc] initWithUTF8String:host];
        NSRLog(@"resolving host %@ loading result: %@", candidateHost, hostStr);
        NSData *build = [[NSData alloc] initWithBytes:addr->ai_addr length: addr->ai_addrlen];
        candidateHostData = [candidateHostData arrayByAddingObject:build];
    }
    freeaddrinfo(addrs);
    return candidateHostData;
}

+ (BOOL)isValidateWithPort:(NSNumber*)port {
    int p = [port intValue];
    // we are treating 0 as a valid port and technically it should work!
    if (p >= 0 && p <= 65535) {
        return YES;
    }
    return NO;
}

+ (int)createSocketNonblockingListenerWithLocalPort:(NSNumber*)localPort
{
    if (![GenericNetworking isValidateWithPort:localPort]) {
        NSRLog(@"invalid port %@", [localPort stringValue]);
        return 0;
    }
    
    int port = [localPort intValue];
    struct sockaddr_in server4;
    int socket_desc4 = socket(AF_INET, SOCK_STREAM, 0);
    if (socket_desc4 <= 0) {
        NSRLog(@"failed to create socket for ipv4 at port %d", port);
        return 0;
    }
    server4.sin_family = AF_INET;
    server4.sin_addr.s_addr = inet_addr("127.0.0.1"); // for security?
    server4.sin_port = htons(port);
    if (setsockopt(socket_desc4, SOL_SOCKET, SO_REUSEADDR, &(int){1}, sizeof(int)) == -1) {
        NSRLog(@"failed to setsockopt for ipv4 at port %d", port);
        close(socket_desc4);
        return 0;
    }
    if (bind(socket_desc4, (struct sockaddr*)&server4, sizeof(server4)) < 0) {
        NSRLog(@"failed to bind socket for ipv4 at port %d", port);
        close(socket_desc4);
        return 0;
    } else {
        NSRLog(@"bound listener v4 for port %d", port);
    }
    if (fcntl(socket_desc4, F_SETFL, fcntl(socket_desc4, F_GETFL, 0) | O_NONBLOCK) == -1) {
        NSRLog(@"failed to call fcntl for none-blocking ipv4 at port %d", port);
        close(socket_desc4);
        return 0;
    }
    if (listen(socket_desc4, SOCKET_QUEUE_MAXSIZE) == -1) {
        NSRLog(@"failed to call fcntl for none-blocking ipv6 at port %d", port);
        close(socket_desc4);
        return 0;
    }
    
    NSRLog(@"socket listener for port %d booted", port);
    return socket_desc4;
}

+ (int)createSocketWithTargetHost:(NSString *)targetHost
                   withTargetPort:(NSNumber *)targetPort
             requireNonblockingIO:(BOOL)useNonblocking
{
    return [self createSocketWithTargetHost:targetHost
                             withTargetPort:targetPort
                       requireNonblockingIO:useNonblocking
                         withConnectTimeout:@(GENERIC_SOCKET_CONNECT_TIMEOUT)];
}

+ (int)createSocketWithTargetHost:(NSString *)targetHost
                   withTargetPort:(NSNumber *)targetPort
             requireNonblockingIO:(BOOL)useNonblocking
               withConnectTimeout:(NSNumber *)connectTimeout
{
    if (![self isValidateWithPort:targetPort]) { return 0; }
    int candidatePort = [targetPort intValue];
    NSArray *addrData = [self resolveIpAddressesFor:targetHost];
    if (!addrData) { return 0; }
    for (id candidateHostData in addrData) {
        if ([candidateHostData length] == sizeof(struct sockaddr_in)) {
            struct sockaddr_in address4;
            [candidateHostData getBytes:&address4 length:sizeof(address4)];
            address4.sin_port = htons(candidatePort);
            char str[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &(address4.sin_addr), str, INET_ADDRSTRLEN);
            int forwardsock = socket(PF_INET, SOCK_STREAM, IPPROTO_TCP);
            if (forwardsock <= 0) {
                NSRLog(@"socket failed to create, trying next");
                continue;
            }
            setsockopt(forwardsock, SOL_SOCKET, SO_NOSIGPIPE, &(int){1}, sizeof(int));
            // connect() must run non-blocking even when the caller wants a
            // blocking socket, otherwise a dropped packet parks us for the
            // full kernel tcp timeout; blocking mode is restored afterwards
            if (fcntl(forwardsock, F_SETFL, fcntl(forwardsock, F_GETFL, 0) | O_NONBLOCK) == -1) {
                NSRLog(@"failed to call fcntl for none-blocking for socket %d", forwardsock);
                close(forwardsock);
                continue;
            }
            int rv = connect(forwardsock, (struct sockaddr*)&address4, sizeof(struct sockaddr_in));
            if (rv != 0) {
                if (errno != EINPROGRESS && errno != EINTR) {
                    NSRLog(@"socket failed to connect, trying next address");
                    close(forwardsock);
                    continue;
                }
                if (!NSRWaitForSocketWritable(forwardsock, [connectTimeout doubleValue])) {
                    NSRLog(@"socket failed to connect before deadline, trying next address");
                    close(forwardsock);
                    continue;
                }
            }
            if (!useNonblocking && fcntl(forwardsock, F_SETFL, fcntl(forwardsock, F_GETFL, 0) & ~O_NONBLOCK) == -1) {
                NSRLog(@"failed to restore blocking io for socket %d", forwardsock);
                close(forwardsock);
                continue;
            }
            NSRLog(@"created socket %d to address %s", forwardsock, str);
            return forwardsock;
        } else if ([candidateHostData length] == sizeof(struct sockaddr_in6)) {
            struct sockaddr_in6 address6;
            [candidateHostData getBytes:&address6 length:sizeof(address6)];
            address6.sin6_port = htons(candidatePort);
            char str[INET6_ADDRSTRLEN];
            inet_ntop(AF_INET6, &(address6.sin6_addr), str, INET6_ADDRSTRLEN);
            int forwardsock = socket(PF_INET6, SOCK_STREAM, IPPROTO_TCP);
            if (forwardsock <= 0) {
                NSRLog(@"socket failed to create, trying next");
                continue;
            }
            setsockopt(forwardsock, SOL_SOCKET, SO_NOSIGPIPE, &(int){1}, sizeof(int));
            if (fcntl(forwardsock, F_SETFL, fcntl(forwardsock, F_GETFL, 0) | O_NONBLOCK) == -1) {
                NSRLog(@"failed to call fcntl for none-blocking for socket %d", forwardsock);
                close(forwardsock);
                continue;
            }
            int rv = connect(forwardsock, (struct sockaddr*)&address6, sizeof(struct sockaddr_in6));
            if (rv != 0) {
                if (errno != EINPROGRESS && errno != EINTR) {
                    NSRLog(@"socket failed to connect, trying next address");
                    close(forwardsock);
                    continue;
                }
                if (!NSRWaitForSocketWritable(forwardsock, [connectTimeout doubleValue])) {
                    NSRLog(@"socket failed to connect before deadline, trying next address");
                    close(forwardsock);
                    continue;
                }
            }
            if (!useNonblocking && fcntl(forwardsock, F_SETFL, fcntl(forwardsock, F_GETFL, 0) & ~O_NONBLOCK) == -1) {
                NSRLog(@"failed to restore blocking io for socket %d", forwardsock);
                close(forwardsock);
                continue;
            }
            NSRLog(@"created socket %d to address %s", forwardsock, str);
            return forwardsock;
        } else {
            NSRLog(@"unrecognized address candidate size");
            continue;
        }
    }
    return 0;
}

// Only characters that can appear in a DNS name or an IPv4/IPv6 literal may be
// substituted into a shell command unquoted.
static BOOL NSRProxyHostIsSafe(NSString *host) {
    if (host.length == 0) { return NO; }
    static NSCharacterSet *disallowed = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_:[]"];
        disallowed = [allowed invertedSet];
    });
    return [host rangeOfCharacterFromSet:disallowed].location == NSNotFound;
}

// %h, %p and %%, expanded in one pass as OpenSSH's percent_expand does, so %%h
// becomes %h rather than %<host>.
static NSString *NSRProxyCommandExpanded(NSString *command, NSString *host, NSNumber *port) {
    NSString *portString = [port stringValue] ?: @"22";
    NSMutableString *expanded = [NSMutableString stringWithCapacity:command.length + host.length];
    NSUInteger length = command.length;
    for (NSUInteger index = 0; index < length; index++) {
        unichar character = [command characterAtIndex:index];
        if (character == '%' && index + 1 < length) {
            unichar next = [command characterAtIndex:index + 1];
            if (next == 'h') {
                [expanded appendString:host];
                index++;
                continue;
            }
            if (next == 'p') {
                [expanded appendString:portString];
                index++;
                continue;
            }
            if (next == '%') {
                [expanded appendString:@"%"];
                index++;
                continue;
            }
        }
        [expanded appendFormat:@"%C", character];
    }
    return expanded;
}

// Where a GUI app, whose PATH has none of these, keeps a command installed
// with Homebrew or pip.
static NSString *NSRProxyCommandPath(void) {
    NSString *home = NSHomeDirectory();
    NSArray<NSString *> *extra = @[
        @"/opt/homebrew/bin",
        @"/usr/local/bin",
        [home stringByAppendingPathComponent:@".local/bin"],
    ];
    NSString *base = NSProcessInfo.processInfo.environment[@"PATH"] ?: @"/usr/bin:/bin";
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:base];
    for (NSString *directory in extra) {
        if (![base containsString:directory]) { [parts addObject:directory]; }
    }
    return [parts componentsJoinedByString:@":"];
}

static NSMutableDictionary<NSNumber *, NSRProxyTask *> *NSRProxyTasks(void) {
    static NSMutableDictionary<NSNumber *, NSRProxyTask *> *tasks = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tasks = [NSMutableDictionary dictionary];
    });
    return tasks;
}

+ (int)createSocketWithProxyCommand:(NSString *)command
                         targetHost:(NSString *)targetHost
                         targetPort:(NSNumber *)targetPort
                            failure:(NSString **)failure
{
    if (![self isValidateWithPort:targetPort]) {
        if (failure) { *failure = @"The server port is not valid."; }
        return 0;
    }
    if (!NSRProxyHostIsSafe(targetHost)) {
        if (failure) { *failure = @"The server address is not a valid hostname."; }
        return 0;
    }
    NSString *expanded = NSRProxyCommandExpanded(command, targetHost, targetPort);

    // One full-duplex socketpair: end 0 is libssh2's socket, end 1 becomes the
    // command's stdin and stdout. FD_CLOEXEC keeps the parent's descriptors out
    // of the child process; dup2 onto 0, 1 and 2 clears FD_CLOEXEC on those.
    int pair[2] = {0, 0};
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) {
        if (failure) { *failure = @"Could not open a channel for the proxy command."; }
        return 0;
    }
    int errorPipe[2] = {0, 0};
    if (pipe(errorPipe) != 0) {
        close(pair[0]);
        close(pair[1]);
        if (failure) { *failure = @"Could not open a channel for the proxy command."; }
        return 0;
    }
    fcntl(pair[0], F_SETFD, FD_CLOEXEC);
    fcntl(pair[1], F_SETFD, FD_CLOEXEC);
    fcntl(errorPipe[0], F_SETFD, FD_CLOEXEC);
    fcntl(errorPipe[1], F_SETFD, FD_CLOEXEC);
    fcntl(errorPipe[0], F_SETFL, fcntl(errorPipe[0], F_GETFL, 0) | O_NONBLOCK);
    setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &(int){1}, sizeof(int));
    setsockopt(pair[1], SOL_SOCKET, SO_NOSIGPIPE, &(int){1}, sizeof(int));

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[@"-c", expanded];
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy] ?: [NSMutableDictionary dictionary];
    environment[@"PATH"] = NSRProxyCommandPath();
    task.environment = environment;
    NSFileHandle *childStream = [[NSFileHandle alloc] initWithFileDescriptor:pair[1] closeOnDealloc:NO];
    NSFileHandle *childError = [[NSFileHandle alloc] initWithFileDescriptor:errorPipe[1] closeOnDealloc:NO];
    task.standardInput = childStream;
    task.standardOutput = childStream;
    task.standardError = childError;

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (failure) { *failure = launchError.localizedDescription ?: @"The proxy command did not start."; }
        close(pair[0]);
        close(pair[1]);
        close(errorPipe[0]);
        close(errorPipe[1]);
        return 0;
    }
    close(pair[1]);
    close(errorPipe[1]);

    NSRProxyTask *proxy = [[NSRProxyTask alloc] initWithTask:task errorFd:errorPipe[0]];
    NSMutableDictionary<NSNumber *, NSRProxyTask *> *tasks = NSRProxyTasks();
    @synchronized (tasks) {
        tasks[@(pair[0])] = proxy;
    }
    return pair[0];
}

+ (nullable NSString *)proxyFailureForSocket:(int)socketDescriptor {
    if (socketDescriptor <= 0) { return nil; }
    NSMutableDictionary<NSNumber *, NSRProxyTask *> *tasks = NSRProxyTasks();
    NSRProxyTask *proxy = nil;
    @synchronized (tasks) {
        proxy = tasks[@(socketDescriptor)];
    }
    return [proxy failureReason];
}

+ (void)destroyNativeSocket:(int)socketDescriptor {
    if (socketDescriptor > 0) {
        NSRLog(@"closing socket fd %d", socketDescriptor);
        NSMutableDictionary<NSNumber *, NSRProxyTask *> *tasks = NSRProxyTasks();
        NSRProxyTask *proxy = nil;
        @synchronized (tasks) {
            proxy = tasks[@(socketDescriptor)];
            [tasks removeObjectForKey:@(socketDescriptor)];
        }
        close(socketDescriptor);
        [proxy stop];
    }
}

+ (NSString*)getResolvedIpAddressWith:(int)socket {
    if (!socket) { return @""; }
    struct sockaddr_storage sin = {0};
    socklen_t len = sizeof(sin);
    if (getpeername(socket, (struct sockaddr*)&sin, &len) != 0) { return @""; }
    char buf[255];
    memset(buf, 0, sizeof(buf));
    switch(sin.ss_family) {
        case AF_INET: {
            struct sockaddr_in *addr_in = (struct sockaddr_in *)&sin;
            inet_ntop(AF_INET, &(addr_in->sin_addr), buf, INET_ADDRSTRLEN);
            break;
        }
        case AF_INET6: {
            struct sockaddr_in6 *addr_in6 = (struct sockaddr_in6 *)&sin;
            inet_ntop(AF_INET6, &(addr_in6->sin6_addr), buf, INET6_ADDRSTRLEN);
            break;
        }
        default:
            break;
    }
    return [[NSString alloc] initWithUTF8String:buf];
}

@end
