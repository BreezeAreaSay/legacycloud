// Превью скриншота (iOS 11) в стиле iOS 6: снимок уменьшается в левый нижний угол и лежит там
// фотографией в белой рамке. Нажатие открывает разметку, свайп влево убирает превью, само оно
// уходит через 5 секунд. Крестик в углу — как у иконок в режиме удаления iOS 6 — сразу удаляет снимок.
//
// Как в iOS 11, пока превью на экране, снимка ещё нет в «Фото». Перехватить запись SpringBoard iOS 6
// надёжно не вышло, поэтому снимок делаем сами вместо -[SBScreenShotter saveScreenshot:]: копия экрана
// (_UICreateScreenUIImage), родная вспышка SBScreenFlash и звук затвора — снаружи всё как у SpringBoard.
// Снимок держим у себя: когда превью уходит, он записывается как есть; после разметки — с пометками;
// крестик и «Удалить скриншот» не записывают ничего. Страховка: снимок, который почему-то задержался
// у нас дольше 20 секунд, записывается в любом случае.
//
// Если снять экран нечем, снимок делает сам SpringBoard, а превью появляется после записи
// (finishedWritingScreenshot:…) — тогда снимок уже в «Фото», и разметка сохраняется копией.

#import "IRShared.h"
#import "IRMarkup.h"
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>

#define kIRScreenshot @"ScreenshotPreview"

static const UIWindowLevel kIRShotThumbnailLevel = 1060;
static const UIWindowLevel kIRShotEditorLevel = 1061;
static const NSTimeInterval kIRShotLifetime = 5;
static const NSTimeInterval kIRShotWatchdog = 20;

@interface UIApplication (IRScreenshot)
- (int)activeInterfaceOrientation;
@end

@interface SBScreenFlash : NSObject
+ (instancetype)sharedInstance;
- (void)flash;
@end

static void IRSaveToPhotos(UIImage *image) {
    UIImageWriteToSavedPhotosAlbum(image, nil, NULL, NULL);
}

static BOOL IRShotEnabled(void) {
    return IRBool(IRPrefsRead(), kIRScreenshot, YES);
}

// Окна SpringBoard не поворачиваются сами: корневой вид поворачиваем под программу на экране
static UIView *IRShotOrientedRoot(UIWindow *window) {
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

// Рамка картинки size, вписанной в rect
static CGRect IRShotFit(CGSize size, CGRect rect) {
    if (size.width <= 0 || size.height <= 0)
        return rect;
    CGFloat scale = MIN(rect.size.width / size.width, rect.size.height / size.height);
    CGSize fit = CGSizeMake(size.width * scale, size.height * scale);
    return CGRectMake(CGRectGetMidX(rect) - fit.width / 2, CGRectGetMidY(rect) - fit.height / 2, fit.width, fit.height);
}

// Крестик iOS 6, как у иконок в режиме удаления: чёрный кружок в белом кольце
static UIImage *IRCloseBoxImage(void) {
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

// Превью ловит касания и чуть за своими краями: крестик торчит из угла
@interface IRShotThumbView : UIView
@end

@implementation IRShotThumbView
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(CGRectInset(self.bounds, -14, -14), point);
}
@end

#pragma mark - Контроллер

@interface IRShotController : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
@property(nonatomic, readonly) BOOL editing;
@property(nonatomic, readonly) BOOL showingThumbnail;
- (void)presentImage:(UIImage *)image held:(BOOL)held;
- (void)removeThumbnail;
- (void)finishEditing:(IRMarkupAction)action animated:(BOOL)animated;
@end

@implementation IRShotController {
    UIImage *_image;
    BOOL _held; // снимок ещё не записан в «Фото»
    UIWindow *_thumbWindow;
    UIView *_thumbRoot;
    UIView *_thumb;
    UIButton *_closeBox;
    CGRect _thumbHome;
    NSUInteger _generation;
    UIWindow *_editorWindow;
    IRMarkupView *_markup;
}

+ (instancetype)shared {
    static IRShotController *controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        controller = [[IRShotController alloc] init];
    });
    return controller;
}

- (BOOL)editing {
    return _editorWindow != nil;
}

- (BOOL)showingThumbnail {
    return _thumbWindow != nil;
}

#pragma mark Превью

