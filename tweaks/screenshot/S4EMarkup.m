// Screenshot markup: the annotation canvas and the toolbars.
//
// Annotations are stored in the shot's own coordinates, so they are saved at full resolution.
// As in iOS 11, the eraser removes a whole annotation. Undo reverts both drawing and erasing.

#import "S4EShared.h"
#import "S4EMarkup.h"
#import <QuartzCore/QuartzCore.h>

typedef enum { S4EMarkupPen, S4EMarkupMarker, S4EMarkupEraser } S4EMarkupTool;

#pragma mark - Tool glyphs

static UIImage *S4EMarkupIcon(void (^draw)(CGContextRef ctx)) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(22, 22), NO, 0);
    [[UIColor whiteColor] set];
    draw(UIGraphicsGetCurrentContext());
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static void S4EFillPolygon(const CGFloat *points, int count) {
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(points[0], points[1])];
    for (int i = 1; i < count; i++)
        [path addLineToPoint:CGPointMake(points[2 * i], points[2 * i + 1])];
    [path closePath];
    [path fill];
}

static UIImage *S4EPenIcon(void) {
    return S4EMarkupIcon(^(CGContextRef ctx) {
        const CGFloat body[] = {6.5, 13, 14.5, 5, 17, 7.5, 9, 15.5};
        const CGFloat tip[] = {6, 13.5, 8.5, 16, 3.5, 18.5};
        const CGFloat cap[] = {15.3, 4.2, 16.4, 3.1, 18.9, 5.6, 17.8, 6.7};
        S4EFillPolygon(body, 4);
        S4EFillPolygon(tip, 3);
        S4EFillPolygon(cap, 4);
    });
}

static UIImage *S4EMarkerIcon(void) {
    return S4EMarkupIcon(^(CGContextRef ctx) {
        const CGFloat body[] = {6.5, 11, 13.5, 4, 18, 8.5, 11, 15.5};
        const CGFloat tip[] = {6, 11.5, 10.5, 16, 7, 18, 4, 15};
        S4EFillPolygon(body, 4);
        S4EFillPolygon(tip, 4);
        [[UIBezierPath bezierPathWithRect:CGRectMake(3, 19.5, 16, 1.8)] fill];
    });
}

static UIImage *S4EEraserIcon(void) {
    return S4EMarkupIcon(^(CGContextRef ctx) {
        CGContextTranslateCTM(ctx, 11, 11);
        CGContextRotateCTM(ctx, -M_PI_4);
        UIBezierPath *outline = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(-8, -4, 16, 8) cornerRadius:2];
        outline.lineWidth = 1.5;
        [outline stroke];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(-8, -4, 6, 8) cornerRadius:2] fill];
    });
}

static UIImage *S4EUndoIcon(void) {
    return S4EMarkupIcon(^(CGContextRef ctx) {
        UIBezierPath *arc = [UIBezierPath bezierPathWithArcCenter:CGPointMake(12, 13) radius:5.5 startAngle:0 endAngle:M_PI clockwise:NO];
        arc.lineWidth = 2.2;
        arc.lineCapStyle = kCGLineCapRound;
        [arc stroke];
        const CGFloat head[] = {3, 12, 10, 12, 6.5, 16.5};
        S4EFillPolygon(head, 3);
    });
}

#pragma mark - Canvas

@interface S4EStroke : NSObject
@property(nonatomic, strong) UIBezierPath *path;
@property(nonatomic, strong) UIColor *color;
@property(nonatomic) BOOL marker;
@end

@implementation S4EStroke
@end

static void S4EDrawStroke(S4EStroke *stroke) {
    [stroke.color setStroke];
    // A single pass over the whole path: the marker doesn't get darker where the line crosses itself
    [stroke.path strokeWithBlendMode:kCGBlendModeNormal alpha:stroke.marker ? 0.45 : 1];
}

