// Night Shift (iOS 9.3): warm colors through the display's gamma table, like f.lux for jailbreak.
// App interfaces don't change — only the way the display outputs colors does.
//
// Safety: the table format is checked before writing. If it is unfamiliar, the feature
// turns itself off and notes that in the settings — the display is left alone.

#import "S4EShared.h"
#import "S4ENightShift.h"
#include <dlfcn.h>
#include <mach/mach.h>

typedef void *S4EFramebuffer;
typedef kern_return_t (*S4EGetMainDisplay_t)(S4EFramebuffer *);
typedef kern_return_t (*S4EGammaTable_t)(S4EFramebuffer, void *);

// 16 KB with headroom: even if the driver returns a larger table than expected, the buffer won't overflow.
#define S4E_GAMMA_WORDS 4096

static S4EFramebuffer gFramebuffer;
static S4EGammaTable_t gSetGamma;
static uint32_t gOriginal[S4E_GAMMA_WORDS];
static uint32_t gWorking[S4E_GAMMA_WORDS];
static size_t gTableWords;
static size_t gChannel[3];
static BOOL gReady;

static float gCurrent, gTarget, gFadeStep;

#pragma mark - Gamma table

static BOOL S4EMonotonic(const uint32_t *table, size_t start) {
    if (table[start + 255] <= table[start])
        return NO;
    for (size_t i = start + 1; i < start + 256; i++)
        if (table[i] < table[i - 1])
            return NO;
    return YES;
}

// Before iOS 7 the three channels of 256 values lie back to back; since iOS 7 each one is preceded by a service word.
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
    S4ELog(@"Night Shift: unfamiliar gamma table, feature turned off");
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

    // The original table is kept in a file: after a SpringBoard restart the display may still hold the warm one.
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

// Scale each channel's input, like the gamma tool from UIKitTools: blue and green fade faster than red.
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

#pragma mark - Schedule and smooth fading

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

// A scheduled change takes 30 seconds, a change from a switch is almost instant.
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

// The driver may reset the table after the screen turns off — restore it.
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
    // Set the right state at once: after a SpringBoard restart the display may still hold the old table.
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
        // Don't slow down SpringBoard's launch: touch the display a couple of seconds later.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            S4ENightShiftStart();
        });
    }
}
