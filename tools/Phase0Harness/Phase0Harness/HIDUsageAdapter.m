#import "HIDUsageAdapter.h"

NSInteger MRHIDUsageFromUIKey(UIKey *key) {
    return (NSInteger)key.keyCode;
}