// Reports changes via UIControlEventValueChanged
@interface S4EMarkupCanvas : UIControl
@property(nonatomic) S4EMarkupTool tool;
@property(nonatomic, strong) UIColor *color;
@property(nonatomic) UIEdgeInsets contentInsets;
- (instancetype)initWithFrame:(CGRect)frame image:(UIImage *)image;
- (CGRect)imageFrame;
- (NSUInteger)strokeCount;
- (BOOL)canUndo;
- (void)undo;
- (UIImage *)renderedImage;
@end

@implementation S4EMarkupCanvas {
    UIImage *_image;
    NSMutableArray *_strokes;
    NSMutableArray *_history;
    S4EStroke *_current;
    CGPoint _previous;
    UIImage *_cache;
}

- (instancetype)initWithFrame:(CGRect)frame image:(UIImage *)image {
    if ((self = [super initWithFrame:frame])) {
        _image = image;
        _strokes = [NSMutableArray array];
        _history = [NSMutableArray array];
        _color = [UIColor redColor];
        self.backgroundColor = [UIColor blackColor];
        self.multipleTouchEnabled = NO;
    }
    return self;
}

- (CGRect)imageFrame {
    CGRect area = UIEdgeInsetsInsetRect(self.bounds, self.contentInsets);
    CGSize size = _image.size;
    if (size.width <= 0 || size.height <= 0 || area.size.width <= 0 || area.size.height <= 0)
        return area;
    CGFloat scale = MIN(area.size.width / size.width, area.size.height / size.height);
    CGSize fit = CGSizeMake(floorf(size.width * scale), floorf(size.height * scale));
    return CGRectMake(floorf(CGRectGetMidX(area) - fit.width / 2), floorf(CGRectGetMidY(area) - fit.height / 2), fit.width, fit.height);
}

- (CGFloat)scale {
    return _image.size.width > 0 ? [self imageFrame].size.width / _image.size.width : 1;
}

- (CGPoint)imagePoint:(CGPoint)point {
    CGRect frame = [self imageFrame];
    CGFloat scale = [self scale];
    return CGPointMake((point.x - frame.origin.x) / scale, (point.y - frame.origin.y) / scale);
}

- (NSUInteger)strokeCount {
    return _strokes.count;
}

- (BOOL)canUndo {
    return _history.count > 0;
}

#pragma mark Drawing

- (void)drawStrokes:(NSArray *)strokes inContext:(CGContextRef)ctx frame:(CGRect)frame {
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, frame);
    CGContextTranslateCTM(ctx, frame.origin.x, frame.origin.y);
    CGContextScaleCTM(ctx, [self scale], [self scale]);
    for (S4EStroke *stroke in strokes)
        S4EDrawStroke(stroke);
    CGContextRestoreGState(ctx);
}

// The shot with the finished annotations is cached: while drawing, only the current line is drawn over it
- (UIImage *)renderCache {
    UIGraphicsBeginImageContextWithOptions(self.bounds.size, YES, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[UIColor blackColor] setFill];
    CGContextFillRect(ctx, self.bounds);
    CGRect frame = [self imageFrame];
    [_image drawInRect:frame];
    [self drawStrokes:_strokes inContext:ctx frame:frame];
    UIImage *cache = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return cache;
}

- (void)drawRect:(CGRect)rect {
    if (!_cache)
        _cache = [self renderCache];
    [_cache drawAtPoint:CGPointZero];
    if (_current)
        [self drawStrokes:@[_current] inContext:UIGraphicsGetCurrentContext() frame:[self imageFrame]];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _cache = nil;
    [self setNeedsDisplay];
}

