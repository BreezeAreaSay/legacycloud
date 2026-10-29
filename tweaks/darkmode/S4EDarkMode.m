// Dark Mode (iOS 13), built from iOS 6's own dark materials.
//
// Bars turn into black glass (UIBarStyleBlack, as in Photos and Music). Grouped tables lie on dark linen
// with charcoal cells and black borders, plain tables become charcoal. Dark text turns light, keeping its
// hue (the blue of values stays blue), and the white embossing under it becomes a black one on top, like
// the titles of iOS 6 bars. The keyboard is the dark one of alerts, action sheets are black translucent.
//
// Only what an app leaves standard is changed: a table with its own background, a bar with its own image,
// a cell with its own background view keep their look. The app's own values are remembered, so the
// appearance switches back and forth live, without restarting apps.
//
// SpringBoard is the engine: it decides the appearance from the settings and the schedule and publishes
// it. Apple apps always follow it; other apps only if In Other Apps was on when they started.

#import "S4EShared.h"
#import "S4EDarkMode.h"

@interface UIColor (S4EDarkMode)
- (NSString *)_systemColorName;
+ (UIColor *)pinStripeColor;
@end

static BOOL gDark;
static BOOL gAppleApp;
static int gApplying; // > 0 while we set a value ourselves, so the setter hooks keep out

#pragma mark - Colors

static BOOL S4ERGBA(UIColor *color, CGFloat *r, CGFloat *g, CGFloat *b, CGFloat *a) {
    if (!color)
        return NO;
    if ([color getRed:r green:g blue:b alpha:a])
        return YES;
    CGFloat white;
    if ([color getWhite:&white alpha:a]) {
        *r = *g = *b = white;
        return YES;
    }
    return NO; // a pattern
}

static CGFloat S4ELuma(CGFloat r, CGFloat g, CGFloat b) {
    return 0.299f * r + 0.587f * g + 0.114f * b;
}

static BOOL S4EIsClear(UIColor *color) {
    CGFloat r, g, b, a;
    return S4ERGBA(color, &r, &g, &b, &a) && a < 0.05f;
}

// The standard light surfaces of iOS 6: white, the pinstripes of grouped tables and their cousins
static BOOL S4EIsLightBackground(UIColor *color) {
    if (!color)
        return YES;
    static NSSet *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [NSSet setWithObjects:@"whiteColor", @"groupTableViewBackgroundColor", @"pinStripeColor", @"tableBackgroundColor",
                                      @"tableCellGroupedBackgroundColor", @"tableCellGroupedBackgroundColorLegacyWhite",
                                      @"tableCellPlainBackgroundColor", nil];
    });
    if ([color isEqual:[UIColor groupTableViewBackgroundColor]])
        return YES;
    if ([UIColor respondsToSelector:@selector(pinStripeColor)] && [color isEqual:[UIColor pinStripeColor]])
        return YES;
    NSString *name = [color respondsToSelector:@selector(_systemColorName)] ? [color _systemColorName] : nil;
    if (name && [names containsObject:name])
        return YES;
    CGFloat r, g, b, a;
    return S4ERGBA(color, &r, &g, &b, &a) && a > 0.9f && S4ELuma(r, g, b) > 0.85f;
}

static CGFloat S4EHueToRGB(CGFloat p, CGFloat q, CGFloat t) {
    if (t < 0)
        t += 1;
    if (t > 1)
        t -= 1;
    if (t < 1.0f / 6)
        return p + (q - p) * 6 * t;
    if (t < 0.5f)
        return q;
    if (t < 2.0f / 3)
        return p + (q - p) * (2.0f / 3 - t) * 6;
    return p;
}

// Dark text turned light with the same hue: black becomes off-white, the blue of values a light blue.
// nil: the color is light enough already.
static UIColor *S4ELightText(UIColor *color) {
    CGFloat r, g, b, a;
    if (!S4ERGBA(color, &r, &g, &b, &a) || a < 0.05f || S4ELuma(r, g, b) >= 0.6f)
        return nil;
    CGFloat max = MAX(r, MAX(g, b)), min = MIN(r, MIN(g, b));
    CGFloat l = (max + min) / 2, d = max - min, s = 0, h = 0;
    if (d > 0.0001f) {
        s = l > 0.5f ? d / (2 - max - min) : d / (max + min);
        if (max == r)
            h = (g - b) / d + (g < b ? 6 : 0);
        else if (max == g)
            h = (b - r) / d + 2;
        else
            h = (r - g) / d + 4;
        h /= 6;
    }
    CGFloat light = 0.94f - 0.55f * l;
    CGFloat q = light < 0.5f ? light * (1 + s) : light + s - light * s, p = 2 * light - q;
    return [UIColor colorWithRed:S4EHueToRGB(p, q, h + 1.0f / 3) green:S4EHueToRGB(p, q, h)
                            blue:S4EHueToRGB(p, q, h - 1.0f / 3) alpha:a];
}

