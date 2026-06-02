#import "LibUSBBridge.h"

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <string.h>
#import <unistd.h>

typedef struct libusb_context libusb_context;
typedef struct libusb_device libusb_device;
typedef struct libusb_device_handle libusb_device_handle;

struct libusb_device_descriptor {
    uint8_t bLength, bDescriptorType;
    uint16_t bcdUSB;
    uint8_t bDeviceClass, bDeviceSubClass, bDeviceProtocol, bMaxPacketSize0;
    uint16_t idVendor, idProduct, bcdDevice;
    uint8_t iManufacturer, iProduct, iSerialNumber, bNumConfigurations;
};
struct libusb_endpoint_descriptor {
    uint8_t bLength, bDescriptorType, bEndpointAddress, bmAttributes;
    uint16_t wMaxPacketSize;
    uint8_t bInterval, bRefresh, bSynchAddress;
    const unsigned char *extra;
    int extra_length;
};
struct libusb_interface_descriptor {
    uint8_t bLength, bDescriptorType, bInterfaceNumber, bAlternateSetting, bNumEndpoints;
    uint8_t bInterfaceClass, bInterfaceSubClass, bInterfaceProtocol, iInterface;
    const struct libusb_endpoint_descriptor *endpoint;
    const unsigned char *extra;
    int extra_length;
};
struct libusb_interface {
    const struct libusb_interface_descriptor *altsetting;
    int num_altsetting;
};
struct libusb_config_descriptor {
    uint8_t bLength, bDescriptorType;
    uint16_t wTotalLength;
    uint8_t bNumInterfaces, bConfigurationValue, iConfiguration, bmAttributes, MaxPower;
    const struct libusb_interface *interface;
    const unsigned char *extra;
    int extra_length;
};

typedef int (*init_fn)(libusb_context **);
typedef void (*exit_fn)(libusb_context *);
typedef ssize_t (*get_device_list_fn)(libusb_context *, libusb_device ***);
typedef void (*free_device_list_fn)(libusb_device **, int);
typedef int (*get_device_descriptor_fn)(libusb_device *, struct libusb_device_descriptor *);
typedef int (*open_fn)(libusb_device *, libusb_device_handle **);
typedef void (*close_fn)(libusb_device_handle *);
typedef int (*control_transfer_fn)(libusb_device_handle *, uint8_t, uint8_t, uint16_t, uint16_t, unsigned char *, uint16_t, unsigned int);
typedef int (*get_active_config_descriptor_fn)(libusb_device *, struct libusb_config_descriptor **);
typedef void (*free_config_descriptor_fn)(struct libusb_config_descriptor *);
typedef int (*claim_interface_fn)(libusb_device_handle *, int);
typedef int (*release_interface_fn)(libusb_device_handle *, int);
typedef int (*bulk_transfer_fn)(libusb_device_handle *, unsigned char, unsigned char *, int, int *, unsigned int);
typedef const char *(*error_name_fn)(int);

struct AndmonUSBAccessory {
    void *library;
    libusb_context *context;
    libusb_device_handle *handle;
    uint8_t endpointIn;
    uint8_t endpointOut;
    int interfaceNumber;
    exit_fn exitUSB;
    close_fn closeUSB;
    release_interface_fn releaseInterface;
    bulk_transfer_fn bulkTransfer;
    error_name_fn errorName;
};

typedef struct {
    void *library;
    libusb_context *context;
    init_fn initUSB;
    exit_fn exitUSB;
    get_device_list_fn getDeviceList;
    free_device_list_fn freeDeviceList;
    get_device_descriptor_fn getDeviceDescriptor;
    open_fn openUSB;
    close_fn closeUSB;
    control_transfer_fn controlTransfer;
    get_active_config_descriptor_fn getActiveConfigDescriptor;
    free_config_descriptor_fn freeConfigDescriptor;
    claim_interface_fn claimInterface;
    release_interface_fn releaseInterface;
    bulk_transfer_fn bulkTransfer;
    error_name_fn errorName;
} USBAPI;

