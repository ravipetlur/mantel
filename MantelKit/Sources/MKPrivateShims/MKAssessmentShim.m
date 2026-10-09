#import "MKAssessmentShim.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

#if !__has_feature(objc_arc)
#error "MKAssessmentShim.m must be compiled with ARC"
#endif

NSErrorDomain const MKAssessmentShimErrorDomain = @"MKAssessmentShimErrorDomain";

static const char *const kFrameworkPath = "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore";
static NSString *const kConfigurationClassName = @"MBAssessmentModeConfiguration";
static NSString *const kAssertionClassName = @"MBAssessmentModeAssertion";

static NSString *const kInitSelector = @"initWithAllowedSystemItems:allowedBundleIdentifiers:";
static NSString *const kActivateSelector = @"activateWithConfiguration:completionHandler:";
static NSString *const kInvalidateSelector = @"invalidate";

/// What Mantel was written against: for each method it calls, the class it is on and its type encoding. An encoding spells
/// the return type and each argument with the offsets they sit at; a method with other arguments has another one.
static NSArray<NSDictionary<NSString *, NSString *> *> *ExpectedMethods(void) {
    return @[
        @{ @"class": kConfigurationClassName, @"selector": kInitSelector, @"encoding": @"@32@0:8@16@24" },
        @{ @"class": kAssertionClassName, @"selector": kActivateSelector, @"encoding": @"v32@0:8@16@?24" },
        @{ @"class": kAssertionClassName, @"selector": kInvalidateSelector, @"encoding": @"v16@0:8" },
    ];
}

/// The key the configuration is kept under, on the assertion that was activated with it.
static const void *kConfigurationKey = &kConfigurationKey;

@interface MKAssessmentReport ()
- (instancetype)initWithFrameworkLoaded:(BOOL)frameworkLoaded
                 configurationClassFound:(BOOL)configurationClassFound
                    assertionClassFound:(BOOL)assertionClassFound
                              encodings:(NSDictionary<NSString *, NSString *> *)encodings
                                problem:(nullable NSString *)problem NS_DESIGNATED_INITIALIZER;
@end

@implementation MKAssessmentReport {
    BOOL _frameworkLoaded, _configurationClassFound, _assertionClassFound;
    NSDictionary<NSString *, NSString *> *_encodings;
    NSString *_problem;
}

- (instancetype)initWithFrameworkLoaded:(BOOL)frameworkLoaded
                 configurationClassFound:(BOOL)configurationClassFound
                    assertionClassFound:(BOOL)assertionClassFound
                              encodings:(NSDictionary<NSString *, NSString *> *)encodings
                                problem:(nullable NSString *)problem {
    self = [super init];
    if (self) {
        _frameworkLoaded = frameworkLoaded;
        _configurationClassFound = configurationClassFound;
        _assertionClassFound = assertionClassFound;
        _encodings = [encodings copy];
        _problem = [problem copy];
    }
    return self;
}

- (BOOL)frameworkLoaded { return _frameworkLoaded; }
- (BOOL)configurationClassFound { return _configurationClassFound; }
- (BOOL)assertionClassFound { return _assertionClassFound; }
- (NSDictionary<NSString *, NSString *> *)encodings { return _encodings; }
- (nullable NSString *)problem { return _problem; }

@end

@implementation MKAssessmentShim