- (void)changed {
    _cache = nil;
    [self setNeedsDisplay];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (UIImage *)renderedImage {
    UIGraphicsBeginImageContextWithOptions(_image.size, YES, _image.scale);
    [_image drawAtPoint:CGPointZero];
    for (S4EStroke *stroke in _strokes)
        S4EDrawStroke(stroke);
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}

#pragma mark Touches

- (void)eraseAt:(CGPoint)point {
    CGFloat reach = 12 / [self scale];
    for (NSInteger i = (NSInteger)_strokes.count - 1; i >= 0; i--) {
        S4EStroke *stroke = _strokes[i];
        CGPathRef outline = CGPathCreateCopyByStrokingPath(stroke.path.CGPath, NULL, MAX(stroke.path.lineWidth, reach * 2),
                                                           kCGLineCapRound, kCGLineJoinRound, 0);
        BOOL hit = outline && CGPathContainsPoint(outline, NULL, point, false);
        if (outline)
            CGPathRelease(outline);
        if (hit) {
            [_strokes removeObjectAtIndex:i];
            [_history addObject:@{@"removed": stroke, @"index": @(i)}];
            [self changed];
            return;
        }
    }
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    CGPoint point = [self imagePoint:[[touches anyObject] locationInView:self]];
    if (self.tool == S4EMarkupEraser) {
        [self eraseAt:point];
        return;
    }
    S4EStroke *stroke = [[S4EStroke alloc] init];
    stroke.marker = self.tool == S4EMarkupMarker;
    stroke.color = self.color;
    UIBezierPath *path = [UIBezierPath bezierPath];
    // Line width is a fraction of the shot's width: it looks the same on screen and in the saved image
    path.lineWidth = _image.size.width * (stroke.marker ? 0.05 : 0.012);
    path.lineCapStyle = kCGLineCapRound;
    path.lineJoinStyle = kCGLineJoinRound;
    [path moveToPoint:point];
    [path addLineToPoint:point]; // a simple tap leaves a dot
    stroke.path = path;
    _current = stroke;
    _previous = point;
    [self setNeedsDisplay];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    CGPoint point = [self imagePoint:[[touches anyObject] locationInView:self]];
    if (self.tool == S4EMarkupEraser) {
        [self eraseAt:point];
        return;
    }
    if (!_current)
        return;
    // Smoothing: a curve through the midpoints of the segments
    CGPoint middle = CGPointMake((_previous.x + point.x) / 2, (_previous.y + point.y) / 2);
    [_current.path addQuadCurveToPoint:middle controlPoint:_previous];
    _previous = point;
    [self setNeedsDisplay];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    if (!_current)
        return;
    [_current.path addLineToPoint:[self imagePoint:[[touches anyObject] locationInView:self]]];
    [_strokes addObject:_current];
    [_history addObject:@{@"added": _current}];
    _current = nil;
    [self changed];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    _current = nil;
    [self setNeedsDisplay];
}

- (void)undo {
    NSDictionary *last = [_history lastObject];
    if (!last)
        return;
    [_history removeLastObject];
    if (last[@"added"])
        [_strokes removeObject:last[@"added"]];
    else
        [_strokes insertObject:last[@"removed"] atIndex:MIN([last[@"index"] unsignedIntegerValue], _strokes.count)];
    [self changed];
}

@end

#pragma mark - Colors

// A glossy drop of color, like iOS 6 buttons; the selected one gets a white ring
@interface S4EMarkupSwatch : UIControl
@property(nonatomic, strong) UIColor *color;
@end

@implementation S4EMarkupSwatch

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGPoint center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    CGRect drop = CGRectMake(center.x - 11, center.y - 11, 22, 22);
    if (self.selected) {
        UIBezierPath *ring = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(drop, -3.5, -3.5)];
        ring.lineWidth = 2;
        [[UIColor whiteColor] setStroke];
        [ring stroke];
    }
    UIBezierPath *oval = [UIBezierPath bezierPathWithOvalInRect:drop];
    [self.color setFill];
    [oval fill];

    CGContextSaveGState(ctx);
    [oval addClip];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    const CGFloat gloss[] = {1, 1, 1, 0.55, 1, 1, 1, 0};
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, gloss, NULL, 2);
    CGContextDrawLinearGradient(ctx, gradient, CGPointMake(0, drop.origin.y), CGPointMake(0, CGRectGetMidY(drop)), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
    CGContextRestoreGState(ctx);

    oval.lineWidth = 1;
    [[UIColor colorWithWhite:0 alpha:0.5] setStroke];
    [oval stroke];
}

