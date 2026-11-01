#import <AppKit/AppKit.h>
#include "CodexBarTestBootstrap.h"

static bool policyApplied;
static bool precededApplication;

// A load-time initializer precedes Swift test discovery and lazy test globals.
__attribute__((constructor))
static void codexbar_test_bootstrap_initialize(void) {
    @autoreleasepool {
        precededApplication = NSApp == nil;
        NSApplication *application = [NSApplication sharedApplication];
        [application setActivationPolicy:NSApplicationActivationPolicyProhibited];
        policyApplied = [application activationPolicy] == NSApplicationActivationPolicyProhibited;
    }
}

bool codexbar_test_bootstrap_applied_policy(void) {
    return policyApplied;
}

bool codexbar_test_bootstrap_preceded_application(void) {
    return precededApplication;
}
