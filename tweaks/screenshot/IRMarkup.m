// Разметка скриншота: холст с пометками и панели инструментов.
//
// Пометки хранятся в координатах самого снимка, поэтому сохраняются в полном разрешении.
// Ластик, как в iOS 11, стирает пометку целиком. Отмена откатывает и рисование, и стирание.

#import "IRMarkup.h"
#import <QuartzCore/QuartzCore.h>

typedef enum { IRMarkupPen, IRMarkupMarker, IRMarkupEraser } IRMarkupTool;

#pragma mark - Знаки инструментов

static UIImage *IRMarkupIcon(void (^draw)(CGContextRef ctx)) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(22, 22), NO, 0);
    [[UIColor whiteColor] set];
    draw(UIGraphicsGetCurrentContext());
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static void IRFillPolygon(const CGFloat *points, int count) {
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(points[0], points[1])];
    for (int i = 1; i < count; i++)
        [path addLineToPoint:CGPointMake(points[2 * i], points[2 * i + 1])];
    [path closePath];
    [path fill];
}

static UIImage *IRPenIcon(void) {
    return IRMarkupIcon(^(CGContextRef ctx) {
        const CGFloat body[] = {6.5, 13, 14.5, 5, 17, 7.5, 9, 15.5};
        const CGFloat tip[] = {6, 13.5, 8.5, 16, 3.5, 18.5};
        const CGFloat cap[] = {15.3, 4.2, 16.4, 3.1, 18.9, 5.6, 17.8, 6.7};
        IRFillPolygon(body, 4);
        IRFillPolygon(tip, 3);
        IRFillPolygon(cap, 4);
    });
}

static UIImage *IRMarkerIcon(void) {
    return IRMarkupIcon(^(CGContextRef ctx) {
        const CGFloat body[] = {6.5, 11, 13.5, 4, 18, 8.5, 11, 15.5};
        const CGFloat tip[] = {6, 11.5, 10.5, 16, 7, 18, 4, 15};
        IRFillPolygon(body, 4);
        IRFillPolygon(tip, 4);
        [[UIBezierPath bezierPathWithRect:CGRectMake(3, 19.5, 16, 1.8)] fill];
    });
}

static UIImage *IREraserIcon(void) {
    return IRMarkupIcon(^(CGContextRef ctx) {
        CGContextTranslateCTM(ctx, 11, 11);
        CGContextRotateCTM(ctx, -M_PI_4);
        UIBezierPath *outline = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(-8, -4, 16, 8) cornerRadius:2];
        outline.lineWidth = 1.5;
        [outline stroke];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(-8, -4, 6, 8) cornerRadius:2] fill];
    });
}

static UIImage *IRUndoIcon(void) {
    return IRMarkupIcon(^(CGContextRef ctx) {
        UIBezierPath *arc = [UIBezierPath bezierPathWithArcCenter:CGPointMake(12, 13) radius:5.5 startAngle:0 endAngle:M_PI clockwise:NO];
        arc.lineWidth = 2.2;
        arc.lineCapStyle = kCGLineCapRound;
        [arc stroke];
        const CGFloat head[] = {3, 12, 10, 12, 6.5, 16.5};
        IRFillPolygon(head, 3);
    });
}

#pragma mark - Холст

@interface IRStroke : NSObject
@property(nonatomic, strong) UIBezierPath *path;
@property(nonatomic, strong) UIColor *color;
@property(nonatomic) BOOL marker;
@end

@implementation IRStroke
@end

static void IRDrawStroke(IRStroke *stroke) {
    [stroke.color setStroke];
    // Один проход по всему пути: маркер не темнеет там, где линия сама себя пересекает
    [stroke.path strokeWithBlendMode:kCGBlendModeNormal alpha:stroke.marker ? 0.45 : 1];
}

