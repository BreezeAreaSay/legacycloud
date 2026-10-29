// Лента «Новое» на иконке новой программы — родная лента iOS 6, но для всех новых программ.
//
// iOS 6 вешает ленту, только если SpringBoard сам пометил программу как новую (обычно при загрузке
// из App Store), поэтому на программах из ipa она появляется через раз, а на программах из Cydia —
// никогда. Твик сам помнит, какие программы новые, до их первого запуска:
//  * программы из /var/mobile/Applications (App Store, ipa) — это SBUserInstalledApplicationIcon:
//    отвечаем «да» на -_shouldShowSashForNewlyInstalledApp, и ленту рисует сам SpringBoard;
//  * у программ из /Applications (Cydia) ленты не бывает: кладём на иконку ту же картинку
//    +[SBIconSashImage sashWithText:] туда же, где её рисует SpringBoard (-accessoryFrameForIconBounds:).
//    Так же поступаем с любой новой программой, если SpringBoard ленту всё-таки не нарисовал.
//    Свою ленту кладём, только когда у иконки нет родной ленты или бейджа, — проверяем после
//    каждого -updateBadge, поэтому лент не бывает две и лента не ложится на бейдж.

#import "IRShared.h"
#import "IRPrivate.h"

#define IR_NEW_APPS_FILE @"new-apps.plist"
#define IR_NOTE_REFRESH @"IRNewAppSashRefresh"

static const NSInteger kIRSashTag = 0x5A54;

static NSMutableSet *gKnown;
static NSMutableSet *gNew;
static BOOL gEnabled = YES;

#pragma mark - Приватные API SpringBoard iOS 6.1

@interface SBIconSashImage : UIImage
+ (id)sashWithText:(NSString *)text;
- (CGRect)accessoryFrameForIconBounds:(CGRect)bounds;
@end

@interface SBUserInstalledApplicationIcon : SBApplicationIcon
- (BOOL)_shouldShowSashForNewlyInstalledApp;
- (NSString *)_newlyInstalledSashLabel;
@end

@interface SBIcon (IRNewAppSash)
- (void)noteBadgeDidChange;
@end

@interface SBIconModel : NSObject
- (SBIcon *)applicationIconForDisplayIdentifier:(NSString *)identifier;
- (id)leafIcons;
@end

@interface SBIconController : NSObject
+ (instancetype)sharedInstance;
- (SBIconModel *)model;
@end

@interface SBIconView (IRNewAppSash)
- (UIView *)iconImageView;
@end

#pragma mark - Какие программы новые

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

static BOOL IRIsNew(NSString *bundleID) {
    return gEnabled && bundleID && [gNew containsObject:bundleID];
}

static SBIconModel *IRIconModel(void) {
    SBIconController *controller = [objc_getClass("SBIconController") sharedInstance];
    return [controller respondsToSelector:@selector(model)] ? [controller model] : nil;
}

// Перерисовать ленту у иконки программы: родную — через noteBadgeDidChange, нашу — уведомлением
static void IRRefreshIcon(NSString *bundleID) {
    SBIconModel *model = IRIconModel();
    SBIcon *icon = [model respondsToSelector:@selector(applicationIconForDisplayIdentifier:)]
        ? [model applicationIconForDisplayIdentifier:bundleID] : nil;
    if ([icon respondsToSelector:@selector(noteBadgeDidChange)])
        [icon noteBadgeDidChange];
    [[NSNotificationCenter defaultCenter] postNotificationName:IR_NOTE_REFRESH object:nil];
}

// Программа появилась, пока SpringBoard работает (установка из App Store, ipa или Cydia)
static void IRNoteSeen(NSString *bundleID) {
    if (!bundleID || !gKnown || [gKnown containsObject:bundleID])
        return;
    [gKnown addObject:bundleID];
    [gNew addObject:bundleID];
    IRSaveState();
    // Иконка уже решила, нужна ли ей лента, — пусть решит ещё раз
    dispatch_async(dispatch_get_main_queue(), ^{
        IRRefreshIcon(bundleID);
    });
}

#pragma mark - Лента для программ из Cydia

// Подпись ленты — та же, что у SpringBoard («Новое»): берём у любой программы из App Store
static NSString *IRSashText(void) {
    static NSString *text;
    if (text)
        return text;
    Class userIcon = objc_getClass("SBUserInstalledApplicationIcon");
    SBIconModel *model = IRIconModel();
    id icons = [model respondsToSelector:@selector(leafIcons)] ? [model leafIcons] : nil;
    for (SBIcon *icon in icons) {
        if (userIcon && [icon isKindOfClass:userIcon] && [icon respondsToSelector:@selector(_newlyInstalledSashLabel)]) {
            NSString *label = [(SBUserInstalledApplicationIcon *)icon _newlyInstalledSashLabel];
            if (label.length) {
                text = label;
                return text;
            }
        }
    }
    NSString *language = [[NSLocale preferredLanguages] count] ? [NSLocale preferredLanguages][0] : @"";
    return [language hasPrefix:@"ru"] ? @"Новое" : @"New";
}

@interface IRSashView : UIImageView
@property(nonatomic, copy) NSString *bundleID;
@end

@implementation IRSashView

- (instancetype)initWithImage:(UIImage *)image {
    if ((self = [super initWithImage:image])) {
        self.userInteractionEnabled = NO;
        self.tag = kIRSashTag;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh:) name:IR_NOTE_REFRESH object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)refresh:(NSNotification *)note {
    if (!IRIsNew(self.bundleID))
        [self removeFromSuperview];
}

