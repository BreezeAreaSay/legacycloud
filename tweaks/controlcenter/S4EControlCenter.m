// Control Center (iOS 7) in iOS 6 style.
//
// iOS 7 layout with Auxo-like materials: grey linen with grooves between sections, square buttons
// in a grey bezel, blue gloss when on, music buttons as white embossed glyphs.
// The sliders are native: UISlider and the MPVolumeView volume slider (with audio output picking, e.g. AirPods),
// just with dark tracks, as in Auxo.
//
// The gesture comes from Activator: iOS 6 SpringBoard has no public way to add a custom system gesture,
// and a transparent window at the screen edge above apps gets no touches. Control Center is an
// Activator action; on first launch it assigns itself to "swipe up from the bottom" if that is free.
// libactivator is loaded via dlopen and its classes are looked up via objc_getClass, without linking.

#import "S4EShared.h"
#import "S4EPrivate.h"
#import "S4ECCDrawing.h"
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>

#define kS4EControlCenter @"ControlCenter"

#define kS4ECCActivatorEvents @"ControlCenterActivatorEvents"
#define kS4ECCListener @"com.skeuo4ever.controlcenter"

static const UIWindowLevel kS4ECCWindowLevel = 1050;

#pragma mark - iOS 6.1 SpringBoard private APIs

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

// Activator (libactivator): only what we use
@interface LAEvent : NSObject
+ (id)eventWithName:(NSString *)name mode:(NSString *)mode;
@property(nonatomic, getter=isHandled) BOOL handled;
@end

@interface LAActivator : NSObject
- (void)registerListener:(id)listener forName:(NSString *)name;
- (void)assignEvent:(LAEvent *)event toListenerWithName:(NSString *)listenerName;
- (NSString *)assignedListenerNameForEvent:(LAEvent *)event;
@end

@interface SBApplicationController (S4EControlCenter)
- (SBApplication *)applicationWithDisplayIdentifier:(NSString *)identifier;
@end

@interface UIApplication (S4EControlCenter)
- (int)activeInterfaceOrientation;
@end

@interface SBUIController (S4EControlCenter)
- (void)activateApplicationAnimated:(SBApplication *)application;
@end

#pragma mark - Toggles

typedef enum { S4ECCAirplane, S4ECCWiFi, S4ECCBluetooth, S4ECCDoNotDisturb, S4ECCRotationLock, S4ECCFlashlight } S4ECCToggle;

// Wi-Fi: SBWiFiManager if it exists, otherwise MobileWiFi directly
typedef void *S4EWiFiClientRef;
static S4EWiFiClientRef S4EWiFiClient(void) {
    static S4EWiFiClientRef client;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_LAZY);
        S4EWiFiClientRef (*create)(CFAllocatorRef, int) = handle ? (S4EWiFiClientRef (*)(CFAllocatorRef, int))dlsym(handle, "WiFiManagerClientCreate") : NULL;
        if (create)
            client = create(kCFAllocatorDefault, 0);
    });
    return client;
}

static BOOL S4EWiFiEnabled(void) {
    SBWiFiManager *manager = [objc_getClass("SBWiFiManager") sharedInstance];
    if ([manager respondsToSelector:@selector(wiFiEnabled)])
        return [manager wiFiEnabled];
    CFPropertyListRef (*copy)(S4EWiFiClientRef, CFStringRef) = (CFPropertyListRef (*)(S4EWiFiClientRef, CFStringRef))dlsym(RTLD_DEFAULT, "WiFiManagerClientCopyProperty");
    if (!copy || !S4EWiFiClient())
        return NO;
    CFPropertyListRef value = copy(S4EWiFiClient(), CFSTR("AllowEnable"));
    BOOL enabled = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)value);
    if (value)
        CFRelease(value);
    return enabled;
}

