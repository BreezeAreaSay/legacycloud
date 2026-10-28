// Пункт управления: знаки и материалы в стиле iOS 6.
// Материалы — как у Auxo: серый лён, квадратные кнопки в серой оправе с текстурным полем,
// синий глянец у включённых, кнопки музыки — просто белые тиснёные знаки.

#pragma once

#import <UIKit/UIKit.h>

typedef enum {
    IRCCGlyphAirplane,
    IRCCGlyphWiFi,
    IRCCGlyphBluetooth,
    IRCCGlyphMoon,
    IRCCGlyphRotationLock,
    IRCCGlyphFlashlight,
    IRCCGlyphTimer,
    IRCCGlyphCalculator,
    IRCCGlyphCamera,
    IRCCGlyphPrevious,
    IRCCGlyphPlay,
    IRCCGlyphPause,
    IRCCGlyphNext,
    IRCCGlyphSunSmall,
    IRCCGlyphSunLarge,
    IRCCGlyphSliders,
} IRCCGlyph;

// Рисует знак текущим цветом в квадрате rect (координаты знаков — сетка 24×24).
void IRCCDrawGlyph(IRCCGlyph glyph, CGRect rect);

// Картинка знака: для ползунка яркости, иконки в Activator и т. п.
UIImage *IRCCGlyphImage(IRCCGlyph glyph, CGFloat size, UIColor *color);

// Серый лён — фон панели.
UIColor *IRCCLinenColor(void);

// Желобок между секциями: тёмная линия и светлая под ней. Высота 2 пт.
UIView *IRCCGroove(CGRect frame);

// Дорожки ползунка: светлая заливка до бегунка и тёмный жёлоб после него.
UIImage *IRCCTrackImage(BOOL filled);

typedef enum {
    IRCCButtonStyleSquare, // скруглённый квадрат в серой оправе: переключатели и программы
    IRCCButtonStylePlain,  // только белый тиснёный знак: кнопки музыки
} IRCCButtonStyle;

@interface IRCCButton : UIControl
@property(nonatomic) IRCCGlyph glyph;
@property(nonatomic) IRCCButtonStyle style;
@property(nonatomic, getter=isOn) BOOL on;
+ (instancetype)buttonWithGlyph:(IRCCGlyph)glyph style:(IRCCButtonStyle)style;
@end
