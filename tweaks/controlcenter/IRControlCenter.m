// Пункт управления (iOS 7) в стиле iOS 6.
//
// Раскладка iOS 7, материалы — по концепту с r/jailbreak: перфорированный тёмный металл, квадратные
// кнопки с серебристым ободком, синий глянец у включённых, круглые серебристые кнопки музыки.
// Ползунки родные: UISlider и громкость MPVolumeView (с выбором вывода звука, например на AirPods).
//
// Жест даёт Activator: в SpringBoard iOS 6 нет открытого способа добавить свой системный жест,
// а прозрачное окно у края поверх программ касаний не получает. Пункт управления — действие
// Activator; при первом запуске оно само встаёт на «Свайп вверх от низа», если тот свободен.
// libactivator подгружаем через dlopen и берём классы через objc_getClass, без линковки.

#import "IRShared.h"
#import "IRPrivate.h"
#import "IRCCDrawing.h"
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>

#define kIRControlCenter @"ControlCenter"

#define kIRCCActivatorDefaults @"ControlCenterActivatorDefaults"
#define kIRCCListener @"com.ios6revive.controlcenter"

static const CGFloat kIRCCPanelHeight = 356;
static const UIWindowLevel kIRCCWindowLevel = 1050;

#pragma mark - Приватные API SpringBoard iOS 6.1

@interface SBTelephonyManager : NSObject
+ (instancetype)sharedTelephonyManager;
- (BOOL)isInAirplaneMode;
- (void)setIsInAirplaneMode:(BOOL)airplaneMode;
@end

@interface SBWiFiManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)wiFiEnabled;
- (void)setWiFiEnabled:(BOOL)enabled;
@end

@interface BluetoothManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)powered;
- (BOOL)setPowered:(BOOL)powered;
- (BOOL)setEnabled:(BOOL)enabled;
@end

@interface SBBulletinSystemStateAdapter : NSObject
+ (instancetype)sharedInstance;
- (BOOL)quietModeEnabled;
@end

@interface BBSettingsGateway : NSObject
- (void)setBehaviorOverrideStatus:(int)status;
@end

@interface SBOrientationLockManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isLocked;
- (void)lock;
- (void)unlock;
@end

@interface SBMediaController : NSObject
+ (instancetype)sharedInstance;
- (BOOL)togglePlayPause;
- (BOOL)changeTrack:(int)direction;
- (NSString *)nowPlayingTitle;
- (NSString *)nowPlayingArtist;
- (NSString *)nowPlayingAlbum;
- (BOOL)isPlaying;
- (BOOL)hasTrack;
@end

// Activator (libactivator): только то, чем пользуемся
@interface LAEvent : NSObject
+ (id)eventWithName:(NSString *)name mode:(NSString *)mode;
@property(nonatomic, getter=isHandled) BOOL handled;
@end

@interface LAActivator : NSObject
- (void)registerListener:(id)listener forName:(NSString *)name;
- (void)assignEvent:(LAEvent *)event toListenerWithName:(NSString *)listenerName;
- (NSString *)assignedListenerNameForEvent:(LAEvent *)event;
@end

@interface SBApplicationController (IRControlCenter)
- (SBApplication *)applicationWithDisplayIdentifier:(NSString *)identifier;
@end

@interface SBUIController (IRControlCenter)
- (void)activateApplicationAnimated:(SBApplication *)application;
@end

#pragma mark - Переключатели

typedef enum { IRCCAirplane, IRCCWiFi, IRCCBluetooth, IRCCDoNotDisturb, IRCCRotationLock, IRCCFlashlight } IRCCToggle;

// Wi-Fi: SBWiFiManager, если он есть, иначе MobileWiFi напрямую
typedef void *IRWiFiClientRef;
static IRWiFiClientRef IRWiFiClient(void) {
    static IRWiFiClientRef client;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_LAZY);
        IRWiFiClientRef (*create)(CFAllocatorRef, int) = handle ? (IRWiFiClientRef (*)(CFAllocatorRef, int))dlsym(handle, "WiFiManagerClientCreate") : NULL;
        if (create)
            client = create(kCFAllocatorDefault, 0);
    });
    return client;
}

