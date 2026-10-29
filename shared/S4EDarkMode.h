// Dark Mode: the appearance and its schedule, shared by SpringBoard (the engine), the apps and Settings.
//
// SpringBoard decides the appearance and publishes it in the state of S4E_NOTIFY_APPEARANCE, so App Store
// apps in a sandbox know it too. As in iOS 13, choosing Light or Dark while Automatic is on holds until
// the next change in the schedule.

#pragma once

#import "S4EShared.h"
#import "S4ENightShift.h"

#define kS4EDarkMode @"DarkMode"                     // the chosen appearance: NO light, YES dark
#define kS4EDMAutomatic @"DarkModeAutomatic"
#define kS4EDMFrom @"DarkModeFrom"                   // dark from, minutes since midnight
#define kS4EDMTo @"DarkModeTo"                       // light from
#define kS4EDMUntil @"DarkModeChoiceUntil"           // a choice made while Automatic is on holds until then
#define kS4EDMOtherApps @"DarkModeOtherApps"

#define S4E_DM_DEFAULT_FROM (22 * 60)
#define S4E_DM_DEFAULT_TO (7 * 60)

#define S4E_NOTIFY_APPEARANCE "com.skeuo4ever/appearance"

enum {
    S4EAppearancePublished = 1u << 0,
    S4EAppearanceDark = 1u << 1,
    S4EAppearanceOtherApps = 1u << 2,
};

static inline S4E_UNUSED int S4EDMFrom(NSDictionary *p) { return (int)S4EDouble(p, kS4EDMFrom, S4E_DM_DEFAULT_FROM); }
static inline S4E_UNUSED int S4EDMTo(NSDictionary *p) { return (int)S4EDouble(p, kS4EDMTo, S4E_DM_DEFAULT_TO); }

static inline S4E_UNUSED BOOL S4EDMScheduledDark(NSDictionary *p, NSDate *now) {
    return S4ENSInWindow(S4ENSMinutes(now), S4EDMFrom(p), S4EDMTo(p));
}

static inline S4E_UNUSED BOOL S4EDMIsDark(NSDictionary *p, NSDate *now) {
    BOOL chosen = S4EBool(p, kS4EDarkMode, NO);
    if (!S4EBool(p, kS4EDMAutomatic, NO) || S4EDouble(p, kS4EDMUntil, 0) > [now timeIntervalSince1970])
        return chosen;
    return S4EDMScheduledDark(p, now);
}

// The next moment the schedule switches the appearance
static inline S4E_UNUSED NSDate *S4EDMNextChange(NSDictionary *p, NSDate *now) {
    NSDate *dark = S4ENSNext(now, S4EDMFrom(p)), *light = S4ENSNext(now, S4EDMTo(p));
    return [dark compare:light] == NSOrderedAscending ? dark : light;
}

// Light or Dark chosen by hand; with Automatic on, the choice holds until the schedule changes again
static inline S4E_UNUSED NSDictionary *S4EDMChoose(NSDictionary *p, BOOL dark, NSDate *now) {
    if (!S4EBool(p, kS4EDMAutomatic, NO) || dark == S4EDMScheduledDark(p, now))
        return @{kS4EDarkMode: @(dark), kS4EDMUntil: [NSNull null]};
    return @{kS4EDarkMode: @(dark), kS4EDMUntil: @([S4EDMNextChange(p, now) timeIntervalSince1970])};
}

// Turning Automatic on follows the schedule at once; turning it off keeps what is on the screen now
static inline S4E_UNUSED NSDictionary *S4EDMSetAutomatic(NSDictionary *p, BOOL automatic, NSDate *now) {
    if (automatic)
        return @{kS4EDMAutomatic: @YES, kS4EDarkMode: @(S4EDMScheduledDark(p, now)), kS4EDMUntil: [NSNull null]};
    return @{kS4EDMAutomatic: @NO, kS4EDarkMode: @(S4EDMIsDark(p, now)), kS4EDMUntil: [NSNull null]};
}

static inline S4E_UNUSED uint64_t S4EAppearanceState(void) {
    static int token;
    static BOOL registered;
    if (!registered)
        registered = (notify_register_check(S4E_NOTIFY_APPEARANCE, &token) == NOTIFY_STATUS_OK);
    uint64_t state = 0;
    if (registered)
        notify_get_state(token, &state);
    return state;
}

// From SpringBoard if it has published, from the plist otherwise
static inline S4E_UNUSED uint64_t S4EAppearance(void) {
    uint64_t state = S4EAppearanceState();
    if (state & S4EAppearancePublished)
        return state;
    NSDictionary *p = S4EPrefsRead();
    if (!p)
        return 0;
    return S4EAppearancePublished | (S4EDMIsDark(p, [NSDate date]) ? S4EAppearanceDark : 0) |
           (S4EBool(p, kS4EDMOtherApps, NO) ? S4EAppearanceOtherApps : 0);
}
