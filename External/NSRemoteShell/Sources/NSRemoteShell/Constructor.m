//
//  Constructor.m
//  
//
//  Created by Lakr Aream on 2022/2/5.
//

#import "Constructor.h"
#import "GenericHeaders.h"
#import "TSEventLoop.h"

#import <Foundation/Foundation.h>

int kLIBSSH2_CONSTRUCTOR_SUCCESS = 0;

#if TARGET_OS_OSX

/*

 https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html

 App Nap will make our Timer inside CFRunLoop not waking up on schedule
 which will then cause a port forward to die

 Hold the activity while at least one TSEventLoop is running, and release it
 when every shell has closed so an idle backgrounded app can enter App Nap.

 */
static NSObject *activity = NULL;
static NSInteger activityCount = 0;

void nsremoteshell_activity_begin(void) {
    @synchronized ([NSProcessInfo class]) {
        activityCount += 1;
        if (activityCount == 1 && !activity) {
            activity = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityLatencyCritical reason:@"NSRemoteShell is latency critical"];
        }
    }
}

void nsremoteshell_activity_end(void) {
    @synchronized ([NSProcessInfo class]) {
        if (activityCount <= 0) {
            return;
        }
        activityCount -= 1;
        if (activityCount == 0 && activity) {
            [[NSProcessInfo processInfo] endActivity:activity];
            activity = NULL;
        }
    }
}

#else

void nsremoteshell_activity_begin(void) {}
void nsremoteshell_activity_end(void) {}

#endif

__attribute__((constructor)) void libssh2_constructor(void) {
    int ret = libssh2_init(0); // flag 1 == no crypto
    if (ret == 0) {
        kLIBSSH2_CONSTRUCTOR_SUCCESS = 1;
        NSRLog(@"libssh2 init success");
    }
}

__attribute__((destructor)) void libssh2_destructor(void) {
    if (kLIBSSH2_CONSTRUCTOR_SUCCESS) {
        libssh2_exit();
    }
#if TARGET_OS_OSX
    @synchronized ([NSProcessInfo class]) {
        if (activity) {
            [[NSProcessInfo processInfo] endActivity:activity];
            activity = NULL;
        }
        activityCount = 0;
    }
#endif
}

int libssh2_init_check() {
    return kLIBSSH2_CONSTRUCTOR_SUCCESS;
}

/*
 used for our CI machine, don't remove this if making contribute
 */
NSString *NSRemoteShellVersion = @"k.S-BrGcrAzymeD6jQ7FdFw6stCZW";