static void S4ESetWiFiEnabled(BOOL enabled) {
    SBWiFiManager *manager = [objc_getClass("SBWiFiManager") sharedInstance];
    if ([manager respondsToSelector:@selector(setWiFiEnabled:)]) {
        [manager setWiFiEnabled:enabled];
        return;
    }
    void (*set)(S4EWiFiClientRef, CFStringRef, CFPropertyListRef) = (void (*)(S4EWiFiClientRef, CFStringRef, CFPropertyListRef))dlsym(RTLD_DEFAULT, "WiFiManagerClientSetProperty");
    if (set && S4EWiFiClient())
        set(S4EWiFiClient(), CFSTR("AllowEnable"), enabled ? kCFBooleanTrue : kCFBooleanFalse);
}

static BluetoothManager *S4EBluetooth(void) {
    Class cls = objc_getClass("BluetoothManager");
    if (!cls) {
        dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_LAZY);
        cls = objc_getClass("BluetoothManager");
    }
    return [cls sharedInstance];
}

static BBSettingsGateway *S4ESettingsGateway(void) {
    static BBSettingsGateway *gateway;
    if (!gateway)
        gateway = [[objc_getClass("BBSettingsGateway") alloc] init];
    return gateway;
}

static AVCaptureSession *gTorchSession;

static AVCaptureDevice *S4ETorchDevice(void) {
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    return [device hasTorch] ? device : nil;
}

