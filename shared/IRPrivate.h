// Приватные API iOS 6.1, которыми пользуются твики.
// Сверено с class-dump iOS 6.1 (MP0w/iOS-Headers). Всё вызывается через проверки respondsToSelector.

#pragma once

#import <UIKit/UIKit.h>

// UIKit

@interface UIApplication (IRPrivate)
- (UIView *)statusBar;
@end

@interface UIStatusBarItemView : UIView
- (id)contentsImageForStyle:(int)style;
- (float)updateContentsAndWidth;
@end

@interface UINavigationController (IRPrivate)
- (BOOL)_isTransitioning;
@end

@interface UIWebDocumentView : UIView
- (id)webView;
@end

// WebKit (WebKit1 внутри UIKit)

@interface WebDataSource : NSObject
- (NSURLRequest *)request;
@end

@interface WebFrame : NSObject
- (WebDataSource *)dataSource;
- (void)loadRequest:(NSURLRequest *)request;
- (void)reload;
@end

@interface WebView : NSObject
- (WebFrame *)mainFrame;
- (NSString *)customUserAgent;
- (void)setCustomUserAgent:(NSString *)userAgent;
@end

// SpringBoard

@interface SpringBoard : UIApplication
- (void)_relaunchSpringBoardNow;
@end

@interface SBAlertItem : NSObject <UIAlertViewDelegate>
- (UIAlertView *)alertSheet;
- (void)dismiss;
@end

@interface SBLowPowerAlertItem : SBAlertItem
@end

@interface SBUIController : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isOnAC;
- (int)batteryCapacityAsPercentage;
@end

@interface SBBrightnessController : NSObject
+ (instancetype)sharedBrightnessController;
- (void)_setBrightnessLevel:(float)level showHUD:(BOOL)showHUD;
@end

@interface SBApplication : NSObject
- (NSString *)bundleIdentifier;
@end

@interface SBApplicationController : NSObject
+ (instancetype)sharedInstance;
- (NSArray *)allApplications;
@end

@interface SBIcon : NSObject
@end

@interface SBApplicationIcon : SBIcon
- (NSString *)applicationBundleID;
@end

@interface SBIconView : UIView
- (SBIcon *)icon;
@end

// ManagedConfiguration

@interface MCProfileConnection : NSObject
+ (instancetype)sharedConnection;
- (id)effectiveValueForSetting:(NSString *)setting;
- (void)setValue:(id)value forSetting:(NSString *)setting;
@end

// Preferences.framework

enum {
    PSGroupCell = 0,
    PSLinkCell = 1,
    PSLinkListCell = 2,
    PSListItemCell = 3,
    PSTitleValueCell = 4,
    PSSliderCell = 5,
    PSSwitchCell = 6,
    PSStaticTextCell = 7,
    PSButtonCell = 13,
};

@interface PSSpecifier : NSObject
@property(retain, nonatomic) NSString *name;
@property(retain, nonatomic) NSString *identifier;
@property(nonatomic) id target;
+ (instancetype)preferenceSpecifierNamed:(NSString *)name target:(id)target set:(SEL)set get:(SEL)get
                                  detail:(Class)detail cell:(int)cell edit:(Class)edit;
+ (instancetype)groupSpecifierWithName:(NSString *)name;
+ (instancetype)emptyGroupSpecifier;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
- (void)setValues:(NSArray *)values titles:(NSArray *)titles;
@end

@interface PSViewController : UIViewController
- (PSSpecifier *)specifier;
@end

@interface PSListController : PSViewController <UIAlertViewDelegate>
- (NSArray *)specifiers;
- (void)setSpecifiers:(NSArray *)specifiers;
- (void)reloadSpecifiers;
- (void)reloadSpecifier:(PSSpecifier *)specifier;
- (BOOL)getGroup:(int *)group row:(int *)row ofSpecifierID:(NSString *)identifier;
- (int)indexOfGroup:(int)group;
- (NSArray *)specifiersInGroup:(int)group;
@end

@interface PSListItemsController : PSListController
@end
