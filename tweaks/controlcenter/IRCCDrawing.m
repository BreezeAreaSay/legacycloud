// Пункт управления: знаки и материалы в стиле iOS 6.
// Всё нарисовано кодом (знаки — на сетке 24×24), чтобы не тащить в пакет картинки.

#import "IRCCDrawing.h"

static void IRCCFill(UIBezierPath *path) {
    [path fill];
}

static void IRCCStroke(UIBezierPath *path, CGFloat width) {
    path.lineWidth = width;
    path.lineCapStyle = kCGLineCapRound;
    path.lineJoinStyle = kCGLineJoinRound;
    [path stroke];
}

static UIBezierPath *IRCCPolygon(const CGFloat *points, int count) {
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(points[0], points[1])];
    for (int i = 1; i < count; i++)
        [path addLineToPoint:CGPointMake(points[2 * i], points[2 * i + 1])];
    [path closePath];
    return path;
}

static void IRCCSun(CGFloat core, CGFloat ray) {
    IRCCFill([UIBezierPath bezierPathWithOvalInRect:CGRectMake(12 - core, 12 - core, core * 2, core * 2)]);
    for (int i = 0; i < 8; i++) {
        CGFloat a = i * M_PI / 4;
        UIBezierPath *line = [UIBezierPath bezierPath];
        [line moveToPoint:CGPointMake(12 + cosf(a) * (core + 2), 12 + sinf(a) * (core + 2))];
        [line addLineToPoint:CGPointMake(12 + cosf(a) * (core + 2 + ray), 12 + sinf(a) * (core + 2 + ray))];
        IRCCStroke(line, 1.8);
    }
}

