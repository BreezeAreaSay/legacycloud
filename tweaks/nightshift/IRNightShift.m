// Night Shift (iOS 9.3): тёплые цвета через гамма-таблицу дисплея, как f.lux для джейлбрейка.
// Интерфейс программ не меняется — меняется только то, как дисплей выводит цвета.
//
// Безопасность: формат таблицы проверяется перед записью. Если он незнакомый, функция
// выключается и пишет об этом в настройки — дисплей не трогаем.

#import "IRShared.h"
#import "IRNightShift.h"
#include <dlfcn.h>
#include <mach/mach.h>

typedef void *IRFramebuffer;
typedef kern_return_t (*IRGetMainDisplay_t)(IRFramebuffer *);
typedef kern_return_t (*IRGammaTable_t)(IRFramebuffer, void *);

// 16 КБ с запасом: даже если драйвер вернёт таблицу больше ожидаемой, буфер не переполнится.
#define IR_GAMMA_WORDS 4096

static IRFramebuffer gFramebuffer;
static IRGammaTable_t gSetGamma;
static uint32_t gOriginal[IR_GAMMA_WORDS];
static uint32_t gWorking[IR_GAMMA_WORDS];
static size_t gTableWords;
static size_t gChannel[3];
static BOOL gReady;

static float gCurrent, gTarget, gFadeStep;

#pragma mark - Гамма-таблица

static BOOL IRMonotonic(const uint32_t *table, size_t start) {
    if (table[start + 255] <= table[start])
        return NO;
    for (size_t i = start + 1; i < start + 256; i++)
        if (table[i] < table[i - 1])
            return NO;
    return YES;
}

// До iOS 7 три канала по 256 значений лежат подряд; с iOS 7 перед каждым есть служебное слово.
static BOOL IRDetectFormat(const uint32_t *table) {
    if (IRMonotonic(table, 0x000) && IRMonotonic(table, 0x100) && IRMonotonic(table, 0x200)) {
        gChannel[0] = 0x000, gChannel[1] = 0x100, gChannel[2] = 0x200;
        gTableWords = 0x300;
        return YES;
    }
    if (IRMonotonic(table, 0x001) && IRMonotonic(table, 0x102) && IRMonotonic(table, 0x203)) {
        gChannel[0] = 0x001, gChannel[1] = 0x102, gChannel[2] = 0x203;
        gTableWords = 0x303;
        return YES;
    }
    return NO;
}

static void IRMarkUnsupported(void) {
    IRLog(@"Night Shift: незнакомая гамма-таблица, функция выключена");
    if (!IRBool(IRPrefsRead(), @"NightShiftUnsupported", NO))
        IRPrefsSet(@"NightShiftUnsupported", @YES);
}

static void IRGammaInit(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer", RTLD_LAZY);
    if (!handle)
        return;
    IRGetMainDisplay_t getMainDisplay = (IRGetMainDisplay_t)dlsym(handle, "IOMobileFramebufferGetMainDisplay");
    IRGammaTable_t getGamma = (IRGammaTable_t)dlsym(handle, "IOMobileFramebufferGetGammaTable");
    gSetGamma = (IRGammaTable_t)dlsym(handle, "IOMobileFramebufferSetGammaTable");
    if (!getMainDisplay || !getGamma || !gSetGamma || getMainDisplay(&gFramebuffer) != KERN_SUCCESS || !gFramebuffer)
        return;

    // Исходную таблицу храним в файле: после перезапуска SpringBoard в дисплее может остаться тёплая.
    NSString *path = IRDataPath(@"gamma-original.bin");
    NSData *saved = [NSData dataWithContentsOfFile:path];
    if (saved.length >= 0x300 * 4 && saved.length <= sizeof(gOriginal)) {
        memcpy(gOriginal, saved.bytes, saved.length);
        if (IRDetectFormat(gOriginal) && saved.length == gTableWords * 4) {
            gReady = YES;
            return;
        }
        memset(gOriginal, 0, sizeof(gOriginal));
    }

    if (getGamma(gFramebuffer, gOriginal) != KERN_SUCCESS || !IRDetectFormat(gOriginal)) {
        IRMarkUnsupported();
        return;
    }
    [[NSData dataWithBytes:gOriginal length:gTableWords * 4] writeToFile:path atomically:YES];
    gReady = YES;
}

