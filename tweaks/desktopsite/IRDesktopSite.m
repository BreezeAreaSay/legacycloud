// «Полная версия сайта» (iOS 9) в родном меню «Поделиться» Safari.
// Включает настольный User-Agent для текущей вкладки и перезагружает страницу; повторное нажатие
// возвращает мобильную версию.

#import "IRShared.h"
#import "IRPrivate.h"
#include <dlfcn.h>

// Safari 6 для OS X на том же движке WebKit, что и в iOS 6: сайты не получат обещаний, которые движок не выполнит.
#define IR_DESKTOP_UA @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_8_3) AppleWebKit/536.29.13 (KHTML, like Gecko) Version/6.0.4 Safari/536.29.13"

static void IRCollectWebViews(UIView *view, Class documentClass, NSMutableArray *found) {
    if (view.hidden || view.alpha < 0.01f)
        return;
    if ([view isKindOfClass:documentClass]) {
        [found addObject:view];
        return;
    }
    for (UIView *subview in view.subviews)
        IRCollectWebViews(subview, documentClass, found);
}

// WebView текущей вкладки — самый крупный видимый документ в окнах Safari.
static WebView *IRActiveWebView(void) {
    Class documentClass = NSClassFromString(@"UIWebBrowserView") ?: NSClassFromString(@"UIWebDocumentView");
    if (!documentClass)
        return nil;
    NSMutableArray *found = [NSMutableArray array];
    for (UIWindow *window in [UIApplication sharedApplication].windows)
        IRCollectWebViews(window, documentClass, found);

    UIWebDocumentView *best = nil;
    CGFloat bestArea = 0;
    for (UIWebDocumentView *view in found) {
        CGFloat area = view.bounds.size.width * view.bounds.size.height;
        if (area > bestArea && [view respondsToSelector:@selector(webView)]) {
            best = view;
            bestArea = area;
        }
    }
    id webView = [best webView];
    return [webView respondsToSelector:@selector(setCustomUserAgent:)] ? webView : nil;
}

// m.example.com → example.com: многие сайты сами переадресуют на мобильный поддомен.
static NSURL *IRDesktopURL(NSURL *url) {
    NSString *host = url.host;
    for (NSString *prefix in @[@"m.", @"mobile.", @"touch."]) {
        if (![host hasPrefix:prefix] || host.length <= prefix.length)
            continue;
        NSString *desktopHost = [host substringFromIndex:prefix.length];
        NSString *string = url.absoluteString;
        NSRange range = [string rangeOfString:host];
        if (range.location != NSNotFound)
            return [NSURL URLWithString:[string stringByReplacingCharactersInRange:range withString:desktopHost]];
    }
    return url;
}

// WebKit в iOS живёт в отдельном веб-потоке: из главного потока к WebView и WebFrame можно
// обращаться только под WebThreadLock() — так делают UIKit и Safari. Блокировка снимается сама
// в конце текущего витка главного цикла.
static void IRWebThreadLock(void) {
    static void (*lock)(void);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = (void (*)(void))dlsym(RTLD_DEFAULT, "WebThreadLock");
    });
    if (lock)
        lock();
}

static BOOL IRIsDesktop(WebView *webView) {
    IRWebThreadLock();
    return [[webView customUserAgent] isEqualToString:IR_DESKTOP_UA];
}

static void IRToggleDesktop(WebView *webView) {
    IRWebThreadLock();
    WebFrame *frame = [webView mainFrame];
    if (!frame)
        return;
    BOOL desktop = ![[webView customUserAgent] isEqualToString:IR_DESKTOP_UA];
    [webView setCustomUserAgent:desktop ? IR_DESKTOP_UA : nil];
    NSURL *url = [[[frame dataSource] request] URL];
    if (desktop && url.host)
        [frame loadRequest:[NSURLRequest requestWithURL:IRDesktopURL(url)]];
    else
        [frame reload];
}

#pragma mark - Пункт меню

@interface IRDesktopSiteActivity : UIActivity
@end

@implementation IRDesktopSiteActivity {
    WebView *_webView; // сильная ссылка: меню живёт недолго, а weak на классы WebKit в iOS 6 не гарантирован
}

- (instancetype)initWithWebView:(WebView *)webView {
    if ((self = [super init]))
        _webView = webView;
    return self;
}

- (NSString *)activityType {
    return @"com.ios6revive.desktopsite";
}

- (NSString *)activityTitle {
    return IRIsDesktop(_webView) ? @"Мобильная версия" : @"Полная версия";
}

// Шаблон-маска 43×43: iOS 6 сама рисует из неё глянцевую серую кнопку меню.
- (UIImage *)activityImage {
    const CGFloat size = 43;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0);
    [[UIColor blackColor] set];

    UIBezierPath *screen = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(5, 8, 33, 21) cornerRadius:2.5];
    [screen appendPath:[[UIBezierPath bezierPathWithRect:CGRectMake(8, 11, 27, 15)] bezierPathByReversingPath]];
    [screen fill];
    [[UIBezierPath bezierPathWithRect:CGRectMake(19, 29, 5, 4)] fill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(13, 33, 17, 2.5) cornerRadius:1.25] fill];

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

- (BOOL)canPerformWithActivityItems:(NSArray *)items {
    return _webView != nil;
}

- (void)performActivity {
    WebView *webView = _webView;
    [self activityDidFinish:YES];
    // Меню «Поделиться» ещё закрывается — страницу трогаем на следующем витке, когда Safari вернулся к вкладке.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (webView)
            IRToggleDesktop(webView);
    });
}

@end

#pragma mark -

static id (*orig_initActivity)(UIActivityViewController *, SEL, NSArray *, NSArray *);
static id hook_initActivity(UIActivityViewController *self, SEL _cmd, NSArray *items, NSArray *activities) {
    WebView *webView = IRActiveWebView();
    if (webView) {
        NSMutableArray *extended = [NSMutableArray arrayWithArray:activities ?: @[]];
        [extended addObject:[[IRDesktopSiteActivity alloc] initWithWebView:webView]];
        activities = extended;
    }
    return orig_initActivity(self, _cmd, items, activities);
}

__attribute__((constructor)) static void IRDesktopSiteInit(void) {
    @autoreleasepool {
        if (!IRIsProcess(@"com.apple.mobilesafari"))
            return;
        IR_HOOK([UIActivityViewController class], @selector(initWithActivityItems:applicationActivities:),
                hook_initActivity, &orig_initActivity);
    }
}
