#import "mr_mac_key_monitor.h"

/* UIKit on the Mac runs inside an AppKit application, but a Catalyst target
 * cannot import AppKit. NSEvent is reached by name instead, through the few
 * public methods declared here; the selectors are AppKit's own. */
@protocol MRNSEventClass
+ (id)addLocalMonitorForEventsMatchingMask:(uint64_t)mask handler:(id _Nullable (^)(id event))block;
+ (void)removeMonitor:(id)monitor;
@end

@protocol MRNSEvent
- (NSUInteger)type;
- (unsigned short)keyCode;
- (NSUInteger)modifierFlags;
- (BOOL)isARepeat;
- (NSInteger)buttonNumber;
@end

id mr_mac_key_monitor_install(MRMacKeyHandler handler) {
#if TARGET_OS_MACCATALYST
    Class eventClass = NSClassFromString(@"NSEvent");
    if (eventClass == Nil) {
        return nil;
    }
    uint64_t mask = (1ULL << MRMacKeyEventTypeKeyDown) | (1ULL << MRMacKeyEventTypeKeyUp) |
                    (1ULL << MRMacKeyEventTypeFlagsChanged);
    return [(Class<MRNSEventClass>)eventClass
        addLocalMonitorForEventsMatchingMask:mask
                                     handler:^id _Nullable(id event) {
                                         id<MRNSEvent> key = event;
                                         NSUInteger type = [key type];
                                         /* isARepeat raises for flagsChanged. */
                                         BOOL repeat = type != MRMacKeyEventTypeFlagsChanged && [key isARepeat];
                                         BOOL consumed = handler((MRMacKeyEventType)type, [key keyCode],
                                                                 (uint64_t)[key modifierFlags], repeat);
                                         return consumed ? nil : event;
                                     }];
#else
    (void)handler;
    return nil;
#endif
}

id mr_mac_mouse_monitor_install(MRMacMouseButtonHandler handler) {
#if TARGET_OS_MACCATALYST
    Class eventClass = NSClassFromString(@"NSEvent");
    if (eventClass == Nil) {
        return nil;
    }
    /* NSEventTypeRightMouseDown/Up = 3/4, NSEventTypeOtherMouseDown/Up = 25/26. */
    uint64_t mask = (1ULL << 3) | (1ULL << 4) | (1ULL << 25) | (1ULL << 26);
    return [(Class<MRNSEventClass>)eventClass
        addLocalMonitorForEventsMatchingMask:mask
                                     handler:^id _Nullable(id event) {
                                         id<MRNSEvent> mouse = event;
                                         NSUInteger type = [mouse type];
                                         BOOL pressed = type == 3 || type == 25;
                                         BOOL consumed = handler((uint16_t)[mouse buttonNumber], pressed);
                                         return consumed ? nil : event;
                                     }];
#else
    (void)handler;
    return nil;
#endif
}

void mr_mac_key_monitor_remove(id monitor) {
#if TARGET_OS_MACCATALYST
    [(Class<MRNSEventClass>)NSClassFromString(@"NSEvent") removeMonitor:monitor];
#else
    (void)monitor;
#endif
}
