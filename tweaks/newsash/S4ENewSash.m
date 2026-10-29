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

#import "S4EShared.h"
#import "S4EPrivate.h"

#define S4E_NEW_APPS_FILE @"new-apps.plist"
#define S4E_NOTE_REFRESH @"S4ENewAppSashRefresh"

static const NSInteger kS4ESashTag = 0x5A54;

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

@interface SBIcon (S4ENewAppSash)
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

@interface SBIconView (S4ENewAppSash)
- (UIView *)iconImageView;
@end

#pragma mark - Какие программы новые

static void S4ESaveState(void) {
    NSDictionary *state = @{@"Known": gKnown.allObjects, @"New": gNew.allObjects};
    [state writeToFile:S4EDataPath(S4E_NEW_APPS_FILE) atomically:YES];
}

static void S4ELoadState(void) {
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:S4EDataPath(S4E_NEW_APPS_FILE)];
    gKnown = state ? [NSMutableSet setWithArray:state[@"Known"] ?: @[]] : nil;
    gNew = [NSMutableSet setWithArray:state[@"New"] ?: @[]];
}

static NSString *S4EBundleIDForIcon(SBIcon *icon) {
    Class appIcon = objc_getClass("SBApplicationIcon");
    if (!appIcon || ![icon isKindOfClass:appIcon] || ![icon respondsToSelector:@selector(applicationBundleID)])
        return nil;
    return [(SBApplicationIcon *)icon applicationBundleID];
}

static BOOL S4EIsNew(NSString *bundleID) {
    return gEnabled && bundleID && [gNew containsObject:bundleID];
}

static SBIconModel *S4EIconModel(void) {
    SBIconController *controller = [objc_getClass("SBIconController") sharedInstance];
    return [controller respondsToSelector:@selector(model)] ? [controller model] : nil;
}

// Перерисовать ленту у иконки программы: родную — через noteBadgeDidChange, нашу — уведомлением
static void S4ERefreshIcon(NSString *bundleID) {
    SBIconModel *model = S4EIconModel();
    SBIcon *icon = [model respondsToSelector:@selector(applicationIconForDisplayIdentifier:)]
        ? [model applicationIconForDisplayIdentifier:bundleID] : nil;
    if ([icon respondsToSelector:@selector(noteBadgeDidChange)])
        [icon noteBadgeDidChange];
    [[NSNotificationCenter defaultCenter] postNotificationName:S4E_NOTE_REFRESH object:nil];
}

// Программа появилась, пока SpringBoard работает (установка из App Store, ipa или Cydia)
static void S4ENoteSeen(NSString *bundleID) {
    if (!bundleID || !gKnown || [gKnown containsObject:bundleID])
        return;
    [gKnown addObject:bundleID];
    [gNew addObject:bundleID];
    S4ESaveState();
    // Иконка уже решила, нужна ли ей лента, — пусть решит ещё раз
    dispatch_async(dispatch_get_main_queue(), ^{
        S4ERefreshIcon(bundleID);
    });
}

#pragma mark - Лента для программ из Cydia

