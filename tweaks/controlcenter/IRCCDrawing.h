// Пункт управления: знаки и материалы в стиле iOS 6.
// Материалы — как в концепте с r/jailbreak: перфорированный тёмный металл, серебристый ободок,
// синий глянец у включённых кнопок, круглые серебристые кнопки музыки.

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

// Перфорированный тёмный металл — фон панели.
UIColor *IRCCPerforatedColor(void);

typedef enum {
    IRCCButtonStyleSquare, // скруглённый квадрат с серебристым ободком: переключатели и программы
    IRCCButtonStyleMedia,  // круглая серебристая кнопка с тёмным знаком: музыка
} IRCCButtonStyle;

@interface IRCCButton : UIControl
@property(nonatomic) IRCCGlyph glyph;
@property(nonatomic) IRCCButtonStyle style;
@property(nonatomic, getter=isOn) BOOL on;
+ (instancetype)buttonWithGlyph:(IRCCGlyph)glyph style:(IRCCButtonStyle)style;
@end
