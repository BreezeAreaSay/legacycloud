// Bold Text (iOS 7, Accessibility): the system font and Helvetica become one weight heavier.
// It takes effect when an app launches, so after it is toggled Settings restarts SpringBoard.

#import "S4EShared.h"

static NSDictionary *gHeavier;

static UIFont *(*orig_fontWithNameSize)(id, SEL, NSString *, CGFloat);

// The bold variant is looked up by name, not via boldSystemFontOfSize:, which may itself call systemFontOfSize:.
static UIFont *(*orig_systemFontOfSize)(id, SEL, CGFloat);
static UIFont *hook_systemFontOfSize(id self, SEL _cmd, CGFloat size) {
    UIFont *regular = orig_systemFontOfSize(self, _cmd, size);
    NSString *heavier = gHeavier[regular.fontName];
    UIFont *bold = (heavier && orig_fontWithNameSize) ? orig_fontWithNameSize(self, @selector(fontWithName:size:), heavier, size) : nil;
    return bold ?: regular;
}

static UIFont *hook_fontWithNameSize(id self, SEL _cmd, NSString *name, CGFloat size) {
    NSString *heavier = name ? gHeavier[name] : nil;
    if (heavier) {
        UIFont *font = orig_fontWithNameSize(self, _cmd, heavier, size);
        if (font)
            return font;
    }
    return orig_fontWithNameSize(self, _cmd, name, size);
}

__attribute__((constructor)) static void S4EBoldTextInit(void) {
    @autoreleasepool {
        if (!S4EFlag(kS4EBoldText, S4EStateBoldText, NO))
            return;
        gHeavier = @{
            @".HelveticaNeueUI": @".HelveticaNeueUI-Bold",
            @".HelveticaNeueUI-Italic": @".HelveticaNeueUI-BoldItalic",
            @"Helvetica": @"Helvetica-Bold",
            @"Helvetica-Oblique": @"Helvetica-BoldOblique",
            @"HelveticaNeue": @"HelveticaNeue-Bold",
            @"HelveticaNeue-Italic": @"HelveticaNeue-BoldItalic",
            @"HelveticaNeue-Light": @"HelveticaNeue-Medium",
            @"HelveticaNeue-Medium": @"HelveticaNeue-Bold",
        };
        Class meta = object_getClass([UIFont class]);
        S4E_HOOK(meta, @selector(systemFontOfSize:), hook_systemFontOfSize, &orig_systemFontOfSize);
        S4E_HOOK(meta, @selector(fontWithName:size:), hook_fontWithNameSize, &orig_fontWithNameSize);
    }
}