static BOOL S4EIsLightShadow(UIColor *color) {
    CGFloat r, g, b, a;
    return S4ERGBA(color, &r, &g, &b, &a) && a > 0.05f && S4ELuma(r, g, b) > 0.6f;
}

#define S4E_COLOR(name, expression) \
    static UIColor *name(void) { \
        static UIColor *color; \
        static dispatch_once_t once; \
        dispatch_once(&once, ^{ color = (expression); }); \
        return color; \
    }

S4E_COLOR(S4EGroupedCell, [UIColor colorWithRed:0.204f green:0.212f blue:0.227f alpha:1])
S4E_COLOR(S4EGroupedBorder, [UIColor colorWithWhite:0.04f alpha:1])
S4E_COLOR(S4EPlainBack, [UIColor colorWithRed:0.11f green:0.114f blue:0.125f alpha:1])
S4E_COLOR(S4EPlainSeparator, [UIColor colorWithRed:0.212f green:0.22f blue:0.24f alpha:1])
S4E_COLOR(S4EHeaderTint, [UIColor colorWithRed:0.25f green:0.26f blue:0.29f alpha:1])
S4E_COLOR(S4EIndexColor, [UIColor colorWithWhite:0.72f alpha:1])
S4E_COLOR(S4ETextShadow, [UIColor colorWithWhite:0 alpha:0.65f])
S4E_COLOR(S4EEtch, [UIColor colorWithWhite:1 alpha:0.06f])

// Dark linen: noise plus "threads", random brightness shifts per row and column, like the grey linen of
// Control Center but darker. A fixed seed, so the fabric is always the same; the tile repeats seamlessly.
static UIColor *S4ELinen(void) {
    static UIColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const int scale = (int)[UIScreen mainScreen].scale, side = 64 * scale;
        uint32_t seed = 0x5e0d;
        int rows[256], columns[256];
        for (int i = 0; i < side; i++) {
            seed = seed * 1103515245 + 12345;
            rows[i] = (int)((seed >> 16) % 11) - 5;
            seed = seed * 1103515245 + 12345;
            columns[i] = (int)((seed >> 16) % 11) - 5;
        }
        uint8_t *pixels = malloc(side * side);
        for (int y = 0; y < side; y++) {
            for (int x = 0; x < side; x++) {
                seed = seed * 1103515245 + 12345;
                int value = 37 + rows[y] / 2 + columns[x] / 2 + (int)((seed >> 16) % 7) - 3;
                pixels[y * side + x] = (uint8_t)MAX(0, MIN(255, value));
            }
        }
        CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
        CGContextRef ctx = CGBitmapContextCreate(pixels, side, side, 8, side, space, kCGImageAlphaNone);
        CGImageRef image = CGBitmapContextCreateImage(ctx);
        color = [UIColor colorWithPatternImage:[UIImage imageWithCGImage:image scale:scale orientation:UIImageOrientationUp]];
        CGImageRelease(image);
        CGContextRelease(ctx);
        CGColorSpaceRelease(space);
        free(pixels);
    });
    return color;
}

static BOOL S4EIsOurBackground(UIColor *color) {
    return color && (color == S4ELinen() || [color isEqual:S4EPlainBack()] || [color isEqual:S4EGroupedCell()]);
}

#pragma mark - Remembering the app's values

static BOOL S4EEqual(id a, id b) {
    return a == b || [a isEqual:b];
}

static id S4EBox(id value) {
    return value ?: [NSNull null];
}

static id S4EUnbox(id value) {
    return value == [NSNull null] ? nil : value;
}

