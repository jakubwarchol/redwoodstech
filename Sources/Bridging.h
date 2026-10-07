// Private IOKit / CoreGraphics declarations, adapted from LinearMouse's
// Modules/PointerKit/Sources/PointerKitC/include/IOKitSPIMac.h (Copyright (C) 2020 Apple Inc., BSD-style license)
// and LinearMouse-Bridging-Header.h (MIT, Copyright (c) 2021-2026 LinearMouse).

#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <IOKit/hidsystem/IOHIDServiceClient.h>

CF_IMPLICIT_BRIDGING_ENABLED

typedef CFTypeRef IOHIDEventRef;
typedef void (^IOHIDServiceClientBlock)(void *_Nullable, void *_Nullable, IOHIDServiceClientRef _Nullable);

IOHIDEventSystemClientRef _Nullable IOHIDEventSystemClientCreate(CFAllocatorRef _Nullable);
void IOHIDEventSystemClientSetMatchingMultiple(IOHIDEventSystemClientRef, CFArrayRef);
void IOHIDEventSystemClientRegisterDeviceMatchingBlock(IOHIDEventSystemClientRef, IOHIDServiceClientBlock, void *_Nullable, void *_Nullable);
void IOHIDEventSystemClientScheduleWithDispatchQueue(IOHIDEventSystemClientRef, dispatch_queue_t);
void IOHIDServiceClientRegisterRemovalBlock(IOHIDServiceClientRef, IOHIDServiceClientBlock, void *_Nullable, void *_Nullable);

IOHIDEventRef _Nullable CGEventCopyIOHIDEvent(CGEventRef);
uint64_t IOHIDEventGetSenderID(IOHIDEventRef);
double IOHIDEventGetFloatValue(IOHIDEventRef, uint32_t field);
void IOHIDEventSetFloatValue(IOHIDEventRef, uint32_t field, double value);

CF_IMPLICIT_BRIDGING_DISABLED
