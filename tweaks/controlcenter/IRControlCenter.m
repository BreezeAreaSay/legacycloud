// Пункт управления (iOS 7) в стиле iOS 6: свайп вверх от нижнего края экрана.
//
// Панель — тёмный лён, как у панели многозадачности iOS 6. Внутри родные элементы iOS 6:
// ползунок UISlider и громкость MPVolumeView (с выбором вывода звука, например на AirPods).
//
// Жест: в SpringBoard iOS 6 нет открытого способа добавить свой системный жест, поэтому, как
// Activator, держим у нижнего края тонкое прозрачное окно SpringBoard поверх программ.
// На экране блокировки окна нет — там внизу слайдер и камера.
//
// Блокировку не берём из одного уведомления: при разблокировке SpringBoard iOS 6 шлёт
// com.apple.springboard.lockstate, пока -[SBAwayController isLocked] ещё отвечает YES (идёт анимация).
// Поэтому перепроверяем позже, при смене программы на экране и в самом начале жеста.

#import "IRShared.h"
#import "IRPrivate.h"
#import "IRCCDrawing.h"
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>

#define kIRControlCenter @"ControlCenter"

static const CGFloat kIRCCEdgeHeight = 8;
static const CGFloat kIRCCPanelHeight = 318;
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
- (BOOL)isPlaying;
- (BOOL)hasTrack;
@end

@interface SBAwayController : NSObject
+ (instancetype)sharedAwayController;
- (BOOL)isLocked;
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
    NSArray *_toggles;            // IRCCButton, tag = IRCCToggle
    UISlider *_brightness;
    UILabel *_title;
    UILabel *_artist;
    IRCCButton *_playPause;
}

static UIView *IRCCSeparator(CGFloat y, CGFloat width) {
    // Гравированная линия: тёмная и светлая под ней
    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(10, y, width - 20, 2)];
    line.userInteractionEnabled = NO;
    UIView *dark = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width - 20, 1)];
    dark.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    UIView *light = [[UIView alloc] initWithFrame:CGRectMake(0, 1, width - 20, 1)];
    light.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [line addSubview:dark];
    [line addSubview:light];
    return line;
}

