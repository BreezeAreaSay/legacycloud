// Dark Mode in SpringBoard: the engine that decides the appearance, dark launch images, and dark icons
// as in iOS 18.
//
// The engine reads the settings and the schedule and publishes the appearance in the state of
// S4E_NOTIFY_APPEARANCE for the apps.
//
// Launch images: an app starts with its Default.png or its last snapshot, both usually light, and only
// then shows its dark interface. For Apple apps whose interface turns dark, the light picture is shown
// with its lightness turned over (hue kept), so there is no white flash.
//
// Icons: the background of an icon turns into black glass with the iOS 6 gloss on it, a white symbol on a
// colored background takes that color (green Messages bubble on black), dark ink on a light background
// turns light. An icon that is a whole picture is only dimmed; an icon that is dark already stays.

#import "S4EShared.h"
#import "S4EDarkMode.h"

@interface SBApplication : NSObject
- (NSString *)bundleIdentifier;
@end

@interface SBIcon : NSObject
- (void)reloadIconImagePurgingImageCache:(BOOL)purge;
@end

@interface SBIconModel : NSObject
- (id)leafIcons;
@end

@interface SBIconController : NSObject
+ (instancetype)sharedInstance;
- (SBIconModel *)model;
@end

static BOOL gDarkNow;   // the appearance published now
static BOOL gIconsDark; // how icons are drawn now

#pragma mark - Pixels

static inline int S4EClampByte(int value) {
    return value < 0 ? 0 : value > 255 ? 255 : value;
}

static inline int S4ELumaByte(int r, int g, int b) {
    return (77 * r + 150 * g + 29 * b) >> 8;
}

static inline float S4ESaturation(float r, float g, float b) {
    float max = MAX(r, MAX(g, b)), min = MIN(r, MIN(g, b));
    return max > 0 ? (max - min) / max : 0;
}

// An RGBA bitmap of an image, premultiplied; the caller frees the pixels and releases the context
static CGContextRef S4EBitmap(CGImageRef image, int *width, int *height, uint8_t **pixels) {
    int w = (int)CGImageGetWidth(image), h = (int)CGImageGetHeight(image);
    uint8_t *data = calloc((size_t)w * h, 4);
    if (!data)
        return NULL;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(data, w, h, 8, w * 4, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) {
        free(data);
        return NULL;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, w, h), image);
    *width = w;
    *height = h;
    *pixels = data;
    return context;
}

static UIImage *S4EImageFromBitmap(CGContextRef context, UIImage *model) {
    CGImageRef image = CGBitmapContextCreateImage(context);
    UIImage *result = image ? [UIImage imageWithCGImage:image scale:model.scale orientation:model.imageOrientation] : nil;
    CGImageRelease(image);
    return result;
}

#pragma mark - Launch images

// Apple apps that keep a light interface (web pages, maps, paper): their launch image stays as it is
static BOOL S4EKeepsLightInterface(NSString *identifier) {
    static NSSet *apps;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        apps = [NSSet setWithObjects:@"com.apple.mobilesafari", @"com.apple.Maps", @"com.apple.mobilenotes", @"com.apple.mobilecal",
                                     @"com.apple.reminders", @"com.apple.iBooks", @"com.apple.AppStore", @"com.apple.MobileStore",
                                     @"com.apple.gamecenter", @"com.apple.podcasts", @"com.apple.itunesu", @"com.apple.Passbook",
                                     @"com.apple.mobileme.fmip1", @"com.apple.mobileme.fmf1", nil];
    });
    return [apps containsObject:identifier];
}

static BOOL S4ELaunchesDark(SBApplication *app) {
    if (!gDarkNow || ![app respondsToSelector:@selector(bundleIdentifier)])
        return NO;
    NSString *identifier = [app bundleIdentifier];
    return [identifier hasPrefix:@"com.apple."] && !S4EKeepsLightInterface(identifier);
}