static void S4ESetTorch(BOOL on) {
    AVCaptureDevice *device = S4ETorchDevice();
    if (!device)
        return;
    // Without a running camera session the torch turns itself off on older iOS
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

static BOOL S4EToggleState(S4ECCToggle toggle) {
    switch (toggle) {
    case S4ECCAirplane: {
        SBTelephonyManager *telephony = [objc_getClass("SBTelephonyManager") sharedTelephonyManager];
        return [telephony respondsToSelector:@selector(isInAirplaneMode)] && [telephony isInAirplaneMode];
    }
    case S4ECCWiFi:
        return S4EWiFiEnabled();
    case S4ECCBluetooth: {
        BluetoothManager *bluetooth = S4EBluetooth();
        return [bluetooth respondsToSelector:@selector(powered)] && [bluetooth powered];
    }
    case S4ECCDoNotDisturb: {
        SBBulletinSystemStateAdapter *adapter = [objc_getClass("SBBulletinSystemStateAdapter") sharedInstance];
        return [adapter respondsToSelector:@selector(quietModeEnabled)] && [adapter quietModeEnabled];
    }
    case S4ECCRotationLock: {
        SBOrientationLockManager *manager = [objc_getClass("SBOrientationLockManager") sharedInstance];
        return [manager respondsToSelector:@selector(isLocked)] && [manager isLocked];
    }
    case S4ECCFlashlight:
        return S4ETorchDevice().torchMode == AVCaptureTorchModeOn;
    }
    return NO;
}

static void S4ESetToggle(S4ECCToggle toggle, BOOL on) {
    switch (toggle) {
    case S4ECCAirplane: {
        SBTelephonyManager *telephony = [objc_getClass("SBTelephonyManager") sharedTelephonyManager];
        if ([telephony respondsToSelector:@selector(setIsInAirplaneMode:)])
            [telephony setIsInAirplaneMode:on];
        break;
    }
    case S4ECCWiFi:
        S4ESetWiFiEnabled(on);
        break;
    case S4ECCBluetooth: {
        BluetoothManager *bluetooth = S4EBluetooth();
        if ([bluetooth respondsToSelector:@selector(setPowered:)])
            [bluetooth setPowered:on];
        if ([bluetooth respondsToSelector:@selector(setEnabled:)])
            [bluetooth setEnabled:on];
        break;
    }
    case S4ECCDoNotDisturb: {
        BBSettingsGateway *gateway = S4ESettingsGateway();
        if ([gateway respondsToSelector:@selector(setBehaviorOverrideStatus:)])
            [gateway setBehaviorOverrideStatus:on ? 1 : 0];
        break;
    }
    case S4ECCRotationLock: {
        SBOrientationLockManager *manager = [objc_getClass("SBOrientationLockManager") sharedInstance];
        if (on && [manager respondsToSelector:@selector(lock)])
            [manager lock];
        else if (!on && [manager respondsToSelector:@selector(unlock)])
            [manager unlock];
        break;
    }
    case S4ECCFlashlight:
        S4ESetTorch(on);
        break;
    }
}

static void S4ESetBrightness(float level) {
    SBBrightnessController *controller = [objc_getClass("SBBrightnessController") sharedBrightnessController];
    if ([controller respondsToSelector:@selector(_setBrightnessLevel:showHUD:)])
        [controller _setBrightnessLevel:level showHUD:NO];
    else
        [UIScreen mainScreen].brightness = level;
}

static void S4ELaunch(NSString *identifier) {
    SBApplicationController *apps = [objc_getClass("SBApplicationController") sharedInstance];
    SBApplication *app = [apps respondsToSelector:@selector(applicationWithDisplayIdentifier:)] ? [apps applicationWithDisplayIdentifier:identifier] : nil;
    SBUIController *ui = [objc_getClass("SBUIController") sharedInstance];
    if (app && [ui respondsToSelector:@selector(activateApplicationAnimated:)])
        [ui activateApplicationAnimated:app];
}

#pragma mark - Panel

@interface S4ECCPanel : UIView
@property(nonatomic, copy) void (^onLaunch)(NSString *identifier);
+ (CGFloat)heightForLandscape:(BOOL)landscape;
- (instancetype)initWithFrame:(CGRect)frame landscape:(BOOL)landscape;
- (void)refresh;
@end

@implementation S4ECCPanel {
    NSArray *_toggles;
    NSArray *_switches;
    NSArray *_media;
    NSArray *_apps;
    UISlider *_brightness;
    MPVolumeView *_volume;
    UILabel *_artist;
    UILabel *_title;
    UILabel *_album;
    S4ECCButton *_playPause;
    BOOL _landscape;
}

static UILabel *S4ECCLabel(void) {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.backgroundColor = [UIColor clearColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.shadowColor = [UIColor colorWithWhite:0 alpha:0.8];
    label.shadowOffset = CGSizeMake(0, -1);
    return label;
}

static S4ECCButton *S4ECCMakeButton(S4ECCGlyph glyph, S4ECCButtonStyle style, NSInteger tag, id target, SEL action) {
    S4ECCButton *button = [S4ECCButton buttonWithGlyph:glyph style:style];
    button.tag = tag;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

// A row of identical buttons with equal gaps inside rect
static void S4ECCLayoutRow(NSArray *buttons, CGRect rect, CGFloat size) {
    CGFloat gap = (rect.size.width - buttons.count * size) / (buttons.count + 1);
    [buttons enumerateObjectsUsingBlock:^(UIView *button, NSUInteger i, BOOL *stop) {
        button.frame = CGRectMake(rect.origin.x + gap + i * (size + gap), rect.origin.y, size, size);
    }];
}

+ (CGFloat)heightForLandscape:(BOOL)landscape {
    return landscape ? 120 : 356;
}

- (instancetype)initWithFrame:(CGRect)frame landscape:(BOOL)landscape {
    if (!(self = [super initWithFrame:frame]))
        return nil;
    CGFloat width = frame.size.width;
    _landscape = landscape;
    self.backgroundColor = S4ECCLinenColor();
    self.clipsToBounds = NO;

    // Shadow on top and a light edge
    CAGradientLayer *shadow = [CAGradientLayer layer];
    shadow.frame = CGRectMake(0, -6, width, 6);
    shadow.colors = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor, (id)[UIColor colorWithWhite:0 alpha:0.5].CGColor];
    [self.layer addSublayer:shadow];
    UIView *edge = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 1)];
    edge.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
    [self addSubview:edge];

    // Grabber: the panel can be pulled down
    UIView *grabber = [[UIView alloc] initWithFrame:CGRectMake(width / 2 - 18, 6, 36, 5)];
    grabber.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    grabber.layer.cornerRadius = 2.5;
    grabber.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
    grabber.layer.borderWidth = 0.5;
    [self addSubview:grabber];

    // Toggles
    const S4ECCGlyph glyphs[] = {S4ECCGlyphAirplane, S4ECCGlyphWiFi, S4ECCGlyphBluetooth, S4ECCGlyphMoon, S4ECCGlyphRotationLock};
    const S4ECCToggle toggles[] = {S4ECCAirplane, S4ECCWiFi, S4ECCBluetooth, S4ECCDoNotDisturb, S4ECCRotationLock};
    NSMutableArray *switches = [NSMutableArray array];
    for (int i = 0; i < 5; i++)
        [switches addObject:S4ECCMakeButton(glyphs[i], S4ECCButtonStyleSquare, toggles[i], self, @selector(toggleTapped:))];
    _switches = switches;

    // Brightness: the native iOS 6 slider
    _brightness = [[UISlider alloc] initWithFrame:CGRectZero];
    _brightness.minimumValueImage = S4ECCGlyphImage(S4ECCGlyphSunSmall, 18, [UIColor colorWithWhite:1 alpha:0.8]);
    _brightness.maximumValueImage = S4ECCGlyphImage(S4ECCGlyphSunLarge, 22, [UIColor colorWithWhite:1 alpha:0.8]);
    [_brightness setMinimumTrackImage:S4ECCTrackImage(YES) forState:UIControlStateNormal];
    [_brightness setMaximumTrackImage:S4ECCTrackImage(NO) forState:UIControlStateNormal];
    [_brightness addTarget:self action:@selector(brightnessChanged:) forControlEvents:UIControlEventValueChanged];

    // Music: artist, title, album and white embossed buttons
    _artist = S4ECCLabel();
    _artist.textColor = [UIColor colorWithWhite:0.62 alpha:1];
    _title = S4ECCLabel();
    _title.textColor = [UIColor whiteColor];
    _album = S4ECCLabel();
    _album.textColor = [UIColor colorWithWhite:0.62 alpha:1];
    const S4ECCGlyph mediaGlyphs[] = {S4ECCGlyphPrevious, S4ECCGlyphPlay, S4ECCGlyphNext};
    NSMutableArray *media = [NSMutableArray array];
    for (int i = 0; i < 3; i++) // tag: -1 previous, 0 play/pause, 1 next
        [media addObject:S4ECCMakeButton(mediaGlyphs[i], S4ECCButtonStylePlain, i - 1, self, @selector(mediaTapped:))];
    _media = media;
    _playPause = media[1];
    _volume = [[MPVolumeView alloc] initWithFrame:CGRectZero];
    if ([_volume respondsToSelector:@selector(setMinimumVolumeSliderImage:forState:)]) {
        [_volume setMinimumVolumeSliderImage:S4ECCTrackImage(YES) forState:UIControlStateNormal];
        [_volume setMaximumVolumeSliderImage:S4ECCTrackImage(NO) forState:UIControlStateNormal];
    }

    // Flashlight and quick-launch apps
    S4ECCButton *flashlight = S4ECCMakeButton(S4ECCGlyphFlashlight, S4ECCButtonStyleSquare, S4ECCFlashlight, self, @selector(toggleTapped:));
    _apps = @[flashlight,
              S4ECCMakeButton(S4ECCGlyphTimer, S4ECCButtonStyleSquare, 1, self, @selector(appTapped:)),
              S4ECCMakeButton(S4ECCGlyphCalculator, S4ECCButtonStyleSquare, 2, self, @selector(appTapped:)),
              S4ECCMakeButton(S4ECCGlyphCamera, S4ECCButtonStyleSquare, 3, self, @selector(appTapped:))];
    _toggles = [switches arrayByAddingObject:flashlight];

    for (UIView *view in [[[[_switches arrayByAddingObjectsFromArray:_media] arrayByAddingObjectsFromArray:_apps]
                             arrayByAddingObjectsFromArray:@[_brightness, _volume]] arrayByAddingObjectsFromArray:@[_artist, _title, _album]])
        [self addSubview:view];

    if (landscape)
        [self layoutLandscape:width];
    else
        [self layoutPortrait:width];
    return self;
}

