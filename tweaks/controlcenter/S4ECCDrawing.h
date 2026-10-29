// Пункт управления: знаки и материалы в стиле iOS 6.
// Материалы — как у Auxo: серый лён, квадратные кнопки в серой оправе с текстурным полем,
// синий глянец у включённых, кнопки музыки — просто белые тиснёные знаки.

#pragma once

#import <UIKit/UIKit.h>

typedef enum {
    S4ECCGlyphAirplane,
    S4ECCGlyphWiFi,
    S4ECCGlyphBluetooth,
    S4ECCGlyphMoon,
    S4ECCGlyphRotationLock,
    S4ECCGlyphFlashlight,
    S4ECCGlyphTimer,
    S4ECCGlyphCalculator,
    S4ECCGlyphCamera,
    S4ECCGlyphPrevious,
    S4ECCGlyphPlay,
    S4ECCGlyphPause,
    S4ECCGlyphNext,
    S4ECCGlyphSunSmall,
    S4ECCGlyphSunLarge,
    S4ECCGlyphSliders,
} S4ECCGlyph;

// Рисует знак текущим цветом в квадрате rect (координаты знаков — сетка 24×24).
void S4ECCDrawGlyph(S4ECCGlyph glyph, CGRect rect);

// Картинка знака: для ползунка яркости, иконки в Activator и т. п.
UIImage *S4ECCGlyphImage(S4ECCGlyph glyph, CGFloat size, UIColor *color);

// Серый лён — фон панели.
UIColor *S4ECCLinenColor(void);

// Желобок между секциями: тёмная линия и светлая под ней. Высота 2 пт.
UIView *S4ECCGroove(CGRect frame);

// Дорожки ползунка: светлая заливка до бегунка и тёмный жёлоб после него.
UIImage *S4ECCTrackImage(BOOL filled);

typedef enum {
    S4ECCButtonStyleSquare, // скруглённый квадрат в серой оправе: переключатели и программы
    S4ECCButtonStylePlain,  // только белый тиснёный знак: кнопки музыки
} S4ECCButtonStyle;

@interface S4ECCButton : UIControl
@property(nonatomic) S4ECCGlyph glyph;
@property(nonatomic) S4ECCButtonStyle style;
@property(nonatomic, getter=isOn) BOOL on;
+ (instancetype)buttonWithGlyph:(S4ECCGlyph)glyph style:(S4ECCButtonStyle)style;
@end