// One themed property of one object. While dark (and the object is ours to theme), dark(original) gives
// our value — NSNull for nil — or nil to leave the app's value. The app's own value is kept next to ours:
// as long as the property still holds ours, the app hasn't touched it, and in light mode it comes back.
// If the app sets a new value meanwhile, that becomes its own value.
static void S4ETheme(id object, const void *key, BOOL dark, id (^get)(void), void (^set)(id value), id (^ours)(id original)) {
    id current = get();
    NSArray *record = objc_getAssociatedObject(object, key);
    id original = current;
    if (record && S4EEqual(S4EUnbox(record[1]), current))
        original = S4EUnbox(record[0]);
    id mine = dark ? ours(original) : nil;
    id wanted = mine ? S4EUnbox(mine) : original;
    if (!S4EEqual(wanted, current)) {
        gApplying++;
        set(wanted);
        gApplying--;
        current = get();
    }
    BOOL keep = mine && !S4EEqual(current, original);
    if (keep || record)
        objc_setAssociatedObject(object, key, keep ? @[S4EBox(original), S4EBox(current)] : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Text

static const char kS4ETextKey, kS4EShadowKey, kS4EOffsetKey, kS4ETextBackKey;

// fill: the color behind the text, for opaque labels; nil means clear
static void S4EStyleLabel(UILabel *label, BOOL dark, UIColor *fill) {
    S4ETheme(label, &kS4ETextKey, dark, ^id { return label.textColor; }, ^(id value) { label.textColor = value; },
             ^id(UIColor *original) { return S4ELightText(original); });
    BOOL flipped = NO, *flippedOut = &flipped; // set by the block below, which runs at once
    S4ETheme(label, &kS4EShadowKey, dark, ^id { return label.shadowColor; }, ^(id value) { label.shadowColor = value; },
             ^id(UIColor *original) {
                 *flippedOut = S4EIsLightShadow(original);
                 return *flippedOut ? S4ETextShadow() : nil;
             });
    // White embossing below becomes a black one on top, as on iOS 6 bars
    S4ETheme(label, &kS4EOffsetKey, dark && flipped, ^id { return [NSValue valueWithCGSize:label.shadowOffset]; },
             ^(id value) { label.shadowOffset = [value CGSizeValue]; },
             ^id(NSValue *original) {
                 CGSize offset = [original CGSizeValue];
                 return offset.height > 0 ? [NSValue valueWithCGSize:CGSizeMake(offset.width, -offset.height)] : nil;
             });
    S4ETheme(label, &kS4ETextBackKey, dark, ^id { return label.backgroundColor; }, ^(id value) { label.backgroundColor = value; },
             ^id(UIColor *original) { return original && S4EIsLightBackground(original) ? (fill ?: [UIColor clearColor]) : nil; });
}

static void S4EStyleTextField(UITextField *field, BOOL dark) {
    // A rounded or bezeled field stays white, so its text stays dark
    BOOL bare = field.borderStyle == UITextBorderStyleNone && !field.background && (!field.backgroundColor || S4EIsClear(field.backgroundColor));
    S4ETheme(field, &kS4ETextKey, dark && bare, ^id { return field.textColor; }, ^(id value) { field.textColor = value; },
             ^id(UIColor *original) { return S4ELightText(original ?: [UIColor blackColor]); });
}

static void S4EStyleTextView(UITextView *view, BOOL dark, UIColor *fill) {
    BOOL light = NO, *lightOut = &light; // set by the block below, which runs at once
    S4ETheme(view, &kS4ETextBackKey, dark, ^id { return view.backgroundColor; }, ^(id value) { view.backgroundColor = value; },
             ^id(UIColor *original) {
                 *lightOut = !original || S4EIsClear(original) || S4EIsLightBackground(original);
                 return original && !S4EIsClear(original) && *lightOut ? (fill ?: [UIColor clearColor]) : nil;
             });
    S4ETheme(view, &kS4ETextKey, dark && light, ^id { return view.textColor; }, ^(id value) { view.textColor = value; },
             ^id(UIColor *original) { return S4ELightText(original ?: [UIColor blackColor]); });
}

static BOOL S4EIsBar(UIView *view) {
    return [view isKindOfClass:[UINavigationBar class]] || [view isKindOfClass:[UIToolbar class]] || [view isKindOfClass:[UISearchBar class]];
}

// Text inside a cell or a header of our own: labels, bare text fields, text views. Controls draw their own
// text, bars are themed separately, and a light surface of the app's own keeps its dark text.
static void S4EStyleContent(UIView *view, BOOL dark, UIColor *fill, int depth) {
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UILabel class]])
            S4EStyleLabel((UILabel *)sub, dark, fill);
        else if ([sub isKindOfClass:[UITextField class]])
            S4EStyleTextField((UITextField *)sub, dark);
        else if ([sub isKindOfClass:[UITextView class]])
            S4EStyleTextView((UITextView *)sub, dark, fill);
        else if (depth < 3 && ![sub isKindOfClass:[UIControl class]] && ![sub isKindOfClass:[UIImageView class]] && !S4EIsBar(sub) &&
                 ![sub isKindOfClass:[UITableView class]] && !(sub.backgroundColor && !S4EIsClear(sub.backgroundColor)))
            S4EStyleContent(sub, dark, fill, depth + 1);
    }
}