void IRCCDrawGlyph(IRCCGlyph glyph, CGRect rect) {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, rect.origin.x, rect.origin.y);
    CGContextScaleCTM(ctx, rect.size.width / 24, rect.size.height / 24);

    switch (glyph) {
    case IRCCGlyphAirplane: {
        IRCCFill([UIBezierPath bezierPathWithRoundedRect:CGRectMake(10.6, 1.5, 2.8, 19) cornerRadius:1.4]);
        const CGFloat wings[] = {1.5, 13.5, 10.6, 8.5, 13.4, 8.5, 22.5, 13.5, 22.5, 15.5, 13.4, 13, 10.6, 13, 1.5, 15.5};
        IRCCFill(IRCCPolygon(wings, 8));
        const CGFloat tail[] = {7, 21.2, 10.6, 18.6, 13.4, 18.6, 17, 21.2, 17, 22.6, 7, 22.6};
        IRCCFill(IRCCPolygon(tail, 6));
        break;
    }
    case IRCCGlyphWiFi:
        for (int i = 1; i <= 3; i++) {
            UIBezierPath *arc = [UIBezierPath bezierPathWithArcCenter:CGPointMake(12, 19) radius:4.2 * i
                                                           startAngle:-M_PI * 0.75 endAngle:-M_PI * 0.25 clockwise:YES];
            IRCCStroke(arc, 2.3);
        }
        IRCCFill([UIBezierPath bezierPathWithOvalInRect:CGRectMake(10.2, 17.2, 3.6, 3.6)]);
        break;
    case IRCCGlyphBluetooth: {
        UIBezierPath *rune = [UIBezierPath bezierPath];
        [rune moveToPoint:CGPointMake(7, 7.5)];
        [rune addLineToPoint:CGPointMake(17, 16)];
        [rune addLineToPoint:CGPointMake(12, 21)];
        [rune addLineToPoint:CGPointMake(12, 3)];
        [rune addLineToPoint:CGPointMake(17, 8)];
        [rune addLineToPoint:CGPointMake(7, 16.5)];
        IRCCStroke(rune, 2.2);
        break;
    }
    case IRCCGlyphMoon:
        // Месяц: круг без смещённого круга
        CGContextSaveGState(ctx);
        CGContextAddRect(ctx, CGRectMake(0, 0, 24, 24));
        CGContextAddEllipseInRect(ctx, CGRectMake(9.5, 1, 15, 15));
        CGContextEOClip(ctx);
        IRCCFill([UIBezierPath bezierPathWithOvalInRect:CGRectMake(3, 3, 18, 18)]);
        CGContextRestoreGState(ctx);
        break;
    case IRCCGlyphRotationLock: {
        IRCCFill([UIBezierPath bezierPathWithRoundedRect:CGRectMake(8.5, 11, 7, 6.5) cornerRadius:1]);
        UIBezierPath *shackle = [UIBezierPath bezierPathWithArcCenter:CGPointMake(12, 11) radius:2.2 startAngle:M_PI endAngle:0 clockwise:YES];
        IRCCStroke(shackle, 1.6);
        UIBezierPath *ring = [UIBezierPath bezierPathWithArcCenter:CGPointMake(12, 12.5) radius:9.5
                                                        startAngle:-M_PI * 0.35 endAngle:M_PI * 1.45 clockwise:YES];
        IRCCStroke(ring, 1.8);
        CGFloat a = M_PI * 1.45;
        CGPoint tip = CGPointMake(12 + 9.5 * cosf(a), 12.5 + 9.5 * sinf(a));
        const CGFloat head[] = {tip.x + 3.2, tip.y + 0.6, tip.x - 1.2, tip.y + 2.6, tip.x - 0.6, tip.y - 2.4};
        IRCCFill(IRCCPolygon(head, 3));
        break;
    }
    case IRCCGlyphFlashlight: {
        const CGFloat head[] = {6.5, 2.5, 17.5, 2.5, 15.5, 9, 8.5, 9};
        IRCCFill(IRCCPolygon(head, 4));
        IRCCFill([UIBezierPath bezierPathWithRoundedRect:CGRectMake(8.5, 9.5, 7, 12.5) cornerRadius:1.5]);
        break;
    }
    case IRCCGlyphTimer: {
        IRCCStroke([UIBezierPath bezierPathWithOvalInRect:CGRectMake(4, 5, 16, 16)], 2);
        IRCCFill([UIBezierPath bezierPathWithRoundedRect:CGRectMake(10, 1.5, 4, 2.2) cornerRadius:0.8]);
        UIBezierPath *hand = [UIBezierPath bezierPath];
        [hand moveToPoint:CGPointMake(12, 13)];
        [hand addLineToPoint:CGPointMake(12, 8)];
        [hand moveToPoint:CGPointMake(12, 13)];
        [hand addLineToPoint:CGPointMake(15.5, 14.5)];
        IRCCStroke(hand, 1.8);
        break;
    }
    case IRCCGlyphCalculator:
        IRCCStroke([UIBezierPath bezierPathWithRoundedRect:CGRectMake(5, 2.5, 14, 19) cornerRadius:2], 1.8);
        IRCCFill([UIBezierPath bezierPathWithRect:CGRectMake(7.5, 5, 9, 3.5)]);
        for (int row = 0; row < 3; row++)
            for (int col = 0; col < 3; col++)
                IRCCFill([UIBezierPath bezierPathWithRect:CGRectMake(7.5 + col * 3.2, 10.5 + row * 3.4, 2.2, 2.2)]);
        break;
    case IRCCGlyphCamera:
        IRCCFill([UIBezierPath bezierPathWithRoundedRect:CGRectMake(8, 4.5, 8, 3) cornerRadius:1]);
        IRCCStroke([UIBezierPath bezierPathWithRoundedRect:CGRectMake(3, 7, 18, 13) cornerRadius:2.5], 1.8);
        IRCCStroke([UIBezierPath bezierPathWithOvalInRect:CGRectMake(8, 9, 8, 8)], 1.8);
        break;
    case IRCCGlyphPlay: {
        const CGFloat play[] = {7, 4, 20, 12, 7, 20};
        IRCCFill(IRCCPolygon(play, 3));
        break;
    }
    case IRCCGlyphPause:
        IRCCFill([UIBezierPath bezierPathWithRect:CGRectMake(6, 4, 4.5, 16)]);
        IRCCFill([UIBezierPath bezierPathWithRect:CGRectMake(13.5, 4, 4.5, 16)]);
        break;
    case IRCCGlyphPrevious: {
        IRCCFill([UIBezierPath bezierPathWithRect:CGRectMake(3, 6, 2.5, 12)]);
        const CGFloat a[] = {14, 6, 14, 18, 5.5, 12};
        const CGFloat b[] = {22, 6, 22, 18, 13.5, 12};
        IRCCFill(IRCCPolygon(a, 3));
        IRCCFill(IRCCPolygon(b, 3));
        break;
    }
    case IRCCGlyphNext: {
        IRCCFill([UIBezierPath bezierPathWithRect:CGRectMake(18.5, 6, 2.5, 12)]);
        const CGFloat a[] = {10, 6, 10, 18, 18.5, 12};
        const CGFloat b[] = {2, 6, 2, 18, 10.5, 12};
        IRCCFill(IRCCPolygon(a, 3));
        IRCCFill(IRCCPolygon(b, 3));
        break;
    }
    case IRCCGlyphSunSmall:
        IRCCSun(2.6, 2.2);
        break;
    case IRCCGlyphSunLarge:
        IRCCSun(4, 3.5);
        break;
    case IRCCGlyphSliders:
        // Два ползунка — знак Пункта управления в Activator
        for (int i = 0; i < 2; i++) {
            CGFloat y = 8 + i * 8, knob = i ? 9 : 15;
            IRCCFill([UIBezierPath bezierPathWithRoundedRect:CGRectMake(3, y - 1, 18, 2) cornerRadius:1]);
            IRCCFill([UIBezierPath bezierPathWithOvalInRect:CGRectMake(knob - 3, y - 3, 6, 6)]);
        }
        break;
    }
    CGContextRestoreGState(ctx);
}

