// Смахивание назад от левого края экрана (iOS 7) с анимацией сдвига iOS 6.
//
// iOS 6 не умеет интерактивные переходы, поэтому экран рисуется снимками:
//  * перед каждым push снимаем текущий экран и вешаем снимок на контроллер, который уходит вниз;
//  * при жесте два снимка (предыдущий и текущий экран) едут вместе за пальцем, как страницы в iOS 6;
//  * если жест завершён — делаем настоящий pop без анимации и плавно убираем снимки.
// Отмена жеста ничего не меняет в программе: стек контроллеров трогается только при завершении.

#import "IRShared.h"
#import "IRPrivate.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kIREdgeWidth = 20;
static const CGFloat kIRShadowWidth = 8;

static const void *kIRSnapshotKey = &kIRSnapshotKey;
static const void *kIRRecognizerKey = &kIRRecognizerKey;

static BOOL gEnabled = YES;
static CFAbsoluteTime gLastTransition;

static UIImage *IRSnapshot(UIView *view) {
    CGRect bounds = view.bounds;
    if (bounds.size.width < 1 || bounds.size.height < 1)
        return nil;
    UIGraphicsBeginImageContextWithOptions(bounds.size, YES, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(ctx, -bounds.origin.x, -bounds.origin.y);
    [view.layer renderInContext:ctx];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static void IRForgetSnapshot(UIViewController *controller) {
    if (controller)
        objc_setAssociatedObject(controller, kIRSnapshotKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Тень по краю уезжающего экрана

@interface IRSwipeShadowView : UIView
@end

@implementation IRSwipeShadowView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.userInteractionEnabled = NO;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat colors[] = {0, 0, 0, 0, 0, 0, 0, 0.3};
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, colors, NULL, 2);
    CGContextDrawLinearGradient(UIGraphicsGetCurrentContext(), gradient, CGPointZero,
                                CGPointMake(self.bounds.size.width, 0), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
}

@end

#pragma mark - Жест

@interface IRSwipeBackHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)attachToNavigationController:(UINavigationController *)navigationController;
@end

@implementation IRSwipeBackHandler {
    UIView *_overlay;
    UIImageView *_previousView;
    UIImageView *_currentView;
    __weak UIView *_touchedView;
    BOOL _active;
}

+ (instancetype)shared {
    static IRSwipeBackHandler *handler;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handler = [[IRSwipeBackHandler alloc] init];
    });
    return handler;
}

