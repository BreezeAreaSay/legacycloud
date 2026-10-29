// Camera timer (iOS 8), built the iOS 6 way.
//
// A timer button sits under the switch-camera button in the Camera's top bar: the same translucent dark
// capsule as the flash button, built on Camera's own PLReorientingButton so it turns with the device.
// Each tap goes Off → 3 s → 10 s. With a delay set, the shutter (on screen or the volume button) starts
// a countdown: a big embossed digit on a dark translucent square, like the iOS 6 volume HUD, with a tick
// every second. Pressing the shutter again cancels it. Photos only: video and panorama are untouched.

#import "S4EShared.h"
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>

#define kS4ECameraTimer @"CameraTimer"            // the feature switch
#define kS4ECameraTimerDelay @"CameraTimerDelay"  // the chosen delay: 0, 3 or 10 seconds

static const NSInteger kS4ETimerButtonTag = 0x7133;

@interface PLCameraView : UIView
@property(nonatomic) int cameraMode; // 0: photo
- (UIView *)_toggleButton;
@end

@interface UIButton (S4ECameraTimer)
- (void)setAutorotationEnabled:(BOOL)enabled;
- (void)startWatchingDeviceOrientationChanges;
- (void)stopWatchingDeviceOrientationChanges;
- (CGAffineTransform)transformForOrientation:(int)orientation;
@end

static BOOL S4ETimerEnabled(NSDictionary *prefs) {
    return S4EBool(prefs, kS4ECameraTimer, YES);
}

static NSInteger S4ETimerDelay(NSDictionary *prefs) {
    NSInteger delay = (NSInteger)S4EDouble(prefs, kS4ECameraTimerDelay, 0);
    return delay == 3 || delay == 10 ? delay : 0;
}

static void S4EPlaySound(uint32_t sound) {
    void (*play)(uint32_t) = (void (*)(uint32_t))dlsym(RTLD_DEFAULT, "AudioServicesPlaySystemSound");
    if (play)
        play(sound);
}

#pragma mark - Drawing

// The capsule behind Camera's top bar buttons: dark glass with a thin light rim
static UIImage *S4ECapsuleImage(CGFloat height) {
    CGSize size = CGSizeMake(height + 2, height);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    UIBezierPath *capsule = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(CGRectMake(0, 0, size.width, size.height), 0.5, 0.5)
                                                       cornerRadius:height / 2 - 0.5];
    [[UIColor colorWithWhite:0 alpha:0.45] setFill];
    [capsule fill];
    [[UIColor colorWithWhite:1 alpha:0.28] setStroke];
    capsule.lineWidth = 1;
    [capsule stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    CGFloat cap = height / 2;
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(0, cap, 0, cap)];
}

// A stopwatch, drawn white
static UIImage *S4EStopwatchImage(void) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(18, 18), NO, 0);
    [[UIColor whiteColor] set];
    UIBezierPath *face = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(2, 3.5, 13, 13)];
    face.lineWidth = 1.8;
    [face stroke];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(6.5, 0.5, 4, 2) cornerRadius:0.8] fill];
    UIBezierPath *hand = [UIBezierPath bezierPath];
    [hand moveToPoint:CGPointMake(8.5, 10)];
    [hand addLineToPoint:CGPointMake(8.5, 6)];
    [hand moveToPoint:CGPointMake(8.5, 10)];
    [hand addLineToPoint:CGPointMake(11.5, 11.5)];
    hand.lineWidth = 1.6;
    hand.lineCapStyle = kCGLineCapRound;
    [hand stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static NSString *S4EDelayTitle(NSInteger delay) {
    return delay ? [NSString stringWithFormat:S4E_L(@" %lds", @" %ld с"), (long)delay] : nil;
}

#pragma mark - Countdown

// A big digit on a dark translucent square, like the iOS 6 volume HUD
@interface S4ECountdownView : UIView
@property(nonatomic, strong) UILabel *digit;
@end

@implementation S4ECountdownView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
        self.layer.cornerRadius = 12;
        _digit = [[UILabel alloc] initWithFrame:self.bounds];
        _digit.backgroundColor = [UIColor clearColor];
        _digit.textAlignment = NSTextAlignmentCenter;
        _digit.font = [UIFont boldSystemFontOfSize:96];
        _digit.textColor = [UIColor whiteColor];
        _digit.shadowColor = [UIColor colorWithWhite:0 alpha:0.7];
        _digit.shadowOffset = CGSizeMake(0, -1);
        [self addSubview:_digit];
    }
    return self;
}