// Lightness turned over with the hue kept: white paper becomes near black, a blue bar a dark blue one.
// A picture that is mostly dark already (a snapshot taken in Dark Mode) is left alone.
static UIImage *S4EDarkLaunchImage(UIImage *image) {
    if (![image isKindOfClass:[UIImage class]] || !image.CGImage)
        return nil;
    int w, h;
    uint8_t *px;
    CGContextRef context = S4EBitmap(image.CGImage, &w, &h, &px);
    if (!context)
        return nil;
    uint64_t sum = 0, count = 0;
    for (size_t i = 0; i < (size_t)w * h; i += 7, count++)
        sum += S4ELumaByte(px[i * 4], px[i * 4 + 1], px[i * 4 + 2]);
    UIImage *result = nil;
    if (count && sum > count * 128) {
        // Dark ink turns light; everything lighter, bars included, goes nearly black like the dark interface
        int delta[256];
        for (int y = 0; y < 256; y++)
            delta[y] = (y < 90 ? 240 - 214 * y / 255 : 15 + 77 * (255 - y) / 255) - y;
        for (size_t i = 0; i < (size_t)w * h; i++) {
            uint8_t *p = px + i * 4;
            int a = p[3];
            if (!a)
                continue;
            int r = p[0] * 255 / a, g = p[1] * 255 / a, b = p[2] * 255 / a;
            int d = delta[S4EClampByte(S4ELumaByte(r, g, b))];
            p[0] = (uint8_t)(S4EClampByte(r + d) * a / 255);
            p[1] = (uint8_t)(S4EClampByte(g + d) * a / 255);
            p[2] = (uint8_t)(S4EClampByte(b + d) * a / 255);
        }
        result = S4EImageFromBitmap(context, image);
    }
    CGContextRelease(context);
    free(px);
    return result;
}

static id (*orig_defaultImageSurface)(SBApplication *, SEL, char *, float, int *, int *, BOOL);
static id hook_defaultImageSurface(SBApplication *self, SEL _cmd, char *flag, float scale, int *originalOrientation,
                                   int *currentOrientation, BOOL canUseSurface) {
    BOOL dark = S4ELaunchesDark(self);
    // An IOSurface can't be read back as pixels: ask for a plain image when we change it
    id image = orig_defaultImageSurface(self, _cmd, flag, scale, originalOrientation, currentOrientation, dark ? NO : canUseSurface);
    return dark ? (S4EDarkLaunchImage(image) ?: image) : image;
}

static id (*orig_defaultImage)(SBApplication *, SEL, char *, float, int *, int *);
static id hook_defaultImage(SBApplication *self, SEL _cmd, char *flag, float scale, int *originalOrientation, int *currentOrientation) {
    id image = orig_defaultImage(self, _cmd, flag, scale, originalOrientation, currentOrientation);
    return S4ELaunchesDark(self) ? (S4EDarkLaunchImage(image) ?: image) : image;
}

#pragma mark - Icons (iOS 18)

