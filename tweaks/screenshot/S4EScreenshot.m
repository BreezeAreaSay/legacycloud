// Screenshot preview (iOS 11) in iOS 6 style: the shot shrinks into the bottom-left corner and sits there
// as a photo in a white frame. A tap opens markup, a swipe left dismisses the preview, and it goes away
// on its own after 5 seconds. The close box in the corner (like iOS 6 icons in delete mode) deletes the shot at once.
//
// As in iOS 11, the shot is not in Photos yet while the preview is on screen. Intercepting iOS 6 SpringBoard's
// write reliably didn't work out, so we take the shot ourselves instead of -[SBScreenShotter saveScreenshot:]: a screen
// copy (_UICreateScreenUIImage), the native SBScreenFlash flash and the shutter sound, so from outside it's just like SpringBoard.
// We hold on to the shot: when the preview goes away it is saved as is; after markup, with the annotations;
// the close box and "Delete Screenshot" save nothing. Safety net: a shot that for some reason stays
// with us longer than 20 seconds is saved anyway.
//
// If there is no way to capture the screen, SpringBoard takes the shot itself and the preview appears after it is written
// (finishedWritingScreenshot:…); the shot is then already in Photos, and markup is saved as a copy.

#import "S4EShared.h"
#import "S4EMarkup.h"
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>

#define kS4EScreenshot @"ScreenshotPreview"

static const UIWindowLevel kS4EShotThumbnailLevel = 1060;
static const UIWindowLevel kS4EShotEditorLevel = 1061;
static const NSTimeInterval kS4EShotLifetime = 5;
static const NSTimeInterval kS4EShotWatchdog = 20;

@interface UIApplication (S4EScreenshot)
- (int)activeInterfaceOrientation;
@end

@interface SBScreenFlash : NSObject
+ (instancetype)sharedInstance;
- (void)flash;
@end

static void S4ESaveToPhotos(UIImage *image) {
    UIImageWriteToSavedPhotosAlbum(image, nil, NULL, NULL);
}

static BOOL S4EShotEnabled(void) {
    return S4EBool(S4EPrefsRead(), kS4EScreenshot, YES);
}

// SpringBoard windows don't rotate by themselves: rotate the root view to match the app on screen
static UIView *S4EShotOrientedRoot(UIWindow *window) {
    UIApplication *springBoard = [UIApplication sharedApplication];
    UIInterfaceOrientation orientation = [springBoard respondsToSelector:@selector(activeInterfaceOrientation)]
        ? (UIInterfaceOrientation)[springBoard activeInterfaceOrientation] : UIInterfaceOrientationPortrait;
    CGRect screen = [UIScreen mainScreen].bounds;
    BOOL landscape = UIInterfaceOrientationIsLandscape(orientation);
    UIView *root = [[UIView alloc] initWithFrame:CGRectMake(0, 0, landscape ? screen.size.height : screen.size.width,
                                                            landscape ? screen.size.width : screen.size.height)];
    root.center = CGPointMake(CGRectGetMidX(screen), CGRectGetMidY(screen));
    root.transform = CGAffineTransformMakeRotation(orientation == UIInterfaceOrientationLandscapeLeft ? -M_PI_2
                                                 : orientation == UIInterfaceOrientationLandscapeRight ? M_PI_2
                                                 : orientation == UIInterfaceOrientationPortraitUpsideDown ? M_PI : 0);
    [window addSubview:root];
    return root;
}

// Frame of an image of the given size fitted into rect
static CGRect S4EShotFit(CGSize size, CGRect rect) {
    if (size.width <= 0 || size.height <= 0)
        return rect;
    CGFloat scale = MIN(rect.size.width / size.width, rect.size.height / size.height);
    CGSize fit = CGSizeMake(size.width * scale, size.height * scale);
    return CGRectMake(CGRectGetMidX(rect) - fit.width / 2, CGRectGetMidY(rect) - fit.height / 2, fit.width, fit.height);
}

