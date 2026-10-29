// Camera timer (iOS 8), built the iOS 6 way.
//
// The timer is a group of its own in Camera's Options panel, between Grid and HDR and Panorama: the same
// translucent white rounded group, with a grey segmented control like the panel's switches — Off, 3 s, 10 s. With a delay set, the shutter (on screen or the volume
// button) starts a countdown: a big embossed digit on a dark translucent square, like the iOS 6 volume
// HUD, with a tick every second. Pressing the shutter again cancels it. Photos only: video and panorama
// are untouched.

#import "S4EShared.h"
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>

#define kS4ECameraTimer @"CameraTimer"            // the feature switch
#define kS4ECameraTimerDelay @"CameraTimerDelay"  // the chosen delay: 0, 3 or 10 seconds

static const void *kS4ETimerRowKey = &kS4ETimerRowKey;
static const NSInteger kS4EDelays[] = {0, 3, 10};

@interface PLCameraView : UIView
@property(nonatomic) int cameraMode; // 0: photo
@end

// A row of the Options panel: draws its own rounded background, shaped by its type (top, bottom, single)
@interface PLCameraSettingsGroupView : UIView
@property(nonatomic) int type;
@property(retain, nonatomic) UILabel *titleLabel;
@property(retain, nonatomic) UISwitch *accessorySwitch;
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

@end

#pragma mark - Options panel

// The timer row: built on Camera's own group view so it has the same background as Grid and HDR,
// with a label like theirs and a segmented control tinted like their switches
@interface S4ETimerRow : NSObject
@property(nonatomic, strong) UIView *group;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) UISegmentedControl *control;
@property(nonatomic) CGFloat panoramaGap; // between Camera's own groups and Panorama; -1 until measured
@end

@implementation S4ETimerRow

- (instancetype)init {
    Class groupClass = objc_getClass("PLCameraSettingsGroupView");
    if (!groupClass || !(self = [super init]))
        return nil;
    _panoramaGap = -1;
    _group = [[groupClass alloc] initWithFrame:CGRectZero];
    _label = [[UILabel alloc] initWithFrame:CGRectZero];
    _label.backgroundColor = [UIColor clearColor];
    [_group addSubview:_label];
    _control = [[UISegmentedControl alloc] initWithItems:@[S4E_L(@"Off", @"Выкл."), S4E_L(@"3 s", @"3 с"), S4E_L(@"10 s", @"10 с")]];
    _control.segmentedControlStyle = UISegmentedControlStyleBar;
    NSInteger delay = S4ETimerDelay(S4EPrefsRead());
    _control.selectedSegmentIndex = delay == 10 ? 2 : delay == 3 ? 1 : 0;
    [_control addTarget:self action:@selector(delayChanged:) forControlEvents:UIControlEventValueChanged];
    [_group addSubview:_control];
    return self;
}

- (void)delayChanged:(UISegmentedControl *)control {
    NSInteger index = control.selectedSegmentIndex;
    S4EPrefsSet(kS4ECameraTimerDelay, @(index >= 0 && index < 3 ? kS4EDelays[index] : 0));
}

// The label and the control copy the look and the margins of the Grid and HDR rows
- (void)layoutLikeGroup:(UIView *)model {
    PLCameraSettingsGroupView *row = (PLCameraSettingsGroupView *)model;
    UILabel *title = [row respondsToSelector:@selector(titleLabel)] ? row.titleLabel : nil;
    UISwitch *toggle = [row respondsToSelector:@selector(accessorySwitch)] ? row.accessorySwitch : nil;
    if (![title isKindOfClass:[UILabel class]])
        title = nil;
    if (![toggle isKindOfClass:[UISwitch class]])
        toggle = nil;
    CGSize size = _group.bounds.size;

    _label.text = S4E_L(@"Timer", @"Таймер");
    _label.font = title.font ?: [UIFont boldSystemFontOfSize:17];
    _label.textColor = title.textColor ?: [UIColor colorWithWhite:0.1 alpha:1];
    _label.shadowColor = title ? title.shadowColor : [UIColor colorWithWhite:1 alpha:0.5];
    _label.shadowOffset = title ? title.shadowOffset : CGSizeMake(0, 1);
    _control.tintColor = toggle.onTintColor ?: [UIColor colorWithWhite:0.42 alpha:1];

    CGFloat left = title.frame.origin.x > 0 ? title.frame.origin.x : 10;
    CGFloat right = toggle ? model.bounds.size.width - CGRectGetMaxX(toggle.frame) : left;
    if (right < 0 || right > 40)
        right = left;
    CGFloat height = MIN(30, size.height - 10);
    CGFloat width = MAX(96, MIN(150, size.width - left - right - 80));
    _control.frame = CGRectMake(size.width - right - width, roundf((size.height - height) / 2), width, height);
    _label.frame = CGRectMake(left, 0, CGRectGetMinX(_control.frame) - left - 8, size.height);
}

@end

static UIView *S4ESettingsGroup(UIView *settings, const char *name) {
    UIView *group = S4EIvar(settings, name);
    return [group isKindOfClass:[UIView class]] && group.superview == settings ? group : nil;
}