static BOOL IRWiFiEnabled(void) {
    SBWiFiManager *manager = [objc_getClass("SBWiFiManager") sharedInstance];
    if ([manager respondsToSelector:@selector(wiFiEnabled)])
        return [manager wiFiEnabled];
    CFPropertyListRef (*copy)(IRWiFiClientRef, CFStringRef) = (CFPropertyListRef (*)(IRWiFiClientRef, CFStringRef))dlsym(RTLD_DEFAULT, "WiFiManagerClientCopyProperty");
    if (!copy || !IRWiFiClient())
        return NO;
    CFPropertyListRef value = copy(IRWiFiClient(), CFSTR("AllowEnable"));
    BOOL enabled = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)value);
    if (value)
        CFRelease(value);
    return enabled;
}

static void IRSetWiFiEnabled(BOOL enabled) {
    SBWiFiManager *manager = [objc_getClass("SBWiFiManager") sharedInstance];
    if ([manager respondsToSelector:@selector(setWiFiEnabled:)]) {
        [manager setWiFiEnabled:enabled];
        return;
    }
    void (*set)(IRWiFiClientRef, CFStringRef, CFPropertyListRef) = (void (*)(IRWiFiClientRef, CFStringRef, CFPropertyListRef))dlsym(RTLD_DEFAULT, "WiFiManagerClientSetProperty");
    if (set && IRWiFiClient())
        set(IRWiFiClient(), CFSTR("AllowEnable"), enabled ? kCFBooleanTrue : kCFBooleanFalse);
}

static BluetoothManager *IRBluetooth(void) {
    Class cls = objc_getClass("BluetoothManager");
    if (!cls) {
        dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_LAZY);
        cls = objc_getClass("BluetoothManager");
    }
    return [cls sharedInstance];
}

static BBSettingsGateway *IRSettingsGateway(void) {
    static BBSettingsGateway *gateway;
    if (!gateway)
        gateway = [[objc_getClass("BBSettingsGateway") alloc] init];
    return gateway;
}

static AVCaptureSession *gTorchSession;

static AVCaptureDevice *IRTorchDevice(void) {
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    return [device hasTorch] ? device : nil;
}

static void IRSetTorch(BOOL on) {
    AVCaptureDevice *device = IRTorchDevice();
    if (!device)
        return;
    // Без запущенной сессии камеры фонарик на старых iOS гаснет сам
    if (on && !gTorchSession) {
        gTorchSession = [[AVCaptureSession alloc] init];
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:NULL];
        if (input && [gTorchSession canAddInput:input])
            [gTorchSession addInput:input];
        [gTorchSession startRunning];
    }
    if ([device lockForConfiguration:NULL]) {
        device.torchMode = on ? AVCaptureTorchModeOn : AVCaptureTorchModeOff;
        [device unlockForConfiguration];
    }
    if (!on) {
        [gTorchSession stopRunning];
        gTorchSession = nil;
    }
}

static BOOL IRToggleState(IRCCToggle toggle) {
    switch (toggle) {
    case IRCCAirplane: {
        SBTelephonyManager *telephony = [objc_getClass("SBTelephonyManager") sharedTelephonyManager];
        return [telephony respondsToSelector:@selector(isInAirplaneMode)] && [telephony isInAirplaneMode];
    }
    case IRCCWiFi:
        return IRWiFiEnabled();
    case IRCCBluetooth: {
        BluetoothManager *bluetooth = IRBluetooth();
        return [bluetooth respondsToSelector:@selector(powered)] && [bluetooth powered];
    }
    case IRCCDoNotDisturb: {
        SBBulletinSystemStateAdapter *adapter = [objc_getClass("SBBulletinSystemStateAdapter") sharedInstance];
        return [adapter respondsToSelector:@selector(quietModeEnabled)] && [adapter quietModeEnabled];
    }
    case IRCCRotationLock: {
        SBOrientationLockManager *manager = [objc_getClass("SBOrientationLockManager") sharedInstance];
        return [manager respondsToSelector:@selector(isLocked)] && [manager isLocked];
    }
    case IRCCFlashlight:
        return IRTorchDevice().torchMode == AVCaptureTorchModeOn;
    }
    return NO;
}

