// Метка новой программы (iOS 7): синяя точка перед подписью иконки до первого запуска.
// Точка нарисована как глянцевый индикатор непрочитанного письма в Почте iOS 6.

#import "IRShared.h"
#import "IRPrivate.h"

#define IR_NEW_APPS_FILE @"new-apps.plist"
#define IR_NOTE_LAUNCHED @"IRNewAppDotLaunched"
#define IR_NOTE_REFRESH @"IRNewAppDotRefresh"

static const NSInteger kIRDotTag = 0x1D07;
static const CGFloat kIRDotSize = 8;

static NSMutableSet *gKnown;
static NSMutableSet *gNew;
static BOOL gEnabled = YES;

static void IRSaveState(void) {
    NSDictionary *state = @{@"Known": gKnown.allObjects, @"New": gNew.allObjects};
    [state writeToFile:IRDataPath(IR_NEW_APPS_FILE) atomically:YES];
}

static void IRLoadState(void) {
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:IRDataPath(IR_NEW_APPS_FILE)];
    gKnown = state ? [NSMutableSet setWithArray:state[@"Known"] ?: @[]] : nil;
    gNew = [NSMutableSet setWithArray:state[@"New"] ?: @[]];
}

static NSString *IRBundleIDForIcon(SBIcon *icon) {
    Class appIcon = objc_getClass("SBApplicationIcon");
    if (!appIcon || ![icon isKindOfClass:appIcon] || ![icon respondsToSelector:@selector(applicationBundleID)])
        return nil;
    return [(SBApplicationIcon *)icon applicationBundleID];
}

// Программа появилась, пока SpringBoard работает (установка из App Store или Cydia).
static void IRNoteSeen(NSString *bundleID) {
    if (!bundleID || !gKnown || [gKnown containsObject:bundleID])
        return;
    [gKnown addObject:bundleID];
    [gNew addObject:bundleID];
    IRSaveState();
}

#pragma mark - Точка

@interface IRNewAppDotView : UIView
@property(nonatomic, copy) NSString *bundleID;
@end

@implementation IRNewAppDotView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.userInteractionEnabled = NO;
        self.tag = kIRDotTag;
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self selector:@selector(appLaunched:) name:IR_NOTE_LAUNCHED object:nil];
        [center addObserver:self selector:@selector(refresh:) name:IR_NOTE_REFRESH object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)appLaunched:(NSNotification *)note {
    if ([note.object isEqual:self.bundleID])
        [self removeFromSuperview];
}

- (void)refresh:(NSNotification *)note {
    if (!gEnabled)
        [self removeFromSuperview];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect ball = CGRectInset(self.bounds, 0.5, 0.5);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();

    // Тёмная окантовка — чтобы точка читалась на любых обоях, как белые подписи с тенью.
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.45].CGColor);
    CGContextFillEllipseInRect(ctx, ball);

    // Синий шар с бликом
    CGRect body = CGRectInset(ball, 0.75, 0.75);
    CGContextSaveGState(ctx);
    CGContextAddEllipseInRect(ctx, body);
    CGContextClip(ctx);
    CGFloat blue[] = {0.47, 0.73, 1.0, 1, 0.10, 0.40, 0.86, 1};
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, blue, NULL, 2);
    CGPoint center = CGPointMake(CGRectGetMidX(body), CGRectGetMidY(body));
    CGContextDrawRadialGradient(ctx, gradient, CGPointMake(center.x, center.y - body.size.height * 0.25), 0,
                                center, body.size.width * 0.6, kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(gradient);

    CGFloat gloss[] = {1, 1, 1, 0.75, 1, 1, 1, 0.05};
    CGGradientRef glossGradient = CGGradientCreateWithColorComponents(space, gloss, NULL, 2);
    CGRect shine = CGRectMake(body.origin.x + body.size.width * 0.2, body.origin.y + body.size.height * 0.08,
                              body.size.width * 0.6, body.size.height * 0.45);
    CGContextAddEllipseInRect(ctx, shine);
    CGContextClip(ctx);
    CGContextDrawLinearGradient(ctx, glossGradient, shine.origin, CGPointMake(shine.origin.x, CGRectGetMaxY(shine)), 0);
    CGGradientRelease(glossGradient);
    CGContextRestoreGState(ctx);

    CGColorSpaceRelease(space);
}

@end

