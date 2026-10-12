#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The domain of the errors this shim makes: code 1, nothing was called because `inspect` found a problem; code 2, macOS's
/// objects couldn't be made.
FOUNDATION_EXPORT NSErrorDomain const MKAssessmentShimErrorDomain;

/// What `+[MKAssessmentShim inspect]` found in macOS's private MenuBarClientCore framework: whether it loaded, whether the
/// two classes are there, and the type encoding of each method Mantel would call.
@interface MKAssessmentReport : NSObject
@property (readonly) BOOL frameworkLoaded;
@property (readonly) BOOL configurationClassFound, assertionClassFound;
/// Selector → the type encoding found for it ("" if the method is missing). Three selectors, see `MKAssessmentShim.m`.
@property (readonly, copy) NSDictionary<NSString *, NSString *> *encodings;
/// nil when everything matches what Mantel expects; otherwise everything that doesn't, in words, separated by "; ".
@property (readonly, copy, nullable) NSString *problem;
- (instancetype)init NS_UNAVAILABLE;
@end

/// The one place Mantel calls macOS's private "assessment mode" API (MBAssessmentModeConfiguration and
/// MBAssessmentModeAssertion), which hides the status items of every app that isn't on an allowlist.
///
/// No method is called before its type encoding has been read and found to be the one Mantel was written against: a
/// private method that changed would otherwise be called with the wrong arguments.
@interface MKAssessmentShim : NSObject
/// Loads the framework (`dlopen`) and checks its classes, selectors and encodings. Only reads: it never activates anything.
+ (MKAssessmentReport *)inspect;

/// Makes an allowlist of `items` (system item numbers) and `bundleIDs` and activates it, if `inspect` finds nothing wrong.
/// Returns the assertion object, which the caller must hold until `invalidate:`; nil, with `error`, when `inspect` found a
/// problem (nothing is called then) or the objects couldn't be made.
///
/// The assertion is returned retained (`NS_RETURNS_RETAINED`): the caller owns it, and no autorelease pool is involved in handing it
/// over.
///
/// `completion` is called when macOS has finished activating, with nil or the error it gave. **It may be called on any
/// thread**, so it is `NS_SWIFT_SENDABLE`. It is not called when this returns nil, and it isn't optional: macOS is always given
/// a block. `error` may be NULL.
+ (nullable id)activateAllowingSystemItems:(NSArray<NSNumber *> *)items
                                 bundleIDs:(NSArray<NSString *> *)bundleIDs
                                completion:(void (^ NS_SWIFT_SENDABLE)(NSError * _Nullable error))completion
                                     error:(NSError * _Nullable * _Nullable)error NS_RETURNS_RETAINED;

/// Ends an assertion that `activateAllowingSystemItems:…` returned. Something that isn't one is ignored.
+ (void)invalidate:(id)assertion;
@end

NS_ASSUME_NONNULL_END