// Масштабируем вход каждого канала, как утилита gamma из UIKitTools: синий и зелёный гаснут быстрее красного.
static void IRApplyStrength(float strength) {
    if (!gReady)
        return;
    const float multiplier[3] = {1.0f, 1.0f - 0.35f * strength, 1.0f - 0.67f * strength};
    memcpy(gWorking, gOriginal, gTableWords * 4);
    for (int c = 0; c < 3; c++) {
        size_t offset = gChannel[c];
        unsigned scale = (unsigned)lroundf(multiplier[c] * 256);
        for (unsigned j = 0; j < 256; j++)
            gWorking[offset + j] = gOriginal[offset + ((j * scale) >> 8)];
    }
    gSetGamma(gFramebuffer, gWorking);
}

#pragma mark - Расписание и плавное включение

static float IRTargetStrength(void) {
    NSDictionary *prefs = IRPrefsRead() ?: @{};
    if (!IRNSActive(prefs, [NSDate date]))
        return 0;
    return (float)MAX(0.05, MIN(1.0, IRDouble(prefs, kIRNSWarmth, IR_NS_DEFAULT_WARMTH)));
}

@interface IRNightShiftClock : NSObject
@end

static IRNightShiftClock *gClock;
static NSTimer *gFadeTimer;

@implementation IRNightShiftClock

- (void)fade:(NSTimer *)timer {
    gCurrent += gFadeStep;
    if ((gFadeStep > 0 && gCurrent >= gTarget) || (gFadeStep < 0 && gCurrent <= gTarget) || gFadeStep == 0) {
        gCurrent = gTarget;
        [gFadeTimer invalidate];
        gFadeTimer = nil;
    }
    IRApplyStrength(gCurrent);
}

// Смена по расписанию — за 30 секунд, по переключателю — почти мгновенно.
- (void)updateWithDuration:(NSTimeInterval)duration {
    float target = IRTargetStrength();
    if (fabsf(target - gTarget) < 0.001f && !gFadeTimer)
        return;
    gTarget = target;
    [gFadeTimer invalidate];
    gFadeTimer = nil;
    NSTimeInterval interval = duration > 5 ? 0.5 : 0.04;
    float steps = MAX(1.0f, (float)(duration / interval));
    gFadeStep = (gTarget - gCurrent) / steps;
    gFadeTimer = [NSTimer scheduledTimerWithTimeInterval:interval target:self selector:@selector(fade:) userInfo:nil repeats:YES];
}

- (void)tick:(NSTimer *)timer {
    [self updateWithDuration:30];
}

@end

static void IRPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    [gClock updateWithDuration:0.25];
}

// После выключения экрана драйвер может сбросить таблицу — восстанавливаем.
static void IRScreenChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    IRApplyStrength(gCurrent);
    [gClock updateWithDuration:0.25];
}

static void IRNightShiftStart(void) {
    IRGammaInit();
    if (!gReady)
        return;
    if (IRBool(IRPrefsRead(), @"NightShiftUnsupported", NO))
        IRPrefsSet(@"NightShiftUnsupported", [NSNull null]);
    gClock = [[IRNightShiftClock alloc] init];
    // Сразу ставим нужное состояние: после перезапуска SpringBoard в дисплее могла остаться старая таблица.
    gCurrent = gTarget = IRTargetStrength();
    IRApplyStrength(gCurrent);
    [NSTimer scheduledTimerWithTimeInterval:30 target:gClock selector:@selector(tick:) userInfo:nil repeats:YES];
    IRObserveDarwin(IR_NOTIFY_PREFS, IRPrefsChanged);
    IRObserveDarwin("com.apple.springboard.hasBlankedScreen", IRScreenChanged);
}

__attribute__((constructor)) static void IRNightShiftInit(void) {
    @autoreleasepool {
        if (!IRIsProcess(@"com.apple.springboard"))
            return;
        // Не тормозим загрузку SpringBoard: дисплей трогаем через пару секунд.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            IRNightShiftStart();
        });
    }
}