static UILabel *IRCCLabel(CGRect frame, UIFont *font, UIColor *color) {
    UILabel *label = [[UILabel alloc] initWithFrame:frame];
    label.backgroundColor = [UIColor clearColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.font = font;
    label.textColor = color;
    label.shadowColor = [UIColor colorWithWhite:0 alpha:0.7];
    label.shadowOffset = CGSizeMake(0, -1);
    return label;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame]))
        return nil;
    CGFloat width = frame.size.width;
    self.backgroundColor = [UIColor scrollViewTexturedBackgroundColor];
    self.clipsToBounds = NO;

    // Тень сверху и светлый кант, как у панели многозадачности
    CAGradientLayer *shadow = [CAGradientLayer layer];
    shadow.frame = CGRectMake(0, -6, width, 6);
    shadow.colors = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor, (id)[UIColor colorWithWhite:0 alpha:0.45].CGColor];
    [self.layer addSublayer:shadow];
    UIView *edge = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 1)];
    edge.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    [self addSubview:edge];

    UIView *grabber = [[UIView alloc] initWithFrame:CGRectMake(width / 2 - 18, 8, 36, 5)];
    grabber.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    grabber.layer.cornerRadius = 2.5;
    grabber.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.1].CGColor;
    grabber.layer.borderWidth = 0.5;
    [self addSubview:grabber];

    // Переключатели
    const IRCCGlyph glyphs[] = {IRCCGlyphAirplane, IRCCGlyphWiFi, IRCCGlyphBluetooth, IRCCGlyphMoon, IRCCGlyphRotationLock};
    const IRCCToggle toggles[] = {IRCCAirplane, IRCCWiFi, IRCCBluetooth, IRCCDoNotDisturb, IRCCRotationLock};
    NSMutableArray *buttons = [NSMutableArray array];
    CGFloat gap = (width - 5 * 46) / 6;
    for (int i = 0; i < 5; i++) {
        IRCCButton *button = [IRCCButton buttonWithGlyph:glyphs[i]];
        button.tag = toggles[i];
        button.frame = CGRectMake(gap + i * (46 + gap), 22, 46, 46);
        [button addTarget:self action:@selector(toggleTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:button];
        [buttons addObject:button];
    }
    [self addSubview:IRCCSeparator(80, width)];

    // Яркость — родной ползунок iOS 6
    _brightness = [[UISlider alloc] initWithFrame:CGRectMake(16, 90, width - 32, 23)];
    _brightness.minimumValueImage = IRCCGlyphImage(IRCCGlyphSunSmall, 18, [UIColor colorWithWhite:1 alpha:0.75]);
    _brightness.maximumValueImage = IRCCGlyphImage(IRCCGlyphSunLarge, 22, [UIColor colorWithWhite:1 alpha:0.75]);
    [_brightness addTarget:self action:@selector(brightnessChanged:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:_brightness];
    [self addSubview:IRCCSeparator(124, width)];

    // Музыка
    _title = IRCCLabel(CGRectMake(20, 132, width - 40, 19), [UIFont boldSystemFontOfSize:15], [UIColor whiteColor]);
    _artist = IRCCLabel(CGRectMake(20, 150, width - 40, 17), [UIFont systemFontOfSize:13], [UIColor colorWithWhite:0.75 alpha:1]);
    [self addSubview:_title];
    [self addSubview:_artist];
    const IRCCGlyph mediaGlyphs[] = {IRCCGlyphPrevious, IRCCGlyphPlay, IRCCGlyphNext};
    for (int i = 0; i < 3; i++) {
        IRCCButton *button = [IRCCButton buttonWithGlyph:mediaGlyphs[i]];
        button.plain = YES;
        button.tag = i - 1; // -1 назад, 0 пауза, 1 вперёд
        button.frame = CGRectMake(width / 2 - 22 + (i - 1) * 80, 168, 44, 40);
        [button addTarget:self action:@selector(mediaTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:button];
        if (i == 1)
            _playPause = button;
    }
    MPVolumeView *volume = [[MPVolumeView alloc] initWithFrame:CGRectMake(20, 214, width - 40, 23)];
    [self addSubview:volume];
    [self addSubview:IRCCSeparator(246, width)];

    // Фонарик и быстрые программы
    const IRCCGlyph appGlyphs[] = {IRCCGlyphFlashlight, IRCCGlyphTimer, IRCCGlyphCalculator, IRCCGlyphCamera};
    gap = (width - 4 * 46) / 5;
    for (int i = 0; i < 4; i++) {
        IRCCButton *button = [IRCCButton buttonWithGlyph:appGlyphs[i]];
        button.tag = i;
        button.frame = CGRectMake(gap + i * (46 + gap), 258, 46, 46);
        [button addTarget:self action:@selector(appTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:button];
        if (i == 0) {
            button.tag = IRCCFlashlight;
            [button removeTarget:self action:@selector(appTapped:) forControlEvents:UIControlEventTouchUpInside];
            [button addTarget:self action:@selector(toggleTapped:) forControlEvents:UIControlEventTouchUpInside];
            [buttons addObject:button];
        }
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
    _title.text = hasTrack ? ([media nowPlayingTitle] ?: @"") : @"Музыка";
    _artist.text = hasTrack ? ([media nowPlayingArtist] ?: @"") : @"";
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

static BOOL IRCCLocked(void) {
    SBAwayController *away = [objc_getClass("SBAwayController") sharedAwayController];
    return [away respondsToSelector:@selector(isLocked)] && [away isLocked];
}

@interface IRCCController : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)updateEdge;
- (void)hideAnimated:(BOOL)animated completion:(void (^)(void))completion;
@property(nonatomic, readonly, getter=isVisible) BOOL visible;
@end

@implementation IRCCController {
    UIWindow *_edgeWindow;
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

- (void)updateEdge {
    BOOL enabled = IRBool(IRPrefsRead(), kIRControlCenter, YES);
    BOOL locked = IRCCLocked();
    if (!_edgeWindow) {
        CGRect screen = [self screen];
        _edgeWindow = [[UIWindow alloc] initWithFrame:CGRectMake(0, screen.size.height - kIRCCEdgeHeight, screen.size.width, kIRCCEdgeHeight)];
        _edgeWindow.windowLevel = kIRCCWindowLevel - 1;
        // Почти прозрачный фон: окно с совсем прозрачным фоном может не получать касания
        _edgeWindow.backgroundColor = [UIColor colorWithWhite:0 alpha:0.011];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(edgePan:)];
        [_edgeWindow addGestureRecognizer:pan];
    }
    // Полоску не прячем, пока открыта панель: её жест ещё может идти, а сама панель лежит выше
    BOOL hidden = !enabled || locked;
    if (_edgeWindow.hidden != hidden)
        IRLog(@"Пункт управления: полоска жеста %@ (включено: %d, блокировка: %d)", hidden ? @"скрыта" : @"видна", enabled, locked);
    _edgeWindow.hidden = hidden;
    if ((!enabled || locked) && self.visible)
        [self hideAnimated:NO completion:nil];
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
    _dim.alpha = 0.35 * offset / kIRCCPanelHeight;
}

- (CGFloat)panelOffset {
    return [self screen].size.height - _panel.frame.origin.y;
}

- (void)prepareToShow {
    [self buildWindow];
    [_panel refresh];
    _window.hidden = NO;
    [_refreshTimer invalidate];
    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:_panel selector:@selector(refresh) userInfo:nil repeats:YES];
}

- (void)settleWithVelocity:(CGFloat)velocity {
    BOOL open = velocity < -250 || (velocity < 250 && [self panelOffset] > kIRCCPanelHeight / 3);
    if (open) {
        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            [self setPanelOffset:kIRCCPanelHeight];
        } completion:nil];
    } else {
        [self hideAnimated:YES completion:nil];
    }
}

- (void)edgePan:(UIPanGestureRecognizer *)pan {
    CGFloat dy = [pan translationInView:pan.view].y;
    switch (pan.state) {
    case UIGestureRecognizerStateBegan:
        if (IRCCLocked()) {
            // Полоска осталась от разблокированного экрана: убираем её и гасим жест
            pan.enabled = NO;
            pan.enabled = YES;
            [self updateEdge];
            return;
        }
        [self prepareToShow];
        [self setPanelOffset:-dy];
        break;
    case UIGestureRecognizerStateChanged:
        [self setPanelOffset:-dy];
        break;
    case UIGestureRecognizerStateEnded:
        [self settleWithVelocity:[pan velocityInView:pan.view].y];
        break;
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed:
        [self hideAnimated:YES completion:nil];
        break;
    default:
        break;
    }
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
    case UIGestureRecognizerStateCancelled:
        [self settleWithVelocity:[pan velocityInView:_window].y];
        break;
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
        [self updateEdge];
        if (completion)
            completion();
    };
    if (!animated || !_window) {
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

@end

#pragma mark - SpringBoard

// Кнопка «Домой» при открытой панели только закрывает её
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
    [[IRCCController shared] updateEdge];
}

// Задержка в миллисекундах: целое число не тянет __fixdfdi, которого нет в заглушках armv7
static void IRCCUpdateEdgeLater(int64_t milliseconds) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, milliseconds * (int64_t)NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [[IRCCController shared] updateEdge];
    });
}

