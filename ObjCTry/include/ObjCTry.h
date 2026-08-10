#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const MEMObjCExceptionDomain;

/// Runs `block` inside @try/@catch, turning a raised NSException into an
/// NSError. Returns YES when the block completed without raising.
///
/// Swift's `try` only catches Swift errors: an ObjC exception unwinding into
/// Swift frames calls std::terminate and aborts the process. AVFAudio raises
/// them on some device-transition failures — notably
/// -[AVAudioIONode setVoiceProcessingEnabled:error:], which raises instead of
/// populating its own error parameter when the IO unit cannot be created while
/// the input device is switching. That killed the whole recorder mid-call.
BOOL MEMRunCatchingExceptions(void (NS_NOESCAPE ^block)(void), NSError **error);

NS_ASSUME_NONNULL_END