static NSError *USBError(NSString *message) {
    return [NSError errorWithDomain:@"dev.andmon.LibUSB" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static void ReturnError(void **errorOut, NSError *error) {
    if (errorOut) *errorOut = (__bridge_retained void *)error;
}

static BOOL LoadSymbol(void *library, void **out, const char *name, NSError **error) {
    *out = dlsym(library, name);
    if (*out) return YES;
    *error = USBError([NSString stringWithFormat:@"libusb is missing symbol %s", name]);
    return NO;
}

static BOOL LoadUSB(USBAPI *api, NSError **error) {
    char executablePath[PATH_MAX];
    uint32_t executablePathSize = sizeof(executablePath);
    NSString *bundledLibraryPath = nil;
    if (_NSGetExecutablePath(executablePath, &executablePathSize) == 0) {
        bundledLibraryPath = [[[[NSString stringWithUTF8String:executablePath]
            stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"../Frameworks/libusb-1.0.dylib"]
            stringByStandardizingPath];
    }
    const char *paths[] = {
        bundledLibraryPath.fileSystemRepresentation,
        "/opt/homebrew/opt/libusb/lib/libusb-1.0.dylib",
        "/usr/local/opt/libusb/lib/libusb-1.0.dylib",
        "libusb-1.0.dylib",
    };
    for (unsigned i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        if (!paths[i]) continue;
        api->library = dlopen(paths[i], RTLD_NOW | RTLD_LOCAL);
        if (api->library) break;
    }
    if (!api->library) {
        *error = USBError(@"Bundled or Homebrew libusb was not found");
        return NO;
    }
#define LOAD(field, name) if (!LoadSymbol(api->library, (void **)&api->field, name, error)) return NO
    LOAD(initUSB, "libusb_init");
    LOAD(exitUSB, "libusb_exit");
    LOAD(getDeviceList, "libusb_get_device_list");
    LOAD(freeDeviceList, "libusb_free_device_list");
    LOAD(getDeviceDescriptor, "libusb_get_device_descriptor");
    LOAD(openUSB, "libusb_open");
    LOAD(closeUSB, "libusb_close");
    LOAD(controlTransfer, "libusb_control_transfer");
    LOAD(getActiveConfigDescriptor, "libusb_get_active_config_descriptor");
    LOAD(freeConfigDescriptor, "libusb_free_config_descriptor");
    LOAD(claimInterface, "libusb_claim_interface");
    LOAD(releaseInterface, "libusb_release_interface");
    LOAD(bulkTransfer, "libusb_bulk_transfer");
    LOAD(errorName, "libusb_error_name");
#undef LOAD
    int result = api->initUSB(&api->context);
    if (result != 0) {
        *error = USBError([NSString stringWithFormat:@"libusb_init failed: %s", api->errorName(result)]);
        return NO;
    }
    return YES;
}

static BOOL IsAccessoryProduct(struct libusb_device_descriptor descriptor) {
    return descriptor.idVendor == 0x18D1 &&
        (descriptor.idProduct == 0x2D00 || descriptor.idProduct == 0x2D01 ||
         descriptor.idProduct == 0x2D04 || descriptor.idProduct == 0x2D05);
}

static BOOL SwitchOneDeviceToAccessoryMode(USBAPI *api, NSError **error) {
    libusb_device **devices = NULL;
    ssize_t count = api->getDeviceList(api->context, &devices);
    if (count < 0) {
        *error = USBError([NSString stringWithFormat:@"USB enumeration failed: %s", api->errorName((int)count)]);
        return NO;
    }
    libusb_device *candidate = NULL;
    NSUInteger candidateCount = 0;
    for (ssize_t i = 0; i < count; i++) {
        struct libusb_device_descriptor descriptor;
        if (api->getDeviceDescriptor(devices[i], &descriptor) != 0 || IsAccessoryProduct(descriptor)) continue;
        libusb_device_handle *handle = NULL;
        if (api->openUSB(devices[i], &handle) != 0) continue;
        unsigned char protocolBytes[2] = {0};
        int result = api->controlTransfer(handle, 0xC0, 51, 0, 0, protocolBytes, 2, 1000);
        if (result == 2 && (protocolBytes[0] | (protocolBytes[1] << 8)) >= 1) {
            candidate = devices[i];
            candidateCount++;
        }
        api->closeUSB(handle);
    }
    if (candidateCount == 0) {
        api->freeDeviceList(devices, 1);
        return NO;
    }
    if (candidateCount > 1) {
        *error = USBError(@"Multiple AOA-capable Android devices found; connect only one tablet");
        api->freeDeviceList(devices, 1);
        return NO;
    }
    libusb_device_handle *handle = NULL;
    int result = api->openUSB(candidate, &handle);
    if (result != 0) {
        *error = USBError([NSString stringWithFormat:@"Opening Android USB device failed: %s", api->errorName(result)]);
        api->freeDeviceList(devices, 1);
        return NO;
    }
    const char *strings[] = {
        "Andmon", "Galaxy Tab S8 Ultra Submonitor", "Wired extended desktop receiver",
        "1.0", "https://localhost/andmon", "andmon-mvp",
    };
    BOOL switched = YES;
    for (uint16_t index = 0; index < 6; index++) {
        result = api->controlTransfer(handle, 0x40, 52, 0, index,
            (unsigned char *)strings[index], (uint16_t)strlen(strings[index]) + 1, 1000);
        if (result < 0) {
            *error = USBError([NSString stringWithFormat:@"AOA identification failed: %s", api->errorName(result)]);
            switched = NO;
            break;
        }
    }
    if (switched) {
        result = api->controlTransfer(handle, 0x40, 53, 0, 0, NULL, 0, 1000);
        if (result < 0) {
            *error = USBError([NSString stringWithFormat:@"AOA start failed: %s", api->errorName(result)]);
            switched = NO;
        }
    }
    api->closeUSB(handle);
    api->freeDeviceList(devices, 1);
    return switched;
}

static BOOL OpenAccessory(USBAPI *api, AndmonUSBAccessory *result, NSError **error) {
    libusb_device **devices = NULL;
    ssize_t count = api->getDeviceList(api->context, &devices);
    if (count < 0) {
        *error = USBError([NSString stringWithFormat:@"USB enumeration failed: %s", api->errorName((int)count)]);
        return NO;
    }
    libusb_device *candidate = NULL;
    NSUInteger candidateCount = 0;
    for (ssize_t i = 0; i < count; i++) {
        struct libusb_device_descriptor descriptor;
        if (api->getDeviceDescriptor(devices[i], &descriptor) == 0 && IsAccessoryProduct(descriptor)) {
            candidate = devices[i];
            candidateCount++;
        }
    }
    if (candidateCount == 0) {
        api->freeDeviceList(devices, 1);
        return NO;
    }
    if (candidateCount > 1) {
        *error = USBError(@"Multiple Android accessory-mode devices found; connect only one tablet");
        api->freeDeviceList(devices, 1);
        return NO;
    }
    struct libusb_config_descriptor *config = NULL;
    int status = api->getActiveConfigDescriptor(candidate, &config);
    if (status != 0) {
        *error = USBError([NSString stringWithFormat:@"Reading Android accessory configuration failed: %s", api->errorName(status)]);
        api->freeDeviceList(devices, 1);
        return NO;
    }
    BOOL opened = NO;
    for (uint8_t interfaceIndex = 0; interfaceIndex < config->bNumInterfaces && !opened; interfaceIndex++) {
        const struct libusb_interface *interface = &config->interface[interfaceIndex];
        for (int alternate = 0; alternate < interface->num_altsetting && !opened; alternate++) {
            const struct libusb_interface_descriptor *setting = &interface->altsetting[alternate];
            if (setting->bInterfaceClass != 0xFF || setting->bInterfaceSubClass != 0xFF ||
                setting->bInterfaceProtocol != 0) continue;
            uint8_t endpointIn = 0, endpointOut = 0;
            for (uint8_t endpoint = 0; endpoint < setting->bNumEndpoints; endpoint++) {
                uint8_t address = setting->endpoint[endpoint].bEndpointAddress;
                if ((setting->endpoint[endpoint].bmAttributes & 3) != 2) continue;
                if (address & 0x80) endpointIn = address; else endpointOut = address;
            }
            libusb_device_handle *handle = NULL;
            status = endpointIn && endpointOut ? api->openUSB(candidate, &handle) : -1;
            if (status == 0 && api->claimInterface(handle, setting->bInterfaceNumber) == 0) {
                result->handle = handle;
                result->endpointIn = endpointIn;
                result->endpointOut = endpointOut;
                result->interfaceNumber = setting->bInterfaceNumber;
                opened = YES;
            } else if (handle) {
                api->closeUSB(handle);
            }
        }
    }
    api->freeConfigDescriptor(config);
    api->freeDeviceList(devices, 1);
    if (!opened) *error = USBError(@"Android accessory has no claimable bulk IN/OUT interface");
    return opened;
}

AndmonUSBAccessory *AndmonUSBAccessoryOpen(void **errorOut) {
    USBAPI api = {0};
    NSError *error = nil;
    if (!LoadUSB(&api, &error)) {
        ReturnError(errorOut, error);
        if (api.library) dlclose(api.library);
        return NULL;
    }
    AndmonUSBAccessory *result = calloc(1, sizeof(AndmonUSBAccessory));
    result->library = api.library;
    result->context = api.context;
    result->exitUSB = api.exitUSB;
    result->closeUSB = api.closeUSB;
    result->releaseInterface = api.releaseInterface;
    result->bulkTransfer = api.bulkTransfer;
    result->errorName = api.errorName;
    if (!OpenAccessory(&api, result, &error)) {
        if (error || !SwitchOneDeviceToAccessoryMode(&api, &error)) {
            error = error ?: USBError(@"No AOA-capable Android device found");
        } else {
            for (int retry = 0; retry < 100 && !result->handle; retry++) {
                NSError *retryError = nil;
                if (!OpenAccessory(&api, result, &retryError) && retryError) error = retryError;
                if (!result->handle) usleep(100000);
            }
            if (!result->handle) error = error ?: USBError(@"Tablet did not reconnect in Android accessory mode");
        }
    }
    if (!result->handle) {
        ReturnError(errorOut, error);
        AndmonUSBAccessoryClose(result);
        return NULL;
    }
    return result;
}

void AndmonUSBAccessoryClose(AndmonUSBAccessory *accessory) {
    if (!accessory) return;
    if (accessory->handle) {
        accessory->releaseInterface(accessory->handle, accessory->interfaceNumber);
        accessory->closeUSB(accessory->handle);
    }
    if (accessory->context) accessory->exitUSB(accessory->context);
    if (accessory->library) dlclose(accessory->library);
    free(accessory);
}

static ssize_t Transfer(AndmonUSBAccessory *accessory, uint8_t endpoint, void *bytes, size_t length, void **errorOut) {
    int transferred = 0;
    int status = accessory->bulkTransfer(accessory->handle, endpoint, bytes, (int)length, &transferred, 1000);
    if (status == 0) return transferred;
    if (status == -7) return 0; // Timeout allows callers to observe cancellation.
    ReturnError(errorOut, USBError([NSString stringWithFormat:@"USB bulk transfer failed: %s", accessory->errorName(status)]));
    return -1;
}

ssize_t AndmonUSBAccessoryRead(AndmonUSBAccessory *accessory, void *bytes, size_t length, void **errorOut) {
    return Transfer(accessory, accessory->endpointIn, bytes, length, errorOut);
}

ssize_t AndmonUSBAccessoryWrite(AndmonUSBAccessory *accessory, const void *bytes, size_t length, void **errorOut) {
    return Transfer(accessory, accessory->endpointOut, (void *)bytes, length, errorOut);
}