+ (MKAssessmentReport *)inspect {
    void *handle = dlopen(kFrameworkPath, RTLD_LAZY);
    if (handle == NULL) {
        const char *reason = dlerror();
        NSString *problem = [NSString stringWithFormat:@"MenuBarClientCore couldn't be loaded (%s)", reason ?: "no reason given"];
        NSMutableDictionary<NSString *, NSString *> *empty = [NSMutableDictionary dictionary];
        for (NSDictionary<NSString *, NSString *> *method in ExpectedMethods()) {
            empty[method[@"selector"]] = @"";
        }
        return [[MKAssessmentReport alloc] initWithFrameworkLoaded:NO
                                           configurationClassFound:NO
                                               assertionClassFound:NO
                                                         encodings:empty
                                                           problem:problem];
    }

    Class configurationClass = NSClassFromString(kConfigurationClassName);
    Class assertionClass = NSClassFromString(kAssertionClassName);

    NSMutableArray<NSString *> *problems = [NSMutableArray array];
    if (configurationClass == Nil) {
        [problems addObject:[NSString stringWithFormat:@"%@ isn't in MenuBarClientCore", kConfigurationClassName]];
    }
    if (assertionClass == Nil) {
        [problems addObject:[NSString stringWithFormat:@"%@ isn't in MenuBarClientCore", kAssertionClassName]];
    }

    NSMutableDictionary<NSString *, NSString *> *encodings = [NSMutableDictionary dictionary];
    for (NSDictionary<NSString *, NSString *> *expected in ExpectedMethods()) {
        NSString *selectorName = expected[@"selector"];
        Class owner = NSClassFromString(expected[@"class"]);
        const char *found = NULL;
        if (owner != Nil) {
            Method method = class_getInstanceMethod(owner, NSSelectorFromString(selectorName));
            if (method != NULL) {
                found = method_getTypeEncoding(method);
            }
        }
        NSString *encoding = found != NULL ? [NSString stringWithUTF8String:found] : @"";
        encodings[selectorName] = encoding;

        if (owner == Nil) {
            continue; // already reported
        }
        if (encoding.length == 0) {
            [problems addObject:[NSString stringWithFormat:@"%@ has no %@", expected[@"class"], selectorName]];
        } else if (![encoding isEqualToString:expected[@"encoding"]]) {
            [problems addObject:[NSString stringWithFormat:@"%@ has encoding \"%@\" where Mantel expects \"%@\"",
                                 selectorName, encoding, expected[@"encoding"]]];
        }
    }

    NSString *problem = problems.count > 0 ? [problems componentsJoinedByString:@"; "] : nil;
    return [[MKAssessmentReport alloc] initWithFrameworkLoaded:YES
                                       configurationClassFound:configurationClass != Nil
                                           assertionClassFound:assertionClass != Nil
                                                     encodings:encodings
                                                       problem:problem];
}

+ (nullable id)activateAllowingSystemItems:(NSArray<NSNumber *> *)items
                                 bundleIDs:(NSArray<NSString *> *)bundleIDs
                                completion:(void (^ NS_SWIFT_SENDABLE)(NSError * _Nullable))completion
                                     error:(NSError **)error {
    // Before any private method is called, and with nothing called at all if one doesn't match.
    MKAssessmentReport *report = [self inspect];
    if (report.problem != nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:MKAssessmentShimErrorDomain
                                         code:1
                                     userInfo:@{ NSLocalizedDescriptionKey:
                                                     [NSString stringWithFormat:@"Mantel didn't call macOS's allowlist: %@", report.problem] }];
        }
        return nil;
    }

    Class configurationClass = NSClassFromString(kConfigurationClassName);
    Class assertionClass = NSClassFromString(kAssertionClassName);

    // initWithAllowedSystemItems:allowedBundleIdentifiers: is "@32@0:8@16@24": an object back, two objects in.
    id configuration = ((id (*)(id, SEL, NSArray *, NSArray *))objc_msgSend)(
        [configurationClass alloc], NSSelectorFromString(kInitSelector), [items copy], [bundleIDs copy]);
    id assertion = configuration != nil ? [[assertionClass alloc] init] : nil;
    if (configuration == nil || assertion == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:MKAssessmentShimErrorDomain
                                         code:2
                                     userInfo:@{ NSLocalizedDescriptionKey: @"macOS didn't make the allowlist objects." }];
        }
        return nil;
    }
    // The assertion may not keep the configuration it was activated with. It is kept as long as the assertion is.
    objc_setAssociatedObject(assertion, kConfigurationKey, configuration, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // activateWithConfiguration:completionHandler: is "v32@0:8@16@?24": nothing back, an object and a block in.
    void (^handler)(NSError * _Nullable) = [completion copy];
    ((void (*)(id, SEL, id, void (^)(NSError * _Nullable)))objc_msgSend)(
        assertion, NSSelectorFromString(kActivateSelector), configuration, handler);
    return assertion;
}

+ (void)invalidate:(id)assertion {
    Class assertionClass = NSClassFromString(kAssertionClassName);
    if (assertionClass == Nil || ![assertion isKindOfClass:assertionClass]) {
        return;
    }
    // invalidate is "v16@0:8", which `activate…` has already checked.
    ((void (*)(id, SEL))objc_msgSend)(assertion, NSSelectorFromString(kInvalidateSelector));
    objc_setAssociatedObject(assertion, kConfigurationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end