// Сообщает об изменениях через UIControlEventValueChanged
@interface IRMarkupCanvas : UIControl
@property(nonatomic) IRMarkupTool tool;
@property(nonatomic, strong) UIColor *color;
@property(nonatomic) UIEdgeInsets contentInsets;
- (instancetype)initWithFrame:(CGRect)frame image:(UIImage *)image;
- (CGRect)imageFrame;
- (NSUInteger)strokeCount;
- (BOOL)canUndo;
- (void)undo;
- (UIImage *)renderedImage;
@end

@implementation IRMarkupCanvas {
    UIImage *_image;
    NSMutableArray *_strokes;
    NSMutableArray *_history;
    IRStroke *_current;
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

#pragma mark Рисование

- (void)drawStrokes:(NSArray *)strokes inContext:(CGContextRef)ctx frame:(CGRect)frame {
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, frame);
    CGContextTranslateCTM(ctx, frame.origin.x, frame.origin.y);
    CGContextScaleCTM(ctx, [self scale], [self scale]);
    for (IRStroke *stroke in strokes)
        IRDrawStroke(stroke);
    CGContextRestoreGState(ctx);
}

// Снимок с готовыми пометками кешируется: при рисовании поверх него рисуется только текущая линия
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
    for (IRStroke *stroke in _strokes)
        IRDrawStroke(stroke);
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}

#pragma mark Касания

- (void)eraseAt:(CGPoint)point {
    CGFloat reach = 12 / [self scale];
    for (NSInteger i = (NSInteger)_strokes.count - 1; i >= 0; i--) {
        IRStroke *stroke = _strokes[i];
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
    if (self.tool == IRMarkupEraser) {
        [self eraseAt:point];
        return;
    }
    IRStroke *stroke = [[IRStroke alloc] init];
    stroke.marker = self.tool == IRMarkupMarker;
    stroke.color = self.color;
    UIBezierPath *path = [UIBezierPath bezierPath];
    // Толщина — доля ширины снимка: одинаково выглядит и на экране, и в сохранённой картинке
    path.lineWidth = _image.size.width * (stroke.marker ? 0.05 : 0.012);
    path.lineCapStyle = kCGLineCapRound;
    path.lineJoinStyle = kCGLineJoinRound;
    [path moveToPoint:point];
    [path addLineToPoint:point]; // простое касание оставляет точку
    stroke.path = path;
    _current = stroke;
    _previous = point;
    [self setNeedsDisplay];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    CGPoint point = [self imagePoint:[[touches anyObject] locationInView:self]];
    if (self.tool == IRMarkupEraser) {
        [self eraseAt:point];
        return;
    }
    if (!_current)
        return;
    // Сглаживание: кривая через середины отрезков
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

#pragma mark - Цвета

// Глянцевая капля цвета, как кнопки iOS 6; у выбранной — белое кольцо
@interface IRMarkupSwatch : UIControl
@property(nonatomic, strong) UIColor *color;
@end

@implementation IRMarkupSwatch

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

#pragma mark - Экран разметки

@interface IRMarkupView () <UIActionSheetDelegate>
@end

@implementation IRMarkupView {
    IRMarkupCanvas *_canvas;
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

    _canvas = [[IRMarkupCanvas alloc] initWithFrame:self.bounds image:image];
    _canvas.contentInsets = UIEdgeInsetsMake(44 + 8, 8, 44 + 8, 8);
    [_canvas addTarget:self action:@selector(canvasChanged) forControlEvents:UIControlEventValueChanged];
    [self addSubview:_canvas];

    // Сверху «Готово», инструменты и корзина — как панель «Фото» при просмотре снимка
    _bar = [[UINavigationBar alloc] initWithFrame:CGRectZero];
    _bar.barStyle = UIBarStyleBlack;
    _bar.translucent = YES;
    UINavigationItem *item = [[UINavigationItem alloc] initWithTitle:@""];
    item.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Готово" style:UIBarButtonItemStyleDone
                                                             target:self action:@selector(doneTapped)];
    if (canDelete)
        item.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
                                                                                target:self action:@selector(trashTapped)];
    UISegmentedControl *tools = [[UISegmentedControl alloc] initWithItems:@[IRPenIcon(), IRMarkerIcon(), IREraserIcon()]];
    tools.segmentedControlStyle = UISegmentedControlStyleBar;
    tools.tintColor = [UIColor colorWithWhite:0.32 alpha:1];
    tools.frame = CGRectMake(0, 0, 132, 30);
    tools.selectedSegmentIndex = 0;
    [tools addTarget:self action:@selector(toolChanged:) forControlEvents:UIControlEventValueChanged];
    item.titleView = tools;
    _bar.items = @[item];
    [self addSubview:_bar];

    // Снизу отмена и шесть цветов, как у разметки iOS 11
    NSArray *colors = @[[UIColor blackColor], [UIColor whiteColor], [UIColor colorWithRed:0.16 green:0.47 blue:0.96 alpha:1],
                        [UIColor colorWithRed:0.20 green:0.75 blue:0.25 alpha:1], [UIColor colorWithRed:1 green:0.80 blue:0 alpha:1],
                        [UIColor colorWithRed:0.92 green:0.16 blue:0.14 alpha:1]];
    UIView *palette = [[UIView alloc] initWithFrame:CGRectMake(0, 0, colors.count * 34, 44)];
    NSMutableArray *swatches = [NSMutableArray array];
    [colors enumerateObjectsUsingBlock:^(UIColor *color, NSUInteger i, BOOL *stop) {
        IRMarkupSwatch *swatch = [[IRMarkupSwatch alloc] initWithFrame:CGRectMake(i * 34, 0, 34, 44)];
        swatch.color = color;
        [swatch addTarget:self action:@selector(swatchTapped:) forControlEvents:UIControlEventTouchUpInside];
        [palette addSubview:swatch];
        [swatches addObject:swatch];
    }];
    _swatches = swatches;
    [self swatchTapped:[swatches lastObject]];

    _undoItem = [[UIBarButtonItem alloc] initWithImage:IRUndoIcon() style:UIBarButtonItemStylePlain target:self action:@selector(undoTapped)];
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
    _canvas.tool = (IRMarkupTool)tools.selectedSegmentIndex;
}