- (void)attachToNavigationController:(UINavigationController *)nav {
    if (!nav.isViewLoaded || objc_getAssociatedObject(nav, kIRRecognizerKey))
        return;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.delegate = self;
    pan.maximumNumberOfTouches = 1;
    [nav.view addGestureRecognizer:pan];
    objc_setAssociatedObject(nav, kIRRecognizerKey, pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UINavigationController *IRNavigationForRecognizer(UIGestureRecognizer *recognizer) {
    UIResponder *responder = recognizer.view.nextResponder;
    return [responder isKindOfClass:[UINavigationController class]] ? (UINavigationController *)responder : nil;
}

- (UIImage *)previousSnapshotForNavigation:(UINavigationController *)nav {
    NSArray *controllers = nav.viewControllers;
    if (controllers.count < 2)
        return nil;
    UIImage *snapshot = objc_getAssociatedObject(controllers[controllers.count - 2], kIRSnapshotKey);
    // После поворота или скрытия панели вкладок старый снимок уже не совпадает с экраном.
    return CGSizeEqualToSize(snapshot.size, nav.view.bounds.size) ? snapshot : nil;
}

- (BOOL)canBeginForNavigation:(UINavigationController *)nav {
    if (!gEnabled || _active || !nav || nav.presentedViewController)
        return NO;
    if ([nav respondsToSelector:@selector(_isTransitioning)] && [nav _isTransitioning])
        return NO;
    if (CFAbsoluteTimeGetCurrent() - gLastTransition < 0.35)
        return NO;
    // Как в iOS 7: своя левая кнопка (например «Отменить») отключает жест.
    UINavigationItem *item = nav.topViewController.navigationItem;
    if (item.hidesBackButton || (item.leftBarButtonItem && !item.leftItemsSupplementBackButton))
        return NO;
    return [self previousSnapshotForNavigation:nav] != nil;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    UIView *host = recognizer.view;
    if ([touch locationInView:host].x - host.bounds.origin.x > kIREdgeWidth)
        return NO;
    if (![self canBeginForNavigation:IRNavigationForRecognizer(recognizer)])
        return NO;
    _touchedView = touch.view;
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    CGPoint velocity = [(UIPanGestureRecognizer *)recognizer velocityInView:recognizer.view];
    if (velocity.x <= 0 || fabsf(velocity.x) < fabsf(velocity.y))
        return NO;
    return [self canBeginForNavigation:IRNavigationForRecognizer(recognizer)];
}

// Прокрутка под пальцем могла начаться раньше нас — разрешаем и гасим её в начале жеста.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    UIView *view = other.view;
    return [view isKindOfClass:[UIScrollView class]] && other == ((UIScrollView *)view).panGestureRecognizer;
}

- (void)cancelScrollingUnderTouch:(UIView *)host {
    for (UIView *view = _touchedView; view && view != host; view = view.superview) {
        if (![view isKindOfClass:[UIScrollView class]])
            continue;
        UIGestureRecognizer *pan = ((UIScrollView *)view).panGestureRecognizer;
        pan.enabled = NO;
        pan.enabled = YES;
    }
}

- (void)setOffset:(CGFloat)offset width:(CGFloat)width {
    CGRect frame = _currentView.frame;
    frame.origin.x = offset;
    _currentView.frame = frame;
    frame.origin.x = offset - width;
    _previousView.frame = frame;
}

- (BOOL)beginWithNavigation:(UINavigationController *)nav {
    UIView *host = nav.view;
    UIImage *previous = [self previousSnapshotForNavigation:nav];
    UIImage *current = IRSnapshot(host);
    if (!previous || !current)
        return NO;

    [host endEditing:YES];
    [self cancelScrollingUnderTouch:host];

    CGRect bounds = host.bounds;
    _overlay = [[UIView alloc] initWithFrame:bounds];
    _overlay.backgroundColor = [UIColor blackColor];
    _overlay.clipsToBounds = YES;

    _previousView = [[UIImageView alloc] initWithImage:previous];
    _currentView = [[UIImageView alloc] initWithImage:current];
    _previousView.frame = _currentView.frame = CGRectMake(0, 0, bounds.size.width, bounds.size.height);

    IRSwipeShadowView *shadow = [[IRSwipeShadowView alloc] initWithFrame:CGRectMake(-kIRShadowWidth, 0, kIRShadowWidth, bounds.size.height)];
    shadow.autoresizingMask = UIViewAutoresizingFlexibleHeight;
    _currentView.clipsToBounds = NO;
    [_currentView addSubview:shadow];

    [_overlay addSubview:_previousView];
    [_overlay addSubview:_currentView];
    [host addSubview:_overlay];
    [self setOffset:0 width:bounds.size.width];
    _active = YES;
    return YES;
}

- (void)finishWithNavigation:(UINavigationController *)nav complete:(BOOL)complete velocity:(CGFloat)velocity {
    UIView *overlay = _overlay;
    CGFloat width = overlay.bounds.size.width;
    CGFloat target = complete ? width : 0;
    CGFloat distance = fabsf(target - _currentView.frame.origin.x);
    NSTimeInterval duration = MAX(0.12, MIN(0.3, distance / MAX(fabsf(velocity), 800)));

    [UIView animateWithDuration:duration delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
                         [self setOffset:target width:width];
                     }
                     completion:^(BOOL finished) {
                         if (complete) {
                             [nav popViewControllerAnimated:NO];
                             // Снимок предыдущего экрана мог устареть — мягко проявляем живой экран.
                             [UIView animateWithDuration:0.15 animations:^{
                                 overlay.alpha = 0;
                             } completion:^(BOOL done) {
                                 [overlay removeFromSuperview];
                             }];
                         } else {
                             [overlay removeFromSuperview];
                         }
                         [self reset];
                     }];
}

- (void)reset {
    _overlay = nil;
    _previousView = nil;
    _currentView = nil;
    _active = NO;
}

- (void)handlePan:(UIPanGestureRecognizer *)recognizer {
    UINavigationController *nav = IRNavigationForRecognizer(recognizer);
    UIView *host = recognizer.view;
    CGFloat width = host.bounds.size.width;

    switch (recognizer.state) {
    case UIGestureRecognizerStateBegan:
        if (!nav || ![self beginWithNavigation:nav]) {
            recognizer.enabled = NO; // отменяем жест
            recognizer.enabled = YES;
        }
        break;
    case UIGestureRecognizerStateChanged:
        if (_active)
            [self setOffset:MAX(0, [recognizer translationInView:host].x) width:width];
        break;
    case UIGestureRecognizerStateEnded: {
        if (!_active)
            break;
        CGFloat offset = MAX(0, [recognizer translationInView:host].x);
        CGFloat velocity = [recognizer velocityInView:host].x;
        BOOL complete = velocity > 500 || (offset > width / 2 && velocity > -200);
        [self finishWithNavigation:nav complete:complete velocity:velocity];
        break;
    }
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed:
        if (_active)
            [self finishWithNavigation:nav complete:NO velocity:0];
        break;
    default:
        break;
    }
}

