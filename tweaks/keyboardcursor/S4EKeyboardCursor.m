// Курсор свайпом по клавиатуре (iOS 12): ведите пальцем по пробелу — курсор едет по тексту,
// влево-вправо по символам и вверх-вниз по строкам. Свайп от Shift выделяет текст.
// Обычное нажатие на пробел и Shift работает как раньше: жест начинается, только когда палец поехал.

#import "S4EShared.h"
#include <dlfcn.h>

#define kS4EKeyboardCursor @"KeyboardCursor"

static const CGFloat kS4EStepX = 9;   // точек на символ
static const CGFloat kS4EStepY = 24;  // точек на строку
static const void *kS4ERecognizerKey = &kS4ERecognizerKey;

@interface UIKBTree : NSObject
- (NSString *)name;
- (NSString *)representedString;
@end

@interface UIKeyboardLayoutStar : UIView
- (UIKBTree *)keyHitTest:(CGPoint)point;
@end

@interface UIKeyboardImpl : UIView
+ (instancetype)activeInstance;
- (UIResponder<UITextInput> *)inputDelegate;
@end

static BOOL gEnabled = YES;

// Поля в Safari и других веб-страницах живут в WebKit: трогать их можно только под WebThreadLock()
static void S4EWebThreadLock(void) {
    static void (*lock)(void);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = (void (*)(void))dlsym(RTLD_DEFAULT, "WebThreadLock");
    });
    if (lock)
        lock();
}

typedef enum { S4ECursorNone, S4ECursorMove, S4ECursorSelect } S4ECursorMode;

@interface S4ECursorHandler : NSObject <UIGestureRecognizerDelegate>
@end

@implementation S4ECursorHandler {
    S4ECursorMode _mode;
    UIResponder<UITextInput> *_input;
    UITextPosition *_anchor;
    UITextPosition *_focus;
    NSInteger _stepsX, _stepsY;
}

+ (instancetype)shared {
    static S4ECursorHandler *handler;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handler = [[S4ECursorHandler alloc] init];
    });
    return handler;
}

- (void)attachTo:(UIView *)layout {
    if (objc_getAssociatedObject(layout, kS4ERecognizerKey))
        return;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
    pan.delegate = self;
    pan.maximumNumberOfTouches = 1;
    [layout addGestureRecognizer:pan];
    objc_setAssociatedObject(layout, kS4ERecognizerKey, pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    _mode = S4ECursorNone;
    UIKeyboardLayoutStar *layout = (UIKeyboardLayoutStar *)recognizer.view;
    if (!gEnabled || ![layout respondsToSelector:@selector(keyHitTest:)])
        return NO;
    UIKBTree *key = [layout keyHitTest:[touch locationInView:layout]];
    NSString *name = [key respondsToSelector:@selector(name)] ? [key name] : nil;
    NSString *string = [key respondsToSelector:@selector(representedString)] ? [key representedString] : nil;
    if ([string isEqualToString:@" "])
        _mode = S4ECursorMove;
    else if ([name rangeOfString:@"Shift" options:NSCaseInsensitiveSearch].location != NSNotFound)
        _mode = S4ECursorSelect;
    return _mode != S4ECursorNone;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (_mode == S4ECursorNone)
        return NO;
    S4EWebThreadLock();
    UIKeyboardImpl *keyboard = [objc_getClass("UIKeyboardImpl") activeInstance];
    id input = [keyboard respondsToSelector:@selector(inputDelegate)] ? [keyboard inputDelegate] : nil;
    if (![input conformsToProtocol:@protocol(UITextInput)] || ![input selectedTextRange])
        return NO;
    _input = input;
    UITextRange *selection = [_input selectedTextRange];
    _anchor = selection.start;
    _focus = selection.end;
    _stepsX = _stepsY = 0;
    return YES;
}

- (void)pan:(UIPanGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateEnded || recognizer.state == UIGestureRecognizerStateCancelled ||
        recognizer.state == UIGestureRecognizerStateFailed) {
        _input = nil;
        _anchor = _focus = nil;
        return;
    }
    if (recognizer.state != UIGestureRecognizerStateChanged || !_input)
        return;

    CGPoint t = [recognizer translationInView:recognizer.view];
    NSInteger stepsX = (NSInteger)(t.x / kS4EStepX), stepsY = (NSInteger)(t.y / kS4EStepY);
    if (stepsX == _stepsX && stepsY == _stepsY)
        return;

    S4EWebThreadLock();
    UITextPosition *focus = _focus;
    if (stepsX != _stepsX)
        focus = [_input positionFromPosition:focus offset:stepsX - _stepsX] ?: focus;
    if (stepsY != _stepsY) {
        UITextLayoutDirection direction = stepsY > _stepsY ? UITextLayoutDirectionDown : UITextLayoutDirectionUp;
        focus = [_input positionFromPosition:focus inDirection:direction offset:labs(stepsY - _stepsY)] ?: focus;
    }
    _stepsX = stepsX;
    _stepsY = stepsY;
    _focus = focus;

    UITextPosition *from = _mode == S4ECursorSelect ? _anchor : focus;
    UITextPosition *to = focus;
    if ([_input comparePosition:from toPosition:to] == NSOrderedDescending) {
        UITextPosition *swap = from;
        from = to;
        to = swap;
    }
    UITextRange *range = [_input textRangeFromPosition:from toPosition:to];
    if (range)
        [_input setSelectedTextRange:range];
}

@end

static void (*orig_didMoveToWindow)(UIView *, SEL);
static void hook_didMoveToWindow(UIView *self, SEL _cmd) {
    orig_didMoveToWindow(self, _cmd);
    if (self.window)
        [[S4ECursorHandler shared] attachTo:self];
}

// Флаг из plist; если программа в песочнице не может его прочитать — включено.
static void S4EReload(void) {
    gEnabled = S4EBool(S4EPrefsRead(), kS4EKeyboardCursor, YES);
}

static void S4EPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    S4EReload();
}

__attribute__((constructor)) static void S4EKeyboardCursorInit(void) {
    @autoreleasepool {
        S4EReload();
        S4EObserveDarwin(S4E_NOTIFY_PREFS, S4EPrefsChanged);
        S4EObserveDarwin(S4E_NOTIFY_STATE, S4EPrefsChanged);
        S4E_HOOK(objc_getClass("UIKeyboardLayoutStar"), @selector(didMoveToWindow), hook_didMoveToWindow, &orig_didMoveToWindow);
    }
}