// The iOS 6 close box, as on icons in delete mode: a black circle in a white ring
static UIImage *S4ECloseBoxImage(void) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(30, 30), NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect circle = CGRectMake(4, 3, 22, 22);
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, 1.5), 2, [UIColor colorWithWhite:0 alpha:0.6].CGColor);
    [[UIColor whiteColor] setFill];
    CGContextFillEllipseInRect(ctx, circle);
    CGContextRestoreGState(ctx);
    [[UIColor blackColor] setFill];
    CGContextFillEllipseInRect(ctx, CGRectInset(circle, 2, 2));
    UIBezierPath *cross = [UIBezierPath bezierPath];
    CGFloat c = 4;
    CGPoint center = CGPointMake(CGRectGetMidX(circle), CGRectGetMidY(circle));
    [cross moveToPoint:CGPointMake(center.x - c, center.y - c)];
    [cross addLineToPoint:CGPointMake(center.x + c, center.y + c)];
    [cross moveToPoint:CGPointMake(center.x + c, center.y - c)];
    [cross addLineToPoint:CGPointMake(center.x - c, center.y + c)];
    cross.lineWidth = 2.2;
    cross.lineCapStyle = kCGLineCapRound;
    [[UIColor whiteColor] setStroke];
    [cross stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

// The preview also catches touches slightly outside its edges: the close box sticks out of the corner
@interface S4EShotThumbView : UIView
@end

@implementation S4EShotThumbView
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(CGRectInset(self.bounds, -14, -14), point);
}
@end

#pragma mark - Controller

@interface S4EShotController : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
@property(nonatomic, readonly) BOOL editing;
@property(nonatomic, readonly) BOOL showingThumbnail;
- (void)presentImage:(UIImage *)image held:(BOOL)held;
- (void)removeThumbnail;
- (void)finishEditing:(S4EMarkupAction)action animated:(BOOL)animated;
@end

@implementation S4EShotController {
    UIImage *_image;
    BOOL _held; // the shot is not saved to Photos yet
    UIWindow *_thumbWindow;
    UIView *_thumbRoot;
    UIView *_thumb;
    UIButton *_closeBox;
    CGRect _thumbHome;
    NSUInteger _generation;
    UIWindow *_editorWindow;
    S4EMarkupView *_markup;
}

+ (instancetype)shared {
    static S4EShotController *controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        controller = [[S4EShotController alloc] init];
    });
    return controller;
}

- (BOOL)editing {
    return _editorWindow != nil;
}

- (BOOL)showingThumbnail {
    return _thumbWindow != nil;
}

#pragma mark Preview

// Where the preview sits: the bottom-left corner, with a 3 pt white frame around the shot
- (CGRect)thumbFrameIn:(CGRect)bounds {
    CGSize size = _image.size;
    CGFloat width = size.width > size.height ? 120 : 84;
    CGFloat height = size.width > 0 ? width * size.height / size.width : width;
    return CGRectMake(12, bounds.size.height - 12 - height - 6, width + 6, height + 6);
}

- (void)presentImage:(UIImage *)image held:(BOOL)held {
    [self removeThumbnail];
    _image = image;
    _held = held;
    NSUInteger generation = ++_generation;
    if (held)
        [self performSelector:@selector(watchdog:) withObject:image afterDelay:kS4EShotWatchdog];

    _thumbWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _thumbWindow.windowLevel = kS4EShotThumbnailLevel;
    _thumbWindow.backgroundColor = [UIColor clearColor];
    _thumbWindow.userInteractionEnabled = NO; // while the shot flies into the corner
    _thumbRoot = S4EShotOrientedRoot(_thumbWindow);

    // The shot as a photo in a white frame with a shadow
    _thumb = [[S4EShotThumbView alloc] initWithFrame:CGRectInset(S4EShotFit(image.size, _thumbRoot.bounds), -3, -3)];
    _thumb.backgroundColor = [UIColor whiteColor];
    _thumb.layer.shadowColor = [UIColor blackColor].CGColor;
    _thumb.layer.shadowOpacity = 0.6;
    _thumb.layer.shadowRadius = 4;
    _thumb.layer.shadowOffset = CGSizeMake(0, 2);
    UIImageView *imageView = [[UIImageView alloc] initWithImage:image];
    imageView.frame = CGRectInset(_thumb.bounds, 3, 3);
    imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_thumb addSubview:imageView];
    // Close box only while the shot is not in Photos: there is no way to delete an already saved shot from there
    _closeBox = nil;
    if (held) {
        _closeBox = [UIButton buttonWithType:UIButtonTypeCustom];
        [_closeBox setImage:S4ECloseBoxImage() forState:UIControlStateNormal];
        _closeBox.frame = CGRectMake(-15, -14, 30, 30);
        _closeBox.alpha = 0;
        [_closeBox addTarget:self action:@selector(deleteTapped) forControlEvents:UIControlEventTouchUpInside];
        [_thumb addSubview:_closeBox];
    }
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(thumbTapped)];
    tap.delegate = self;
    [_thumb addGestureRecognizer:tap];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(thumbPanned:)];
    pan.delegate = self;
    [_thumb addGestureRecognizer:pan];
    [_thumbRoot addSubview:_thumb];
    _thumbWindow.hidden = NO;

    _thumbHome = [self thumbFrameIn:_thumbRoot.bounds];
    [UIView animateWithDuration:0.35 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_thumb.frame = self->_thumbHome;
    } completion:^(BOOL finished) {
        [[S4EShotController shared] thumbnailLanded:generation];
    }];
}

