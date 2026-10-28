// Пункт управления: знаки и глянцевые круглые кнопки в стиле iOS 6.
// Знаки нарисованы кодом на сетке 24×24, чтобы не тащить в пакет картинки.

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

#pragma mark - Кнопка

@implementation IRCCButton

+ (instancetype)buttonWithGlyph:(IRCCGlyph)glyph {
    IRCCButton *button = [[self alloc] initWithFrame:CGRectMake(0, 0, 46, 46)];
    button.glyph = glyph;
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

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [self setNeedsDisplay];
}

static void IRCCGradient(CGContextRef ctx, CGRect rect, const CGFloat *colors) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, colors, NULL, 2);
    CGContextDrawLinearGradient(ctx, gradient, CGPointMake(0, CGRectGetMinY(rect)), CGPointMake(0, CGRectGetMaxY(rect)), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect bounds = self.bounds;
    CGFloat glyphSize = self.plain ? MIN(bounds.size.width, bounds.size.height) * 0.62 : 22;
    CGRect glyphRect = CGRectMake(CGRectGetMidX(bounds) - glyphSize / 2, CGRectGetMidY(bounds) - glyphSize / 2, glyphSize, glyphSize);

    if (!self.plain) {
        CGRect circle = CGRectInset(bounds, 1.5, 1.5);
        // Светлый ободок снизу — кнопка «вдавлена» в лён
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.12].CGColor);
        CGContextFillEllipseInRect(ctx, CGRectOffset(circle, 0, 1));
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.7].CGColor);
        CGContextFillEllipseInRect(ctx, circle);

        CGRect body = CGRectInset(circle, 1, 1);
        CGContextSaveGState(ctx);
        CGContextAddEllipseInRect(ctx, body);
        CGContextClip(ctx);
        const CGFloat dark[] = {0.36, 0.37, 0.39, 1, 0.11, 0.12, 0.13, 1};
        const CGFloat blue[] = {0.45, 0.70, 1.0, 1, 0.10, 0.38, 0.84, 1};
        const CGFloat pressed[] = {0.22, 0.23, 0.25, 1, 0.07, 0.08, 0.09, 1};
        IRCCGradient(ctx, body, self.highlighted ? pressed : (self.on ? blue : dark));
        // Глянец на верхней половине
        CGContextAddEllipseInRect(ctx, CGRectMake(body.origin.x - body.size.width * 0.2, body.origin.y - body.size.height * 0.55,
                                                  body.size.width * 1.4, body.size.height));
        CGContextClip(ctx);
        const CGFloat gloss[] = {1, 1, 1, 0.32, 1, 1, 1, 0.06};
        IRCCGradient(ctx, CGRectMake(body.origin.x, body.origin.y, body.size.width, body.size.height / 2), gloss);
        CGContextRestoreGState(ctx);
    }

    // Белый знак с тиснением: тёмная тень сверху, как надписи на чёрном стекле iOS 6
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, -1), 0, [UIColor colorWithWhite:0 alpha:0.6].CGColor);
    [[UIColor colorWithWhite:1 alpha:(self.plain && self.highlighted) ? 0.5 : 1] set];
    CGContextBeginTransparencyLayer(ctx, NULL);
    IRCCDrawGlyph(self.glyph, glyphRect);
    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);
}

@end