static void IRSetToggle(IRCCToggle toggle, BOOL on) {
    switch (toggle) {
    case IRCCAirplane: {
        SBTelephonyManager *telephony = [objc_getClass("SBTelephonyManager") sharedTelephonyManager];
        if ([telephony respondsToSelector:@selector(setIsInAirplaneMode:)])
            [telephony setIsInAirplaneMode:on];
        break;
    }
    case IRCCWiFi:
        IRSetWiFiEnabled(on);
        break;
    case IRCCBluetooth: {
        BluetoothManager *bluetooth = IRBluetooth();
        if ([bluetooth respondsToSelector:@selector(setPowered:)])
            [bluetooth setPowered:on];
        if ([bluetooth respondsToSelector:@selector(setEnabled:)])
            [bluetooth setEnabled:on];
        break;
    }
    case IRCCDoNotDisturb: {
        BBSettingsGateway *gateway = IRSettingsGateway();
        if ([gateway respondsToSelector:@selector(setBehaviorOverrideStatus:)])
            [gateway setBehaviorOverrideStatus:on ? 1 : 0];
        break;
    }
    case IRCCRotationLock: {
        SBOrientationLockManager *manager = [objc_getClass("SBOrientationLockManager") sharedInstance];
        if (on && [manager respondsToSelector:@selector(lock)])
            [manager lock];
        else if (!on && [manager respondsToSelector:@selector(unlock)])
            [manager unlock];
        break;
    }
    case IRCCFlashlight:
        IRSetTorch(on);
        break;
    }
}

static void IRSetBrightness(float level) {
    SBBrightnessController *controller = [objc_getClass("SBBrightnessController") sharedBrightnessController];
    if ([controller respondsToSelector:@selector(_setBrightnessLevel:showHUD:)])
        [controller _setBrightnessLevel:level showHUD:NO];
    else
        [UIScreen mainScreen].brightness = level;
}

static void IRLaunch(NSString *identifier) {
    SBApplicationController *apps = [objc_getClass("SBApplicationController") sharedInstance];
    SBApplication *app = [apps respondsToSelector:@selector(applicationWithDisplayIdentifier:)] ? [apps applicationWithDisplayIdentifier:identifier] : nil;
    SBUIController *ui = [objc_getClass("SBUIController") sharedInstance];
    if (app && [ui respondsToSelector:@selector(activateApplicationAnimated:)])
        [ui activateApplicationAnimated:app];
}

#pragma mark - Панель

@interface IRCCPanel : UIView
@property(nonatomic, copy) void (^onLaunch)(NSString *identifier);
- (void)refresh;
@end

@implementation IRCCPanel {
    NSArray *_toggles;
    UISlider *_brightness;
    UILabel *_artist;
    UILabel *_title;
    UILabel *_album;
    IRCCButton *_playPause;
}

