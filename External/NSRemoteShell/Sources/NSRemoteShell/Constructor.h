//
//  Constructor.h
//  
//
//  Created by Lakr Aream on 2022/2/5.
//

#ifndef Constructor_h
#define Constructor_h

/// return 1 if success
int libssh2_init_check(void);

/// Holds the process-wide latency-critical activity while at least one
/// NSRemoteShell event loop is running, and releases it when idle so a
/// backgrounded app with no active connections can enter App Nap.
void nsremoteshell_activity_begin(void);
void nsremoteshell_activity_end(void);

#endif /* Constructor_h */
