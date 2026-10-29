// Control Center: glyphs and materials in iOS 6 style.
// Everything is drawn in code (glyphs on a 24×24 grid) so the package doesn't have to ship images.

#import "S4ECCDrawing.h"

static void S4ECCFill(UIBezierPath *path) {
    [path fill];
}

static void S4ECCStroke(UIBezierPath *path, CGFloat width) {
    path.lineWidth = width;
    path.lineCapStyle = kCGLineCapRound;
    path.lineJoinStyle = kCGLineJoinRound;
    [path stroke];
}

static UIBezierPath *S4ECCPolygon(const CGFloat *points, int count) {
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(points[0], points[1])];
    for (int i = 1; i < count; i++)
        [path addLineToPoint:CGPointMake(points[2 * i], points[2 * i + 1])];
    [path closePath];
    return path;
}

static void S4ECCSun(CGFloat core, CGFloat ray) {
    S4ECCFill([UIBezierPath bezierPathWithOvalInRect:CGRectMake(12 - core, 12 - core, core * 2, core * 2)]);
    for (int i = 0; i < 8; i++) {
        CGFloat a = i * M_PI / 4;
        UIBezierPath *line = [UIBezierPath bezierPath];
        [line moveToPoint:CGPointMake(12 + cosf(a) * (core + 2), 12 + sinf(a) * (core + 2))];
        [line addLineToPoint:CGPointMake(12 + cosf(a) * (core + 2 + ray), 12 + sinf(a) * (core + 2 + ray))];
        S4ECCStroke(line, 1.8);
    }
}