@end

@interface S4ECameraTimer : NSObject
+ (instancetype)shared;
@property(nonatomic, readonly) BOOL counting;
- (void)startOnCameraView:(PLCameraView *)view seconds:(NSInteger)seconds;
- (void)cancel;
@end

static void (*orig_shutterClicked)(PLCameraView *, SEL);

@implementation S4ECameraTimer {
    PLCameraView *_cameraView;
    S4ECountdownView *_hud;
    NSInteger _remaining;
}

+ (instancetype)shared {
    static S4ECameraTimer *timer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        timer = [[S4ECameraTimer alloc] init];
    });
    return timer;
}

- (BOOL)counting {
    return _cameraView != nil;
}

// The digit stays upright however the phone is held, like Camera's own buttons
- (CGAffineTransform)transformForDeviceOrientation {
    switch ([UIDevice currentDevice].orientation) {
    case UIDeviceOrientationLandscapeLeft:
        return CGAffineTransformMakeRotation(M_PI_2);
    case UIDeviceOrientationLandscapeRight:
        return CGAffineTransformMakeRotation(-M_PI_2);
    case UIDeviceOrientationPortraitUpsideDown:
        return CGAffineTransformMakeRotation(M_PI);
    default:
        return CGAffineTransformIdentity;
    }
}

- (void)startOnCameraView:(PLCameraView *)view seconds:(NSInteger)seconds {
    [self cancel];
    _cameraView = view;
    _remaining = seconds;
    _hud = [[S4ECountdownView alloc] initWithFrame:CGRectMake(0, 0, 150, 150)];
    _hud.center = CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds));
    _hud.transform = [self transformForDeviceOrientation];
    [view addSubview:_hud];
    [self tick];
}

- (void)tick {
    if (!_cameraView)
        return;
    if (_remaining <= 0) {
        PLCameraView *view = _cameraView;
        [self cancel];
        orig_shutterClicked(view, @selector(_shutterButtonClicked));
        return;
    }
    UILabel *digit = _hud.digit;
    digit.text = [NSString stringWithFormat:@"%ld", (long)_remaining];
    digit.transform = CGAffineTransformMakeScale(1.25, 1.25);
    digit.alpha = 0.4;
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        digit.transform = CGAffineTransformIdentity;
        digit.alpha = 1;
    } completion:nil];
    S4EPlaySound(1103); // Tink
    _remaining--;
    [self performSelector:@selector(tick) withObject:nil afterDelay:1];
}

- (void)cancel {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(tick) object:nil];
    [_hud removeFromSuperview];
    _hud = nil;
    _cameraView = nil;
}

#pragma mark Button

- (void)timerButtonTapped:(UIButton *)button {
    NSInteger delay = S4ETimerDelay(S4EPrefsRead());
    delay = delay == 0 ? 3 : delay == 3 ? 10 : 0;
    S4EPrefsSet(kS4ECameraTimerDelay, @(delay));
    [button setTitle:S4EDelayTitle(delay) forState:UIControlStateNormal];
}

@end

#pragma mark - Camera