@end

#pragma mark - Markup screen

@interface S4EMarkupView () <UIActionSheetDelegate>
@end

@implementation S4EMarkupView {
    S4EMarkupCanvas *_canvas;
    UINavigationBar *_bar;
    UIToolbar *_toolbar;
    UIBarButtonItem *_undoItem;
    NSArray *_swatches;
    UIActionSheet *_sheet;
    BOOL _canDelete;
}

- (instancetype)initWithFrame:(CGRect)frame image:(UIImage *)image canDelete:(BOOL)canDelete {
    if (!(self = [super initWithFrame:frame]))
        return nil;
    _canDelete = canDelete;
    self.backgroundColor = [UIColor blackColor];

    _canvas = [[S4EMarkupCanvas alloc] initWithFrame:self.bounds image:image];
    _canvas.contentInsets = UIEdgeInsetsMake(44 + 8, 8, 44 + 8, 8);
    [_canvas addTarget:self action:@selector(canvasChanged) forControlEvents:UIControlEventValueChanged];
    [self addSubview:_canvas];

    // On top: Done, the tools and the trash, like the Photos bar when viewing a picture
    _bar = [[UINavigationBar alloc] initWithFrame:CGRectZero];
    _bar.barStyle = UIBarStyleBlack;
    _bar.translucent = YES;
    UINavigationItem *item = [[UINavigationItem alloc] initWithTitle:@""];
    item.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:S4E_L(@"Done", @"Готово") style:UIBarButtonItemStyleDone
                                                             target:self action:@selector(doneTapped)];
    if (canDelete)
        item.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
                                                                                target:self action:@selector(trashTapped)];
    UISegmentedControl *tools = [[UISegmentedControl alloc] initWithItems:@[S4EPenIcon(), S4EMarkerIcon(), S4EEraserIcon()]];
    tools.segmentedControlStyle = UISegmentedControlStyleBar;
    tools.tintColor = [UIColor colorWithWhite:0.32 alpha:1];
    tools.frame = CGRectMake(0, 0, 132, 30);
    tools.selectedSegmentIndex = 0;
    [tools addTarget:self action:@selector(toolChanged:) forControlEvents:UIControlEventValueChanged];
    item.titleView = tools;
    _bar.items = @[item];
    [self addSubview:_bar];

    // At the bottom: undo and six colors, as in iOS 11 markup
    NSArray *colors = @[[UIColor blackColor], [UIColor whiteColor], [UIColor colorWithRed:0.16 green:0.47 blue:0.96 alpha:1],
                        [UIColor colorWithRed:0.20 green:0.75 blue:0.25 alpha:1], [UIColor colorWithRed:1 green:0.80 blue:0 alpha:1],
                        [UIColor colorWithRed:0.92 green:0.16 blue:0.14 alpha:1]];
    UIView *palette = [[UIView alloc] initWithFrame:CGRectMake(0, 0, colors.count * 34, 44)];
    NSMutableArray *swatches = [NSMutableArray array];
    [colors enumerateObjectsUsingBlock:^(UIColor *color, NSUInteger i, BOOL *stop) {
        S4EMarkupSwatch *swatch = [[S4EMarkupSwatch alloc] initWithFrame:CGRectMake(i * 34, 0, 34, 44)];
        swatch.color = color;
        [swatch addTarget:self action:@selector(swatchTapped:) forControlEvents:UIControlEventTouchUpInside];
        [palette addSubview:swatch];
        [swatches addObject:swatch];
    }];
    _swatches = swatches;
    [self swatchTapped:[swatches lastObject]];

    _undoItem = [[UIBarButtonItem alloc] initWithImage:S4EUndoIcon() style:UIBarButtonItemStylePlain target:self action:@selector(undoTapped)];
    _undoItem.enabled = NO;
    UIBarButtonItem *flexible = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *balance = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
    balance.width = 34;
    _toolbar = [[UIToolbar alloc] initWithFrame:CGRectZero];
    _toolbar.barStyle = UIBarStyleBlack;
    _toolbar.translucent = YES;
    _toolbar.items = @[_undoItem, flexible, [[UIBarButtonItem alloc] initWithCustomView:palette], flexible, balance];
    [self addSubview:_toolbar];
    [self setNeedsLayout];
    [self layoutIfNeeded];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    _canvas.frame = self.bounds;
    _bar.frame = CGRectMake(0, 0, size.width, 44);
    _toolbar.frame = CGRectMake(0, size.height - 44, size.width, 44);
}