// Место превью: левый нижний угол, белая рамка 3 пт вокруг снимка
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
        [self performSelector:@selector(watchdog:) withObject:image afterDelay:kIRShotWatchdog];

    _thumbWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _thumbWindow.windowLevel = kIRShotThumbnailLevel;
    _thumbWindow.backgroundColor = [UIColor clearColor];
    _thumbWindow.userInteractionEnabled = NO; // пока снимок летит в угол
    _thumbRoot = IRShotOrientedRoot(_thumbWindow);

    // Снимок как фотография в белой рамке с тенью
    _thumb = [[IRShotThumbView alloc] initWithFrame:CGRectInset(IRShotFit(image.size, _thumbRoot.bounds), -3, -3)];
    _thumb.backgroundColor = [UIColor whiteColor];
    _thumb.layer.shadowColor = [UIColor blackColor].CGColor;
    _thumb.layer.shadowOpacity = 0.6;
    _thumb.layer.shadowRadius = 4;
    _thumb.layer.shadowOffset = CGSizeMake(0, 2);
    UIImageView *imageView = [[UIImageView alloc] initWithImage:image];
    imageView.frame = CGRectInset(_thumb.bounds, 3, 3);
    imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_thumb addSubview:imageView];
    // Крестик — только пока снимка нет в «Фото»: удалить оттуда уже записанный снимок нечем
    _closeBox = nil;
    if (held) {
        _closeBox = [UIButton buttonWithType:UIButtonTypeCustom];
        [_closeBox setImage:IRCloseBoxImage() forState:UIControlStateNormal];
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
        [[IRShotController shared] thumbnailLanded:generation];
    }];
}

// Снимок не должен потеряться, даже если превью почему-то не показалось или застряло
- (void)watchdog:(UIImage *)image {
    if (image != _image || !_held || _editorWindow)
        return;
    IRLog(@"превью скриншота: снимок задержался, записываю");
    IRSaveToPhotos(_image);
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

// Касания крестика — его собственные, а не нажатие или свайп по превью
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    return !_closeBox || ![touch.view isDescendantOfView:_closeBox];
}

// Крестик: снимок не записывается, превью сжимается и исчезает
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
        IRShotController *controller = [IRShotController shared];
        if (generation == controller->_generation)
            [controller removeThumbnail];
    }];
}

- (void)scheduleTimeout {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(thumbnailTimedOut) object:nil];
    [self performSelector:@selector(thumbnailTimedOut) withObject:nil afterDelay:kIRShotLifetime];
}

- (void)thumbnailTimedOut {
    [self slideThumbnailAway];
}

// Превью уходит влево; снимок записывается, если ещё не записан
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
        IRShotController *controller = [IRShotController shared];
        if (generation == controller->_generation)
            [controller removeThumbnail];
    }];
}

- (void)removeThumbnail {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(thumbnailTimedOut) object:nil];
    if (!_thumbWindow)
        return;
    if (_held && _image && !_editorWindow)
        IRSaveToPhotos(_image);
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
        // Влево свободно, вправо — с сопротивлением
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

#pragma mark Разметка