UIImage *IRCCGlyphImage(IRCCGlyph glyph, CGFloat size, UIColor *color) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0);
    [color set];
    IRCCDrawGlyph(glyph, CGRectMake(0, 0, size, size));
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

#pragma mark - Материалы

// Ячейка 4×4 пт: тёмный металл и отверстие со светлым краем снизу
UIColor *IRCCPerforatedColor(void) {
    static UIColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(4, 4), YES, 0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.17 alpha:1].CGColor);
        CGContextFillRect(ctx, CGRectMake(0, 0, 4, 4));
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.08].CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(1.1, 1.5, 1.8, 1.8));
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.04 alpha:1].CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(1.1, 1.1, 1.8, 1.8));
        UIImage *tile = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        color = [UIColor colorWithPatternImage:tile];
    });
    return color;
}

static void IRCCGradient(CGContextRef ctx, CGRect rect, const CGFloat *colors) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, colors, NULL, 2);
    CGContextDrawLinearGradient(ctx, gradient, CGPointMake(0, CGRectGetMinY(rect)), CGPointMake(0, CGRectGetMaxY(rect)), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
}

// Тень под кнопкой: заливаем форму с тенью, поверх потом рисуется сама кнопка
static void IRCCDropShadow(CGContextRef ctx, UIBezierPath *shape) {
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, 1), 2, [UIColor colorWithWhite:0 alpha:0.8].CGColor);
    [[UIColor colorWithWhite:0.5 alpha:1] setFill];
    [shape fill];
    CGContextRestoreGState(ctx);
}

#pragma mark - Кнопка

@implementation IRCCButton

+ (instancetype)buttonWithGlyph:(IRCCGlyph)glyph style:(IRCCButtonStyle)style {
    IRCCButton *button = [[self alloc] initWithFrame:CGRectMake(0, 0, 50, 50)];
    button.glyph = glyph;
    button.style = style;
    return button;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}

- (void)setOn:(BOOL)on {
    _on = on;
    [self setNeedsDisplay];
}

- (void)setGlyph:(IRCCGlyph)glyph {
    _glyph = glyph;
    [self setNeedsDisplay];
}

- (void)setStyle:(IRCCButtonStyle)style {
    _style = style;
    [self setNeedsDisplay];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [self setNeedsDisplay];
}

