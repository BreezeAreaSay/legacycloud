// Разметка скриншота (iOS 11) в стиле iOS 6: чёрные полупрозрачные панели, как в «Фото» при просмотре,
// перо, маркер и ластик в сегментах, шесть глянцевых цветов и отмена.

#pragma once

#import <UIKit/UIKit.h>

typedef enum {
    IRMarkupKeep,   // закрыть и оставить снимок — с пометками, если они есть
    IRMarkupDelete, // удалить снимок, а если он уже в «Фото» — не сохранять пометки
} IRMarkupAction;

@interface IRMarkupView : UIView
// canDelete: снимок ещё не записан в «Фото», и его можно удалить, как в iOS 11
- (instancetype)initWithFrame:(CGRect)frame image:(UIImage *)image canDelete:(BOOL)canDelete;
@property(nonatomic, copy) void (^onFinish)(IRMarkupAction action);
@property(nonatomic, readonly) BOOL edited;
@property(nonatomic, readonly) CGRect imageFrame;
- (UIImage *)renderedImage;
// Закрыть открытое меню действий, если экран уходит без ответа (блокировка, «Домой»)
- (void)dismissSheet;
@end
