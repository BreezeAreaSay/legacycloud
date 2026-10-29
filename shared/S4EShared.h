// Skeuo4Ever — code shared by every tweak (header only: each tweak compiles it in).
//
// How settings work:
//  * The source of truth is a plist in /var/mobile/Library/Preferences, written by Settings and SpringBoard.
//  * After writing, the S4E_NOTIFY_PREFS Darwin notification is posted.
//  * SpringBoard (the core tweak) rereads the plist and publishes a short bit mask in the state of the
//    S4E_NOTIFY_STATE notification. App Store apps live in a sandbox and may not be able to read the
//    plist, so they take their flags from that mask.
//
// Language: every user-facing string is written in English and Russian with S4E_L(en, ru). Settings
// offer Automatic (the system language), English and Russian.

#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <notify.h>
#include <substrate.h>

#define S4E_UNUSED __attribute__((unused))

#define S4E_PREFS_PATH @"/var/mobile/Library/Preferences/com.skeuo4ever.plist"
#define S4E_DATA_DIR @"/var/mobile/Library/Skeuo4Ever"
#define S4E_DYLIB_DIR @"/Library/MobileSubstrate/DynamicLibraries"

#define S4E_NOTIFY_PREFS "com.skeuo4ever/prefs-changed"
#define S4E_NOTIFY_STATE "com.skeuo4ever/state"
#define S4E_NOTIFY_RESPRING "com.skeuo4ever/respring"

// Settings keys
#define kS4ESwipeBack @"SwipeBack"
#define kS4ELowPower @"LowPowerMode"
#define kS4EBoldText @"BoldText"
#define kS4ENewSash @"NewAppSash"
#define kS4ELanguage @"Language" // "auto", "en" or "ru"

// State bit mask published by SpringBoard
enum {
    S4EStatePublished = 1u << 0,
    S4EStateSwipeBack = 1u << 1,
    S4EStateLowPower = 1u << 2,
    S4EStateBoldText = 1u << 3,
};

#define S4ELog(fmt, ...) NSLog(@"[Skeuo4Ever] " fmt, ##__VA_ARGS__)

// Hooks a method; does nothing if the class or method is missing.
#define S4E_HOOK(cls, selector, replacement, original) \
    do { \
        Class _s4e_cls = (cls); \
        if (_s4e_cls) MSHookMessageEx(_s4e_cls, (selector), (IMP)(replacement), (IMP *)(original)); \
    } while (0)

static inline S4E_UNUSED NSDictionary *S4EPrefsRead(void) {
    return [NSDictionary dictionaryWithContentsOfFile:S4E_PREFS_PATH];
}

static inline S4E_UNUSED BOOL S4EBool(NSDictionary *prefs, NSString *key, BOOL fallback) {
    id value = prefs[key];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

static inline S4E_UNUSED double S4EDouble(NSDictionary *prefs, NSString *key, double fallback) {
    id value = prefs[key];
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
}

// NSNull in changes removes the key.
static inline S4E_UNUSED void S4EPrefsSetValues(NSDictionary *changes) {
    NSMutableDictionary *prefs = [S4EPrefsRead() mutableCopy] ?: [NSMutableDictionary dictionary];
    [changes enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if (value == [NSNull null])
            [prefs removeObjectForKey:key];
        else
            prefs[key] = value;
    }];
    if (![prefs writeToFile:S4E_PREFS_PATH atomically:YES])
        S4ELog(@"could not write %@", S4E_PREFS_PATH);
    notify_post(S4E_NOTIFY_PREFS);
}

static inline S4E_UNUSED void S4EPrefsSet(NSString *key, id value) {
    S4EPrefsSetValues(@{key: value ?: [NSNull null]});
}

static inline S4E_UNUSED uint64_t S4EStateRead(void) {
    static int token;
    static BOOL registered;
    if (!registered)
        registered = (notify_register_check(S4E_NOTIFY_STATE, &token) == NOTIFY_STATUS_OK);
    uint64_t state = 0;
    if (registered)
        notify_get_state(token, &state);
    return state;
}

// A feature flag: from the plist, or from SpringBoard's mask if the plist is out of reach (sandbox).
static inline S4E_UNUSED BOOL S4EFlag(NSString *key, uint64_t bit, BOOL fallback) {
    NSDictionary *prefs = S4EPrefsRead();
    if (prefs)
        return S4EBool(prefs, key, fallback);
    uint64_t state = S4EStateRead();
    if (state & S4EStatePublished)
        return (state & bit) != 0;
    return fallback;
}

static inline S4E_UNUSED void S4EObserveDarwin(const char *name, CFNotificationCallback callback) {
    CFStringRef cfName = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingUTF8);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, callback, cfName, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFRelease(cfName);
}

static inline S4E_UNUSED BOOL S4EIsProcess(NSString *bundleID) {
    return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:bundleID];
}

static inline S4E_UNUSED NSString *S4EDataPath(NSString *name) {
    [[NSFileManager defaultManager] createDirectoryAtPath:S4E_DATA_DIR withIntermediateDirectories:YES attributes:nil error:NULL];
    return [S4E_DATA_DIR stringByAppendingPathComponent:name];
}

static inline S4E_UNUSED id S4EIvar(id object, const char *name) {
    if (!object)
        return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

#pragma mark - Language

// -1: not decided yet; 0: English; 1: Russian. Every tweak has its own copy and resets it when settings change.
static int gS4ERussian S4E_UNUSED = -1;

static S4E_UNUSED void S4ELanguageChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                          const void *object, CFDictionaryRef info) {
    gS4ERussian = -1;
}

static inline S4E_UNUSED void S4EResetLanguage(void) {
    gS4ERussian = -1;
}

static inline S4E_UNUSED BOOL S4EIsRussian(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        S4EObserveDarwin(S4E_NOTIFY_PREFS, S4ELanguageChanged);
    });
    if (gS4ERussian < 0) {
        NSString *choice = S4EPrefsRead()[kS4ELanguage];
        if ([choice isEqual:@"ru"] || [choice isEqual:@"en"]) {
            gS4ERussian = [choice isEqual:@"ru"];
        } else {
            NSArray *languages = [NSLocale preferredLanguages];
            gS4ERussian = languages.count && [languages[0] hasPrefix:@"ru"];
        }
    }
    return gS4ERussian == 1;
}

// A user-facing string in the current language
#define S4E_L(en, ru) (S4EIsRussian() ? (ru) : (en))