// The shot must not get lost, even if the preview somehow never showed up or got stuck
- (void)watchdog:(UIImage *)image {
    if (image != _image || !_held || _editorWindow)
        return;
    S4ELog(@"screenshot preview: shot held too long, saving it");
    S4ESaveToPhotos(_image);
    _held = NO;
}

- (void)thumbnailLanded:(NSUInteger)generation {
    if (generation != _generation || !_thumb)
        return;
    _thumb.layer.shadowPath = [UIBezierPath bezierPathWithRect:_thumb.bounds].CGPath;
    _thumbWindow.userInteractionEnabled = YES;
    [UIView animateWithDuration:0.2 animations:^{
        self->_closeBox.alpha = 1;
    }];
    [self scheduleTimeout];
}

// Touches on the close box are its own, not a tap or swipe on the preview
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    return !_closeBox || ![touch.view isDescendantOfView:_closeBox];
}

// Close box: the shot is not saved, the preview shrinks and disappears
- (void)deleteTapped {
    if (!_thumb || !_held)
        return;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(thumbnailTimedOut) object:nil];
    _held = NO;
    _image = nil;
    NSUInteger generation = _generation;
    _thumbWindow.userInteractionEnabled = NO;
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self->_thumb.transform = CGAffineTransformMakeScale(0.2, 0.2);
        self->_thumb.alpha = 0;
    } completion:^(BOOL finished) {
        S4EShotController *controller = [S4EShotController shared];
        if (generation == controller->_generation)
            [controller removeThumbnail];
    }];
}

- (void)scheduleTimeout {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(thumbnailTimedOut) object:nil];
    [self performSelector:@selector(thumbnailTimedOut) withObject:nil afterDelay:kS4EShotLifetime];
}

- (void)thumbnailTimedOut {
    [self slideThumbnailAway];
}

// The preview slides away to the left; the shot is saved if it hasn't been yet
- (void)slideThumbnailAway {
    if (!_thumb)
        return;
    NSUInteger generation = _generation;
    _thumbWindow.userInteractionEnabled = NO;
    CGRect away = _thumb.frame;
    away.origin.x = -away.size.width - 20;
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self->_thumb.frame = away;
    } completion:^(BOOL finished) {
        S4EShotController *controller = [S4EShotController shared];
        if (generation == controller->_generation)
            [controller removeThumbnail];
    }];
}

- (void)removeThumbnail {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(thumbnailTimedOut) object:nil];
    if (!_thumbWindow)
        return;
    if (_held && _image && !_editorWindow)
        S4ESaveToPhotos(_image);
    if (!_editorWindow) {
        _image = nil;
        _held = NO;
    }
    _thumbWindow.hidden = YES;
    _thumbWindow = nil;
    _thumbRoot = nil;
    _thumb = nil;
    _closeBox = nil;
}