void S4ECCDrawGlyph(S4ECCGlyph glyph, CGRect rect) {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, rect.origin.x, rect.origin.y);
    CGContextScaleCTM(ctx, rect.size.width / 24, rect.size.height / 24);

    switch (glyph) {
    case S4ECCGlyphAirplane: {
        S4ECCFill([UIBezierPath bezierPathWithRoundedRect:CGRectMake(10.6, 1.5, 2.8, 19) cornerRadius:1.4]);
        const CGFloat wings[] = {1.5, 13.5, 10.6, 8.5, 13.4, 8.5, 22.5, 13.5, 22.5, 15.5, 13.4, 13, 10.6, 13, 1.5, 15.5};
        S4ECCFill(S4ECCPolygon(wings, 8));
        const CGFloat tail[] = {7, 21.2, 10.6, 18.6, 13.4, 18.6, 17, 21.2, 17, 22.6, 7, 22.6};
        S4ECCFill(S4ECCPolygon(tail, 6));
        break;
    }
    case S4ECCGlyphWiFi:
        for (int i = 1; i <= 3; i++) {
            UIBezierPath *arc = [UIBezierPath bezierPathWithArcCenter:CGPointMake(12, 19) radius:4.2 * i
                                                           startAngle:-M_PI * 0.75 endAngle:-M_PI * 0.25 clockwise:YES];
            S4ECCStroke(arc, 2.3);
        }
        S4ECCFill([UIBezierPath bezierPathWithOvalInRect:CGRectMake(10.2, 17.2, 3.6, 3.6)]);
        break;
    case S4ECCGlyphBluetooth: {
        UIBezierPath *rune = [UIBezierPath bezierPath];
        [rune moveToPoint:CGPointMake(7, 7.5)];
        [rune addLineToPoint:CGPointMake(17, 16)];
        [rune addLineToPoint:CGPointMake(12, 21)];
        [rune addLineToPoint:CGPointMake(12, 3)];
        [rune addLineToPoint:CGPointMake(17, 8)];
        [rune addLineToPoint:CGPointMake(7, 16.5)];
        S4ECCStroke(rune, 2.2);
        break;
    }
    case S4ECCGlyphMoon:
        // Crescent: a circle minus an offset circle
        CGContextSaveGState(ctx);
        CGContextAddRect(ctx, CGRectMake(0, 0, 24, 24));
        CGContextAddEllipseInRect(ctx, CGRectMake(9.5, 1, 15, 15));
        CGContextEOClip(ctx);
        S4ECCFill([UIBezierPath bezierPathWithOvalInRect:CGRectMake(3, 3, 18, 18)]);
        CGContextRestoreGState(ctx);
        break;
    case S4ECCGlyphRotationLock: {
        S4ECCFill([UIBezierPath bezierPathWithRoundedRect:CGRectMake(8.5, 11, 7, 6.5) cornerRadius:1]);
        UIBezierPath *shackle = [UIBezierPath bezierPathWithArcCenter:CGPointMake(12, 11) radius:2.2 startAngle:M_PI endAngle:0 clockwise:YES];
        S4ECCStroke(shackle, 1.6);
        UIBezierPath *ring = [UIBezierPath bezierPathWithArcCenter:CGPointMake(12, 12.5) radius:9.5
                                                        startAngle:-M_PI * 0.35 endAngle:M_PI * 1.45 clockwise:YES];
        S4ECCStroke(ring, 1.8);
        CGFloat a = M_PI * 1.45;
        CGPoint tip = CGPointMake(12 + 9.5 * cosf(a), 12.5 + 9.5 * sinf(a));
        const CGFloat head[] = {tip.x + 3.2, tip.y + 0.6, tip.x - 1.2, tip.y + 2.6, tip.x - 0.6, tip.y - 2.4};
        S4ECCFill(S4ECCPolygon(head, 3));
        break;
    }
    case S4ECCGlyphFlashlight: {
        const CGFloat head[] = {6.5, 2.5, 17.5, 2.5, 15.5, 9, 8.5, 9};
        S4ECCFill(S4ECCPolygon(head, 4));
        S4ECCFill([UIBezierPath bezierPathWithRoundedRect:CGRectMake(8.5, 9.5, 7, 12.5) cornerRadius:1.5]);
        break;
    }
    case S4ECCGlyphTimer: {
        S4ECCStroke([UIBezierPath bezierPathWithOvalInRect:CGRectMake(4, 5, 16, 16)], 2);
        S4ECCFill([UIBezierPath bezierPathWithRoundedRect:CGRectMake(10, 1.5, 4, 2.2) cornerRadius:0.8]);
        UIBezierPath *hand = [UIBezierPath bezierPath];
        [hand moveToPoint:CGPointMake(12, 13)];
        [hand addLineToPoint:CGPointMake(12, 8)];
        [hand moveToPoint:CGPointMake(12, 13)];
        [hand addLineToPoint:CGPointMake(15.5, 14.5)];
        S4ECCStroke(hand, 1.8);
        break;
    }
    case S4ECCGlyphCalculator:
        S4ECCStroke([UIBezierPath bezierPathWithRoundedRect:CGRectMake(5, 2.5, 14, 19) cornerRadius:2], 1.8);
        S4ECCFill([UIBezierPath bezierPathWithRect:CGRectMake(7.5, 5, 9, 3.5)]);
        for (int row = 0; row < 3; row++)
            for (int col = 0; col < 3; col++)
                S4ECCFill([UIBezierPath bezierPathWithRect:CGRectMake(7.5 + col * 3.2, 10.5 + row * 3.4, 2.2, 2.2)]);
        break;
    case S4ECCGlyphCamera:
        S4ECCFill([UIBezierPath bezierPathWithRoundedRect:CGRectMake(8, 4.5, 8, 3) cornerRadius:1]);
        S4ECCStroke([UIBezierPath bezierPathWithRoundedRect:CGRectMake(3, 7, 18, 13) cornerRadius:2.5], 1.8);
        S4ECCStroke([UIBezierPath bezierPathWithOvalInRect:CGRectMake(8, 9, 8, 8)], 1.8);
        break;
    case S4ECCGlyphPlay: {
        const CGFloat play[] = {7, 4, 20, 12, 7, 20};
        S4ECCFill(S4ECCPolygon(play, 3));
        break;
    }
    case S4ECCGlyphPause:
        S4ECCFill([UIBezierPath bezierPathWithRect:CGRectMake(6, 4, 4.5, 16)]);
        S4ECCFill([UIBezierPath bezierPathWithRect:CGRectMake(13.5, 4, 4.5, 16)]);
        break;
    case S4ECCGlyphPrevious: {
        S4ECCFill([UIBezierPath bezierPathWithRect:CGRectMake(3, 6, 2.5, 12)]);
        const CGFloat a[] = {14, 6, 14, 18, 5.5, 12};
        const CGFloat b[] = {22, 6, 22, 18, 13.5, 12};
        S4ECCFill(S4ECCPolygon(a, 3));
        S4ECCFill(S4ECCPolygon(b, 3));
        break;
    }
    case S4ECCGlyphNext: {
        S4ECCFill([UIBezierPath bezierPathWithRect:CGRectMake(18.5, 6, 2.5, 12)]);
        const CGFloat a[] = {10, 6, 10, 18, 18.5, 12};
        const CGFloat b[] = {2, 6, 2, 18, 10.5, 12};
        S4ECCFill(S4ECCPolygon(a, 3));
        S4ECCFill(S4ECCPolygon(b, 3));
        break;
    }
    case S4ECCGlyphSunSmall:
        S4ECCSun(2.6, 2.2);
        break;
    case S4ECCGlyphSunLarge:
        S4ECCSun(4, 3.5);
        break;
    case S4ECCGlyphSliders:
        // Two sliders: the Control Center glyph in Activator
        for (int i = 0; i < 2; i++) {
            CGFloat y = 8 + i * 8, knob = i ? 9 : 15;
            S4ECCFill([UIBezierPath bezierPathWithRoundedRect:CGRectMake(3, y - 1, 18, 2) cornerRadius:1]);
            S4ECCFill([UIBezierPath bezierPathWithOvalInRect:CGRectMake(knob - 3, y - 3, 6, 6)]);
        }
        break;
    }
    CGContextRestoreGState(ctx);
}