@end

// Родная лента или бейдж уже на иконке
static BOOL IRHasNativeAccessory(SBIconView *iconView) {
    UIImageView *accessory = IRIvar(iconView, "_accessoryView");
    return [accessory isKindOfClass:[UIImageView class]] && accessory.image && !accessory.hidden && accessory.superview;
}

// Лента живёт внутри картинки иконки: так она сама качается, затемняется и прячется вместе с ней
static void IRUpdateSash(SBIconView *iconView) {
    SBIcon *icon = [iconView respondsToSelector:@selector(icon)] ? [iconView icon] : nil;
    NSString *bundleID = IRBundleIDForIcon(icon);
    IRNoteSeen(bundleID);

    UIView *imageView = [iconView respondsToSelector:@selector(iconImageView)] ? [iconView iconImageView] : nil;
    if (![imageView isKindOfClass:[UIView class]])
        return;
    IRSashView *sash = (IRSashView *)[imageView viewWithTag:kIRSashTag];
    if (!IRIsNew(bundleID) || IRHasNativeAccessory(iconView)) {
        [sash removeFromSuperview];
        return;
    }
    if (![sash isKindOfClass:[IRSashView class]]) {
        Class sashClass = objc_getClass("SBIconSashImage");
        SBIconSashImage *image = [sashClass respondsToSelector:@selector(sashWithText:)] ? [sashClass sashWithText:IRSashText()] : nil;
        if (!image)
            return;
        sash = [[IRSashView alloc] initWithImage:image];
        imageView.clipsToBounds = NO;
        [imageView addSubview:sash];
    }
    sash.bundleID = bundleID;
    SBIconSashImage *image = (SBIconSashImage *)sash.image;
    if ([image respondsToSelector:@selector(accessoryFrameForIconBounds:)])
        sash.frame = [image accessoryFrameForIconBounds:imageView.bounds];
    else // правый верхний угол, как у родной ленты
        sash.frame = CGRectMake(imageView.bounds.size.width - image.size.width + 4, -4, image.size.width, image.size.height);
}

#pragma mark - Перехваты SpringBoard

// Родная лента у программ из App Store и ipa
static BOOL (*orig_shouldShowSash)(id, SEL);
static BOOL hook_shouldShowSash(id self, SEL _cmd) {
    return orig_shouldShowSash(self, _cmd) || IRIsNew(IRBundleIDForIcon(self));
}

static void (*orig_positionLabel)(SBIconView *, SEL);
static void hook_positionLabel(SBIconView *self, SEL _cmd) {
    orig_positionLabel(self, _cmd);
    IRUpdateSash(self);
}

static void (*orig_setIcon)(SBIconView *, SEL, SBIcon *);
static void hook_setIcon(SBIconView *self, SEL _cmd, SBIcon *icon) {
    orig_setIcon(self, _cmd, icon);
    IRUpdateSash(self);
}

static void (*orig_updateBadge)(SBIconView *, SEL);
static void hook_updateBadge(SBIconView *self, SEL _cmd) {
    orig_updateBadge(self, _cmd);
    IRUpdateSash(self);
}

static void (*orig_didLaunch)(SBApplication *, SEL, id);
static void hook_didLaunch(SBApplication *self, SEL _cmd, id process) {
    orig_didLaunch(self, _cmd, process);
    NSString *bundleID = [self respondsToSelector:@selector(bundleIdentifier)] ? [self bundleIdentifier] : nil;
    if (bundleID && [gNew containsObject:bundleID]) {
        [gNew removeObject:bundleID];
        IRSaveState();
        IRRefreshIcon(bundleID);
    }
}

// При первом запуске твика запоминаем все программы как «старые», чтобы ленты не появились везде.
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
    for (NSString *bundleID in gNew)
        IRRefreshIcon(bundleID);
}

static void IRPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    BOOL enabled = IRBool(IRPrefsRead(), kIRNewAppDot, YES);
    if (enabled == gEnabled)
        return;
    gEnabled = enabled;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSString *bundleID in [gNew copy])
            IRRefreshIcon(bundleID);
    });
}

__attribute__((constructor)) static void IRNewAppDotInit(void) {
    @autoreleasepool {
        if (!IRIsProcess(@"com.apple.springboard"))
            return;
        IRLoadState();
        gEnabled = IRBool(IRPrefsRead(), kIRNewAppDot, YES);
        IRObserveDarwin(IR_NOTIFY_PREFS, IRPrefsChanged);

        IR_HOOK(objc_getClass("SBUserInstalledApplicationIcon"), @selector(_shouldShowSashForNewlyInstalledApp),
                hook_shouldShowSash, &orig_shouldShowSash);
        Class iconView = objc_getClass("SBIconView");
        IR_HOOK(iconView, @selector(positionLabel), hook_positionLabel, &orig_positionLabel);
        IR_HOOK(iconView, @selector(setIcon:), hook_setIcon, &orig_setIcon);
        IR_HOOK(iconView, @selector(updateBadge), hook_updateBadge, &orig_updateBadge);
        IR_HOOK(objc_getClass("SBApplication"), @selector(didLaunch:), hook_didLaunch, &orig_didLaunch);
        IR_HOOK(objc_getClass("SpringBoard"), @selector(applicationDidFinishLaunching:), hook_finishLaunching, &orig_finishLaunching);
    }
}
