// Night Shift schedule: shared by SpringBoard (the engine) and Settings (the switches).

#pragma once

#import "S4EShared.h"

#define kS4ENSScheduled @"NightShiftScheduled"
#define kS4ENSFrom @"NightShiftFrom"            // minutes since midnight
#define kS4ENSTo @"NightShiftTo"
#define kS4ENSManualUntil @"NightShiftManualUntil" // manually on until (seconds since 1970)
#define kS4ENSOffUntil @"NightShiftOffUntil"       // manually off within the schedule until
#define kS4ENSWarmth @"NightShiftWarmth"           // 0…1

#define S4E_NS_DEFAULT_FROM (22 * 60)
#define S4E_NS_DEFAULT_TO (7 * 60)
#define S4E_NS_DEFAULT_WARMTH 0.5

static inline S4E_UNUSED int S4ENSMinutes(NSDate *date) {
    NSDateComponents *c = [[NSCalendar currentCalendar] components:NSHourCalendarUnit | NSMinuteCalendarUnit fromDate:date];
    return (int)(c.hour * 60 + c.minute);
}

static inline S4E_UNUSED BOOL S4ENSInWindow(int now, int from, int to) {
    if (from == to)
        return NO;
    if (from < to)
        return now >= from && now < to;
    return now >= from || now < to; // the window spans midnight
}

// The nearest moment strictly after date when the clock shows minutes.
static inline S4E_UNUSED NSDate *S4ENSNext(NSDate *date, int minutes) {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *c = [calendar components:NSYearCalendarUnit | NSMonthCalendarUnit | NSDayCalendarUnit fromDate:date];
    c.hour = minutes / 60;
    c.minute = minutes % 60;
    NSDate *result = [calendar dateFromComponents:c];
    if ([result timeIntervalSinceDate:date] <= 0) {
        NSDateComponents *day = [[NSDateComponents alloc] init];
        day.day = 1;
        result = [calendar dateByAddingComponents:day toDate:result options:0];
    }
    return result;
}

static inline S4E_UNUSED int S4ENSFrom(NSDictionary *p) { return (int)S4EDouble(p, kS4ENSFrom, S4E_NS_DEFAULT_FROM); }
static inline S4E_UNUSED int S4ENSTo(NSDictionary *p) { return (int)S4EDouble(p, kS4ENSTo, S4E_NS_DEFAULT_TO); }

static inline S4E_UNUSED BOOL S4ENSScheduledNow(NSDictionary *p, NSDate *now) {
    return S4EBool(p, kS4ENSScheduled, NO) && S4ENSInWindow(S4ENSMinutes(now), S4ENSFrom(p), S4ENSTo(p));
}

static inline S4E_UNUSED BOOL S4ENSActive(NSDictionary *p, NSDate *now) {
    NSTimeInterval t = [now timeIntervalSince1970];
    if (S4EDouble(p, kS4ENSManualUntil, 0) > t)
        return YES;
    return S4ENSScheduledNow(p, now) && !(S4EDouble(p, kS4ENSOffUntil, 0) > t);
}

// The "Manually Enable Until Tomorrow" switch, as in iOS: turns it on until morning,
// and turning it off within the schedule keeps it off until the end of the current window.
static inline S4E_UNUSED NSDictionary *S4ENSManualChanges(NSDictionary *p, BOOL on, NSDate *now) {
    NSNumber *endOfWindow = @([S4ENSNext(now, S4ENSTo(p)) timeIntervalSince1970]);
    if (on)
        return @{kS4ENSManualUntil: endOfWindow, kS4ENSOffUntil: [NSNull null]};
    if (S4ENSScheduledNow(p, now))
        return @{kS4ENSManualUntil: [NSNull null], kS4ENSOffUntil: endOfWindow};
    return @{kS4ENSManualUntil: [NSNull null], kS4ENSOffUntil: [NSNull null]};
}