// Точка живёт внутри картинки подписи: так она сама прячется и затухает вместе с подписью
// (в доке, при перетаскивании, в режиме редактирования).
static void IRUpdateDot(SBIconView *iconView) {
    UIView *label = IRIvar(iconView, "_labelView");
    if (![label isKindOfClass:[UIView class]])
        return;
    IRNewAppDotView *dot = (IRNewAppDotView *)[label viewWithTag:kIRDotTag];
    NSString *bundleID = [iconView respondsToSelector:@selector(icon)] ? IRBundleIDForIcon([iconView icon]) : nil;
    IRNoteSeen(bundleID);

    if (!gEnabled || !bundleID || ![gNew containsObject:bundleID]) {
        [dot removeFromSuperview];
        return;
    }
    if (![dot isKindOfClass:[IRNewAppDotView class]]) {
        dot = [[IRNewAppDotView alloc] initWithFrame:CGRectZero];
        label.clipsToBounds = NO;
        [label addSubview:dot];
    }
    dot.bundleID = bundleID;
    CGSize size = label.bounds.size;
    dot.frame = CGRectMake(-kIRDotSize - 1.5f, roundf((size.height - kIRDotSize) / 2 - 1), kIRDotSize, kIRDotSize);
}

#pragma mark - Перехваты SpringBoard

static void (*orig_positionLabel)(SBIconView *, SEL);
static void hook_positionLabel(SBIconView *self, SEL _cmd) {
    orig_positionLabel(self, _cmd);
    IRUpdateDot(self);
}

static void (*orig_setIcon)(SBIconView *, SEL, SBIcon *);
static void hook_setIcon(SBIconView *self, SEL _cmd, SBIcon *icon) {
    orig_setIcon(self, _cmd, icon);
    IRUpdateDot(self);
}

static void (*orig_didLaunch)(SBApplication *, SEL, id);
static void hook_didLaunch(SBApplication *self, SEL _cmd, id process) {
    orig_didLaunch(self, _cmd, process);
    NSString *bundleID = [self respondsToSelector:@selector(bundleIdentifier)] ? [self bundleIdentifier] : nil;
    if (bundleID && [gNew containsObject:bundleID]) {
        [gNew removeObject:bundleID];
        IRSaveState();
        [[NSNotificationCenter defaultCenter] postNotificationName:IR_NOTE_LAUNCHED object:bundleID];
    }
}

// При первом запуске твика запоминаем все программы как «старые», чтобы точки не появились везде.
// Потом при каждой загрузке SpringBoard ищем установленные, пока он был выключен.
static void (*orig_finishLaunching)(UIApplication *, SEL, id);
static void hook_finishLaunching(UIApplication *self, SEL _cmd, id application) {
    orig_finishLaunching(self, _cmd, application);
    SBApplicationController *controller = [objc_getClass("SBApplicationController") sharedInstance];
    if (![controller respondsToSelector:@selector(allApplications)])
        return;
    NSMutableSet *installed = [NSMutableSet set];
    for (SBApplication *app in [controller allApplications])
        if ([app respondsToSelector:@selector(bundleIdentifier)] && [app bundleIdentifier])
            [installed addObject:[app bundleIdentifier]];
    if (!installed.count)
        return;

    if (!gKnown) {
        gKnown = installed;
    } else {
        for (NSString *bundleID in installed)
            if (![gKnown containsObject:bundleID])
                [gNew addObject:bundleID];
        [gKnown unionSet:installed];
        [gNew intersectSet:installed]; // удалённые программы забываем
    }
    IRSaveState();
}

static void IRPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    gEnabled = IRBool(IRPrefsRead(), kIRNewAppDot, YES);
    [[NSNotificationCenter defaultCenter] postNotificationName:IR_NOTE_REFRESH object:nil];
}

__attribute__((constructor)) static void IRNewAppDotInit(void) {
    @autoreleasepool {
        if (!IRIsProcess(@"com.apple.springboard"))
            return;
        IRLoadState();
        gEnabled = IRBool(IRPrefsRead(), kIRNewAppDot, YES);
        IRObserveDarwin(IR_NOTIFY_PREFS, IRPrefsChanged);

        Class iconView = objc_getClass("SBIconView");
        IR_HOOK(iconView, @selector(positionLabel), hook_positionLabel, &orig_positionLabel);
        IR_HOOK(iconView, @selector(setIcon:), hook_setIcon, &orig_setIcon);
        IR_HOOK(objc_getClass("SBApplication"), @selector(didLaunch:), hook_didLaunch, &orig_didLaunch);
        IR_HOOK(objc_getClass("SpringBoard"), @selector(applicationDidFinishLaunching:), hook_finishLaunching, &orig_finishLaunching);
    }
}
