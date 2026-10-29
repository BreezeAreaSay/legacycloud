// Режим энергосбережения (iOS 9).
//  * Во всех программах: заливка батарейки в строке состояния становится жёлтой.
//  * В SpringBoard: кнопка «Энергосбережение» в предупреждении о низком заряде, снижение яркости,
//    автоблокировка через минуту и автоматическое выключение при зарядке до 80 %.

#import "S4EShared.h"
#import "S4EPrivate.h"
#include <dlfcn.h>

#define kS4ESavedAutoLock @"LowPowerSavedAutoLock"
#define kS4ESavedBrightness @"LowPowerSavedBrightness"
#define kS4EDimmedBrightness @"LowPowerDimmedBrightness"

static BOOL gLowPower;

#pragma mark - Жёлтая батарейка

// Перекрашивает только заливку уровня, контур и тень остаются родными.
// Корпус батарейки находим по самой длинной горизонтальной линии основного цвета —
// это верхний или нижний край контура (молния и «носик» короче).
static UIImage *S4ETintBattery(UIImage *image) {
    CGImageRef source = image.CGImage;
    if (!source)
        return nil;
    size_t width = CGImageGetWidth(source), height = CGImageGetHeight(source);
    if (width < 8 || height < 4 || width > 512 || height > 256)
        return nil;

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    uint8_t *pixels = calloc(width * height * 4, 1);
    CGContextRef ctx = CGBitmapContextCreate(pixels, width, height, 8, width * 4, space,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    UIImage *result = nil;
    if (!ctx)
        goto done;
    CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), source);

    // 1. Основной цвет значка — самый частый среди непрозрачных пикселей (строка 0 в памяти — верх картинки).
    {
        static uint32_t histogram[4096];
        memset(histogram, 0, sizeof(histogram));
        uint32_t best = 0, bestCount = 0;
        for (size_t i = 0; i < width * height; i++) {
            uint8_t *p = pixels + i * 4;
            if (p[3] < 200)
                continue;
            uint32_t bin = ((uint32_t)(p[0] >> 4) << 8) | ((uint32_t)(p[1] >> 4) << 4) | (p[2] >> 4);
            if (++histogram[bin] > bestCount) {
                bestCount = histogram[bin];
                best = bin;
            }
        }
        if (!bestCount)
            goto done;
        int r = (int)((best >> 8) & 0xF) * 17, g = (int)((best >> 4) & 0xF) * 17, b = (int)(best & 0xF) * 17;

        #define S4E_IS_GLYPH(x, y) ({ uint8_t *q = pixels + ((y) * width + (x)) * 4; \
            q[3] >= 128 && abs(q[0] - r) <= 48 && abs(q[1] - g) <= 48 && abs(q[2] - b) <= 48; })

        // 2. Самая длинная горизонтальная линия — край корпуса.
        size_t lineStart = 0, lineLength = 0;
        for (size_t y = 0; y < height; y++) {
            size_t run = 0;
            for (size_t x = 0; x < width; x++) {
                run = S4E_IS_GLYPH(x, y) ? run + 1 : 0;
                if (run > lineLength) {
                    lineLength = run;
                    lineStart = x + 1 - run;
                }
            }
        }
        if (lineLength < 6)
            goto done;

        // 3. Верх и низ корпуса — строки, где основной цвет закрывает почти всю ширину.
        size_t top = height, bottom = 0;
        for (size_t y = 0; y < height; y++) {
            size_t count = 0;
            for (size_t x = lineStart; x < lineStart + lineLength; x++)
                count += S4E_IS_GLYPH(x, y);
            if (count * 5 >= lineLength * 4) {
                top = MIN(top, y);
                bottom = MAX(bottom, y);
            }
        }
        #undef S4E_IS_GLYPH

        size_t inset = (size_t)MAX(1, lroundf(image.scale));
        if (top >= bottom || bottom - top + 1 < 3 * inset || lineLength * 2 < (bottom - top + 1) * 3)
            goto done;

        // 4. Внутри контура закрашиваем то, что уже нарисовано (заливку уровня), жёлтым глянцем.
        CGRect inside = CGRectMake(lineStart + inset, height - bottom - 1 + inset,
                                   lineLength - 2 * inset, bottom - top + 1 - 2 * inset);
        CGContextSaveGState(ctx);
        CGContextClipToRect(ctx, inside);
        CGContextSetBlendMode(ctx, kCGBlendModeSourceAtop);
        CGFloat yellow[] = {1.0, 0.90, 0.36, 1, 0.96, 0.71, 0.0, 1};
        CGGradientRef gradient = CGGradientCreateWithColorComponents(space, yellow, NULL, 2);
        CGContextDrawLinearGradient(ctx, gradient, CGPointMake(0, CGRectGetMaxY(inside)), CGPointMake(0, CGRectGetMinY(inside)), 0);
        CGGradientRelease(gradient);
        CGContextRestoreGState(ctx);

        CGImageRef tinted = CGBitmapContextCreateImage(ctx);
        result = [UIImage imageWithCGImage:tinted scale:image.scale orientation:image.imageOrientation];
        CGImageRelease(tinted);
    }

