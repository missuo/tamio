//
//  GenericNetworking.h
//  
//
//  Created by Lakr Aream on 2022/2/5.
//

#import <Foundation/Foundation.h>

#import "GenericHeaders.h"

NS_ASSUME_NONNULL_BEGIN

@interface GenericNetworking : NSObject

+ (NSArray *)resolveIpAddressesFor:(NSString*)candidateHost;

+ (BOOL)isValidateWithPort:(NSNumber*)port;

+ (int)createSocketNonblockingListenerWithLocalPort:(NSNumber*)localPort;

+ (int)createSocketWithTargetHost:(NSString*)targetHost
                   withTargetPort:(NSNumber*)targetPort
             requireNonblockingIO:(BOOL)useNonblocking
;

+ (int)createSocketWithTargetHost:(NSString*)targetHost
                   withTargetPort:(NSNumber*)targetPort
             requireNonblockingIO:(BOOL)useNonblocking
               withConnectTimeout:(NSNumber*)connectTimeout
;

/// A connected socket whose other end is a running command: `command` is
/// started with %h and %p replaced by the host and port, and its stdin and
/// stdout are the SSH stream. Returns 0 when the command cannot be started,
/// with the reason in `failure`. The caller owns the descriptor and closes it
/// with `destroyNativeSocket:`, which also ends the command.
+ (int)createSocketWithProxyCommand:(NSString *)command
                         targetHost:(NSString *)targetHost
                         targetPort:(NSNumber *)targetPort
                            failure:(NSString *_Nullable *_Nullable)failure;

/// Why the proxy command for `socketDescriptor` stopped before the SSH
/// handshake completed, read from its stderr or exit status; nil when none was
/// recorded.
+ (nullable NSString *)proxyFailureForSocket:(int)socketDescriptor;

+ (void)destroyNativeSocket:(int)socketDescriptor;

+ (NSString*)getResolvedIpAddressWith:(int)socket;

@end

NS_ASSUME_NONNULL_END
