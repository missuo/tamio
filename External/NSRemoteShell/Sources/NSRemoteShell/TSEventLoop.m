//
//  NSRemoteEvent.m
//  
//
//  Created by Lakr Aream on 2022/2/5.
//

// TS: Thread Safe

#import "TSEventLoop.h"
#import "Constructor.h"

@interface TSEventLoop ()

@property (nonatomic, nonnull, strong) NSThread *associatedThread;
@property (nonatomic, nonnull, strong) NSRunLoop *associatedRunLoop;
@property (nonatomic, nonnull, strong) NSTimer *associatedTimer;
@property (nonatomic, nonnull, strong) NSPort *associatedPort;
@property (nonatomic, nullable, weak) NSRemoteShell *parent;
@property (nonatomic, assign) BOOL loopDestroyed;

@end

@implementation TSEventLoop

- (instancetype)initWithParent:(__weak NSRemoteShell*)parent {
    if (self = [super init]) {
        _parent = parent;
        _loopDestroyed = NO;
        nsremoteshell_activity_begin();
        _associatedThread = [[NSThread alloc] initWithTarget:self
                                                    selector:@selector(associatedThreadHandler)
                                                      object:NULL];
        NSString *threadName = [[NSString alloc] initWithFormat:@"sb.moe.tamio.shell.%p", parent];
        [_associatedThread setName:threadName];
        NSRLog(@"opening thread %@", threadName);
        [_associatedThread start];
    }
    return self;
}

- (void)dealloc {
    NSRLog(@"TSEventLoop object at %p deallocating", self);
    [self destroyLoop];
}

- (void)explicitRequestHandle {
    [self.associatedPort sendBeforeDate:[[NSDate alloc] init]
                             components:NULL
                                   from:NULL
                               reserved:NO];
}

- (void)associatedThreadHandler {
    self.associatedRunLoop = [NSRunLoop currentRunLoop];
    
    self.associatedPort = [[NSPort alloc] init];
    self.associatedPort.delegate = self;
    [self.associatedRunLoop addPort:self.associatedPort forMode:NSRunLoopCommonModes];
    
    self.associatedTimer = [[NSTimer alloc] initWithFireDate: [[NSDate alloc] init]
                                                    interval:0.1
                                                      target:self selector:@selector(associatedLoopHandler)
                                                    userInfo:NULL
                                                     repeats:YES];
    [self.associatedRunLoop addTimer:self.associatedTimer forMode:NSRunLoopCommonModes];
    [self.associatedRunLoop run];
    NSRLog(@"thread %@ exiting", [[NSThread currentThread] name]);
}

- (void)handleMachMessage:(void *)msg {
    // we don't care about the message, if received any, call handler
    [self associatedLoopHandler];
}

- (void)associatedLoopHandler {
    if (!self.parent) {
        [self destroyLoop];
        return;
    }
#if DEBUG
    NSString *name = [[NSThread currentThread] name];
    NSString *want = [[NSString alloc] initWithFormat:@"sb.moe.tamio.shell.%p", self.parent];
    if (![name isEqualToString:want]) {
        NSRLog(@"\n\n");
        NSRLog(@"[E] shell name mismatch");
        NSRLog(@"expect: %@", want);
        NSRLog(@" found: %@", name);
        NSRLog(@"\n\n");
    }
#endif
    [self.parent handleRequestsIfNeeded];
    // the timer above wakes this handler about 10 times a second and
    // port messages add extra runs on top; the nap throttles back to
    // back housekeeping so a busy session can not spin a whole core
    usleep(20000);
}

- (void)destroyLoop {
    BOOL shouldEndActivity = NO;
    @synchronized (self) {
        if (!_loopDestroyed) {
            _loopDestroyed = YES;
            shouldEndActivity = YES;
        }
    }
    if (shouldEndActivity) {
        nsremoteshell_activity_end();
    }
    [self.associatedTimer invalidate];
    [self.associatedRunLoop removePort:self.associatedPort forMode:NSRunLoopCommonModes];
    CFRunLoopRef runLoop = [self.associatedRunLoop getCFRunLoop];
    if (runLoop) { CFRunLoopStop(runLoop); }
}

@end