static UILabel *IRCCLabel(CGRect frame, UIFont *font, UIColor *color) {
    UILabel *label = [[UILabel alloc] initWithFrame:frame];
    label.backgroundColor = [UIColor clearColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.font = font;
    label.textColor = color;
    label.shadowColor = [UIColor colorWithWhite:0 alpha:0.8];
    label.shadowOffset = CGSizeMake(0, -1);
    return label;
}

static IRCCButton *IRCCMakeButton(IRCCGlyph glyph, IRCCButtonStyle style, CGRect frame, NSInteger tag, id target, SEL action) {
    IRCCButton *button = [IRCCButton buttonWithGlyph:glyph style:style];
    button.frame = frame;
    button.tag = tag;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame]))
        return nil;
    CGFloat width = frame.size.width;
    self.backgroundColor = IRCCPerforatedColor();
    self.clipsToBounds = NO;

    // Тень сверху и светлый кант
    CAGradientLayer *shadow = [CAGradientLayer layer];
    shadow.frame = CGRectMake(0, -6, width, 6);
    shadow.colors = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor, (id)[UIColor colorWithWhite:0 alpha:0.5].CGColor];
    [self.layer addSublayer:shadow];
    UIView *edge = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 1)];
    edge.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
    [self addSubview:edge];

    // Язычок: панель можно стянуть вниз
    UIView *grabber = [[UIView alloc] initWithFrame:CGRectMake(width / 2 - 18, 7, 36, 5)];
    grabber.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    grabber.layer.cornerRadius = 2.5;
    grabber.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
    grabber.layer.borderWidth = 0.5;
    [self addSubview:grabber];

    // Переключатели
    const IRCCGlyph glyphs[] = {IRCCGlyphAirplane, IRCCGlyphWiFi, IRCCGlyphBluetooth, IRCCGlyphMoon, IRCCGlyphRotationLock};
    const IRCCToggle toggles[] = {IRCCAirplane, IRCCWiFi, IRCCBluetooth, IRCCDoNotDisturb, IRCCRotationLock};
    NSMutableArray *buttons = [NSMutableArray array];
    CGFloat gap = (width - 5 * 52) / 6;
    for (int i = 0; i < 5; i++) {
        IRCCButton *button = IRCCMakeButton(glyphs[i], IRCCButtonStyleSquare, CGRectMake(gap + i * (52 + gap), 20, 52, 52),
                                            toggles[i], self, @selector(toggleTapped:));
        [self addSubview:button];
        [buttons addObject:button];
    }

    // Яркость — родной ползунок iOS 6
    _brightness = [[UISlider alloc] initWithFrame:CGRectMake(16, 88, width - 32, 23)];
    _brightness.minimumValueImage = IRCCGlyphImage(IRCCGlyphSunSmall, 18, [UIColor colorWithWhite:1 alpha:0.8]);
    _brightness.maximumValueImage = IRCCGlyphImage(IRCCGlyphSunLarge, 22, [UIColor colorWithWhite:1 alpha:0.8]);
    [_brightness addTarget:self action:@selector(brightnessChanged:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:_brightness];

    // Музыка: исполнитель, название, альбом и круглые серебристые кнопки
    _artist = IRCCLabel(CGRectMake(20, 122, width - 40, 16), [UIFont boldSystemFontOfSize:13], [UIColor colorWithWhite:0.62 alpha:1]);
    _title = IRCCLabel(CGRectMake(20, 138, width - 40, 22), [UIFont boldSystemFontOfSize:18], [UIColor whiteColor]);
    _album = IRCCLabel(CGRectMake(20, 161, width - 40, 15), [UIFont boldSystemFontOfSize:11], [UIColor colorWithWhite:0.62 alpha:1]);
    [self addSubview:_artist];
    [self addSubview:_title];
    [self addSubview:_album];
    const IRCCGlyph mediaGlyphs[] = {IRCCGlyphPrevious, IRCCGlyphPlay, IRCCGlyphNext};
    for (int i = 0; i < 3; i++) {
        // tag: -1 назад, 0 пауза, 1 вперёд
        IRCCButton *button = IRCCMakeButton(mediaGlyphs[i], IRCCButtonStyleMedia, CGRectMake(width / 2 - 25 + (i - 1) * 76, 184, 50, 50),
                                            i - 1, self, @selector(mediaTapped:));
        [self addSubview:button];
        if (i == 1)
            _playPause = button;
    }
    MPVolumeView *volume = [[MPVolumeView alloc] initWithFrame:CGRectMake(20, 248, width - 40, 23)];
    [self addSubview:volume];

    // Фонарик и быстрые программы
    const IRCCGlyph appGlyphs[] = {IRCCGlyphFlashlight, IRCCGlyphTimer, IRCCGlyphCalculator, IRCCGlyphCamera};
    gap = (width - 4 * 60) / 5;
    for (int i = 0; i < 4; i++) {
        CGRect buttonFrame = CGRectMake(gap + i * (60 + gap), 282, 60, 60);
        IRCCButton *button = i == 0
            ? IRCCMakeButton(appGlyphs[i], IRCCButtonStyleSquare, buttonFrame, IRCCFlashlight, self, @selector(toggleTapped:))
            : IRCCMakeButton(appGlyphs[i], IRCCButtonStyleSquare, buttonFrame, i, self, @selector(appTapped:));
        [self addSubview:button];
        if (i == 0)
            [buttons addObject:button];
    }
    _toggles = buttons;
    return self;
}