// The button lives next to the switch-camera button and follows Camera's own visibility rules for it
static void S4EUpdateTimerButton(PLCameraView *view) {
    UIView *toggle = [view respondsToSelector:@selector(_toggleButton)] ? [view _toggleButton] : nil;
    UIView *host = toggle.superview ?: view;
    UIButton *button = (UIButton *)[host viewWithTag:kS4ETimerButtonTag];
    BOOL photo = [view respondsToSelector:@selector(cameraMode)] && view.cameraMode == 0;
    NSDictionary *prefs = S4EPrefsRead();
    if (!S4ETimerEnabled(prefs)) {
        [button removeFromSuperview];
        return;
    }
    if (!button) {
        Class reorienting = objc_getClass("PLReorientingButton");
        button = reorienting ? [[reorienting alloc] initWithFrame:CGRectZero] : [UIButton buttonWithType:UIButtonTypeCustom];
        if (![button isKindOfClass:[UIButton class]])
            return;
        button.tag = kS4ETimerButtonTag;
        [button setBackgroundImage:S4ECapsuleImage(32) forState:UIControlStateNormal];
        [button setImage:S4EStopwatchImage() forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        button.titleLabel.shadowOffset = CGSizeMake(0, -1);
        [button setTitleShadowColor:[UIColor colorWithWhite:0 alpha:0.6] forState:UIControlStateNormal];
        button.showsTouchWhenHighlighted = YES;
        [button addTarget:[S4ECameraTimer shared] action:@selector(timerButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        if ([button respondsToSelector:@selector(setAutorotationEnabled:)])
            [button setAutorotationEnabled:YES];
        if ([button respondsToSelector:@selector(startWatchingDeviceOrientationChanges)])
            [button startWatchingDeviceOrientationChanges];
        [host addSubview:button];
    }
    [button setTitle:S4EDelayTitle(S4ETimerDelay(prefs)) forState:UIControlStateNormal];

    // Under the switch-camera button, or in the top right corner on a device with one camera
    CGRect anchor = toggle ? toggle.frame : CGRectMake(host.bounds.size.width - 72, 10, 64, 0);
    CGFloat width = 64, height = 32;
    button.bounds = CGRectMake(0, 0, width, height);
    button.center = CGPointMake(CGRectGetMaxX(anchor) - width / 2, CGRectGetMaxY(anchor) + 8 + height / 2);
    button.hidden = !photo;
}

static void hook_shutterClicked(PLCameraView *self, SEL _cmd) {
    S4ECameraTimer *timer = [S4ECameraTimer shared];
    // Pressing the shutter during the countdown cancels it, as in iOS 8
    if (timer.counting) {
        [timer cancel];
        return;
    }
    NSDictionary *prefs = S4EPrefsRead();
    NSInteger delay = S4ETimerEnabled(prefs) ? S4ETimerDelay(prefs) : 0;
    BOOL photo = [self respondsToSelector:@selector(cameraMode)] && self.cameraMode == 0;
    if (delay && photo) {
        [timer startOnCameraView:self seconds:delay];
        return;
    }
    orig_shutterClicked(self, _cmd);
}

static void (*orig_layoutSubviews)(PLCameraView *, SEL);
static void hook_layoutSubviews(PLCameraView *self, SEL _cmd) {
    orig_layoutSubviews(self, _cmd);
    S4EUpdateTimerButton(self);
}

static void (*orig_updateOverlayControls)(PLCameraView *, SEL);
static void hook_updateOverlayControls(PLCameraView *self, SEL _cmd) {
    orig_updateOverlayControls(self, _cmd);
    S4EUpdateTimerButton(self);
}

static void (*orig_setOverlayControlsVisible)(PLCameraView *, SEL, BOOL);
static void hook_setOverlayControlsVisible(PLCameraView *self, SEL _cmd, BOOL visible) {
    orig_setOverlayControlsVisible(self, _cmd, visible);
    UIView *toggle = [self respondsToSelector:@selector(_toggleButton)] ? [self _toggleButton] : nil;
    UIView *button = [(toggle.superview ?: self) viewWithTag:kS4ETimerButtonTag];
    if (!visible)
        button.hidden = YES;
    else
        S4EUpdateTimerButton(self);
}

// Switching to video or panorama, or leaving Camera, stops the countdown
static void (*orig_modeWillChange)(PLCameraView *, SEL, id);
static void hook_modeWillChange(PLCameraView *self, SEL _cmd, id controller) {
    [[S4ECameraTimer shared] cancel];
    orig_modeWillChange(self, _cmd, controller);
}

__attribute__((constructor)) static void S4ECameraTimerInit(void) {
    @autoreleasepool {
        Class cameraView = objc_getClass("PLCameraView");
        if (!cameraView)
            return;
        S4E_HOOK(cameraView, @selector(_shutterButtonClicked), hook_shutterClicked, &orig_shutterClicked);
        S4E_HOOK(cameraView, @selector(layoutSubviews), hook_layoutSubviews, &orig_layoutSubviews);
        S4E_HOOK(cameraView, @selector(_updateOverlayControls), hook_updateOverlayControls, &orig_updateOverlayControls);
        S4E_HOOK(cameraView, @selector(_setOverlayControlsVisible:), hook_setOverlayControlsVisible, &orig_setOverlayControlsVisible);
        S4E_HOOK(cameraView, @selector(cameraControllerModeWillChange:), hook_modeWillChange, &orig_modeWillChange);
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil
                                                      usingBlock:^(NSNotification *note) {
                                                          [[S4ECameraTimer shared] cancel];
                                                      }];
    }
}
