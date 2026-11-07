// One's only Objective-C: Swift can't catch an Objective-C exception. Apple's audio classes raise one (instead of
// returning an error) when the speaker can't start, e.g. while the Mac is asleep with the lid closed; uncaught, it
// ends One (0.9.98, Nov 6 and 7 2026). `OneCatch` runs a block and hands back the exception's reason instead.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Runs `block`. Returns nil when it finished, or the reason of the Objective-C exception it raised.
NSString *_Nullable OneCatch(NS_NOESCAPE void (^block)(void));
NS_ASSUME_NONNULL_END