- (void)refresh {
    for (IRCCButton *button in _toggles)
        button.on = IRToggleState((IRCCToggle)button.tag);
    if (!_brightness.tracking)
        _brightness.value = [UIScreen mainScreen].brightness;

    SBMediaController *media = [objc_getClass("SBMediaController") sharedInstance];
    BOOL hasTrack = [media respondsToSelector:@selector(hasTrack)] && [media hasTrack];
    _artist.text = hasTrack ? ([media nowPlayingArtist] ?: @"") : @"";
    _title.text = hasTrack ? ([media nowPlayingTitle] ?: @"") : @"Музыка";
    // Альбом капителью с разрядкой, как подписи на стекле iOS 6
    NSString *album = hasTrack && [media respondsToSelector:@selector(nowPlayingAlbum)] ? [[media nowPlayingAlbum] uppercaseString] : nil;
    _album.attributedText = [[NSAttributedString alloc] initWithString:album ?: @""
                                                            attributes:@{NSKernAttributeName: @2, NSFontAttributeName: _album.font,
                                                                         NSForegroundColorAttributeName: _album.textColor}];
    _album.textAlignment = NSTextAlignmentCenter;
    _playPause.glyph = (hasTrack && [media isPlaying]) ? IRCCGlyphPause : IRCCGlyphPlay;
}

- (void)toggleTapped:(IRCCButton *)button {
    IRSetToggle((IRCCToggle)button.tag, !button.on);
    button.on = !button.on;
    // Часть переключателей применяется не сразу — сверяемся через мгновение
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refresh];
    });
}

- (void)brightnessChanged:(UISlider *)slider {
    IRSetBrightness(slider.value);
}

- (void)mediaTapped:(IRCCButton *)button {
    SBMediaController *media = [objc_getClass("SBMediaController") sharedInstance];
    if (button.tag == 0 && [media respondsToSelector:@selector(togglePlayPause)])
        [media togglePlayPause];
    else if (button.tag != 0 && [media respondsToSelector:@selector(changeTrack:)])
        [media changeTrack:(int)button.tag];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refresh];
    });
}

- (void)appTapped:(IRCCButton *)button {
    NSArray *apps = @[@"", @"com.apple.mobiletimer", @"com.apple.calculator", @"com.apple.camera"];
    if (self.onLaunch && button.tag > 0 && button.tag < (NSInteger)apps.count)
        self.onLaunch(apps[button.tag]);
}

@end

#pragma mark - Контроллер

static NSString *IRActivatorConstant(const char *name) {
    NSString *const *value = (NSString *const *)dlsym(RTLD_DEFAULT, name);
    return value ? *value : nil;
}

@interface IRCCController : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)showAnimated;
- (void)hideAnimated:(BOOL)animated completion:(void (^)(void))completion;
@property(nonatomic, readonly, getter=isVisible) BOOL visible;
@end

@implementation IRCCController {
    UIWindow *_window;
    UIView *_dim;
    IRCCPanel *_panel;
    NSTimer *_refreshTimer;
    CGFloat _panStartY;
}

+ (instancetype)shared {
    static IRCCController *controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        controller = [[IRCCController alloc] init];
    });
    return controller;
}

- (CGRect)screen {
    return [UIScreen mainScreen].bounds;
}

- (BOOL)isVisible {
    return _window && !_window.hidden;
}

- (void)buildWindow {
    if (_window)
        return;
    CGRect screen = [self screen];
    _window = [[UIWindow alloc] initWithFrame:screen];
    _window.windowLevel = kIRCCWindowLevel;
    _window.backgroundColor = [UIColor clearColor];

    _dim = [[UIView alloc] initWithFrame:screen];
    _dim.backgroundColor = [UIColor blackColor];
    _dim.alpha = 0;
    [_dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dimTapped)]];
    [_window addSubview:_dim];

    _panel = [[IRCCPanel alloc] initWithFrame:CGRectMake(0, screen.size.height, screen.size.width, kIRCCPanelHeight)];
    // Через синглтон, а не self: без цикла удержания и без __weak (на armv7 он требует таблиц SjLj)
    _panel.onLaunch = ^(NSString *identifier) {
        [[IRCCController shared] hideAnimated:YES completion:^{
            IRLaunch(identifier);
        }];
    };
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panelPan:)];
    pan.delegate = self;
    [_panel addGestureRecognizer:pan];
    [_window addSubview:_panel];
}