UIImage *S4ECCGlyphImage(S4ECCGlyph glyph, CGFloat size, UIColor *color) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0);
    [color set];
    S4ECCDrawGlyph(glyph, CGRectMake(0, 0, size, size));
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

#pragma mark - Materials

// Linen: noise plus "threads", i.e. random brightness shifts per row and column. The generator has a fixed
// seed so the fabric always comes out the same. The 64×64 pt tile repeats seamlessly.
UIColor *S4ECCLinenColor(void) {
    static UIColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const int scale = (int)[UIScreen mainScreen].scale, side = 64 * scale;
        uint32_t seed = 0x6a0a;
        int rows[256], columns[256];
        for (int i = 0; i < side; i++) {
            seed = seed * 1103515245 + 12345;
            rows[i] = (int)((seed >> 16) % 13) - 6;
            seed = seed * 1103515245 + 12345;
            columns[i] = (int)((seed >> 16) % 13) - 6;
        }
        uint8_t *pixels = malloc(side * side);
        for (int y = 0; y < side; y++) {
            for (int x = 0; x < side; x++) {
                seed = seed * 1103515245 + 12345;
                int value = 60 + rows[y] / 2 + columns[x] / 2 + (int)((seed >> 16) % 9) - 4;
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

// A fine dot mesh in the button field, as in Auxo
static UIColor *S4ECCMeshColor(void) {
    static UIColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(3, 3), NO, 0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.4].CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(0.3, 0.3, 1.2, 1.2));
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.05].CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(1.8, 1.8, 1, 1));
        UIImage *tile = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        color = [UIColor colorWithPatternImage:tile];
    });
    return color;
}

UIView *S4ECCGroove(CGRect frame) {
    frame.size.height = 2;
    UIView *groove = [[UIView alloc] initWithFrame:frame];
    UIView *dark = [[UIView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, 1)];
    dark.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    UIView *light = [[UIView alloc] initWithFrame:CGRectMake(0, 1, frame.size.width, 1)];
    light.backgroundColor = [UIColor colorWithWhite:1 alpha:0.09];
    [groove addSubview:dark];
    [groove addSubview:light];
    return groove;
}

static void S4ECCGradient(CGContextRef ctx, CGRect rect, const CGFloat *colors) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, colors, NULL, 2);
    CGContextDrawLinearGradient(ctx, gradient, CGPointMake(0, CGRectGetMinY(rect)), CGPointMake(0, CGRectGetMaxY(rect)), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
}

UIImage *S4ECCTrackImage(BOOL filled) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(11, 10), NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect track = CGRectMake(0.5, 0.5, 10, 8);
    UIBezierPath *capsule = [UIBezierPath bezierPathWithRoundedRect:track cornerRadius:4];
    if (!filled) {
        // The trough is sunk into the linen: a light edge underneath
        [[UIColor colorWithWhite:1 alpha:0.12] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectOffset(track, 0, 1) cornerRadius:4] fill];
    }
    CGContextSaveGState(ctx);
    [capsule addClip];
    const CGFloat light[] = {0.93, 0.93, 0.94, 1, 0.66, 0.66, 0.68, 1};
    const CGFloat dark[] = {0.06, 0.06, 0.07, 1, 0.21, 0.21, 0.22, 1};
    S4ECCGradient(ctx, track, filled ? light : dark);
    CGContextRestoreGState(ctx);
    [[UIColor colorWithWhite:0 alpha:0.6] setStroke];
    capsule.lineWidth = 1;
    [capsule stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(0, 5, 0, 5)];
}

// Shadow under the button: fill the shape with a shadow, the button itself is drawn on top afterwards
static void S4ECCDropShadow(CGContextRef ctx, UIBezierPath *shape) {
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, 1), 2, [UIColor colorWithWhite:0 alpha:0.75].CGColor);
    [[UIColor colorWithWhite:0.5 alpha:1] setFill];
    [shape fill];
    CGContextRestoreGState(ctx);
}

// An embossed white glyph: a dark shadow on top, like lettering on iOS 6 black glass
static void S4ECCDrawEmbossedGlyph(CGContextRef ctx, S4ECCGlyph glyph, CGRect rect, UIColor *color, UIColor *shadow) {
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, -1), 0, shadow.CGColor);
    [color set];
    CGContextBeginTransparencyLayer(ctx, NULL);
    S4ECCDrawGlyph(glyph, rect);
    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);
}

