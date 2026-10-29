// Control Center: glyphs and materials in iOS 6 style.
// Auxo-like materials: grey linen, square buttons in a grey bezel with a textured field,
// blue gloss when on, music buttons are just white embossed glyphs.

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

// Draws a glyph in the current color in the square rect (glyph coordinates use a 24×24 grid).
void S4ECCDrawGlyph(S4ECCGlyph glyph, CGRect rect);

// A glyph image: for the brightness slider, the Activator icon, etc.
UIImage *S4ECCGlyphImage(S4ECCGlyph glyph, CGFloat size, UIColor *color);

// Grey linen: the panel background.
UIColor *S4ECCLinenColor(void);

// A groove between sections: a dark line with a light one under it. 2 pt tall.
UIView *S4ECCGroove(CGRect frame);

// Slider tracks: a light fill up to the thumb and a dark trough after it.
UIImage *S4ECCTrackImage(BOOL filled);

typedef enum {
    S4ECCButtonStyleSquare, // rounded square in a grey bezel: toggles and apps
    S4ECCButtonStylePlain,  // just a white embossed glyph: music buttons
} S4ECCButtonStyle;

@interface S4ECCButton : UIControl
@property(nonatomic) S4ECCGlyph glyph;
@property(nonatomic) S4ECCButtonStyle style;
@property(nonatomic, getter=isOn) BOOL on;
+ (instancetype)buttonWithGlyph:(S4ECCGlyph)glyph style:(S4ECCButtonStyle)style;
@end
