// Screenshot markup (iOS 11) in iOS 6 style: black translucent bars, as when viewing a picture in Photos,
// pen, marker and eraser in a segmented control, six glossy colors and undo.

#pragma once

#import <UIKit/UIKit.h>

typedef enum {
    S4EMarkupKeep,   // close and keep the shot, with annotations if there are any
    S4EMarkupDelete, // delete the shot, or if it is already in Photos, don't save the annotations
} S4EMarkupAction;

@interface S4EMarkupView : UIView
// canDelete: the shot is not saved to Photos yet and can be deleted, as in iOS 11
- (instancetype)initWithFrame:(CGRect)frame image:(UIImage *)image canDelete:(BOOL)canDelete;
@property(nonatomic, copy) void (^onFinish)(S4EMarkupAction action);
@property(nonatomic, readonly) BOOL edited;
@property(nonatomic, readonly) CGRect imageFrame;
- (UIImage *)renderedImage;
// Closes an open action sheet if the screen goes away without an answer (lock, Home)
- (void)dismissSheet;
@end
