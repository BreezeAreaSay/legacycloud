// iOS6Revive — общий код всех твиков (только заголовок: каждый твик компилирует его в себя).
//
// Как устроены настройки:
//  * Источник правды — plist в /var/mobile/Library/Preferences. Его пишут Настройки и SpringBoard.
//  * После записи отправляется Darwin-уведомление IR_NOTIFY_PREFS.
//  * SpringBoard (твик core) перечитывает plist и публикует короткую битовую маску в состоянии
//    уведомления IR_NOTIFY_STATE. Программы из App Store живут в песочнице и могут не прочитать
//    plist — тогда они берут флаги из этой маски.

#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <notify.h>
#include <substrate.h>

#define IR_UNUSED __attribute__((unused))

#define IR_PREFS_PATH @"/var/mobile/Library/Preferences/com.ios6revive.plist"
#define IR_DATA_DIR @"/var/mobile/Library/iOS6Revive"
#define IR_DYLIB_DIR @"/Library/MobileSubstrate/DynamicLibraries"

#define IR_NOTIFY_PREFS "com.ios6revive/prefs-changed"
#define IR_NOTIFY_STATE "com.ios6revive/state"
#define IR_NOTIFY_RESPRING "com.ios6revive/respring"

// Ключи настроек
#define kIRSwipeBack @"SwipeBack"
#define kIRLowPower @"LowPowerMode"
#define kIRBoldText @"BoldText"
#define kIRNewAppDot @"NewAppDot"

// Битовая маска состояния, которую публикует SpringBoard
enum {
    IRStatePublished = 1u << 0,
    IRStateSwipeBack = 1u << 1,
    IRStateLowPower = 1u << 2,
    IRStateBoldText = 1u << 3,
};

#define IRLog(fmt, ...) NSLog(@"[iOS6Revive] " fmt, ##__VA_ARGS__)

// Перехват метода: если класса или метода нет, ничего не делаем.
#define IR_HOOK(cls, selector, replacement, original) \
    do { \
        Class _ir_cls = (cls); \
        if (_ir_cls) MSHookMessageEx(_ir_cls, (selector), (IMP)(replacement), (IMP *)(original)); \
    } while (0)

static inline IR_UNUSED NSDictionary *IRPrefsRead(void) {
    return [NSDictionary dictionaryWithContentsOfFile:IR_PREFS_PATH];
}

static inline IR_UNUSED BOOL IRBool(NSDictionary *prefs, NSString *key, BOOL fallback) {
    id value = prefs[key];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

static inline IR_UNUSED double IRDouble(NSDictionary *prefs, NSString *key, double fallback) {
    id value = prefs[key];
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
}

// NSNull в changes удаляет ключ.
static inline IR_UNUSED void IRPrefsSetValues(NSDictionary *changes) {
    NSMutableDictionary *prefs = [IRPrefsRead() mutableCopy] ?: [NSMutableDictionary dictionary];
    [changes enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if (value == [NSNull null])
            [prefs removeObjectForKey:key];
        else
            prefs[key] = value;
    }];
    if (![prefs writeToFile:IR_PREFS_PATH atomically:YES])
        IRLog(@"не удалось записать %@", IR_PREFS_PATH);
    notify_post(IR_NOTIFY_PREFS);
}

static inline IR_UNUSED void IRPrefsSet(NSString *key, id value) {
    IRPrefsSetValues(@{key: value ?: [NSNull null]});
}

static inline IR_UNUSED uint64_t IRStateRead(void) {
    static int token;
    static BOOL registered;
    if (!registered)
        registered = (notify_register_check(IR_NOTIFY_STATE, &token) == NOTIFY_STATUS_OK);
    uint64_t state = 0;
    if (registered)
        notify_get_state(token, &state);
    return state;
}

// Флаг функции: из plist, а если он недоступен (песочница) — из маски SpringBoard.
static inline IR_UNUSED BOOL IRFlag(NSString *key, uint64_t bit, BOOL fallback) {
    NSDictionary *prefs = IRPrefsRead();
    if (prefs)
        return IRBool(prefs, key, fallback);
    uint64_t state = IRStateRead();
    if (state & IRStatePublished)
        return (state & bit) != 0;
    return fallback;
}

static inline IR_UNUSED void IRObserveDarwin(const char *name, CFNotificationCallback callback) {
    CFStringRef cfName = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingUTF8);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, callback, cfName, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFRelease(cfName);
}

static inline IR_UNUSED BOOL IRIsProcess(NSString *bundleID) {
    return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:bundleID];
}

static inline IR_UNUSED NSString *IRDataPath(NSString *name) {
    [[NSFileManager defaultManager] createDirectoryAtPath:IR_DATA_DIR withIntermediateDirectories:YES attributes:nil error:NULL];
    return [IR_DATA_DIR stringByAppendingPathComponent:name];
}

static inline IR_UNUSED id IRIvar(id object, const char *name) {
    if (!object)
        return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}
