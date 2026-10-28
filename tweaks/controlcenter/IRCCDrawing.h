// Пункт управления: знаки и глянцевые круглые кнопки в стиле iOS 6.

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
} IRCCGlyph;

// Рисует знак белым в квадрате rect (координаты знаков — сетка 24×24).
void IRCCDrawGlyph(IRCCGlyph glyph, CGRect rect);

// Картинка знака: для ползунка яркости и т. п.
UIImage *IRCCGlyphImage(IRCCGlyph glyph, CGFloat size, UIColor *color);

// Круглая кнопка: тёмное стекло, во включённом состоянии — синий глянец, как кнопки iOS 6.
// plain — без круга, только знак (кнопки музыки, как в панели многозадачности).
@interface IRCCButton : UIControl
@property(nonatomic) IRCCGlyph glyph;
@property(nonatomic, getter=isOn) BOOL on;
@property(nonatomic) BOOL plain;
+ (instancetype)buttonWithGlyph:(IRCCGlyph)glyph;
@end