@end

#pragma mark - Перехваты UINavigationController

static void (*orig_viewDidLoad)(UINavigationController *, SEL);
static void hook_viewDidLoad(UINavigationController *self, SEL _cmd) {
    orig_viewDidLoad(self, _cmd);
    [[IRSwipeBackHandler shared] attachToNavigationController:self];
}

static void (*orig_viewDidAppear)(UINavigationController *, SEL, BOOL);
static void hook_viewDidAppear(UINavigationController *self, SEL _cmd, BOOL animated) {
    orig_viewDidAppear(self, _cmd, animated);
    [[IRSwipeBackHandler shared] attachToNavigationController:self]; // если подкласс не вызвал viewDidLoad у super
}

static void (*orig_push)(UINavigationController *, SEL, UIViewController *, BOOL);
static void hook_push(UINavigationController *self, SEL _cmd, UIViewController *controller, BOOL animated) {
    UIViewController *top = self.topViewController;
    if (gEnabled && top && controller && top != controller && self.isViewLoaded && self.view.window) {
        UIImage *snapshot = IRSnapshot(self.view);
        if (snapshot)
            objc_setAssociatedObject(top, kIRSnapshotKey, snapshot, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    gLastTransition = CFAbsoluteTimeGetCurrent();
    orig_push(self, _cmd, controller, animated);
}

static UIViewController *(*orig_pop)(UINavigationController *, SEL, BOOL);
static UIViewController *hook_pop(UINavigationController *self, SEL _cmd, BOOL animated) {
    gLastTransition = CFAbsoluteTimeGetCurrent();
    UIViewController *popped = orig_pop(self, _cmd, animated);
    IRForgetSnapshot(self.topViewController); // снимок нужен, только пока контроллер закрыт другим
    return popped;
}

static NSArray *(*orig_popTo)(UINavigationController *, SEL, UIViewController *, BOOL);
static NSArray *hook_popTo(UINavigationController *self, SEL _cmd, UIViewController *controller, BOOL animated) {
    gLastTransition = CFAbsoluteTimeGetCurrent();
    NSArray *popped = orig_popTo(self, _cmd, controller, animated);
    for (UIViewController *each in popped)
        IRForgetSnapshot(each);
    IRForgetSnapshot(self.topViewController);
    return popped;
}

static NSArray *(*orig_popToRoot)(UINavigationController *, SEL, BOOL);
static NSArray *hook_popToRoot(UINavigationController *self, SEL _cmd, BOOL animated) {
    gLastTransition = CFAbsoluteTimeGetCurrent();
    NSArray *popped = orig_popToRoot(self, _cmd, animated);
    for (UIViewController *each in popped)
        IRForgetSnapshot(each);
    IRForgetSnapshot(self.topViewController);
    return popped;
}

static void (*orig_setViewControllers)(UINavigationController *, SEL, NSArray *, BOOL);
static void hook_setViewControllers(UINavigationController *self, SEL _cmd, NSArray *controllers, BOOL animated) {
    gLastTransition = CFAbsoluteTimeGetCurrent();
    orig_setViewControllers(self, _cmd, controllers, animated);
    IRForgetSnapshot(self.topViewController);
}

#pragma mark -

static void IRReloadSettings(void) {
    gEnabled = IRFlag(kIRSwipeBack, IRStateSwipeBack, YES);
}

static void IRStateChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    IRReloadSettings();
}

__attribute__((constructor)) static void IRSwipeBackInit(void) {
    @autoreleasepool {
        if (IRIsProcess(@"com.apple.springboard"))
            return;
        IRReloadSettings();
        IRObserveDarwin(IR_NOTIFY_STATE, IRStateChanged);

        Class nav = [UINavigationController class];
        IR_HOOK(nav, @selector(viewDidLoad), hook_viewDidLoad, &orig_viewDidLoad);
        IR_HOOK(nav, @selector(viewDidAppear:), hook_viewDidAppear, &orig_viewDidAppear);
        IR_HOOK(nav, @selector(pushViewController:animated:), hook_push, &orig_push);
        IR_HOOK(nav, @selector(popViewControllerAnimated:), hook_pop, &orig_pop);
        IR_HOOK(nav, @selector(popToViewController:animated:), hook_popTo, &orig_popTo);
        IR_HOOK(nav, @selector(popToRootViewControllerAnimated:), hook_popToRoot, &orig_popToRoot);
        IR_HOOK(nav, @selector(setViewControllers:animated:), hook_setViewControllers, &orig_setViewControllers);
    }
}