// Portrait, as in iOS 7: everything in one column, sections separated by grooves, as in Auxo
- (void)layoutPortrait:(CGFloat)width {
    S4ECCLayoutRow(_switches, CGRectMake(0, 20, width, 52), 52);
    _brightness.frame = CGRectMake(16, 86, width - 32, 23);
    [self addSubview:S4ECCGroove(CGRectMake(10, 120, width - 20, 2))];
    _artist.font = [UIFont boldSystemFontOfSize:13];
    _artist.frame = CGRectMake(20, 129, width - 40, 16);
    _title.font = [UIFont boldSystemFontOfSize:18];
    _title.frame = CGRectMake(20, 145, width - 40, 22);
    _album.font = [UIFont boldSystemFontOfSize:11];
    _album.frame = CGRectMake(20, 168, width - 40, 15);
    [_media enumerateObjectsUsingBlock:^(UIView *button, NSUInteger i, BOOL *stop) {
        button.frame = CGRectMake(width / 2 - 30 + ((int)i - 1) * 80, 188, 60, 44);
    }];
    _volume.frame = CGRectMake(20, 238, width - 40, 23);
    [self addSubview:S4ECCGroove(CGRectMake(10, 272, width - 20, 2))];
    S4ECCLayoutRow(_apps, CGRectMake(0, 284, width, 58), 58);
}

