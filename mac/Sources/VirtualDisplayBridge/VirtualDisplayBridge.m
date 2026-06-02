#import "VirtualDisplayBridge.h"

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>

struct AndmonVirtualDisplay {
    void *retainedDisplay;
    uint32_t displayID;
};

static NSError *AndmonError(NSString *message) {
    return [NSError errorWithDomain:@"dev.andmon.VirtualDisplay"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL RequireSelector(Class cls, SEL selector, BOOL classMethod, NSError **error) {
    BOOL found = classMethod ? [cls respondsToSelector:selector] : [cls instancesRespondToSelector:selector];
    if (!found && error) {
        *error = AndmonError([NSString stringWithFormat:@"%@ is missing selector %@",
                              NSStringFromClass(cls), NSStringFromSelector(selector)]);
    }
    return found;
}

AndmonVirtualDisplay *AndmonVirtualDisplayCreate(void **errorOut) {
    NSError *error = nil;
    id descriptor = nil;
    id modeAllocated = nil;
    id mode = nil;
    id settings = nil;
    id displayAllocated = nil;
    id display = nil;
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    if (!descriptorClass || !modeClass || !settingsClass || !displayClass) {
        error = AndmonError(@"Private CGVirtualDisplay runtime classes are unavailable");
        goto fail;
    }

    SEL modeInit = NSSelectorFromString(@"initWithWidth:height:refreshRate:");
    SEL displayInit = NSSelectorFromString(@"initWithDescriptor:");
    SEL applySettings = NSSelectorFromString(@"applySettings:");
    SEL displayIDSelector = NSSelectorFromString(@"displayID");
    if (!RequireSelector(modeClass, modeInit, NO, &error) ||
        !RequireSelector(displayClass, displayInit, NO, &error) ||
        !RequireSelector(displayClass, applySettings, NO, &error) ||
        !RequireSelector(displayClass, displayIDSelector, NO, &error)) {
        goto fail;
    }

    descriptor = [descriptorClass new];
    // Keep the identity stable so macOS restores the saved display arrangement
    // when the virtual display is recreated after the host restarts.
    uint32_t serial = 1;
    [descriptor setValue:dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0) forKey:@"queue"];
    [descriptor setValue:@"Andmon Galaxy Tab" forKey:@"name"];
    [descriptor setValue:@2960 forKey:@"maxPixelsWide"];
    [descriptor setValue:@1848 forKey:@"maxPixelsHigh"];
    [descriptor setValue:@(serial) forKey:@"serialNum"];
    [descriptor setValue:@(serial) forKey:@"serialNumber"];
    [descriptor setValue:@(0x5355) forKey:@"vendorID"];
    [descriptor setValue:@(0x424D) forKey:@"productID"];
    [descriptor setValue:[NSValue valueWithSize:NSMakeSize(326.4, 203.7)] forKey:@"sizeInMillimeters"];
    // Use the Display P3 gamut with a D65 white point end to end.
    [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.3127, 0.3290)] forKey:@"whitePoint"];
    [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.1500, 0.0600)] forKey:@"bluePrimary"];
    [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.2650, 0.6900)] forKey:@"greenPrimary"];
    [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.6800, 0.3200)] forKey:@"redPrimary"];

    modeAllocated = ((id (*)(id, SEL))objc_msgSend)(modeClass, sel_registerName("alloc"));
    mode = ((id (*)(id, SEL, NSUInteger, NSUInteger, double))objc_msgSend)(
        modeAllocated, modeInit, 1336, 834, 60.0);
    settings = [settingsClass new];
    [settings setValue:@[mode] forKey:@"modes"];
    [settings setValue:@1 forKey:@"hiDPI"];
    [settings setValue:@0 forKey:@"rotation"];

    displayAllocated = ((id (*)(id, SEL))objc_msgSend)(displayClass, sel_registerName("alloc"));
    display = ((id (*)(id, SEL, id))objc_msgSend)(displayAllocated, displayInit, descriptor);
    if (!display) {
        error = AndmonError(@"CGVirtualDisplay initialization failed");
        goto fail;
    }
    BOOL applied = ((BOOL (*)(id, SEL, id))objc_msgSend)(display, applySettings, settings);
    if (!applied) {
        error = AndmonError(@"CGVirtualDisplay rejected the requested HiDPI mode");
        goto fail;
    }

    uint32_t displayID = ((uint32_t (*)(id, SEL))objc_msgSend)(display, displayIDSelector);
    CGDisplayModeRef currentMode = CGDisplayCopyDisplayMode(displayID);
    size_t logicalWidth = currentMode ? CGDisplayModeGetWidth(currentMode) : 0;
    size_t logicalHeight = currentMode ? CGDisplayModeGetHeight(currentMode) : 0;
    size_t pixelWidth = currentMode ? CGDisplayModeGetPixelWidth(currentMode) : 0;
    size_t pixelHeight = currentMode ? CGDisplayModeGetPixelHeight(currentMode) : 0;
    if (currentMode) CFRelease(currentMode);
    if (logicalWidth != 1336 || logicalHeight != 834 || pixelWidth != 2672 || pixelHeight != 1668) {
        error = AndmonError([NSString stringWithFormat:
            @"Virtual display mode is logical %zu x %zu backed by %zu x %zu; expected logical 1336 x 834 backed by 2672 x 1668",
            logicalWidth, logicalHeight, pixelWidth, pixelHeight]);
        goto fail;
    }

    AndmonVirtualDisplay *result = calloc(1, sizeof(AndmonVirtualDisplay));
    result->retainedDisplay = (__bridge_retained void *)display;
    result->displayID = displayID;
    return result;

fail:
    if (errorOut) *errorOut = (__bridge_retained void *)error;
    return NULL;
}

void AndmonVirtualDisplayRelease(AndmonVirtualDisplay *display) {
    if (!display) return;
    if (display->retainedDisplay) {
        CFRelease(display->retainedDisplay);
    }
    free(display);
}

uint32_t AndmonVirtualDisplayID(AndmonVirtualDisplay *display) {
    return display ? display->displayID : 0;
}