#pragma mark - Bars

static const char kS4EBarStyleKey, kS4EBarTintKey;

static BOOL S4EBarHasImage(UIView *bar) {
    if ([bar isKindOfClass:[UINavigationBar class]])
        return [(UINavigationBar *)bar backgroundImageForBarMetrics:UIBarMetricsDefault] != nil;
    if ([bar isKindOfClass:[UIToolbar class]])
        return [(UIToolbar *)bar backgroundImageForToolbarPosition:UIToolbarPositionAny barMetrics:UIBarMetricsDefault] != nil;
    return NO;
}

// Black glass: the iOS 6 black bar style, which also turns the status bar black
static void S4EStyleBar(UIView *view) {
    id bar = view;
    BOOL dark = gDark && !S4EBarHasImage(view);
    S4ETheme(view, &kS4EBarStyleKey, dark, ^id { return @([bar barStyle]); }, ^(id value) { [bar setBarStyle:[value intValue]]; },
             ^id(NSNumber *original) { return [original intValue] == UIBarStyleDefault ? @(UIBarStyleBlack) : nil; });
    S4ETheme(view, &kS4EBarTintKey, dark, ^id { return [bar tintColor]; }, ^(id value) { [bar setTintColor:value]; },
             ^id(UIColor *original) { return original ? [NSNull null] : nil; });
}

#pragma mark - Tables

static const char kS4EThemedKey, kS4ETouchedKey, kS4EBackgroundKey, kS4EHiddenKey, kS4ESeparatorKey, kS4EIndexKey, kS4ETintKey;

static BOOL S4ETableThemed(UITableView *table) {
    return table && [objc_getAssociatedObject(table, &kS4EThemedKey) boolValue];
}

static UITableView *S4ETableOf(UIView *view) {
    int depth = 0;
    for (UIView *parent = view.superview; parent && depth < 4; parent = parent.superview, depth++)
        if ([parent isKindOfClass:[UITableView class]])
            return (UITableView *)parent;
    return nil;
}