static int S4EGroupType(UIView *group) {
    return [group respondsToSelector:@selector(type)] ? [(PLCameraSettingsGroupView *)group type] : 0;
}

// Height of one row and the gap between separate groups, as Camera lays them out; remembered for sizeThatFits:
static CGFloat gS4ERowHeight = 47, gS4EGap = 18;

static void (*orig_settingsLayout)(UIView *, SEL);
static void hook_settingsLayout(UIView *self, SEL _cmd) {
    orig_settingsLayout(self, _cmd);
    S4ETimerRow *row = objc_getAssociatedObject(self, kS4ETimerRowKey);
    if (!row)
        return;
    UIView *grid = S4ESettingsGroup(self, "_gridLinesGroup"), *hdr = S4ESettingsGroup(self, "_hdrGroup"),
           *pano = S4ESettingsGroup(self, "_panoramaGroup");
    UIView *above = hdr ?: grid;
    if (!above) {
        row.group.hidden = YES;
        return;
    }
    row.group.hidden = NO;
    CGFloat height = above.frame.size.height > 0 ? above.frame.size.height : gS4ERowHeight;
    // Measured once, before Panorama is moved down
    if (pano && row.panoramaGap < 0 && above.frame.size.height > 0 && pano.frame.size.height > 0)
        row.panoramaGap = MAX(0, CGRectGetMinY(pano.frame) - CGRectGetMaxY(above.frame));
    // Grid and HDR share one rounded group: a top and a bottom piece with no gap. Then the timer is a group
    // of its own, shaped like Panorama's; if they ever come as separate groups, it is one more like HDR.
    BOOL shared = grid && hdr && fabs(CGRectGetMinY(hdr.frame) - CGRectGetMaxY(grid.frame)) < 1 && S4EGroupType(grid) != S4EGroupType(hdr);
    CGFloat gap = grid && hdr && !shared ? CGRectGetMinY(hdr.frame) - CGRectGetMaxY(grid.frame)
                : row.panoramaGap >= 0 ? row.panoramaGap : gS4EGap;
    if (gap < 0 || gap > 40)
        gap = gS4EGap;
    gS4ERowHeight = height;
    gS4EGap = gap;

    UIView *model = shared && pano ? pano : above;
    if ([row.group respondsToSelector:@selector(setType:)] && S4EGroupType(row.group) != S4EGroupType(model)) {
        [(PLCameraSettingsGroupView *)row.group setType:S4EGroupType(model)];
        [row.group setNeedsDisplay];
    }
    row.group.frame = CGRectMake(above.frame.origin.x, CGRectGetMaxY(above.frame) + gap, above.frame.size.width, height);
    [row layoutLikeGroup:above];
    if (pano) {
        CGRect frame = pano.frame;
        frame.origin.y = CGRectGetMaxY(row.group.frame) + (row.panoramaGap >= 0 ? row.panoramaGap : gap);
        pano.frame = frame;
    }

    // In case Camera sized the panel before we could measure a row: grow it downwards
    CGFloat needed = CGRectGetMaxY(pano ? pano.frame : row.group.frame);
    CGRect bounds = self.bounds;
    if (needed > CGRectGetMaxY(bounds) + 0.5) {
        CGFloat extra = needed - CGRectGetMaxY(bounds);
        bounds.size.height += extra;
        self.bounds = bounds;
        self.center = CGPointMake(self.center.x, self.center.y + extra / 2);
    }
}

static CGSize (*orig_settingsSizeThatFits)(UIView *, SEL, CGSize);
static CGSize hook_settingsSizeThatFits(UIView *self, SEL _cmd, CGSize size) {
    CGSize fits = orig_settingsSizeThatFits(self, _cmd, size);
    if (objc_getAssociatedObject(self, kS4ETimerRowKey))
        fits.height += gS4ERowHeight + gS4EGap;
    return fits;
}

static id (*orig_settingsInit)(UIView *, SEL, CGRect, BOOL, BOOL, BOOL);
static id hook_settingsInit(UIView *self, SEL _cmd, CGRect frame, BOOL grid, BOOL hdr, BOOL pano) {
    self = orig_settingsInit(self, _cmd, frame, grid, hdr, pano);
    if (self && S4ETimerEnabled(S4EPrefsRead())) {
        S4ETimerRow *row = [[S4ETimerRow alloc] init];
        if (row) {
            [self addSubview:row.group];
            objc_setAssociatedObject(self, kS4ETimerRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    return self;
}

#pragma mark - Camera

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
        S4E_HOOK(cameraView, @selector(cameraControllerModeWillChange:), hook_modeWillChange, &orig_modeWillChange);
        Class settings = objc_getClass("PLCameraSettingsView");
        if (settings) {
            S4E_HOOK(settings, @selector(initWithFrame:showGrid:showHDR:showPano:), hook_settingsInit, &orig_settingsInit);
            S4E_HOOK(settings, @selector(layoutSubviews), hook_settingsLayout, &orig_settingsLayout);
            S4E_HOOK(settings, @selector(sizeThatFits:), hook_settingsSizeThatFits, &orig_settingsSizeThatFits);
        }
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil
                                                      usingBlock:^(NSNotification *note) {
                                                          [[S4ECameraTimer shared] cancel];
                                                      }];
    }
}