#pragma mark - Button

@implementation S4ECCButton

+ (instancetype)buttonWithGlyph:(S4ECCGlyph)glyph style:(S4ECCButtonStyle)style {
    S4ECCButton *button = [[self alloc] initWithFrame:CGRectMake(0, 0, 50, 50)];
    button.glyph = glyph;
    button.style = style;
    return button;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)setOn:(BOOL)on {
    _on = on;
    [self setNeedsDisplay];
}

- (void)setGlyph:(S4ECCGlyph)glyph {
    _glyph = glyph;
    [self setNeedsDisplay];
}

- (void)setStyle:(S4ECCButtonStyle)style {
    _style = style;
    [self setNeedsDisplay];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [self setNeedsDisplay];
}

// Rounded square: a grey bezel with a dark textured field or blue gloss inside
- (void)drawSquare:(CGContextRef)ctx {
    CGRect outer = CGRectInset(self.bounds, 1.5, 1.5);
    outer.size.height -= 1;
    CGFloat radius = MIN(outer.size.width, outer.size.height) * 0.18;
    UIBezierPath *rim = [UIBezierPath bezierPathWithRoundedRect:outer cornerRadius:radius];
    S4ECCDropShadow(ctx, rim);

    CGContextSaveGState(ctx);
    [rim addClip];
    const CGFloat frame[] = {0.86, 0.86, 0.87, 1, 0.52, 0.52, 0.54, 1};
    S4ECCGradient(ctx, outer, frame);
    CGContextRestoreGState(ctx);

    CGRect inner = CGRectInset(outer, 2.5, 2.5);
    UIBezierPath *field = [UIBezierPath bezierPathWithRoundedRect:inner cornerRadius:MAX(radius - 2, 1)];
    CGContextSaveGState(ctx);
    [field addClip];
    if (self.on) {
        const CGFloat blue[] = {0.45, 0.72, 0.99, 1, 0.11, 0.40, 0.86, 1};
        S4ECCGradient(ctx, inner, blue);
    } else {
        const CGFloat grey[] = {0.35, 0.35, 0.37, 1, 0.17, 0.17, 0.18, 1};
        S4ECCGradient(ctx, inner, grey);
        [S4ECCMeshColor() setFill];
        CGContextFillRect(ctx, inner);
    }
    // Gloss on top and a shadow along the top edge: the field is sunk into the bezel
    const CGFloat gloss[] = {1, 1, 1, self.on ? 0.30 : 0.10, 1, 1, 1, 0.02};
    S4ECCGradient(ctx, CGRectMake(inner.origin.x, inner.origin.y, inner.size.width, inner.size.height / 2), gloss);
    const CGFloat inset[] = {0, 0, 0, 0.5, 0, 0, 0, 0};
    S4ECCGradient(ctx, CGRectMake(inner.origin.x, inner.origin.y, inner.size.width, 4), inset);
    if (self.highlighted) {
        [[UIColor colorWithWhite:0 alpha:0.3] setFill];
        CGContextFillRect(ctx, inner);
    }
    CGContextRestoreGState(ctx);
    [[UIColor colorWithWhite:0 alpha:0.55] setStroke];
    field.lineWidth = 1;
    [field stroke];

    CGFloat size = MIN(inner.size.width, inner.size.height) * 0.56;
    CGRect glyphRect = CGRectMake(CGRectGetMidX(inner) - size / 2, CGRectGetMidY(inner) - size / 2, size, size);
    UIColor *shadow = self.on ? [UIColor colorWithRed:0 green:0.12 blue:0.4 alpha:0.6] : [UIColor colorWithWhite:0 alpha:0.85];
    S4ECCDrawEmbossedGlyph(ctx, self.glyph, glyphRect, [UIColor colorWithWhite:1 alpha:self.on ? 1 : 0.88], shadow);
}

// Glyph only, like the music buttons in Auxo and in the iOS 6 multitasking bar
- (void)drawPlain:(CGContextRef)ctx {
    CGRect bounds = self.bounds;
    CGFloat size = MIN(bounds.size.width, bounds.size.height) * 0.7;
    CGRect glyphRect = CGRectMake(CGRectGetMidX(bounds) - size / 2, CGRectGetMidY(bounds) - size / 2, size, size);
    S4ECCDrawEmbossedGlyph(ctx, self.glyph, glyphRect, [UIColor colorWithWhite:1 alpha:self.highlighted ? 0.45 : 0.95],
                          [UIColor colorWithWhite:0 alpha:0.8]);
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (self.style == S4ECCButtonStylePlain)
        [self drawPlain:ctx];
    else
        [self drawSquare:ctx];
}

@end