- (void)thumbPanned:(UIPanGestureRecognizer *)pan {
    CGFloat dx = [pan translationInView:_thumbRoot].x;
    switch (pan.state) {
    case UIGestureRecognizerStateBegan:
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(thumbnailTimedOut) object:nil];
        break;
    case UIGestureRecognizerStateChanged:
        // Free to the left, with resistance to the right
        _thumb.frame = CGRectOffset(_thumbHome, dx < 0 ? dx : dx * 0.3, 0);
        break;
    case UIGestureRecognizerStateEnded:
    case UIGestureRecognizerStateCancelled:
        if (dx < -40 || [pan velocityInView:_thumbRoot].x < -300) {
            [self slideThumbnailAway];
        } else {
            [UIView animateWithDuration:0.2 animations:^{
                self->_thumb.frame = self->_thumbHome;
            }];
            [self scheduleTimeout];
        }
        break;
    default:
        break;
    }
}

#pragma mark Markup

- (void)thumbTapped {
    if (!_thumb || !_image)
        return;
    CGRect from = [_thumbRoot convertRect:CGRectInset(_thumb.frame, 3, 3) toView:nil];
    UIImage *image = _image;

    _editorWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _editorWindow.windowLevel = kS4EShotEditorLevel;
    _editorWindow.backgroundColor = [UIColor clearColor];
    UIView *root = S4EShotOrientedRoot(_editorWindow);
    _markup = [[S4EMarkupView alloc] initWithFrame:root.bounds image:image canDelete:_held];
    _markup.alpha = 0;
    // Via the singleton rather than self: no retain cycle and no __weak (on armv7 it needs SjLj tables)
    _markup.onFinish = ^(S4EMarkupAction action) {
        [[S4EShotController shared] finishEditing:action animated:YES];
    };
    [root addSubview:_markup];

    // The preview grows into the shot on the markup screen
    UIImageView *zoom = [[UIImageView alloc] initWithImage:image];
    zoom.frame = [root convertRect:from fromView:nil];
    [root addSubview:zoom];
    UIView *black = [[UIView alloc] initWithFrame:root.bounds];
    black.backgroundColor = [UIColor blackColor];
    black.alpha = 0;
    [root insertSubview:black belowSubview:zoom];
    _editorWindow.hidden = NO;
    [self removeThumbnail];

    S4EMarkupView *markup = _markup;
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        zoom.frame = markup.imageFrame;
        black.alpha = 1;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.15 animations:^{
            markup.alpha = 1;
        } completion:^(BOOL done) {
            [zoom removeFromSuperview];
            [black removeFromSuperview];
        }];
    }];
}

- (void)finishEditing:(S4EMarkupAction)action animated:(BOOL)animated {
    if (!_markup)
        return;
    [_markup dismissSheet];
    UIImage *result = nil;
    if (_held) // the shot is not in Photos yet: save it, with or without annotations
        result = action == S4EMarkupKeep ? (_markup.edited ? [_markup renderedImage] : _image) : nil;
    else // the shot is already in Photos: save the annotations as a copy
        result = action == S4EMarkupKeep && _markup.edited ? [_markup renderedImage] : nil;
    if (result)
        S4ESaveToPhotos(result);

    _image = nil;
    _held = NO;
    _markup = nil;
    UIWindow *window = _editorWindow;
    _editorWindow = nil;
    if (!animated) {
        window.hidden = YES;
        return;
    }
    [UIView animateWithDuration:0.25 animations:^{
        window.alpha = 0;
    } completion:^(BOOL finished) {
        window.hidden = YES;
    }];
}

@end

#pragma mark - SpringBoard

static void S4EShotPresent(UIImage *image, BOOL held) {
    S4EShotController *controller = [S4EShotController shared];
    if (controller.editing) {
        if (held)
            S4ESaveToPhotos(image);
        return;
    }
    [controller presentImage:image held:held];
}