static UIImage *S4EDarkIcon(UIImage *icon) {
    if (![icon isKindOfClass:[UIImage class]] || !icon.CGImage)
        return nil;
    int w, h;
    uint8_t *px;
    CGContextRef context = S4EBitmap(icon.CGImage, &w, &h, &px);
    if (!context)
        return nil;
    UIImage *result = nil;
    float *bg = calloc((size_t)h * 3, sizeof(float)), *low = calloc((size_t)h * 3, sizeof(float)), *high = calloc((size_t)h * 3, sizeof(float));
    int *sampled = calloc((size_t)h, sizeof(int));
    if (!bg || !low || !high || !sampled || w < 20 || h < 20 || w > 512 || h > 512)
        goto done;

    // The opaque body of the icon
    int x0 = w, x1 = -1, y0 = h, y1 = -1;
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++)
            if (px[(y * w + x) * 4 + 3] >= 250) {
                x0 = MIN(x0, x);
                x1 = MAX(x1, x);
                y0 = MIN(y0, y);
                y1 = MAX(y1, y);
            }
    if (x1 - x0 < 16 || y1 - y0 < 16)
        goto done;
    int bw = x1 - x0 + 1, bh = y1 - y0 + 1, band = MAX(2, bw / 10);

    // The background, row by row, from strips along the left and right edges (rounded corners included):
    // the gradient and the gloss run from top to bottom
    double spread = 0, deviation = 0;
    int rows = 0, deviationCount = 0;
    for (int y = y0; y <= y1; y++) {
        int left = -1, right = -1;
        for (int x = x0; x <= x1 && left < 0; x++)
            if (px[(y * w + x) * 4 + 3] >= 250)
                left = x;
        for (int x = x1; x >= x0 && right < 0; x--)
            if (px[(y * w + x) * 4 + 3] >= 250)
                right = x;
        if (left < 0 || right - left < 2 * band + 6)
            continue;
        float side[2][3] = {{0}};
        int count[2] = {0};
        for (int s = 0; s < 2; s++) {
            int from = s == 0 ? left + 2 : right - 1 - band;
            for (int x = from; x < from + band; x++) {
                uint8_t *p = px + (y * w + x) * 4;
                if (p[3] < 250)
                    continue;
                for (int c = 0; c < 3; c++)
                    side[s][c] += p[c];
                count[s]++;
            }
        }
        if (!count[0] || !count[1])
            continue;
        for (int c = 0; c < 3; c++) {
            float l = side[0][c] / count[0], r = side[1][c] / count[1];
            bg[y * 3 + c] = (l + r) / 2;
            spread += fabsf(l - r);
        }
        sampled[y] = 1;
        rows++;
        for (int s = 0; s < 2; s++) {
            int from = s == 0 ? left + 2 : right - 1 - band;
            for (int x = from; x < from + band; x += 2) {
                uint8_t *p = px + (y * w + x) * 4;
                if (p[3] < 250)
                    continue;
                int worst = 0;
                for (int c = 0; c < 3; c++)
                    worst = MAX(worst, abs((int)p[c] - (int)bg[y * 3 + c]));
                deviation += worst;
                deviationCount++;
            }
        }
    }
    if (rows < bh / 2 || !deviationCount)
        goto done;
    // Rows without a sample (the very top and bottom) take the nearest one
    int first = y0;
    while (!sampled[first])
        first++;
    for (int y = y0, last = first; y <= y1; y++) {
        if (sampled[y])
            last = y;
        else
            memcpy(bg + y * 3, bg + last * 3, 3 * sizeof(float));
    }
    float average[3] = {0};
    for (int y = y0; y <= y1; y++)
        for (int c = 0; c < 3; c++)
            average[c] += bg[y * 3 + c] / bh;
    float bgLuma = S4ELumaByte((int)average[0], (int)average[1], (int)average[2]) / 255.0f;
    float bgSaturation = S4ESaturation(average[0], average[1], average[2]);
    if (bgLuma < 0.22f)
        goto done; // dark already: Clock, Stocks, Camera

    BOOL uniform = spread / (rows * 3) < 22 && deviation / deviationCount < 26;
    // What counts as background in a row: the range of the background over the rows a little above, since
    // the gloss ends in an arc — lower in the middle than at the edges
    int reach = MAX(2, bh * 3 / 10);
    for (int y = y0; y <= y1; y++)
        for (int c = 0; c < 3; c++) {
            low[y * 3 + c] = 255;
            high[y * 3 + c] = 0;
            for (int above = MAX(y0, y - reach); above <= MIN(y1, y + 2); above++) {
                low[y * 3 + c] = MIN(low[y * 3 + c], bg[above * 3 + c]);
                high[y * 3 + c] = MAX(high[y * 3 + c], bg[above * 3 + c]);
            }
        }
    // The symbol's new color and the tint of the glass come from the average background: a row's own
    // color would carry the old gloss boundary into them
    float averageLuma = MAX(1, S4ELumaByte((int)average[0], (int)average[1], (int)average[2]));
    for (int y = 0; y < h; y++) {
        int row = MIN(MAX(y, y0), y1);
        float v = (float)(row - y0) / bh;
        float base = 50 - 38 * v; // black glass: 0.20 at the top, 0.05 at the bottom
        for (int x = 0; x < w; x++) {
            uint8_t *p = px + (y * w + x) * 4;
            int a = p[3];
            if (!a)
                continue;
            float r = p[0] * 255.0f / a, g = p[1] * 255.0f / a, b = p[2] * 255.0f / a;
            if (!uniform) {
                // A whole picture: only dimmed, as iOS 18 does with icons it can't take apart
                r *= 0.7f;
                g *= 0.7f;
                b *= 0.7f;
            } else {
                float d = 0, value[3] = {r, g, b};
                for (int c = 0; c < 3; c++)
                    d = MAX(d, MAX(low[row * 3 + c] - value[c], value[c] - high[row * 3 + c]));
                float t = MIN(1, MAX(0, (d - 18) / 50));
                t = t * t * (3 - 2 * t); // 0: background, 1: symbol
                float nr = base + 0.10f * (average[0] - base), ng = base + 0.10f * (average[1] - base), nb = base + 0.10f * (average[2] - base);
                float pl = S4ELumaByte((int)r, (int)g, (int)b) / 255.0f;
                float sr = r, sg = g, sb = b;
                if (bgSaturation > 0.25f && S4ESaturation(r, g, b) < 0.25f && pl > 0.55f) {
                    // A white symbol on color takes the color, bright enough to stand out on black
                    float k = MIN(3, MAX(1, 150 / averageLuma)) * pl;
                    sr = MIN(255, average[0] * k);
                    sg = MIN(255, average[1] * k);
                    sb = MIN(255, average[2] * k);
                } else if (bgLuma > 0.6f && pl < 0.45f) {
                    // Dark ink on light paper turns light
                    float dl = (0.94f - 0.55f * pl - pl) * 255;
                    sr = MIN(255, MAX(0, r + dl));
                    sg = MIN(255, MAX(0, g + dl));
                    sb = MIN(255, MAX(0, b + dl));
                }
                r = nr + (sr - nr) * t;
                g = ng + (sg - ng) * t;
                b = nb + (sb - nb) * t;
            }
            p[0] = (uint8_t)(S4EClampByte((int)r) * a / 255);
            p[1] = (uint8_t)(S4EClampByte((int)g) * a / 255);
            p[2] = (uint8_t)(S4EClampByte((int)b) * a / 255);
        }
    }
    if (uniform) {
        // The iOS 6 gloss over the top half: on black it reads as glass
        float cx = x0 + bw / 2.0f, cy = y0 - 0.25f * bh, rx = 0.9f * bw, ry = 0.78f * bh, edge = cy + ry;
        for (int y = y0; y < (int)edge && y < h; y++) {
            float strength = 0.20f - 0.14f * (y - y0) / (edge - y0);
            for (int x = x0; x <= x1; x++) {
                float dx = (x - cx) / rx, dy = (y - cy) / ry;
                if (dx * dx + dy * dy > 1)
                    continue;
                uint8_t *p = px + (y * w + x) * 4;
                for (int c = 0; c < 3; c++)
                    p[c] = (uint8_t)(p[c] + (p[3] - p[c]) * strength);
            }
        }
    }
    result = S4EImageFromBitmap(context, icon);

