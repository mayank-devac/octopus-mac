#import "SidebarWindowFocus.h"
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <string.h>

// Runtime-only bridge, following yabai's window_manager_focus_window_with_raise:
// https://github.com/asmvik/yabai/blob/master/src/window_manager.c
// Name the target window instead of requesting app-wide activation. The caller raises
// it through AX afterwards; this private API does not guarantee Space-switch ordering.
typedef CGError (*SetFrontProcessFn)(ProcessSerialNumber *, uint32_t, uint32_t);
typedef CGError (*PostEventRecordFn)(ProcessSerialNumber *, uint8_t *);
typedef OSStatus (*ProcessForPIDFn)(pid_t, ProcessSerialNumber *);

static const uint32_t userGeneratedMode = 0x200; // kCPSUserGenerated
static SetFrontProcessFn setFrontProcess;
static PostEventRecordFn postEventRecord;
static ProcessForPIDFn processForPID;

static BOOL isAvailable(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Keep both frameworks loaded while their function pointers are in use.
        void *skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        void *services = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY);
        if (skyLight) {
            setFrontProcess = (SetFrontProcessFn)dlsym(skyLight, "_SLPSSetFrontProcessWithOptions");
            postEventRecord = (PostEventRecordFn)dlsym(skyLight, "SLPSPostEventRecordTo");
        }
        // Deprecated but still the only PID-to-PSN mapping these calls accept.
        if (services) processForPID = (ProcessForPIDFn)dlsym(services, "GetProcessForPID");
    });
    return setFrontProcess && postEventRecord && processForPID;
}

// Synthesised key-window event pair; without it the app activates but may keep its
// previous key window.
static void makeKeyWindow(ProcessSerialNumber *psn, uint32_t windowID) {
    uint8_t event[0xf8] = { [0x04] = 0xf8, [0x3a] = 0x10 };
    memcpy(event + 0x3c, &windowID, sizeof(windowID));
    memset(event + 0x20, 0xff, 0x10);
    event[0x08] = 0x01;
    postEventRecord(psn, event);
    event[0x08] = 0x02;
    postEventRecord(psn, event);
}

BOOL SidebarWindowFocusRequest(pid_t pid, uint32_t windowID) {
    if (pid <= 0 || !windowID || !isAvailable()) return NO;
    ProcessSerialNumber psn = { 0, 0 };
    if (processForPID(pid, &psn) != noErr) return NO;
    if (setFrontProcess(&psn, windowID, userGeneratedMode) != kCGErrorSuccess) return NO;
    makeKeyWindow(&psn, windowID);
    return YES;
}
