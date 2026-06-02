#pragma once

#include <stdint.h>
#include "LibUSBBridge.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AndmonVirtualDisplay AndmonVirtualDisplay;

/// Creates a 1336 x 834 HiDPI virtual desktop backed by 2672 x 1668 pixels.
/// Returns NULL and writes a retained CFErrorRef-compatible object on failure.
AndmonVirtualDisplay *AndmonVirtualDisplayCreate(void **errorOut);
void AndmonVirtualDisplayRelease(AndmonVirtualDisplay *display);
uint32_t AndmonVirtualDisplayID(AndmonVirtualDisplay *display);

#ifdef __cplusplus
}
#endif