- (void)swatchTapped:(IRMarkupSwatch *)swatch {
    for (IRMarkupSwatch *other in _swatches)
        other.selected = other == swatch;
    _canvas.color = swatch.color;
}

- (void)undoTapped {
    [_canvas undo];
}

#pragma mark Готово и корзина

- (void)showSheet:(UIActionSheet *)sheet {
    [self dismissSheet];
    sheet.actionSheetStyle = UIActionSheetStyleBlackTranslucent;
    _sheet = sheet;
    [sheet showInView:self];
}

- (void)doneTapped {
    if (!self.edited) {
        [self finish:IRMarkupKeep];
        return;
    }
    [self showSheet:_canDelete
        ? [[UIActionSheet alloc] initWithTitle:nil delegate:self cancelButtonTitle:@"Отменить"
                        destructiveButtonTitle:@"Удалить скриншот" otherButtonTitles:@"Сохранить в Фото", nil]
        : [[UIActionSheet alloc] initWithTitle:nil delegate:self cancelButtonTitle:@"Отменить"
                        destructiveButtonTitle:@"Не сохранять пометки" otherButtonTitles:@"Сохранить копию в Фото", nil]];
}

- (void)trashTapped {
    [self showSheet:[[UIActionSheet alloc] initWithTitle:nil delegate:self cancelButtonTitle:@"Отменить"
                                  destructiveButtonTitle:@"Удалить скриншот" otherButtonTitles:nil]];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index {
    _sheet = nil;
    if (index == sheet.cancelButtonIndex)
        return;
    [self finish:index == sheet.destructiveButtonIndex ? IRMarkupDelete : IRMarkupKeep];
}

- (void)dismissSheet {
    UIActionSheet *sheet = _sheet;
    _sheet = nil;
    sheet.delegate = nil;
    [sheet dismissWithClickedButtonIndex:sheet.cancelButtonIndex animated:NO];
}

- (void)finish:(IRMarkupAction)action {
    if (self.onFinish)
        self.onFinish(action);
}

@end
