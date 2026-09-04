#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Reads the public UIKeyboardHIDUsage value without asking Swift to switch on
/// an SDK enum that may gain values on a newer OS.
FOUNDATION_EXPORT NSInteger MRHIDUsageFromUIKey(UIKey *key);

NS_ASSUME_NONNULL_END