// Подпись ленты — та же, что у SpringBoard («Новое»): берём у любой программы из App Store
static NSString *S4ESashText(void) {
    static NSString *text;
    if (text)
        return text;
    Class userIcon = objc_getClass("SBUserInstalledApplicationIcon");
    SBIconModel *model = S4EIconModel();
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

@interface S4ESashView : UIImageView
@property(nonatomic, copy) NSString *bundleID;
@end

@implementation S4ESashView

- (instancetype)initWithImage:(UIImage *)image {
    if ((self = [super initWithImage:image])) {
        self.userInteractionEnabled = NO;
        self.tag = kS4ESashTag;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh:) name:S4E_NOTE_REFRESH object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)refresh:(NSNotification *)note {
    if (!S4EIsNew(self.bundleID))
        [self removeFromSuperview];
}

@end

// Родная лента или бейдж уже на иконке
static BOOL S4EHasNativeAccessory(SBIconView *iconView) {
    UIImageView *accessory = S4EIvar(iconView, "_accessoryView");
    return [accessory isKindOfClass:[UIImageView class]] && accessory.image && !accessory.hidden && accessory.superview;
}

// Лента живёт внутри картинки иконки: так она сама качается, затемняется и прячется вместе с ней
static void S4EUpdateSash(SBIconView *iconView) {
    SBIcon *icon = [iconView respondsToSelector:@selector(icon)] ? [iconView icon] : nil;
    NSString *bundleID = S4EBundleIDForIcon(icon);
    S4ENoteSeen(bundleID);

    UIView *imageView = [iconView respondsToSelector:@selector(iconImageView)] ? [iconView iconImageView] : nil;
    if (![imageView isKindOfClass:[UIView class]])
        return;
    S4ESashView *sash = (S4ESashView *)[imageView viewWithTag:kS4ESashTag];
    if (!S4EIsNew(bundleID) || S4EHasNativeAccessory(iconView)) {
        [sash removeFromSuperview];
        return;
    }
    if (![sash isKindOfClass:[S4ESashView class]]) {
        Class sashClass = objc_getClass("SBIconSashImage");
        SBIconSashImage *image = [sashClass respondsToSelector:@selector(sashWithText:)] ? [sashClass sashWithText:S4ESashText()] : nil;
        if (!image)
            return;
        sash = [[S4ESashView alloc] initWithImage:image];
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
    return orig_shouldShowSash(self, _cmd) || S4EIsNew(S4EBundleIDForIcon(self));
}

static void (*orig_positionLabel)(SBIconView *, SEL);
static void hook_positionLabel(SBIconView *self, SEL _cmd) {
    orig_positionLabel(self, _cmd);
    S4EUpdateSash(self);
}

static void (*orig_setIcon)(SBIconView *, SEL, SBIcon *);
static void hook_setIcon(SBIconView *self, SEL _cmd, SBIcon *icon) {
    orig_setIcon(self, _cmd, icon);
    S4EUpdateSash(self);
}

static void (*orig_updateBadge)(SBIconView *, SEL);
static void hook_updateBadge(SBIconView *self, SEL _cmd) {
    orig_updateBadge(self, _cmd);
    S4EUpdateSash(self);
}

static void (*orig_didLaunch)(SBApplication *, SEL, id);
static void hook_didLaunch(SBApplication *self, SEL _cmd, id process) {
    orig_didLaunch(self, _cmd, process);
    NSString *bundleID = [self respondsToSelector:@selector(bundleIdentifier)] ? [self bundleIdentifier] : nil;
    if (bundleID && [gNew containsObject:bundleID]) {
        [gNew removeObject:bundleID];
        S4ESaveState();
        S4ERefreshIcon(bundleID);
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
    S4ESaveState();
    for (NSString *bundleID in gNew)
        S4ERefreshIcon(bundleID);
}

static void S4EPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    BOOL enabled = S4EBool(S4EPrefsRead(), kS4ENewSash, YES);
    if (enabled == gEnabled)
        return;
    gEnabled = enabled;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSString *bundleID in [gNew copy])
            S4ERefreshIcon(bundleID);
    });
}

__attribute__((constructor)) static void S4ENewSashInit(void) {
    @autoreleasepool {
        if (!S4EIsProcess(@"com.apple.springboard"))
            return;
        S4ELoadState();
        gEnabled = S4EBool(S4EPrefsRead(), kS4ENewSash, YES);
        S4EObserveDarwin(S4E_NOTIFY_PREFS, S4EPrefsChanged);

        S4E_HOOK(objc_getClass("SBUserInstalledApplicationIcon"), @selector(_shouldShowSashForNewlyInstalledApp),
                hook_shouldShowSash, &orig_shouldShowSash);
        Class iconView = objc_getClass("SBIconView");
        S4E_HOOK(iconView, @selector(positionLabel), hook_positionLabel, &orig_positionLabel);
        S4E_HOOK(iconView, @selector(setIcon:), hook_setIcon, &orig_setIcon);
        S4E_HOOK(iconView, @selector(updateBadge), hook_updateBadge, &orig_updateBadge);
        S4E_HOOK(objc_getClass("SBApplication"), @selector(didLaunch:), hook_didLaunch, &orig_didLaunch);
        S4E_HOOK(objc_getClass("SpringBoard"), @selector(applicationDidFinishLaunching:), hook_finishLaunching, &orig_finishLaunching);
    }
}