// Screen copy: _UICreateScreenUIImage(WithRotation) in iOS 6 UIKit, otherwise UIGetScreenImage
static UIImage *S4ECaptureScreen(void) {
    void *(*withRotation)(BOOL) = (void *(*)(BOOL))dlsym(RTLD_DEFAULT, "_UICreateScreenUIImageWithRotation");
    if (withRotation)
        return CFBridgingRelease(withRotation(YES));
    void *(*plain)(void) = (void *(*)(void))dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
    if (plain)
        return CFBridgingRelease(plain());
    CGImageRef (*legacy)(void) = (CGImageRef (*)(void))dlsym(RTLD_DEFAULT, "UIGetScreenImage");
    CGImageRef cgImage = legacy ? legacy() : NULL;
    if (!cgImage)
        return nil;
    UIImage *image = [UIImage imageWithCGImage:cgImage scale:[UIScreen mainScreen].scale orientation:UIImageOrientationUp];
    CGImageRelease(cgImage);
    return image;
}

// Shutter sound, as for a screenshot; the system sound is silent when the ringer is off
static void S4EPlayShutter(void) {
    void (*play)(uint32_t) = (void (*)(uint32_t))dlsym(RTLD_DEFAULT, "AudioServicesPlaySystemSound");
    if (play)
        play(1108);
}

// Our shot instead of SpringBoard's: that way the preview and markup work fully
static void (*orig_saveScreenshot)(id, SEL, BOOL);
static void hook_saveScreenshot(id self, SEL _cmd, BOOL flash) {
    S4EShotController *controller = [S4EShotController shared];
    if (controller.showingThumbnail) {
        [controller removeThumbnail];
        [CATransaction flush]; // the old preview must not end up in the shot
    }
    UIImage *image = S4EShotEnabled() && !controller.editing ? S4ECaptureScreen() : nil;
    if (!image) {
        orig_saveScreenshot(self, _cmd, flash);
        return;
    }
    if (flash) {
        SBScreenFlash *screenFlash = [objc_getClass("SBScreenFlash") sharedInstance];
        if ([screenFlash respondsToSelector:@selector(flash)])
            [screenFlash flash];
    }
    S4EPlayShutter();
    S4EShotPresent(image, YES);
}

// Fallback: SpringBoard took the shot (there was no way to capture the screen), so the preview comes after the write
static void (*orig_finishedWriting)(id, SEL, UIImage *, NSError *, void *);
static void hook_finishedWriting(id self, SEL _cmd, UIImage *image, NSError *error, void *context) {
    orig_finishedWriting(self, _cmd, image, error, context);
    if (error || ![image isKindOfClass:[UIImage class]] || !S4EShotEnabled())
        return;
    dispatch_async(dispatch_get_main_queue(), ^{
        S4EShotPresent(image, NO);
    });
}

// Home on the markup screen closes it and saves the shot with the annotations
static BOOL gSwallowMenuUp;

static void (*orig_menuButtonDown)(id, SEL, void *);
static void hook_menuButtonDown(id self, SEL _cmd, void *event) {
    S4EShotController *controller = [S4EShotController shared];
    if (controller.editing) {
        gSwallowMenuUp = YES;
        [controller finishEditing:S4EMarkupKeep animated:YES];
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

// Lock: nothing is lost; the shot is saved and markup closes keeping the annotations
static void S4EShotLockStateChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        S4EShotController *controller = [S4EShotController shared];
        if (controller.editing)
            [controller finishEditing:S4EMarkupKeep animated:NO];
        else
            [controller removeThumbnail];
    });
}

__attribute__((constructor)) static void S4EScreenshotInit(void) {
    @autoreleasepool {
        if (!S4EIsProcess(@"com.apple.springboard"))
            return;
        Class shotter = objc_getClass("SBScreenShotter");
        S4E_HOOK(shotter, @selector(saveScreenshot:), hook_saveScreenshot, &orig_saveScreenshot);
        S4E_HOOK(shotter, @selector(finishedWritingScreenshot:didFinishSavingWithError:context:), hook_finishedWriting, &orig_finishedWriting);
        Class springBoard = objc_getClass("SpringBoard");
        S4E_HOOK(springBoard, @selector(menuButtonDown:), hook_menuButtonDown, &orig_menuButtonDown);
        S4E_HOOK(springBoard, @selector(menuButtonUp:), hook_menuButtonUp, &orig_menuButtonUp);
        S4EObserveDarwin("com.apple.springboard.lockstate", S4EShotLockStateChanged);
    }
}