done:
    free(bg);
    free(low);
    free(high);
    free(sampled);
    CGContextRelease(context);
    free(px);
    return result;
}

static id (*orig_generateIconImage)(id, SEL, int);
static id hook_generateIconImage(id self, SEL _cmd, int format) {
    id image = orig_generateIconImage(self, _cmd, format);
    return gIconsDark ? (S4EDarkIcon(image) ?: image) : image;
}

// Icons made in the background would skip the hook above
static BOOL (*orig_canGenerateInBackground)(id, SEL, int);
static BOOL hook_canGenerateInBackground(id self, SEL _cmd, int format) {
    return gIconsDark ? NO : orig_canGenerateInBackground(self, _cmd, format);
}

// SpringBoard keeps icons it has made, on disk too: a note of how they were made tells after a restart
// whether they must be made again
static NSString *S4EIconsNotePath(void) {
    return S4EDataPath(@"icons-dark");
}

static void S4EReloadIcons(void) {
    SBIconController *controller = [objc_getClass("SBIconController") sharedInstance];
    SBIconModel *model = [controller respondsToSelector:@selector(model)] ? [controller model] : nil;
    id icons = [model respondsToSelector:@selector(leafIcons)] ? [model leafIcons] : nil;
    for (SBIcon *icon in icons)
        if ([icon respondsToSelector:@selector(reloadIconImagePurgingImageCache:)])
            [icon reloadIconImagePurgingImageCache:YES]; // folders follow their apps
    if (gIconsDark)
        [[NSData data] writeToFile:S4EIconsNotePath() atomically:YES];
    else
        [[NSFileManager defaultManager] removeItemAtPath:S4EIconsNotePath() error:NULL];
}

