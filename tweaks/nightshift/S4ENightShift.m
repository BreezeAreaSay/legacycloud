// Night Shift (iOS 9.3): тёплые цвета через гамма-таблицу дисплея, как f.lux для джейлбрейка.
// Интерфейс программ не меняется — меняется только то, как дисплей выводит цвета.
//
// Безопасность: формат таблицы проверяется перед записью. Если он незнакомый, функция
// выключается и пишет об этом в настройки — дисплей не трогаем.

#import "S4EShared.h"
#import "S4ENightShift.h"
#include <dlfcn.h>
#include <mach/mach.h>

typedef void *S4EFramebuffer;
typedef kern_return_t (*S4EGetMainDisplay_t)(S4EFramebuffer *);
typedef kern_return_t (*S4EGammaTable_t)(S4EFramebuffer, void *);

// 16 КБ с запасом: даже если драйвер вернёт таблицу больше ожидаемой, буфер не переполнится.
#define S4E_GAMMA_WORDS 4096

static S4EFramebuffer gFramebuffer;
static S4EGammaTable_t gSetGamma;
static uint32_t gOriginal[S4E_GAMMA_WORDS];
static uint32_t gWorking[S4E_GAMMA_WORDS];
static size_t gTableWords;
static size_t gChannel[3];
static BOOL gReady;

static float gCurrent, gTarget, gFadeStep;

#pragma mark - Гамма-таблица

static BOOL S4EMonotonic(const uint32_t *table, size_t start) {
    if (table[start + 255] <= table[start])
        return NO;
    for (size_t i = start + 1; i < start + 256; i++)
        if (table[i] < table[i - 1])
            return NO;
    return YES;
}

// До iOS 7 три канала по 256 значений лежат подряд; с iOS 7 перед каждым есть служебное слово.
static BOOL S4EDetectFormat(const uint32_t *table) {
    if (S4EMonotonic(table, 0x000) && S4EMonotonic(table, 0x100) && S4EMonotonic(table, 0x200)) {
        gChannel[0] = 0x000, gChannel[1] = 0x100, gChannel[2] = 0x200;
        gTableWords = 0x300;
        return YES;
    }
    if (S4EMonotonic(table, 0x001) && S4EMonotonic(table, 0x102) && S4EMonotonic(table, 0x203)) {
        gChannel[0] = 0x001, gChannel[1] = 0x102, gChannel[2] = 0x203;
        gTableWords = 0x303;
        return YES;
    }
    return NO;
}

static void S4EMarkUnsupported(void) {
    S4ELog(@"Night Shift: незнакомая гамма-таблица, функция выключена");
    if (!S4EBool(S4EPrefsRead(), @"NightShiftUnsupported", NO))
        S4EPrefsSet(@"NightShiftUnsupported", @YES);
}

static void S4EGammaInit(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer", RTLD_LAZY);
    if (!handle)
        return;
    S4EGetMainDisplay_t getMainDisplay = (S4EGetMainDisplay_t)dlsym(handle, "IOMobileFramebufferGetMainDisplay");
    S4EGammaTable_t getGamma = (S4EGammaTable_t)dlsym(handle, "IOMobileFramebufferGetGammaTable");
    gSetGamma = (S4EGammaTable_t)dlsym(handle, "IOMobileFramebufferSetGammaTable");
    if (!getMainDisplay || !getGamma || !gSetGamma || getMainDisplay(&gFramebuffer) != KERN_SUCCESS || !gFramebuffer)
        return;

    // Исходную таблицу храним в файле: после перезапуска SpringBoard в дисплее может остаться тёплая.
    NSString *path = S4EDataPath(@"gamma-original.bin");
    NSData *saved = [NSData dataWithContentsOfFile:path];
    if (saved.length >= 0x300 * 4 && saved.length <= sizeof(gOriginal)) {
        memcpy(gOriginal, saved.bytes, saved.length);
        if (S4EDetectFormat(gOriginal) && saved.length == gTableWords * 4) {
            gReady = YES;
            return;
        }
        memset(gOriginal, 0, sizeof(gOriginal));
    }

    if (getGamma(gFramebuffer, gOriginal) != KERN_SUCCESS || !S4EDetectFormat(gOriginal)) {
        S4EMarkUnsupported();
        return;
    }
    [[NSData dataWithBytes:gOriginal length:gTableWords * 4] writeToFile:path atomically:YES];
    gReady = YES;
}

// Масштабируем вход каждого канала, как утилита gamma из UIKitTools: синий и зелёный гаснут быстрее красного.
static void S4EApplyStrength(float strength) {
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

static float S4ETargetStrength(void) {
    NSDictionary *prefs = S4EPrefsRead() ?: @{};
    if (!S4ENSActive(prefs, [NSDate date]))
        return 0;
    return (float)MAX(0.05, MIN(1.0, S4EDouble(prefs, kS4ENSWarmth, S4E_NS_DEFAULT_WARMTH)));
}

@interface S4ENightShiftClock : NSObject
@end

static S4ENightShiftClock *gClock;
static NSTimer *gFadeTimer;

@implementation S4ENightShiftClock

- (void)fade:(NSTimer *)timer {
    gCurrent += gFadeStep;
    if ((gFadeStep > 0 && gCurrent >= gTarget) || (gFadeStep < 0 && gCurrent <= gTarget) || gFadeStep == 0) {
        gCurrent = gTarget;
        [gFadeTimer invalidate];
        gFadeTimer = nil;
    }
    S4EApplyStrength(gCurrent);
}

// Смена по расписанию — за 30 секунд, по переключателю — почти мгновенно.
- (void)updateWithDuration:(NSTimeInterval)duration {
    float target = S4ETargetStrength();
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

static void S4EPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    [gClock updateWithDuration:0.25];
}

// После выключения экрана драйвер может сбросить таблицу — восстанавливаем.
static void S4EScreenChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    S4EApplyStrength(gCurrent);
    [gClock updateWithDuration:0.25];
}

static void S4ENightShiftStart(void) {
    S4EGammaInit();
    if (!gReady)
        return;
    if (S4EBool(S4EPrefsRead(), @"NightShiftUnsupported", NO))
        S4EPrefsSet(@"NightShiftUnsupported", [NSNull null]);
    gClock = [[S4ENightShiftClock alloc] init];
    // Сразу ставим нужное состояние: после перезапуска SpringBoard в дисплее могла остаться старая таблица.
    gCurrent = gTarget = S4ETargetStrength();
    S4EApplyStrength(gCurrent);
    [NSTimer scheduledTimerWithTimeInterval:30 target:gClock selector:@selector(tick:) userInfo:nil repeats:YES];
    S4EObserveDarwin(S4E_NOTIFY_PREFS, S4EPrefsChanged);
    S4EObserveDarwin("com.apple.springboard.hasBlankedScreen", S4EScreenChanged);
}

__attribute__((constructor)) static void S4ENightShiftInit(void) {
    @autoreleasepool {
        if (!S4EIsProcess(@"com.apple.springboard"))
            return;
        // Не тормозим загрузку SpringBoard: дисплей трогаем через пару секунд.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            S4ENightShiftStart();
        });
    }
}
