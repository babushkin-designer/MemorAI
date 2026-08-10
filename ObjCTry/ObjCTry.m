#import "ObjCTry.h"

NSString *const MEMObjCExceptionDomain = @"com.local.memorai.objc-exception";

BOOL MEMRunCatchingExceptions(void (NS_NOESCAPE ^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSString *description = [NSString stringWithFormat:@"%@: %@",
                                     exception.name,
                                     exception.reason ?: @"(no reason given)"];
            *error = [NSError errorWithDomain:MEMObjCExceptionDomain
                                         code:1
                                     userInfo:@{ NSLocalizedDescriptionKey: description }];
        }
        return NO;
    }
}