static BOOL S4EIconsShouldBeDark(NSDictionary *prefs, BOOL dark) {
    NSString *mode = prefs[kS4EDMIcons];
    if ([mode isEqual:@"dark"])
        return YES;
    if ([mode isEqual:@"light"])
        return NO;
    return dark;
}

#pragma mark - The engine

@interface S4EAppearanceClock : NSObject
@end

static S4EAppearanceClock *gClock;
static NSTimer *gClockTimer;
static BOOL gLaunched;

static void S4EPublishAppearance(void) {
    NSDictionary *prefs = S4EPrefsRead() ?: @{};
    gDarkNow = S4EDMIsDark(prefs, [NSDate date]);
    uint64_t state = S4EAppearancePublished | (gDarkNow ? S4EAppearanceDark : 0) |
                     (S4EBool(prefs, kS4EDMOtherApps, NO) ? S4EAppearanceOtherApps : 0);
    static int token;
    static BOOL ready;
    if (!ready)
        ready = notify_register_check(S4E_NOTIFY_APPEARANCE, &token) == NOTIFY_STATUS_OK;
    if (ready) {
        uint64_t old = 0;
        notify_get_state(token, &old);
        if (old != state) {
            notify_set_state(token, state);
            notify_post(S4E_NOTIFY_APPEARANCE);
        }
    }
    BOOL icons = S4EIconsShouldBeDark(prefs, gDarkNow);
    if (icons != gIconsDark) {
        gIconsDark = icons;
        if (gLaunched)
            S4EReloadIcons();
    }
    // The schedule is checked twice a minute only while Automatic is on
    BOOL automatic = S4EBool(prefs, kS4EDMAutomatic, NO);
    if (automatic && !gClockTimer)
        gClockTimer = [NSTimer scheduledTimerWithTimeInterval:30 target:gClock selector:@selector(tick:) userInfo:nil repeats:YES];
    else if (!automatic && gClockTimer) {
        [gClockTimer invalidate];
        gClockTimer = nil;
    }
}

@implementation S4EAppearanceClock
- (void)tick:(NSTimer *)timer {
    S4EPublishAppearance();
}
@end

static void S4EEngineWake(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    S4EPublishAppearance();
}

static void (*orig_finishedLaunching)(id, SEL, id);
static void hook_finishedLaunching(id self, SEL _cmd, id application) {
    orig_finishedLaunching(self, _cmd, application);
    gLaunched = YES;
    // Icons kept from before the restart may have been made the other way
    BOOL noted = [[NSFileManager defaultManager] fileExistsAtPath:S4EIconsNotePath()];
    if (noted != gIconsDark)
        S4EReloadIcons();
}

__attribute__((constructor)) static void S4EDarkSpringBoardInit(void) {
    @autoreleasepool {
        if (!S4EIsProcess(@"com.apple.springboard"))
            return;
        gClock = [[S4EAppearanceClock alloc] init];
        S4EPublishAppearance();
        S4EObserveDarwin(S4E_NOTIFY_PREFS, S4EEngineWake);
        // A timer stands still while the phone sleeps: check again when the screen turns on
        S4EObserveDarwin("com.apple.springboard.hasBlankedScreen", S4EEngineWake);
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationSignificantTimeChangeNotification object:nil queue:nil
                                                      usingBlock:^(NSNotification *note) {
                                                          S4EPublishAppearance();
                                                      }];
        S4E_HOOK(objc_getClass("SpringBoard"), @selector(applicationDidFinishLaunching:), hook_finishedLaunching, &orig_finishedLaunching);

        Class application = objc_getClass("SBApplication");
        S4E_HOOK(application, @selector(defaultImage:preferredScale:originalOrientation:currentOrientation:canUseIOSurface:),
                 hook_defaultImageSurface, &orig_defaultImageSurface);
        S4E_HOOK(application, @selector(defaultImage:preferredScale:originalOrientation:currentOrientation:),
                 hook_defaultImage, &orig_defaultImage);

        Class icon = objc_getClass("SBApplicationIcon");
        S4E_HOOK(icon, @selector(generateIconImage:), hook_generateIconImage, &orig_generateIconImage);
        S4E_HOOK(icon, @selector(canGenerateImageInBackgroundForFormat:), hook_canGenerateInBackground, &orig_canGenerateInBackground);
    }
}