// Скруглённый квадрат: серебристый ободок, внутри перфорированный металл или синий глянец
- (void)drawSquare:(CGContextRef)ctx glyphRect:(CGRect)glyphRect {
    CGRect outer = CGRectInset(self.bounds, 1.5, 1.5);
    outer.size.height -= 1;
    CGFloat radius = MIN(outer.size.width, outer.size.height) * 0.2;
    UIBezierPath *rim = [UIBezierPath bezierPathWithRoundedRect:outer cornerRadius:radius];
    IRCCDropShadow(ctx, rim);

    CGContextSaveGState(ctx);
    [rim addClip];
    const CGFloat silver[] = {0.96, 0.96, 0.96, 1, 0.60, 0.60, 0.61, 1};
    IRCCGradient(ctx, outer, silver);
    CGContextRestoreGState(ctx);

    CGRect inner = CGRectInset(outer, 2.5, 2.5);
    UIBezierPath *field = [UIBezierPath bezierPathWithRoundedRect:inner cornerRadius:radius - 2];
    CGContextSaveGState(ctx);
    [field addClip];
    if (self.on) {
        const CGFloat blue[] = {0.45, 0.72, 0.99, 1, 0.11, 0.40, 0.86, 1};
        IRCCGradient(ctx, inner, blue);
        const CGFloat gloss[] = {1, 1, 1, 0.30, 1, 1, 1, 0.06};
        IRCCGradient(ctx, CGRectMake(inner.origin.x, inner.origin.y, inner.size.width, inner.size.height / 2), gloss);
    } else {
        [IRCCPerforatedColor() setFill];
        CGContextFillRect(ctx, inner);
        const CGFloat lift[] = {1, 1, 1, 0.14, 1, 1, 1, 0};
        IRCCGradient(ctx, inner, lift);
    }
    // Поле утоплено в ободок: тень по верхнему краю
    const CGFloat inset[] = {0, 0, 0, 0.55, 0, 0, 0, 0};
    IRCCGradient(ctx, CGRectMake(inner.origin.x, inner.origin.y, inner.size.width, 5), inset);
    if (self.highlighted) {
        [[UIColor colorWithWhite:0 alpha:0.3] setFill];
        CGContextFillRect(ctx, inner);
    }
    CGContextRestoreGState(ctx);
    [[UIColor colorWithWhite:0 alpha:0.5] setStroke];
    field.lineWidth = 1;
    [field stroke];

    // Знак с тиснением: тёмная тень сверху, как надписи на чёрном стекле iOS 6
    CGContextSaveGState(ctx);
    UIColor *shadow = self.on ? [UIColor colorWithRed:0 green:0.12 blue:0.4 alpha:0.6] : [UIColor colorWithWhite:0 alpha:0.8];
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, -1), 0, shadow.CGColor);
    [[UIColor colorWithWhite:1 alpha:self.on ? 1 : 0.85] set];
    CGContextBeginTransparencyLayer(ctx, NULL);
    IRCCDrawGlyph(self.glyph, glyphRect);
    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);
}

// Круглая серебристая кнопка с тёмным знаком
- (void)drawMedia:(CGContextRef)ctx glyphRect:(CGRect)glyphRect {
    CGRect circle = CGRectInset(self.bounds, 2, 2);
    circle.size.height -= 1;
    circle.size.width = circle.size.height = MIN(circle.size.width, circle.size.height);
    circle.origin.x = CGRectGetMidX(self.bounds) - circle.size.width / 2;
    UIBezierPath *disc = [UIBezierPath bezierPathWithOvalInRect:circle];
    IRCCDropShadow(ctx, disc);

    CGContextSaveGState(ctx);
    [disc addClip];
    const CGFloat silver[] = {0.97, 0.97, 0.97, 1, 0.68, 0.68, 0.70, 1};
    const CGFloat pressed[] = {0.78, 0.78, 0.79, 1, 0.52, 0.52, 0.54, 1};
    IRCCGradient(ctx, circle, self.highlighted ? pressed : silver);
    const CGFloat gloss[] = {1, 1, 1, 0.45, 1, 1, 1, 0.05};
    IRCCGradient(ctx, CGRectMake(circle.origin.x, circle.origin.y, circle.size.width, circle.size.height / 2), gloss);
    CGContextRestoreGState(ctx);
    [[UIColor colorWithWhite:0 alpha:0.45] setStroke];
    disc.lineWidth = 1;
    [disc stroke];

    // Тёмный знак, вдавленный в металл: светлая тень снизу
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, 1), 0, [UIColor colorWithWhite:1 alpha:0.7].CGColor);
    [[UIColor colorWithWhite:0.2 alpha:1] set];
    CGContextBeginTransparencyLayer(ctx, NULL);
    IRCCDrawGlyph(self.glyph, glyphRect);
    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect bounds = self.bounds;
    CGFloat glyphSize = MIN(bounds.size.width, bounds.size.height) * (self.style == IRCCButtonStyleMedia ? 0.42 : 0.46);
    CGRect glyphRect = CGRectMake(CGRectGetMidX(bounds) - glyphSize / 2, CGRectGetMidY(bounds) - glyphSize / 2 - 0.5, glyphSize, glyphSize);
    if (self.style == IRCCButtonStyleMedia)
        [self drawMedia:ctx glyphRect:glyphRect];
    else
        [self drawSquare:ctx glyphRect:glyphRect];
}

@end