// Landscape, like iOS 7 on iPad: music, toggles and apps in a single row on top,
// an "artist — song" line under the music, volume on the left and brightness on the right at the bottom
- (void)layoutLandscape:(CGFloat)width {
    CGFloat music = 142, switches = 190, apps = width - music - switches;
    [_media enumerateObjectsUsingBlock:^(UIView *button, NSUInteger i, BOOL *stop) {
        button.frame = CGRectMake(music / 2 - 20 + ((int)i - 1) * 44, 16, 40, 32);
    }];
    _title.font = [UIFont boldSystemFontOfSize:12];
    _title.frame = CGRectMake(6, 52, music - 12, 15);
    _title.lineBreakMode = NSLineBreakByTruncatingTail;
    _artist.hidden = YES;
    _album.hidden = YES;
    S4ECCLayoutRow(_switches, CGRectMake(music, 16, switches, 32), 32);
    S4ECCLayoutRow(_apps, CGRectMake(music + switches, 16, apps, 32), 32);
    [self addSubview:S4ECCGroove(CGRectMake(10, 74, width - 20, 2))];
    _volume.frame = CGRectMake(12, 85, width / 2 - 18, 23);
    _brightness.frame = CGRectMake(width / 2 + 6, 85, width / 2 - 18, 23);
}

- (void)refresh {
    for (S4ECCButton *button in _toggles)
        button.on = S4EToggleState((S4ECCToggle)button.tag);
    if (!_brightness.tracking)
        _brightness.value = [UIScreen mainScreen].brightness;

    SBMediaController *media = [objc_getClass("SBMediaController") sharedInstance];
    BOOL hasTrack = [media respondsToSelector:@selector(hasTrack)] && [media hasTrack];
    NSString *artist = hasTrack ? ([media nowPlayingArtist] ?: @"") : @"";
    NSString *title = hasTrack ? ([media nowPlayingTitle] ?: @"") : S4E_L(@"Music", @"Музыка");
    _playPause.glyph = (hasTrack && [media isPlaying]) ? S4ECCGlyphPause : S4ECCGlyphPlay;
    if (_landscape) {
        // One line: artist in grey, song in white
        NSMutableAttributedString *line = [[NSMutableAttributedString alloc] init];
        if (artist.length)
            [line appendAttributedString:[[NSAttributedString alloc] initWithString:[artist stringByAppendingString:@" "]
                                                                         attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12],
                                                                                      NSForegroundColorAttributeName: [UIColor colorWithWhite:0.62 alpha:1]}]];
        [line appendAttributedString:[[NSAttributedString alloc] initWithString:title
                                                                     attributes:@{NSFontAttributeName: _title.font,
                                                                                  NSForegroundColorAttributeName: [UIColor whiteColor]}]];
        _title.attributedText = line;
        _title.textAlignment = NSTextAlignmentCenter;
        _title.lineBreakMode = NSLineBreakByTruncatingTail;
        return;
    }
    _artist.text = artist;
    _title.text = title;
    // Album in letter-spaced capitals, like captions on iOS 6 glass
    NSString *album = hasTrack && [media respondsToSelector:@selector(nowPlayingAlbum)] ? [[media nowPlayingAlbum] uppercaseString] : nil;
    _album.attributedText = [[NSAttributedString alloc] initWithString:album ?: @""
                                                            attributes:@{NSKernAttributeName: @2, NSFontAttributeName: _album.font,
                                                                         NSForegroundColorAttributeName: _album.textColor}];
    _album.textAlignment = NSTextAlignmentCenter;
}

