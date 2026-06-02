#pragma once

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AndmonUSBAccessory AndmonUSBAccessory;

/// Performs the AOA mode switch, reconnects, and opens bulk endpoints.
AndmonUSBAccessory *AndmonUSBAccessoryOpen(void **errorOut);
void AndmonUSBAccessoryClose(AndmonUSBAccessory *accessory);
ssize_t AndmonUSBAccessoryRead(AndmonUSBAccessory *accessory, void *bytes, size_t length, void **errorOut);
ssize_t AndmonUSBAccessoryWrite(AndmonUSBAccessory *accessory, const void *bytes, size_t length, void **errorOut);

#ifdef __cplusplus
}
#endif
