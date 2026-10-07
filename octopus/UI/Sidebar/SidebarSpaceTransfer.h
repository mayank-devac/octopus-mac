#import <Foundation/Foundation.h>
// This header is also the target's Swift bridging header.
#import "SidebarWindowFocus.h"

// Submission is asynchronous. YES means submitted, not that the window moved.
BOOL SidebarSpaceTransferIsAvailable(void);
BOOL SidebarSpaceTransferSubmit(uint32_t windowID, uint64_t desktopID);
