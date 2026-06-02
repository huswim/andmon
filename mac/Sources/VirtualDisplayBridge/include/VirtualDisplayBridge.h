#pragma once

#include <stdint.h>
#include "LibUSBBridge.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AndmonVirtualDisplay AndmonVirtualDisplay;

/// Creates a 1480 x 924 HiDPI virtual desktop backed by 2960 x 1848 pixels.
/// Returns NULL and writes a retained CFErrorRef-compatible object on failure.
AndmonVirtualDisplay *AndmonVirtualDisplayCreate(void **errorOut);
void AndmonVirtualDisplayRelease(AndmonVirtualDisplay *display);
uint32_t AndmonVirtualDisplayID(AndmonVirtualDisplay *display);

#ifdef __cplusplus
}
#endif