- (void)toggleTapped:(S4ECCButton *)button {
    S4ESetToggle((S4ECCToggle)button.tag, !button.on);
    button.on = !button.on;
    // Some toggles don't apply right away, so check again a moment later
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refresh];
    });
}

- (void)brightnessChanged:(UISlider *)slider {
    S4ESetBrightness(slider.value);
}

- (void)mediaTapped:(S4ECCButton *)button {
    SBMediaController *media = [objc_getClass("SBMediaController") sharedInstance];
    if (button.tag == 0 && [media respondsToSelector:@selector(togglePlayPause)])
        [media togglePlayPause];
    else if (button.tag != 0 && [media respondsToSelector:@selector(changeTrack:)])
        [media changeTrack:(int)button.tag];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refresh];
    });
}

- (void)appTapped:(S4ECCButton *)button {
    NSArray *apps = @[@"", @"com.apple.mobiletimer", @"com.apple.calculator", @"com.apple.camera"];
    if (self.onLaunch && button.tag > 0 && button.tag < (NSInteger)apps.count)
        self.onLaunch(apps[button.tag]);
}

@end

#pragma mark - Controller

static NSString *S4EActivatorConstant(const char *name) {
    NSString *const *value = (NSString *const *)dlsym(RTLD_DEFAULT, name);
    return value ? *value : nil;
}

@interface S4ECCController : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)showAnimated;
- (void)hideAnimated:(BOOL)animated completion:(void (^)(void))completion;
@property(nonatomic, readonly, getter=isVisible) BOOL visible;
@end

@implementation S4ECCController {
    UIWindow *_window;
    UIView *_dim;
    S4ECCPanel *_panel;
    NSTimer *_refreshTimer;
    CGFloat _panStartY;
    UIView *_root;
    BOOL _landscape;
}

+ (instancetype)shared {
    static S4ECCController *controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        controller = [[S4ECCController alloc] init];
    });
    return controller;
}

- (CGRect)screen {
    return [UIScreen mainScreen].bounds;
}

- (BOOL)isVisible {
    return _window && !_window.hidden;
}

// SpringBoard windows don't rotate by themselves: rotate the content to match the app on screen.
// _root is the screen in the app's orientation; the dimming view and the panel live in its coordinates.
- (void)buildWindowForOrientation:(UIInterfaceOrientation)orientation {
    CGRect screen = [self screen];
    if (!_window) {
        _window = [[UIWindow alloc] initWithFrame:screen];
        _window.windowLevel = kS4ECCWindowLevel;
        _window.backgroundColor = [UIColor clearColor];
        _root = [[UIView alloc] initWithFrame:screen];
        [_window addSubview:_root];
        _dim = [[UIView alloc] initWithFrame:screen];
        _dim.backgroundColor = [UIColor blackColor];
        _dim.alpha = 0;
        [_dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dimTapped)]];
        [_root addSubview:_dim];
    }

    BOOL landscape = UIInterfaceOrientationIsLandscape(orientation);
    CGFloat angle = orientation == UIInterfaceOrientationLandscapeLeft ? -M_PI_2
                  : orientation == UIInterfaceOrientationLandscapeRight ? M_PI_2
                  : orientation == UIInterfaceOrientationPortraitUpsideDown ? M_PI : 0;
    _root.transform = CGAffineTransformIdentity;
    _root.bounds = landscape ? CGRectMake(0, 0, screen.size.height, screen.size.width) : CGRectMake(0, 0, screen.size.width, screen.size.height);
    _root.center = CGPointMake(CGRectGetMidX(screen), CGRectGetMidY(screen));
    _root.transform = CGAffineTransformMakeRotation(angle);
    _dim.frame = _root.bounds;

    if (_panel && _landscape == landscape)
        return;
    [_panel removeFromSuperview];
    _landscape = landscape;
    CGSize size = _root.bounds.size;
    _panel = [[S4ECCPanel alloc] initWithFrame:CGRectMake(0, size.height, size.width, [S4ECCPanel heightForLandscape:landscape])
                                    landscape:landscape];
    // Via the singleton rather than self: no retain cycle and no __weak (on armv7 it needs SjLj tables)
    _panel.onLaunch = ^(NSString *identifier) {
        [[S4ECCController shared] hideAnimated:YES completion:^{
            S4ELaunch(identifier);
        }];
    };
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panelPan:)];
    pan.delegate = self;
    [_panel addGestureRecognizer:pan];
    [_root addSubview:_panel];
}