// Пан по панели не должен мешать ползункам
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    for (UIView *view = touch.view; view && view != _panel; view = view.superview)
        if ([view isKindOfClass:[UISlider class]] || [view isKindOfClass:[MPVolumeView class]])
            return NO;
    return YES;
}

- (void)setPanelOffset:(CGFloat)offset {
    // offset: 0 — закрыта, kIRCCPanelHeight — открыта полностью
    offset = MAX(0, MIN(kIRCCPanelHeight, offset));
    CGRect frame = _panel.frame;
    frame.origin.y = [self screen].size.height - offset;
    _panel.frame = frame;
    _dim.alpha = 0.4 * offset / kIRCCPanelHeight;
}

- (CGFloat)panelOffset {
    return [self screen].size.height - _panel.frame.origin.y;
}

- (void)showAnimated {
    if (self.visible)
        return;
    [self buildWindow];
    [_panel refresh];
    [self setPanelOffset:0];
    _window.hidden = NO;
    [_refreshTimer invalidate];
    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:_panel selector:@selector(refresh) userInfo:nil repeats:YES];
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        [self setPanelOffset:kIRCCPanelHeight];
    } completion:nil];
}

- (void)panelPan:(UIPanGestureRecognizer *)pan {
    CGFloat dy = [pan translationInView:_window].y;
    switch (pan.state) {
    case UIGestureRecognizerStateBegan:
        _panStartY = [self panelOffset];
        break;
    case UIGestureRecognizerStateChanged:
        [self setPanelOffset:_panStartY - dy];
        break;
    case UIGestureRecognizerStateEnded:
    case UIGestureRecognizerStateCancelled: {
        CGFloat velocity = [pan velocityInView:_window].y;
        if (velocity > 250 || (velocity > -250 && [self panelOffset] < kIRCCPanelHeight * 2 / 3)) {
            [self hideAnimated:YES completion:nil];
        } else {
            [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                [self setPanelOffset:kIRCCPanelHeight];
            } completion:nil];
        }
        break;
    }
    default:
        break;
    }
}

- (void)dimTapped {
    [self hideAnimated:YES completion:nil];
}

- (void)hideAnimated:(BOOL)animated completion:(void (^)(void))completion {
    [_refreshTimer invalidate];
    _refreshTimer = nil;
    void (^finish)(void) = ^{
        self->_window.hidden = YES;
        if (completion)
            completion();
    };
    if (!animated || !self.visible) {
        [self setPanelOffset:0];
        finish();
        return;
    }
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        [self setPanelOffset:0];
    } completion:^(BOOL done) {
        finish();
    }];
}

#pragma mark Activator

- (void)activator:(LAActivator *)activator receiveEvent:(LAEvent *)event forListenerName:(NSString *)listenerName {
    if (!IRBool(IRPrefsRead(), kIRControlCenter, YES))
        return;
    if (self.visible)
        [self hideAnimated:YES completion:nil];
    else
        [self showAnimated];
    event.handled = YES;
}

// «Домой», пока панель открыта, только закрывает её
- (void)activator:(LAActivator *)activator receiveDeactivateEvent:(LAEvent *)event {
    if (!self.visible)
        return;
    [self hideAnimated:YES completion:nil];
    event.handled = YES;
}

- (NSString *)activator:(LAActivator *)activator requiresLocalizedTitleForListenerName:(NSString *)listenerName {
    return @"Пункт управления";
}

- (NSString *)activator:(LAActivator *)activator requiresLocalizedDescriptionForListenerName:(NSString *)listenerName {
    return @"Переключатели, яркость, музыка и фонарик";
}

- (NSString *)activator:(LAActivator *)activator requiresLocalizedGroupForListenerName:(NSString *)listenerName {
    return @"iOS6Revive";
}

// Не на экране блокировки: оттуда запуск программ и переключатели без разблокировки ни к чему
- (NSArray *)activator:(LAActivator *)activator requiresCompatibleEventModesForListenerWithName:(NSString *)listenerName {
    NSString *springBoard = IRActivatorConstant("LAEventModeSpringBoard");
    NSString *application = IRActivatorConstant("LAEventModeApplication");
    return springBoard && application ? @[springBoard, application] : @[];
}

