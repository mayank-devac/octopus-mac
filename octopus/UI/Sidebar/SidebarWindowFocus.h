#import <Foundation/Foundation.h>
#import <sys/types.h>

// Requests focus for one window through WindowServer. YES means the request was
// submitted, not that its Space is visible or that the window is key.
BOOL SidebarWindowFocusRequest(pid_t pid, uint32_t windowID);