done:
    if (ctx)
        CGContextRelease(ctx);
    free(pixels);
    CGColorSpaceRelease(space);
    return result;
}

static const void *kS4ERenderedLowPowerKey = &kS4ERenderedLowPowerKey;

static id (*orig_contentsImageForStyle)(UIStatusBarItemView *, SEL, int);
static id hook_contentsImageForStyle(UIStatusBarItemView *self, SEL _cmd, int style) {
    id image = orig_contentsImageForStyle(self, _cmd, style);
    objc_setAssociatedObject(self, kS4ERenderedLowPowerKey, @(gLowPower), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!gLowPower || ![image isKindOfClass:[UIImage class]])
        return image;
    return S4ETintBattery(image) ?: image;
}

// Значок нарисован в другом режиме — говорим UIKit, что его надо перерисовать.
// Тогда картинку, ширину и раскладку строки состояния пересчитывает сам UIKit.
static BOOL (*orig_updateForNewData)(UIStatusBarItemView *, SEL, id, int);
static BOOL hook_updateForNewData(UIStatusBarItemView *self, SEL _cmd, id data, int actions) {
    BOOL changed = orig_updateForNewData(self, _cmd, data, actions);
    NSNumber *rendered = objc_getAssociatedObject(self, kS4ERenderedLowPowerKey);
    return changed || (rendered && rendered.boolValue != gLowPower);
}

static void S4ERefreshBatteryViews(void) {
    UIApplication *app = [UIApplication sharedApplication];
    UIStatusBar *statusBar = [app respondsToSelector:@selector(statusBar)] ? (UIStatusBar *)[app statusBar] : nil;
    if ([statusBar respondsToSelector:@selector(forceUpdateData:)])
        [statusBar forceUpdateData:NO];
}

static void S4EStateChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    BOOL lowPower = S4EFlag(kS4ELowPower, S4EStateLowPower, NO);
    if (lowPower == gLowPower)
        return;
    gLowPower = lowPower;
    S4ERefreshBatteryViews();
}

#pragma mark - SpringBoard: яркость и автоблокировка

static BOOL gEffectsApplied;

static MCProfileConnection *S4EProfileConnection(void) {
    Class cls = objc_getClass("MCProfileConnection");
    if (!cls) {
        dlopen("/System/Library/PrivateFrameworks/ManagedConfiguration.framework/ManagedConfiguration", RTLD_LAZY);
        cls = objc_getClass("MCProfileConnection");
    }
    return [cls respondsToSelector:@selector(sharedConnection)] ? [cls sharedConnection] : nil;
}

static NSString *S4EAutoLockSetting(void) {
    NSString *__unsafe_unretained *constant = (NSString *__unsafe_unretained *)dlsym(RTLD_DEFAULT, "MCFeatureAutoLockTime");
    return (constant && *constant) ? *constant : @"maxInactivity";
}

static float S4EBrightness(void) {
    return [UIScreen mainScreen].brightness;
}

static void S4ESetBrightness(float level) {
    SBBrightnessController *controller = [objc_getClass("SBBrightnessController") sharedBrightnessController];
    if ([controller respondsToSelector:@selector(_setBrightnessLevel:showHUD:)])
        [controller _setBrightnessLevel:level showHUD:NO];
    else
        [UIScreen mainScreen].brightness = level;
}

static void S4EApplyEffects(BOOL on) {
    MCProfileConnection *mc = S4EProfileConnection();
    NSString *setting = S4EAutoLockSetting();
    BOOL canUseMC = [mc respondsToSelector:@selector(effectiveValueForSetting:)] && [mc respondsToSelector:@selector(setValue:forSetting:)];
    NSMutableDictionary *changes = [NSMutableDictionary dictionary];

    if (on) {
        // Автоблокировка: минимум, который есть в iOS 6, — одна минута.
        NSNumber *autoLock = canUseMC ? [mc effectiveValueForSetting:setting] : nil;
        if ([autoLock isKindOfClass:[NSNumber class]] && (autoLock.intValue > 60 || autoLock.intValue <= 0)) {
            changes[kS4ESavedAutoLock] = autoLock;
            [mc setValue:@60 forSetting:setting];
        }
        float brightness = S4EBrightness();
        if (brightness > 0.06f) {
            float dimmed = MAX(0.05f, brightness * 0.8f);
            changes[kS4ESavedBrightness] = @(brightness);
            changes[kS4EDimmedBrightness] = @(dimmed);
            S4ESetBrightness(dimmed);
        }
    } else {
        NSDictionary *prefs = S4EPrefsRead() ?: @{};
        NSNumber *savedAutoLock = prefs[kS4ESavedAutoLock];
        if (canUseMC && savedAutoLock && [[mc effectiveValueForSetting:setting] intValue] == 60)
            [mc setValue:savedAutoLock forSetting:setting];
        // Яркость возвращаем, только если пользователь сам её не менял.
        NSNumber *saved = prefs[kS4ESavedBrightness], *dimmed = prefs[kS4EDimmedBrightness];
        if (saved && dimmed && fabsf(S4EBrightness() - dimmed.floatValue) < 0.03f)
            S4ESetBrightness(saved.floatValue);
        changes[kS4ESavedAutoLock] = changes[kS4ESavedBrightness] = changes[kS4EDimmedBrightness] = [NSNull null];
    }
    if (changes.count)
        S4EPrefsSetValues(changes);
}

