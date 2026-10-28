// Расписание Night Shift: общее для SpringBoard (движок) и Настроек (переключатели).

#pragma once

#import "IRShared.h"

#define kIRNSScheduled @"NightShiftScheduled"
#define kIRNSFrom @"NightShiftFrom"            // минуты от полуночи
#define kIRNSTo @"NightShiftTo"
#define kIRNSManualUntil @"NightShiftManualUntil" // включено вручную до (секунды с 1970)
#define kIRNSOffUntil @"NightShiftOffUntil"       // выключено вручную внутри расписания до
#define kIRNSWarmth @"NightShiftWarmth"           // 0…1

#define IR_NS_DEFAULT_FROM (22 * 60)
#define IR_NS_DEFAULT_TO (7 * 60)
#define IR_NS_DEFAULT_WARMTH 0.5

static inline IR_UNUSED int IRNSMinutes(NSDate *date) {
    NSDateComponents *c = [[NSCalendar currentCalendar] components:NSHourCalendarUnit | NSMinuteCalendarUnit fromDate:date];
    return (int)(c.hour * 60 + c.minute);
}

static inline IR_UNUSED BOOL IRNSInWindow(int now, int from, int to) {
    if (from == to)
        return NO;
    if (from < to)
        return now >= from && now < to;
    return now >= from || now < to; // окно через полночь
}

// Ближайший момент строго после date, когда на часах minutes.
static inline IR_UNUSED NSDate *IRNSNext(NSDate *date, int minutes) {
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

static inline IR_UNUSED int IRNSFrom(NSDictionary *p) { return (int)IRDouble(p, kIRNSFrom, IR_NS_DEFAULT_FROM); }
static inline IR_UNUSED int IRNSTo(NSDictionary *p) { return (int)IRDouble(p, kIRNSTo, IR_NS_DEFAULT_TO); }

static inline IR_UNUSED BOOL IRNSScheduledNow(NSDictionary *p, NSDate *now) {
    return IRBool(p, kIRNSScheduled, NO) && IRNSInWindow(IRNSMinutes(now), IRNSFrom(p), IRNSTo(p));
}

static inline IR_UNUSED BOOL IRNSActive(NSDictionary *p, NSDate *now) {
    NSTimeInterval t = [now timeIntervalSince1970];
    if (IRDouble(p, kIRNSManualUntil, 0) > t)
        return YES;
    return IRNSScheduledNow(p, now) && !(IRDouble(p, kIRNSOffUntil, 0) > t);
}

// Переключатель «Вручную включить до завтра» — как в iOS: включает до утра,
// а выключение внутри расписания гасит его до конца текущего окна.
static inline IR_UNUSED NSDictionary *IRNSManualChanges(NSDictionary *p, BOOL on, NSDate *now) {
    NSNumber *endOfWindow = @([IRNSNext(now, IRNSTo(p)) timeIntervalSince1970]);
    if (on)
        return @{kIRNSManualUntil: endOfWindow, kIRNSOffUntil: [NSNull null]};
    if (IRNSScheduledNow(p, now))
        return @{kIRNSManualUntil: [NSNull null], kIRNSOffUntil: endOfWindow};
    return @{kIRNSManualUntil: [NSNull null], kIRNSOffUntil: [NSNull null]};
}