// Иконка — кнопка панели со знаком ползунков
- (UIImage *)activator:(LAActivator *)activator requiresIconForListenerName:(NSString *)listenerName scale:(CGFloat)scale {
    IRCCButton *button = [IRCCButton buttonWithGlyph:IRCCGlyphSliders style:IRCCButtonStyleSquare];
    button.frame = CGRectMake(0, 0, 29, 29);
    UIGraphicsBeginImageContextWithOptions(button.bounds.size, NO, scale);
    [button drawRect:button.bounds];
    UIImage *icon = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return icon;
}

- (UIImage *)activator:(LAActivator *)activator requiresSmallIconForListenerName:(NSString *)listenerName scale:(CGFloat)scale {
    return [self activator:activator requiresIconForListenerName:listenerName scale:scale];
}

@end

#pragma mark - SpringBoard

static LAActivator *IRActivator(void) {
    static BOOL loaded;
    if (!loaded) {
        loaded = YES;
        dlopen("/usr/lib/libactivator.dylib", RTLD_LAZY);
    }
    return [objc_getClass("LAActivator") sharedInstance];
}

// Один раз ставим Пункт управления на «Свайп вверх от низа» — если жест ещё ничем не занят.
// Флаг в настройках: если потом жест переназначат, второй раз не вмешиваемся.
static void IRAssignDefaultGesture(void) {
    if (IRBool(IRPrefsRead(), kIRCCActivatorDefaults, NO))
        return;
    LAActivator *activator = IRActivator();
    NSString *slide = IRActivatorConstant("LAEventNameSlideInFromBottom");
    NSString *springBoard = IRActivatorConstant("LAEventModeSpringBoard");
    NSString *application = IRActivatorConstant("LAEventModeApplication");
    Class eventClass = objc_getClass("LAEvent");
    if (!activator || !slide || !springBoard || !application || !eventClass)
        return;
    for (NSString *mode in @[springBoard, application]) {
        LAEvent *event = [eventClass eventWithName:slide mode:mode];
        if (![activator assignedListenerNameForEvent:event])
            [activator assignEvent:event toListenerWithName:kIRCCListener];
    }
    IRPrefsSet(kIRCCActivatorDefaults, @YES);
}

// Кнопка «Домой» при открытой панели только закрывает её (если Activator не сделал этого раньше)
static BOOL gSwallowMenuUp;

static void (*orig_menuButtonDown)(id, SEL, void *);
static void hook_menuButtonDown(id self, SEL _cmd, void *event) {
    if ([IRCCController shared].visible) {
        gSwallowMenuUp = YES;
        [[IRCCController shared] hideAnimated:YES completion:nil];
        return;
    }
    orig_menuButtonDown(self, _cmd, event);
}

static void (*orig_menuButtonUp)(id, SEL, void *);
static void hook_menuButtonUp(id self, SEL _cmd, void *event) {
    if (gSwallowMenuUp) {
        gSwallowMenuUp = NO;
        return;
    }
    orig_menuButtonUp(self, _cmd, event);
}

static void (*orig_finishLaunching)(id, SEL, id);
static void hook_finishLaunching(id self, SEL _cmd, id application) {
    orig_finishLaunching(self, _cmd, application);
    IRAssignDefaultGesture();
}

static void IRCCLockStateChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[IRCCController shared] hideAnimated:NO completion:nil];
    });
}

__attribute__((constructor)) static void IRControlCenterInit(void) {
    @autoreleasepool {
        if (!IRIsProcess(@"com.apple.springboard"))
            return;
        Class springBoard = objc_getClass("SpringBoard");
        IR_HOOK(springBoard, @selector(applicationDidFinishLaunching:), hook_finishLaunching, &orig_finishLaunching);
        IR_HOOK(springBoard, @selector(menuButtonDown:), hook_menuButtonDown, &orig_menuButtonDown);
        IR_HOOK(springBoard, @selector(menuButtonUp:), hook_menuButtonUp, &orig_menuButtonUp);
        IRObserveDarwin("com.apple.springboard.lockstate", IRCCLockStateChanged);
        LAActivator *activator = IRActivator();
        if ([activator respondsToSelector:@selector(registerListener:forName:)])
            [activator registerListener:[IRCCController shared] forName:kIRCCListener];
        else
            IRLog(@"Activator не найден: Пункт управления открыть нечем");
    }
}
