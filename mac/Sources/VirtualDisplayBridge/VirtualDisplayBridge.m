#import "VirtualDisplayBridge.h"

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
- (uint32_t)displayID;
@end

struct AndmonVirtualDisplay {
    void *retainedDisplay;
    uint32_t displayID;
};

static NSError *AndmonError(NSString *message) {
    return [NSError errorWithDomain:@"dev.andmon.VirtualDisplay"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

AndmonVirtualDisplay *AndmonVirtualDisplayCreate(int32_t refreshRate, void **errorOut) {
    NSError *error = nil;
    id descriptor = nil;
    CGVirtualDisplayMode *mode = nil;
    id settings = nil;
    CGVirtualDisplay *display = nil;
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    if (!descriptorClass || !modeClass || !settingsClass || !displayClass) {
        error = AndmonError(@"Private CGVirtualDisplay runtime classes are unavailable");
        goto fail;
    }

    descriptor = [descriptorClass new];
    // Keep the identity stable so macOS restores the saved display arrangement
    // when the virtual display is recreated after the host restarts.
    // We use a unique fixed value instead of 1 to avoid conflicts with other 
    // virtual displays that might have been mistakenly set to mirror.
    uint32_t serial = 0x414E444D; // "ANDM" in hex
    [descriptor setValue:dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0) forKey:@"queue"];
    [descriptor setValue:@"Andmon Galaxy Tab" forKey:@"name"];
    [descriptor setValue:@2960 forKey:@"maxPixelsWide"];
    [descriptor setValue:@1848 forKey:@"maxPixelsHigh"];
    [descriptor setValue:@(serial) forKey:@"serialNum"];
    [descriptor setValue:@(serial) forKey:@"serialNumber"];
    [descriptor setValue:@(0x5355) forKey:@"vendorID"];
    [descriptor setValue:@(0x424D) forKey:@"productID"];
    [descriptor setValue:[NSValue valueWithSize:NSMakeSize(326.4, 203.7)] forKey:@"sizeInMillimeters"];
    // Galaxy Tab S8 Ultra Natural mode targets the sRGB gamut with a D65
    // white point. BT.709 uses the same primaries for the encoded SDR stream.
    [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.3127, 0.3290)] forKey:@"whitePoint"];
    [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.1500, 0.0600)] forKey:@"bluePrimary"];
    [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.3000, 0.6000)] forKey:@"greenPrimary"];
    [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.6400, 0.3300)] forKey:@"redPrimary"];

    mode = [[modeClass alloc] initWithWidth:1480 height:924 refreshRate:(double)refreshRate];
    settings = [settingsClass new];
    [settings setValue:@[mode] forKey:@"modes"];
    [settings setValue:@1 forKey:@"hiDPI"];
    [settings setValue:@0 forKey:@"rotation"];

    display = [[displayClass alloc] initWithDescriptor:descriptor];
    if (!display) {
        error = AndmonError(@"CGVirtualDisplay initialization failed");
        goto fail;
    }
    BOOL applied = [display applySettings:settings];
    if (!applied) {
        error = AndmonError(@"CGVirtualDisplay rejected the requested HiDPI mode");
        goto fail;
    }

    uint32_t displayID = [display displayID];
    CGDisplayModeRef currentMode = CGDisplayCopyDisplayMode(displayID);
    size_t logicalWidth = currentMode ? CGDisplayModeGetWidth(currentMode) : 0;
    size_t logicalHeight = currentMode ? CGDisplayModeGetHeight(currentMode) : 0;
    size_t pixelWidth = currentMode ? CGDisplayModeGetPixelWidth(currentMode) : 0;
    size_t pixelHeight = currentMode ? CGDisplayModeGetPixelHeight(currentMode) : 0;
    if (currentMode) CFRelease(currentMode);
    if (logicalWidth != 1480 || logicalHeight != 924 || pixelWidth != 2960 || pixelHeight != 1848) {
        error = AndmonError([NSString stringWithFormat:
            @"Virtual display mode is logical %zu x %zu backed by %zu x %zu; expected logical 1480 x 924 backed by 2960 x 1848",
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