static void S4EStyleCell(UITableViewCell *cell) {
    UITableView *table = S4ETableOf(cell);
    BOOL grouped = table.style == UITableViewStyleGrouped;
    UIView *backgroundView = cell.backgroundView;
    BOOL ownView = backgroundView && ![backgroundView isKindOfClass:objc_getClass("UIGroupTableViewCellBackground")];
    BOOL dark = gDark && S4ETableThemed(table) && !ownView;
    UIColor *fill = grouped ? S4EGroupedCell() : S4EPlainBack();
    BOOL standard = NO, *standardOut = &standard; // set by the block below, which runs at once
    S4ETheme(cell, &kS4EBackgroundKey, dark, ^id { return cell.backgroundColor; }, ^(id value) { cell.backgroundColor = value; },
             ^id(UIColor *original) {
                 // A plain cell may show the table's color, which is ours already
                 if (S4EIsOurBackground(original) || S4EIsClear(original)) {
                     *standardOut = YES;
                     return nil;
                 }
                 *standardOut = S4EIsLightBackground(original);
                 return *standardOut ? fill : nil;
             });
    UIView *content = cell.contentView;
    S4ETheme(content, &kS4EBackgroundKey, dark && standard, ^id { return content.backgroundColor; },
             ^(id value) { content.backgroundColor = value; },
             ^id(UIColor *original) { return original && !S4EIsClear(original) && S4EIsLightBackground(original) ? fill : nil; });
    S4EStyleContent(content, dark && standard, fill, 0);
    // A cell that was dark keeps being checked, even from the reuse queue, until it is light again
    objc_setAssociatedObject(cell, &kS4ETouchedKey, dark ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void S4EStyleHeader(UITableViewHeaderFooterView *header) {
    UITableView *table = S4ETableOf(header);
    BOOL dark = gDark && S4ETableThemed(table);
    // The labels are read from the ivars: the getters would create them
    for (NSString *name in @[@"_label", @"_detailLabel"]) {
        UILabel *label = S4EIvar(header, name.UTF8String);
        if ([label isKindOfClass:[UILabel class]])
            S4EStyleLabel(label, dark, nil);
    }
    // The grey-blue gradient of plain headers, darkened
    if (table.style == UITableViewStylePlain && [header respondsToSelector:@selector(setTintColor:)])
        S4ETheme(header, &kS4ETintKey, dark, ^id { return header.tintColor; }, ^(id value) { header.tintColor = value; },
                 ^id(UIColor *original) { return original ? nil : S4EHeaderTint(); });
}

// A header or footer view of the app's own, or the table header: only its text
static void S4EStyleLooseView(UIView *view, UITableView *table) {
    if ([view isKindOfClass:[UITableViewCell class]] || [view isKindOfClass:[UITableViewHeaderFooterView class]] ||
        [view isKindOfClass:[UIImageView class]] || S4EIsBar(view) || [view isKindOfClass:[UIControl class]])
        return;
    if ([view isKindOfClass:[UILabel class]]) {
        S4EStyleLabel((UILabel *)view, gDark && S4ETableThemed(table), nil);
        return;
    }
    if (view.backgroundColor && !S4EIsClear(view.backgroundColor))
        return;
    S4EStyleContent(view, gDark && S4ETableThemed(table), nil, 0);
}

static void S4EStyleTable(UITableView *table) {
    BOOL grouped = table.style == UITableViewStyleGrouped;
    UIView *backgroundView = table.backgroundView;
    BOOL ownView = backgroundView && ![backgroundView isKindOfClass:objc_getClass("UITableViewBackgroundView")];
    BOOL standard = NO, *standardOut = &standard; // set by the block below, which runs at once
    S4ETheme(table, &kS4EBackgroundKey, gDark && !ownView, ^id { return table.backgroundColor; },
             ^(id value) { table.backgroundColor = value; },
             ^id(UIColor *original) {
                 *standardOut = S4EIsLightBackground(original);
                 return *standardOut ? (grouped ? S4ELinen() : S4EPlainBack()) : nil;
             });
    BOOL dark = gDark && standard;
    if (backgroundView && !ownView)
        S4ETheme(backgroundView, &kS4EHiddenKey, dark, ^id { return @(backgroundView.hidden); },
                 ^(id value) { backgroundView.hidden = [value boolValue]; }, ^id(id original) { return @YES; });
    S4ETheme(table, &kS4ESeparatorKey, dark, ^id { return table.separatorColor; }, ^(id value) { table.separatorColor = value; },
             ^id(UIColor *original) { return S4EIsClear(original) ? nil : grouped ? S4EGroupedBorder() : S4EPlainSeparator(); });
    if ([table respondsToSelector:@selector(setSectionIndexColor:)])
        S4ETheme(table, &kS4EIndexKey, dark, ^id { return table.sectionIndexColor; }, ^(id value) { table.sectionIndexColor = value; },
                 ^id(UIColor *original) { return original ? nil : S4EIndexColor(); });

    if (dark == S4ETableThemed(table))
        return;
    objc_setAssociatedObject(table, &kS4EThemedKey, dark ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (UIView *sub in table.subviews) {
        if ([sub isKindOfClass:[UITableViewCell class]])
            S4EStyleCell((UITableViewCell *)sub);
        else if ([sub isKindOfClass:[UITableViewHeaderFooterView class]])
            S4EStyleHeader((UITableViewHeaderFooterView *)sub);
        else
            S4EStyleLooseView(sub, table);
    }
}

#pragma mark - Switching live

static void S4ERestyle(UIView *view) {
    if (S4EIsBar(view))
        S4EStyleBar(view);
    else if ([view isKindOfClass:[UITableView class]])
        S4EStyleTable((UITableView *)view);
    else if ([view isKindOfClass:[UITableViewCell class]])
        S4EStyleCell((UITableViewCell *)view);
    else if ([view isKindOfClass:[UITableViewHeaderFooterView class]])
        S4EStyleHeader((UITableViewHeaderFooterView *)view);
    else if ([view.superview isKindOfClass:[UITableView class]])
        S4EStyleLooseView(view, (UITableView *)view.superview);
    for (UIView *sub in view.subviews)
        S4ERestyle(sub);
}

static void S4EAppearanceChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    uint64_t state = S4EAppearance();
    BOOL dark = (state & S4EAppearanceDark) && (gAppleApp || (state & S4EAppearanceOtherApps));
    if (dark == gDark)
        return;
    gDark = dark;
    for (UIWindow *window in [UIApplication sharedApplication].windows)
        S4ERestyle(window);
}

#pragma mark - Hooks: bars

// The same three hooks for each kind of bar
#define S4E_BAR_HOOKS(kind)                                                                     \
    static void (*orig_##kind##_didMoveToWindow)(UIView *, SEL);                                \
    static void hook_##kind##_didMoveToWindow(UIView *self, SEL _cmd) {                         \
        orig_##kind##_didMoveToWindow(self, _cmd);                                              \
        if (self.window)                                                                        \
            S4EStyleBar(self);                                                                  \
    }                                                                                           \
    static void (*orig_##kind##_setBarStyle)(UIView *, SEL, int);                               \
    static void hook_##kind##_setBarStyle(UIView *self, SEL _cmd, int style) {                  \
        orig_##kind##_setBarStyle(self, _cmd, style);                                           \
        if (!gApplying && self.window)                                                          \
            S4EStyleBar(self);                                                                  \
    }                                                                                           \
    static void (*orig_##kind##_setTintColor)(UIView *, SEL, UIColor *);                        \
    static void hook_##kind##_setTintColor(UIView *self, SEL _cmd, UIColor *color) {            \
        orig_##kind##_setTintColor(self, _cmd, color);                                          \
        if (!gApplying && self.window)                                                          \
            S4EStyleBar(self);                                                                  \
    }

S4E_BAR_HOOKS(navigationBar)
S4E_BAR_HOOKS(toolbar)
S4E_BAR_HOOKS(searchBar)

#define S4E_HOOK_BAR(cls, kind)                                                                              \
    do {                                                                                                     \
        S4E_HOOK(cls, @selector(didMoveToWindow), hook_##kind##_didMoveToWindow, &orig_##kind##_didMoveToWindow); \
        S4E_HOOK(cls, @selector(setBarStyle:), hook_##kind##_setBarStyle, &orig_##kind##_setBarStyle);       \
        S4E_HOOK(cls, @selector(setTintColor:), hook_##kind##_setTintColor, &orig_##kind##_setTintColor);    \
    } while (0)

#pragma mark - Hooks: tables

static void (*orig_table_didMoveToWindow)(UITableView *, SEL);
static void hook_table_didMoveToWindow(UITableView *self, SEL _cmd) {
    orig_table_didMoveToWindow(self, _cmd);
    if (self.window)
        S4EStyleTable(self);
}

static void (*orig_table_setBackgroundColor)(UITableView *, SEL, UIColor *);
static void hook_table_setBackgroundColor(UITableView *self, SEL _cmd, UIColor *color) {
    orig_table_setBackgroundColor(self, _cmd, color);
    if (!gApplying && self.window)
        S4EStyleTable(self);
}

static void (*orig_table_setBackgroundView)(UITableView *, SEL, UIView *);
static void hook_table_setBackgroundView(UITableView *self, SEL _cmd, UIView *view) {
    orig_table_setBackgroundView(self, _cmd, view);
    if (!gApplying && self.window)
        S4EStyleTable(self);
}

static void (*orig_table_setSeparatorColor)(UITableView *, SEL, UIColor *);
static void hook_table_setSeparatorColor(UITableView *self, SEL _cmd, UIColor *color) {
    orig_table_setSeparatorColor(self, _cmd, color);
    if (!gApplying && self.window)
        S4EStyleTable(self);
}

// Header and footer views of the app's own arrive here
static void (*orig_table_didAddSubview)(UITableView *, SEL, UIView *);
static void hook_table_didAddSubview(UITableView *self, SEL _cmd, UIView *view) {
    orig_table_didAddSubview(self, _cmd, view);
    if (S4ETableThemed(self))
        S4EStyleLooseView(view, self);
}

static void (*orig_cell_layoutSubviews)(UITableViewCell *, SEL);
static void hook_cell_layoutSubviews(UITableViewCell *self, SEL _cmd) {
    orig_cell_layoutSubviews(self, _cmd);
    if (gDark || objc_getAssociatedObject(self, &kS4ETouchedKey))
        S4EStyleCell(self);
}

static void (*orig_header_layoutSubviews)(UITableViewHeaderFooterView *, SEL);
static void hook_header_layoutSubviews(UITableViewHeaderFooterView *self, SEL _cmd) {
    orig_header_layoutSubviews(self, _cmd);
    S4EStyleHeader(self);
}

// The light etched line under each group and the highlight inside it, softened on dark linen
static id S4ESoftEtch(UIView *background, UIColor *color) {
    if (!gDark || !S4ETableThemed(S4ETableOf(background)) || !S4EIsLightShadow(color))
        return color;
    return S4EEtch();
}

static id (*orig_bottomShadowColor)(UIView *, SEL);
static id hook_bottomShadowColor(UIView *self, SEL _cmd) {
    return S4ESoftEtch(self, orig_bottomShadowColor(self, _cmd));
}

static id (*orig_topShadowColor)(UIView *, SEL);
static id hook_topShadowColor(UIView *self, SEL _cmd) {
    return S4ESoftEtch(self, orig_topShadowColor(self, _cmd));
}

#pragma mark - Hooks: keyboard and action sheets

static int (*orig_keyboardAppearance)(id, SEL);
static int hook_keyboardAppearance(id self, SEL _cmd) {
    int appearance = orig_keyboardAppearance(self, _cmd);
    return gDark && appearance == UIKeyboardAppearanceDefault ? UIKeyboardAppearanceAlert : appearance;
}

static void S4EStyleSheet(UIActionSheet *sheet) {
    if (gDark && (sheet.actionSheetStyle == UIActionSheetStyleAutomatic || sheet.actionSheetStyle == UIActionSheetStyleDefault))
        sheet.actionSheetStyle = UIActionSheetStyleBlackTranslucent;
}

static void (*orig_showInView)(UIActionSheet *, SEL, UIView *);
static void hook_showInView(UIActionSheet *self, SEL _cmd, UIView *view) {
    S4EStyleSheet(self);
    orig_showInView(self, _cmd, view);
}

static void (*orig_showFromToolbar)(UIActionSheet *, SEL, UIToolbar *);
static void hook_showFromToolbar(UIActionSheet *self, SEL _cmd, UIToolbar *toolbar) {
    S4EStyleSheet(self);
    orig_showFromToolbar(self, _cmd, toolbar);
}

static void (*orig_showFromTabBar)(UIActionSheet *, SEL, UITabBar *);
static void hook_showFromTabBar(UIActionSheet *self, SEL _cmd, UITabBar *tabBar) {
    S4EStyleSheet(self);
    orig_showFromTabBar(self, _cmd, tabBar);
}

static void (*orig_showFromBarButtonItem)(UIActionSheet *, SEL, UIBarButtonItem *, BOOL);
static void hook_showFromBarButtonItem(UIActionSheet *self, SEL _cmd, UIBarButtonItem *item, BOOL animated) {
    S4EStyleSheet(self);
    orig_showFromBarButtonItem(self, _cmd, item, animated);
}

static void (*orig_showFromRect)(UIActionSheet *, SEL, CGRect, UIView *, BOOL);
static void hook_showFromRect(UIActionSheet *self, SEL _cmd, CGRect rect, UIView *view, BOOL animated) {
    S4EStyleSheet(self);
    orig_showFromRect(self, _cmd, rect, view, animated);
}

#pragma mark - SpringBoard: the engine

@interface S4EAppearanceClock : NSObject
@end

static S4EAppearanceClock *gClock;
static NSTimer *gClockTimer;

static void S4EPublishAppearance(void) {
    NSDictionary *prefs = S4EPrefsRead() ?: @{};
    uint64_t state = S4EAppearancePublished | (S4EDMIsDark(prefs, [NSDate date]) ? S4EAppearanceDark : 0) |
                     (S4EBool(prefs, kS4EDMOtherApps, NO) ? S4EAppearanceOtherApps : 0);
    static int token;
    static BOOL ready;
    if (!ready)
        ready = notify_register_check(S4E_NOTIFY_APPEARANCE, &token) == NOTIFY_STATUS_OK;
    if (ready) {
        uint64_t old = 0;
        notify_get_state(token, &old);
        if (old != state) {
            notify_set_state(token, state);
            notify_post(S4E_NOTIFY_APPEARANCE);
        }
    }
    // The schedule is checked twice a minute only while Automatic is on
    BOOL automatic = S4EBool(prefs, kS4EDMAutomatic, NO);
    if (automatic && !gClockTimer)
        gClockTimer = [NSTimer scheduledTimerWithTimeInterval:30 target:gClock selector:@selector(tick:) userInfo:nil repeats:YES];
    else if (!automatic && gClockTimer) {
        [gClockTimer invalidate];
        gClockTimer = nil;
    }
}

@implementation S4EAppearanceClock
- (void)tick:(NSTimer *)timer {
    S4EPublishAppearance();
}
@end

static void S4EEngineWake(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    S4EPublishAppearance();
}

#pragma mark - Start

__attribute__((constructor)) static void S4EDarkModeInit(void) {
    @autoreleasepool {
        NSBundle *bundle = [NSBundle mainBundle];
        NSString *identifier = bundle.bundleIdentifier;
        if (!identifier || ![bundle.bundlePath hasSuffix:@".app"])
            return;
        if ([identifier isEqualToString:@"com.apple.springboard"]) {
            gClock = [[S4EAppearanceClock alloc] init];
            S4EObserveDarwin(S4E_NOTIFY_PREFS, S4EEngineWake);
            // A timer stands still while the phone sleeps: check again when the screen turns on
            S4EObserveDarwin("com.apple.springboard.hasBlankedScreen", S4EEngineWake);
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationSignificantTimeChangeNotification object:nil queue:nil
                                                          usingBlock:^(NSNotification *note) {
                                                              S4EPublishAppearance();
                                                          }];
            S4EPublishAppearance();
            return;
        }
        // Other apps are decided once, at launch: games and the rest stay untouched unless allowed
        gAppleApp = [identifier hasPrefix:@"com.apple."];
        uint64_t state = S4EAppearance();
        if (!gAppleApp && !(state & S4EAppearanceOtherApps))
            return;
        gDark = (state & S4EAppearanceDark) != 0;
        S4EObserveDarwin(S4E_NOTIFY_APPEARANCE, S4EAppearanceChanged);

        S4E_HOOK_BAR([UINavigationBar class], navigationBar);
        S4E_HOOK_BAR([UIToolbar class], toolbar);
        S4E_HOOK_BAR([UISearchBar class], searchBar);

        Class table = [UITableView class];
        S4E_HOOK(table, @selector(didMoveToWindow), hook_table_didMoveToWindow, &orig_table_didMoveToWindow);
        S4E_HOOK(table, @selector(setBackgroundColor:), hook_table_setBackgroundColor, &orig_table_setBackgroundColor);
        S4E_HOOK(table, @selector(setBackgroundView:), hook_table_setBackgroundView, &orig_table_setBackgroundView);
        S4E_HOOK(table, @selector(setSeparatorColor:), hook_table_setSeparatorColor, &orig_table_setSeparatorColor);
        S4E_HOOK(table, @selector(didAddSubview:), hook_table_didAddSubview, &orig_table_didAddSubview);
        S4E_HOOK([UITableViewCell class], @selector(layoutSubviews), hook_cell_layoutSubviews, &orig_cell_layoutSubviews);
        S4E_HOOK([UITableViewHeaderFooterView class], @selector(layoutSubviews), hook_header_layoutSubviews, &orig_header_layoutSubviews);
        Class groupBackground = objc_getClass("UIGroupTableViewCellBackground");
        S4E_HOOK(groupBackground, @selector(_bottomShadowColor), hook_bottomShadowColor, &orig_bottomShadowColor);
        S4E_HOOK(groupBackground, @selector(_topShadowColor), hook_topShadowColor, &orig_topShadowColor);

        S4E_HOOK(objc_getClass("UITextInputTraits"), @selector(keyboardAppearance), hook_keyboardAppearance, &orig_keyboardAppearance);

        Class sheet = [UIActionSheet class];
        S4E_HOOK(sheet, @selector(showInView:), hook_showInView, &orig_showInView);
        S4E_HOOK(sheet, @selector(showFromToolbar:), hook_showFromToolbar, &orig_showFromToolbar);
        S4E_HOOK(sheet, @selector(showFromTabBar:), hook_showFromTabBar, &orig_showFromTabBar);
        S4E_HOOK(sheet, @selector(showFromBarButtonItem:animated:), hook_showFromBarButtonItem, &orig_showFromBarButtonItem);
        S4E_HOOK(sheet, @selector(showFromRect:inView:animated:), hook_showFromRect, &orig_showFromRect);
    }
}