static void S4ESpringBoardPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    BOOL on = S4EBool(S4EPrefsRead(), kS4ELowPower, NO);
    if (on == gEffectsApplied)
        return;
    gEffectsApplied = on;
    S4EApplyEffects(on);
}

#pragma mark - SpringBoard: предупреждение о низком заряде

static const void *kS4EButtonIndexKey = &kS4EButtonIndexKey;

static void (*orig_configure)(SBLowPowerAlertItem *, SEL, BOOL, BOOL);
static void hook_configure(SBLowPowerAlertItem *self, SEL _cmd, BOOL configure, BOOL requirePasscode) {
    orig_configure(self, _cmd, configure, requirePasscode);
    if (S4EBool(S4EPrefsRead(), kS4ELowPower, NO) || ![self respondsToSelector:@selector(alertSheet)])
        return;
    UIAlertView *sheet = [self alertSheet];
    if (![sheet isKindOfClass:[UIAlertView class]])
        return;
    // Алерт настраивается заново после разблокировки — не добавляем кнопку второй раз.
    NSString *title = @"Энергосбережение";
    NSInteger index = -1;
    for (NSInteger i = 0; i < sheet.numberOfButtons; i++)
        if ([[sheet buttonTitleAtIndex:i] isEqualToString:title])
            index = i;
    if (index < 0)
        index = [sheet addButtonWithTitle:title];
    objc_setAssociatedObject(self, kS4EButtonIndexKey, @(index), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void (*orig_clicked)(SBLowPowerAlertItem *, SEL, UIAlertView *, NSInteger);
static void hook_clicked(SBLowPowerAlertItem *self, SEL _cmd, UIAlertView *alert, NSInteger index) {
    NSNumber *ours = objc_getAssociatedObject(self, kS4EButtonIndexKey);
    if (!ours || ours.integerValue != index) {
        orig_clicked(self, _cmd, alert, index);
        return;
    }
    S4EPrefsSet(kS4ELowPower, @YES);
    if ([self respondsToSelector:@selector(dismiss)])
        [self dismiss];
}

#pragma mark - SpringBoard: выключение при 80 %

// Как в iOS 9: выключаемся, когда заряд на зарядке переходит через 80 %, а не сразу после включения.
static int gLastPercent = -1;

static void (*orig_updateBatteryState)(SBUIController *, SEL, id);
static void hook_updateBatteryState(SBUIController *self, SEL _cmd, id state) {
    orig_updateBatteryState(self, _cmd, state);
    if (![self respondsToSelector:@selector(isOnAC)] || ![self respondsToSelector:@selector(batteryCapacityAsPercentage)])
        return;
    int percent = [self batteryCapacityAsPercentage];
    BOOL crossed = gLastPercent >= 0 && gLastPercent < 80 && percent >= 80;
    gLastPercent = percent;
    if (gEffectsApplied && crossed && [self isOnAC])
        S4EPrefsSet(kS4ELowPower, @NO);
}

#pragma mark -

__attribute__((constructor)) static void S4EBatteryInit(void) {
    @autoreleasepool {
        gLowPower = S4EFlag(kS4ELowPower, S4EStateLowPower, NO);
        S4EObserveDarwin(S4E_NOTIFY_STATE, S4EStateChanged);
        Class batteryView = objc_getClass("UIStatusBarBatteryItemView");
        S4E_HOOK(batteryView, @selector(contentsImageForStyle:), hook_contentsImageForStyle, &orig_contentsImageForStyle);
        S4E_HOOK(batteryView, @selector(updateForNewData:actions:), hook_updateForNewData, &orig_updateForNewData);

        if (!S4EIsProcess(@"com.apple.springboard"))
            return;
        gEffectsApplied = S4EBool(S4EPrefsRead(), kS4ELowPower, NO); // эффекты уже применены до перезапуска
        S4EObserveDarwin(S4E_NOTIFY_PREFS, S4ESpringBoardPrefsChanged);
        Class alert = objc_getClass("SBLowPowerAlertItem");
        S4E_HOOK(alert, @selector(configure:requirePasscodeForActions:), hook_configure, &orig_configure);
        S4E_HOOK(alert, @selector(alertView:clickedButtonAtIndex:), hook_clicked, &orig_clicked);
        S4E_HOOK(objc_getClass("SBUIController"), @selector(updateBatteryState:), hook_updateBatteryState, &orig_updateBatteryState);
    }
}