- (CGFloat)panelHeight {
    return _panel.frame.size.height;
}

// Panning the panel must not get in the way of the sliders
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    for (UIView *view = touch.view; view && view != _panel; view = view.superview)
        if ([view isKindOfClass:[UISlider class]] || [view isKindOfClass:[MPVolumeView class]])
            return NO;
    return YES;
}

- (void)setPanelOffset:(CGFloat)offset {
    // offset: 0 is closed, the panel height is fully open
    CGFloat height = [self panelHeight];
    offset = MAX(0, MIN(height, offset));
    CGRect frame = _panel.frame;
    frame.origin.y = _root.bounds.size.height - offset;
    _panel.frame = frame;
    _dim.alpha = height > 0 ? 0.4 * offset / height : 0;
}

- (CGFloat)panelOffset {
    return _root.bounds.size.height - _panel.frame.origin.y;
}

- (void)showAnimated {
    if (self.visible)
        return;
    UIApplication *springBoard = [UIApplication sharedApplication];
    UIInterfaceOrientation orientation = [springBoard respondsToSelector:@selector(activeInterfaceOrientation)]
        ? (UIInterfaceOrientation)[springBoard activeInterfaceOrientation] : UIInterfaceOrientationPortrait;
    [self buildWindowForOrientation:orientation];
    [_panel refresh];
    [self setPanelOffset:0];
    _window.hidden = NO;
    [_refreshTimer invalidate];
    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:_panel selector:@selector(refresh) userInfo:nil repeats:YES];
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        [self setPanelOffset:[self panelHeight]];
    } completion:nil];
}