static void (*orig_frontDisplayDidChange)(id, SEL);
static void hook_frontDisplayDidChange(id self, SEL _cmd) {
    orig_frontDisplayDidChange(self, _cmd);
    IRCCUpdateEdgeLater(0);
}

static void IRCCStateChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    // Блокировка и разблокировка применяются не мгновенно, а с анимацией
    IRCCUpdateEdgeLater(0);
    IRCCUpdateEdgeLater(700);
    IRCCUpdateEdgeLater(2000);
}

__attribute__((constructor)) static void IRControlCenterInit(void) {
    @autoreleasepool {
        if (!IRIsProcess(@"com.apple.springboard"))
            return;
        Class springBoard = objc_getClass("SpringBoard");
        IR_HOOK(springBoard, @selector(applicationDidFinishLaunching:), hook_finishLaunching, &orig_finishLaunching);
        IR_HOOK(springBoard, @selector(menuButtonDown:), hook_menuButtonDown, &orig_menuButtonDown);
        IR_HOOK(springBoard, @selector(menuButtonUp:), hook_menuButtonUp, &orig_menuButtonUp);
        IR_HOOK(springBoard, @selector(frontDisplayDidChange), hook_frontDisplayDidChange, &orig_frontDisplayDidChange);
        IRObserveDarwin(IR_NOTIFY_PREFS, IRCCStateChanged);
        IRObserveDarwin("com.apple.springboard.lockstate", IRCCStateChanged);
    }
}