- (BOOL)edited {
    return _canvas.strokeCount > 0;
}

- (CGRect)imageFrame {
    return [_canvas imageFrame];
}

- (UIImage *)renderedImage {
    return [_canvas renderedImage];
}

- (void)canvasChanged {
    _undoItem.enabled = [_canvas canUndo];
}

- (void)toolChanged:(UISegmentedControl *)tools {
    _canvas.tool = (S4EMarkupTool)tools.selectedSegmentIndex;
}

- (void)swatchTapped:(S4EMarkupSwatch *)swatch {
    for (S4EMarkupSwatch *other in _swatches)
        other.selected = other == swatch;
    _canvas.color = swatch.color;
}

- (void)undoTapped {
    [_canvas undo];
}

#pragma mark Done and trash

- (void)showSheet:(UIActionSheet *)sheet {
    [self dismissSheet];
    sheet.actionSheetStyle = UIActionSheetStyleBlackTranslucent;
    _sheet = sheet;
    [sheet showInView:self];
}

// As in iOS 11: while the shot is not in Photos, Done always asks whether to save or delete it
- (void)doneTapped {
    if (!_canDelete && !self.edited) {
        [self finish:S4EMarkupKeep];
        return;
    }
    [self showSheet:_canDelete
        ? [[UIActionSheet alloc] initWithTitle:nil delegate:self cancelButtonTitle:S4E_L(@"Cancel", @"Отменить")
                        destructiveButtonTitle:S4E_L(@"Delete Screenshot", @"Удалить скриншот")
                             otherButtonTitles:S4E_L(@"Save to Photos", @"Сохранить в Фото"), nil]
        : [[UIActionSheet alloc] initWithTitle:nil delegate:self cancelButtonTitle:S4E_L(@"Cancel", @"Отменить")
                        destructiveButtonTitle:S4E_L(@"Don't Save Markup", @"Не сохранять пометки")
                             otherButtonTitles:S4E_L(@"Save Copy to Photos", @"Сохранить копию в Фото"), nil]];
}

- (void)trashTapped {
    [self showSheet:[[UIActionSheet alloc] initWithTitle:nil delegate:self cancelButtonTitle:S4E_L(@"Cancel", @"Отменить")
                                  destructiveButtonTitle:S4E_L(@"Delete Screenshot", @"Удалить скриншот") otherButtonTitles:nil]];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index {
    _sheet = nil;
    if (index == sheet.cancelButtonIndex)
        return;
    [self finish:index == sheet.destructiveButtonIndex ? S4EMarkupDelete : S4EMarkupKeep];
}

- (void)dismissSheet {
    UIActionSheet *sheet = _sheet;
    _sheet = nil;
    sheet.delegate = nil;
    [sheet dismissWithClickedButtonIndex:sheet.cancelButtonIndex animated:NO];
}

- (void)finish:(S4EMarkupAction)action {
    if (self.onFinish)
        self.onFinish(action);
}

@end