- (void)panelPan:(UIPanGestureRecognizer *)pan {
    CGFloat dy = [pan translationInView:_root].y;
    switch (pan.state) {
    case UIGestureRecognizerStateBegan:
        _panStartY = [self panelOffset];
        break;
    case UIGestureRecognizerStateChanged:
        [self setPanelOffset:_panStartY - dy];
        break;
    case UIGestureRecognizerStateEnded:
    case UIGestureRecognizerStateCancelled: {
        CGFloat velocity = [pan velocityInView:_root].y;
        if (velocity > 250 || (velocity > -250 && [self panelOffset] < [self panelHeight] * 2 / 3)) {
            [self hideAnimated:YES completion:nil];
        } else {
            [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                [self setPanelOffset:[self panelHeight]];
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
    if (!S4EBool(S4EPrefsRead(), kS4EControlCenter, YES))
        return;
    if (self.visible)
        [self hideAnimated:YES completion:nil];
    else
        [self showAnimated];
    event.handled = YES;
}

// Home while the panel is open only closes it
- (void)activator:(LAActivator *)activator receiveDeactivateEvent:(LAEvent *)event {
    if (!self.visible)
        return;
    [self hideAnimated:YES completion:nil];
    event.handled = YES;
}

- (NSString *)activator:(LAActivator *)activator requiresLocalizedTitleForListenerName:(NSString *)listenerName {
    return S4E_L(@"Control Center", @"Пункт управления");
}

- (NSString *)activator:(LAActivator *)activator requiresLocalizedDescriptionForListenerName:(NSString *)listenerName {
    return S4E_L(@"Toggles, brightness, music and flashlight", @"Переключатели, яркость, музыка и фонарик");
}

- (NSString *)activator:(LAActivator *)activator requiresLocalizedGroupForListenerName:(NSString *)listenerName {
    return @"Skeuo4Ever";
}

// Not on the lock screen: launching apps and flipping toggles from there without unlocking makes no sense
- (NSArray *)activator:(LAActivator *)activator requiresCompatibleEventModesForListenerWithName:(NSString *)listenerName {
    NSString *springBoard = S4EActivatorConstant("LAEventModeSpringBoard");
    NSString *application = S4EActivatorConstant("LAEventModeApplication");
    return springBoard && application ? @[springBoard, application] : @[];
}

// Icon: a panel button with the sliders glyph
- (UIImage *)activator:(LAActivator *)activator requiresIconForListenerName:(NSString *)listenerName scale:(CGFloat)scale {
    S4ECCButton *button = [S4ECCButton buttonWithGlyph:S4ECCGlyphSliders style:S4ECCButtonStyleSquare];
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

static LAActivator *S4EActivator(void) {
    static BOOL loaded;
    if (!loaded) {
        loaded = YES;
        dlopen("/usr/lib/libactivator.dylib", RTLD_LAZY);
    }
    return [objc_getClass("LAActivator") sharedInstance];
}

// Assign Control Center to "swipe up from the bottom" on the left, in the center and on the right: each gesture
// only if nothing uses it yet, and each only once. The list of already assigned ones is kept in settings,
// so a gesture the user reassigns later is never touched again, while new default gestures still reach
// existing installs.
static void S4EAssignDefaultGestures(void) {
    LAActivator *activator = S4EActivator();
    NSString *springBoard = S4EActivatorConstant("LAEventModeSpringBoard");
    NSString *application = S4EActivatorConstant("LAEventModeApplication");
    Class eventClass = objc_getClass("LAEvent");
    if (!activator || !springBoard || !application || !eventClass)
        return;
    NSArray *done = S4EPrefsRead()[kS4ECCActivatorEvents];
    NSMutableArray *handled = [done isKindOfClass:[NSArray class]] ? [done mutableCopy] : [NSMutableArray array];
    BOOL changed = NO;
    for (NSString *constant in @[@"LAEventNameSlideInFromBottom", @"LAEventNameSlideInFromBottomLeft", @"LAEventNameSlideInFromBottomRight"]) {
        NSString *name = S4EActivatorConstant(constant.UTF8String);
        if (!name || [handled containsObject:name])
            continue;
        for (NSString *mode in @[springBoard, application]) {
            LAEvent *event = [eventClass eventWithName:name mode:mode];
            if (![activator assignedListenerNameForEvent:event])
                [activator assignEvent:event toListenerWithName:kS4ECCListener];
        }
        [handled addObject:name];
        changed = YES;
    }
    if (changed)
        S4EPrefsSet(kS4ECCActivatorEvents, handled);
}

// The Home button only closes the panel while it is open (unless Activator has already done that)
static BOOL gSwallowMenuUp;

static void (*orig_menuButtonDown)(id, SEL, void *);
static void hook_menuButtonDown(id self, SEL _cmd, void *event) {
    if ([S4ECCController shared].visible) {
        gSwallowMenuUp = YES;
        [[S4ECCController shared] hideAnimated:YES completion:nil];
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
    S4EAssignDefaultGestures();
}

static void S4ECCLockStateChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[S4ECCController shared] hideAnimated:NO completion:nil];
    });
}

__attribute__((constructor)) static void S4EControlCenterInit(void) {
    @autoreleasepool {
        if (!S4EIsProcess(@"com.apple.springboard"))
            return;
        Class springBoard = objc_getClass("SpringBoard");
        S4E_HOOK(springBoard, @selector(applicationDidFinishLaunching:), hook_finishLaunching, &orig_finishLaunching);
        S4E_HOOK(springBoard, @selector(menuButtonDown:), hook_menuButtonDown, &orig_menuButtonDown);
        S4E_HOOK(springBoard, @selector(menuButtonUp:), hook_menuButtonUp, &orig_menuButtonUp);
        S4EObserveDarwin("com.apple.springboard.lockstate", S4ECCLockStateChanged);
        LAActivator *activator = S4EActivator();
        if ([activator respondsToSelector:@selector(registerListener:forName:)])
            [activator registerListener:[S4ECCController shared] forName:kS4ECCListener];
        else
            S4ELog(@"Activator not found: nothing can open Control Center");
    }
}