- (void)thumbTapped {
    if (!_thumb || !_image)
        return;
    CGRect from = [_thumbRoot convertRect:CGRectInset(_thumb.frame, 3, 3) toView:nil];
    UIImage *image = _image;

    _editorWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _editorWindow.windowLevel = kIRShotEditorLevel;
    _editorWindow.backgroundColor = [UIColor clearColor];
    UIView *root = IRShotOrientedRoot(_editorWindow);
    _markup = [[IRMarkupView alloc] initWithFrame:root.bounds image:image canDelete:_held];
    _markup.alpha = 0;
    // Через синглтон, а не self: без цикла удержания и без __weak (на armv7 он требует таблиц SjLj)
    _markup.onFinish = ^(IRMarkupAction action) {
        [[IRShotController shared] finishEditing:action animated:YES];
    };
    [root addSubview:_markup];

    // Превью вырастает в снимок на экране разметки
    UIImageView *zoom = [[UIImageView alloc] initWithImage:image];
    zoom.frame = [root convertRect:from fromView:nil];
    [root addSubview:zoom];
    UIView *black = [[UIView alloc] initWithFrame:root.bounds];
    black.backgroundColor = [UIColor blackColor];
    black.alpha = 0;
    [root insertSubview:black belowSubview:zoom];
    _editorWindow.hidden = NO;
    [self removeThumbnail];

    IRMarkupView *markup = _markup;
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

- (void)finishEditing:(IRMarkupAction)action animated:(BOOL)animated {
    if (!_markup)
        return;
    [_markup dismissSheet];
    UIImage *result = nil;
    if (_held) // снимка ещё нет в «Фото»: записываем его — с пометками или без
        result = action == IRMarkupKeep ? (_markup.edited ? [_markup renderedImage] : _image) : nil;
    else // снимок уже в «Фото»: пометки сохраняем копией
        result = action == IRMarkupKeep && _markup.edited ? [_markup renderedImage] : nil;
    if (result)
        IRSaveToPhotos(result);

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

static void IRShotPresent(UIImage *image, BOOL held) {
    IRShotController *controller = [IRShotController shared];
    if (controller.editing) {
        if (held)
            IRSaveToPhotos(image);
        return;
    }
    [controller presentImage:image held:held];
}

// Копия экрана: _UICreateScreenUIImage(WithRotation) в UIKit iOS 6, иначе UIGetScreenImage
static UIImage *IRCaptureScreen(void) {
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

// Звук затвора, как у снимка экрана; системный звук молчит при выключенном звонке
static void IRPlayShutter(void) {
    void (*play)(uint32_t) = (void (*)(uint32_t))dlsym(RTLD_DEFAULT, "AudioServicesPlaySystemSound");
    if (play)
        play(1108);
}

// Наш снимок вместо снимка SpringBoard: превью и разметка тогда работают полностью
static void (*orig_saveScreenshot)(id, SEL, BOOL);
static void hook_saveScreenshot(id self, SEL _cmd, BOOL flash) {
    IRShotController *controller = [IRShotController shared];
    if (controller.showingThumbnail) {
        [controller removeThumbnail];
        [CATransaction flush]; // старое превью не должно попасть в кадр
    }
    UIImage *image = IRShotEnabled() && !controller.editing ? IRCaptureScreen() : nil;
    if (!image) {
        orig_saveScreenshot(self, _cmd, flash);
        return;
    }
    if (flash) {
        SBScreenFlash *screenFlash = [objc_getClass("SBScreenFlash") sharedInstance];
        if ([screenFlash respondsToSelector:@selector(flash)])
            [screenFlash flash];
    }
    IRPlayShutter();
    IRShotPresent(image, YES);
}

// Запасной путь: снимок сделал SpringBoard (снять экран было нечем) — превью после записи
static void (*orig_finishedWriting)(id, SEL, UIImage *, NSError *, void *);
static void hook_finishedWriting(id self, SEL _cmd, UIImage *image, NSError *error, void *context) {
    orig_finishedWriting(self, _cmd, image, error, context);
    if (error || ![image isKindOfClass:[UIImage class]] || !IRShotEnabled())
        return;
    dispatch_async(dispatch_get_main_queue(), ^{
        IRShotPresent(image, NO);
    });
}

// «Домой» на экране разметки закрывает её и сохраняет снимок с пометками
static BOOL gSwallowMenuUp;

static void (*orig_menuButtonDown)(id, SEL, void *);
static void hook_menuButtonDown(id self, SEL _cmd, void *event) {
    IRShotController *controller = [IRShotController shared];
    if (controller.editing) {
        gSwallowMenuUp = YES;
        [controller finishEditing:IRMarkupKeep animated:YES];
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

// Блокировка: ничего не теряем — снимок записывается, разметка закрывается с пометками
static void IRShotLockStateChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        IRShotController *controller = [IRShotController shared];
        if (controller.editing)
            [controller finishEditing:IRMarkupKeep animated:NO];
        else
            [controller removeThumbnail];
    });
}

__attribute__((constructor)) static void IRScreenshotInit(void) {
    @autoreleasepool {
        if (!IRIsProcess(@"com.apple.springboard"))
            return;
        Class shotter = objc_getClass("SBScreenShotter");
        IR_HOOK(shotter, @selector(saveScreenshot:), hook_saveScreenshot, &orig_saveScreenshot);
        IR_HOOK(shotter, @selector(finishedWritingScreenshot:didFinishSavingWithError:context:), hook_finishedWriting, &orig_finishedWriting);
        Class springBoard = objc_getClass("SpringBoard");
        IR_HOOK(springBoard, @selector(menuButtonDown:), hook_menuButtonDown, &orig_menuButtonDown);
        IR_HOOK(springBoard, @selector(menuButtonUp:), hook_menuButtonUp, &orig_menuButtonUp);
        IRObserveDarwin("com.apple.springboard.lockstate", IRShotLockStateChanged);
    }
}
