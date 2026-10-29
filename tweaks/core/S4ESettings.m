// The Skeuo4Ever screen in Settings: an entry at the root, switches for every feature, Night Shift
// and Battery Health.
// Built from native iOS 6 Preferences.framework cells, so it looks like part of the system.

#import "S4EShared.h"
#import "S4EPrivate.h"
#import "S4ENightShift.h"
#include <dlfcn.h>
#include <mach/mach.h>
#include <sys/sysctl.h>

#pragma mark - Specifier storage

static void **S4ESpecifiersSlot(PSListController *controller) {
    Ivar ivar = class_getInstanceVariable(objc_getClass("PSListController"), "_specifiers");
    if (!ivar)
        return NULL;
    return (void **)((uint8_t *)(__bridge void *)controller + ivar_getOffset(ivar));
}

static NSArray *S4ESpecifiers(PSListController *controller) {
    void **slot = S4ESpecifiersSlot(controller);
    return slot ? (__bridge NSArray *)*slot : nil;
}

// Write the ivar directly, as settings bundles do: Preferences.framework releases it itself in dealloc.
static void S4ESetSpecifiersStorage(PSListController *controller, NSArray *specifiers) {
    void **slot = S4ESpecifiersSlot(controller);
    if (!slot) {
        [controller setSpecifiers:specifiers];
        return;
    }
    void *old = *slot;
    *slot = specifiers ? (void *)CFBridgingRetain(specifiers) : NULL;
    if (old)
        CFRelease(old);
}

static BOOL S4EFeatureInstalled(NSString *dylib) {
    NSString *path = [S4E_DYLIB_DIR stringByAppendingPathComponent:[dylib stringByAppendingPathExtension:@"dylib"]];
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

static PSSpecifier *S4EGroup(NSString *title, NSString *footer) {
    PSSpecifier *group = title ? [PSSpecifier groupSpecifierWithName:title] : [PSSpecifier emptyGroupSpecifier];
    if (footer)
        [group setProperty:footer forKey:@"footerText"];
    return group;
}

#pragma mark - Confirmation (UIAlertView holds its delegate weakly)

@interface S4EAlertDelegate : NSObject <UIAlertViewDelegate>
@property(nonatomic, copy) void (^handler)(BOOL confirmed);
@end

static NSMutableSet *gActiveAlerts;

@implementation S4EAlertDelegate
+ (void)showTitle:(NSString *)title message:(NSString *)message confirm:(NSString *)confirm handler:(void (^)(BOOL))handler {
    S4EAlertDelegate *delegate = [[S4EAlertDelegate alloc] init];
    delegate.handler = handler;
    if (!gActiveAlerts)
        gActiveAlerts = [NSMutableSet set];
    [gActiveAlerts addObject:delegate];
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title message:message delegate:delegate
                                          cancelButtonTitle:S4E_L(@"Cancel", @"Отменить") otherButtonTitles:confirm, nil];
    [alert show];
}

- (void)alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex {
    if (self.handler)
        self.handler(buttonIndex != alertView.cancelButtonIndex);
    [gActiveAlerts removeObject:self];
}
@end

#pragma mark - Switch values

// Bold Text needs a SpringBoard restart, so we ask for confirmation, like iOS 7.
// s4eOwner is the list that holds the switch: on cancel we flip the switch back.
static void S4EApplySetting(PSSpecifier *spec, id value) {
    NSString *key = [spec propertyForKey:@"s4eKey"];
    if (![key isEqualToString:kS4EBoldText]) {
        S4EPrefsSet(key, value);
        return;
    }
    PSListController *owner = [[spec propertyForKey:@"s4eOwner"] nonretainedObjectValue];
    // A strong reference on purpose: the block lives only until the alert closes, and a __weak variable
    // on armv7 needs SjLj exception tables, which the SDK stubs don't have.
    [S4EAlertDelegate showTitle:nil
                       message:S4E_L(@"Applying this setting will restart SpringBoard and all apps.",
                                     @"Чтобы применить этот параметр, SpringBoard и все программы будут перезапущены.")
                       confirm:S4E_L(@"Continue", @"Продолжить")
                       handler:^(BOOL confirmed) {
                           if (!confirmed) {
                               [owner reloadSpecifier:spec];
                               return;
                           }
                           S4EPrefsSet(kS4EBoldText, value);
                           notify_post(S4E_NOTIFY_RESPRING);
                       }];
}

static PSSpecifier *S4EMakeSwitch(id target, PSListController *owner, NSString *name, NSString *key, BOOL fallback) {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name target:target set:@selector(s4e_setValue:specifier:)
                                                          get:@selector(s4e_value:) detail:nil cell:PSSwitchCell edit:nil];
    [spec setProperty:key forKey:@"s4eKey"];
    [spec setProperty:@(fallback) forKey:@"s4eDefault"];
    [spec setProperty:[NSValue valueWithNonretainedObject:owner] forKey:@"s4eOwner"];
    return spec;
}

static PSSpecifier *S4EMakeLink(id target, NSString *name, Class detail) {
    return [PSSpecifier preferenceSpecifierNamed:name target:target set:NULL get:NULL detail:detail cell:PSLinkCell edit:nil];
}

static id S4EValueFor(PSSpecifier *spec) {
    id value = S4EPrefsRead()[[spec propertyForKey:@"s4eKey"]];
    return value ?: [spec propertyForKey:@"s4eDefault"];
}

#pragma mark - Base list

@interface S4EListController : PSListController
- (NSMutableArray *)s4e_buildSpecifiers;
@end

@implementation S4EListController

- (NSArray *)specifiers {
    if (!S4ESpecifiers(self))
        S4ESetSpecifiersStorage(self, [self s4e_buildSpecifiers]);
    return S4ESpecifiers(self);
}

- (NSMutableArray *)s4e_buildSpecifiers {
    return [NSMutableArray array];
}

- (void)s4e_refresh {
    [self setSpecifiers:[self s4e_buildSpecifiers]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self s4e_refresh];
}

- (PSSpecifier *)s4e_switch:(NSString *)name key:(NSString *)key fallback:(BOOL)fallback {
    return S4EMakeSwitch(self, self, name, key, fallback);
}

- (PSSpecifier *)s4e_link:(NSString *)name detail:(Class)detail {
    return S4EMakeLink(self, name, detail);
}

- (PSSpecifier *)s4e_info:(NSString *)name value:(NSString *)value {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name target:self set:NULL get:@selector(s4e_infoValue:)
                                                       detail:nil cell:PSTitleValueCell edit:nil];
    [spec setProperty:value forKey:@"s4eValue"];
    return spec;
}

- (id)s4e_infoValue:(PSSpecifier *)spec {
    return [spec propertyForKey:@"s4eValue"];
}

- (PSSpecifier *)s4e_choice:(NSString *)name key:(NSString *)key values:(NSArray *)values titles:(NSArray *)titles fallback:(id)fallback {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name target:self set:@selector(s4e_setValue:specifier:)
                                                          get:@selector(s4e_value:) detail:NSClassFromString(@"PSListItemsController")
                                                         cell:PSLinkListCell edit:nil];
    [spec setValues:values titles:titles];
    [spec setProperty:key forKey:@"s4eKey"];
    [spec setProperty:fallback forKey:@"s4eDefault"];
    return spec;
}

- (id)s4e_value:(PSSpecifier *)spec {
    return S4EValueFor(spec);
}

- (void)s4e_setValue:(id)value specifier:(PSSpecifier *)spec {
    S4EApplySetting(spec, value);
    // A new language applies at once: every screen rebuilds its rows when it appears
    if ([[spec propertyForKey:@"s4eKey"] isEqualToString:kS4ELanguage]) {
        S4EResetLanguage();
        [self s4e_refresh];
    }
}

@end

#pragma mark - Battery Health (iOS 11.3)

typedef mach_port_t s4e_io_object_t;
typedef CFMutableDictionaryRef (*S4EIOServiceMatching_t)(const char *);
typedef s4e_io_object_t (*S4EIOServiceGetMatchingService_t)(mach_port_t, CFDictionaryRef);
typedef kern_return_t (*S4EIORegistryEntryCreateCFProperties_t)(s4e_io_object_t, CFMutableDictionaryRef *, CFAllocatorRef, uint32_t);
typedef kern_return_t (*S4EIOObjectRelease_t)(s4e_io_object_t);

static NSDictionary *S4EBatteryInfo(void) {
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!iokit)
        return nil;
    S4EIOServiceMatching_t matching = (S4EIOServiceMatching_t)dlsym(iokit, "IOServiceMatching");
    S4EIOServiceGetMatchingService_t getService = (S4EIOServiceGetMatchingService_t)dlsym(iokit, "IOServiceGetMatchingService");
    S4EIORegistryEntryCreateCFProperties_t copyProperties = (S4EIORegistryEntryCreateCFProperties_t)dlsym(iokit, "IORegistryEntryCreateCFProperties");
    S4EIOObjectRelease_t release = (S4EIOObjectRelease_t)dlsym(iokit, "IOObjectRelease");
    if (!matching || !getService || !copyProperties || !release)
        return nil;

    s4e_io_object_t service = getService(MACH_PORT_NULL, matching("IOPMPowerSource"));
    if (!service)
        return nil;
    CFMutableDictionaryRef properties = NULL;
    kern_return_t result = copyProperties(service, &properties, kCFAllocatorDefault, 0);
    release(service);
    if (result != KERN_SUCCESS || !properties)
        return nil;
    return CFBridgingRelease(properties);
}

// Design capacity, in case the power controller doesn't report it.
static double S4EDesignCapacityForModel(void) {
    char machine[32] = {0};
    size_t size = sizeof(machine) - 1;
    if (sysctlbyname("hw.machine", machine, &size, NULL, 0) != 0)
        return 0;
    NSDictionary *capacities = @{
        @"iPhone2,1": @1219, @"iPhone3,1": @1420, @"iPhone3,2": @1420, @"iPhone3,3": @1420,
        @"iPhone4,1": @1432, @"iPhone5,1": @1440, @"iPhone5,2": @1440,
    };
    return [capacities[@(machine)] doubleValue];
}

@interface S4EBatteryHealthController : S4EListController
@end

@implementation S4EBatteryHealthController

- (NSMutableArray *)s4e_buildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];
    NSDictionary *info = S4EBatteryInfo();
    double maxCapacity = S4EDouble(info, @"MaxCapacity", 0);
    double design = S4EDouble(info, @"DesignCapacity", 0);
    if (design <= 0)
        design = S4EDesignCapacityForModel();

    if (maxCapacity <= 0 || design <= 0) {
        [specs addObject:S4EGroup(nil, S4E_L(@"Unable to get battery information.", @"Не удалось получить данные об аккумуляторе."))];
        return specs;
    }

    // On older iOS MaxCapacity comes in mAh; if it comes as a percentage, take it as is.
    double health = maxCapacity <= 100 ? maxCapacity : MIN(100.0, maxCapacity / design * 100.0);

    [specs addObject:S4EGroup(nil, S4E_L(@"iPhone batteries, like all rechargeable batteries, are consumable components "
                                         @"that become less effective as they chemically age.",
                                         @"Аккумуляторы iPhone, как и все аккумуляторы, — расходный материал: "
                                         @"по мере химического старения их ёмкость снижается."))];
    NSString *capacityFooter = health >= 80
        ? S4E_L(@"This is a measure of battery capacity relative to when it was new. "
                @"Lower capacity may result in fewer hours of usage between charges.",
                @"Это ёмкость аккумулятора относительно нового. Чем она ниже, тем меньше iPhone работает от одной зарядки.")
        : S4E_L(@"Your battery's health is significantly degraded. Replace the battery to get back its original battery life.",
                @"Состояние аккумулятора значительно ухудшилось. Замените аккумулятор, чтобы вернуть прежнее время работы.");
    [specs addObject:S4EGroup(nil, capacityFooter)];
    [specs addObject:[self s4e_info:S4E_L(@"Maximum Capacity", @"Максимальная ёмкость")
                              value:[NSString stringWithFormat:@"%.0f %%", health]]];

    [specs addObject:S4EGroup(S4E_L(@"Details", @"Подробнее"), nil)];
    double cycles = S4EDouble(info, @"CycleCount", -1);
    if (cycles >= 0)
        [specs addObject:[self s4e_info:S4E_L(@"Cycle Count", @"Циклы перезарядки") value:[NSString stringWithFormat:@"%.0f", cycles]]];
    if (maxCapacity > 100)
        [specs addObject:[self s4e_info:S4E_L(@"Current Capacity", @"Ёмкость сейчас")
                                  value:[NSString stringWithFormat:S4E_L(@"%.0f mAh", @"%.0f мА·ч"), maxCapacity]]];
    [specs addObject:[self s4e_info:S4E_L(@"Design Capacity", @"Паспортная ёмкость")
                              value:[NSString stringWithFormat:S4E_L(@"%.0f mAh", @"%.0f мА·ч"), design]]];
    double temperature = S4EDouble(info, @"Temperature", 0);
    if (temperature > 0 && temperature < 10000)
        [specs addObject:[self s4e_info:S4E_L(@"Temperature", @"Температура")
                                  value:[NSString stringWithFormat:@"%.1f °C", temperature / 100.0]]];
    return specs;
}

@end

#pragma mark - Night Shift (iOS 9.3)

@interface S4ENightShiftController : S4EListController
@end

@implementation S4ENightShiftController

- (NSMutableArray *)s4e_buildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];
    NSDictionary *prefs = S4EPrefsRead() ?: @{};

    NSString *footer = S4E_L(@"Night Shift automatically shifts the colors of your display to the warmer end of the color spectrum "
                             @"after dark. This may help you get a better night's sleep.",
                             @"Night Shift автоматически смещает цвета дисплея к тёплому краю спектра после наступления темноты. "
                             @"Это может улучшить качество сна.");
    if (S4EBool(prefs, @"NightShiftUnsupported", NO))
        footer = S4E_L(@"The display's gamma table could not be read on this device, so Night Shift is turned off.",
                       @"На этом устройстве не удалось прочитать гамма-таблицу дисплея, поэтому Night Shift выключен.");
    [specs addObject:S4EGroup(nil, footer)];
    [specs addObject:[self s4e_switch:S4E_L(@"Scheduled", @"Запланировано") key:kS4ENSScheduled fallback:NO]];
    if (S4EBool(prefs, kS4ENSScheduled, NO)) {
        [specs addObject:[self s4e_time:S4E_L(@"From", @"С") key:kS4ENSFrom fallback:S4E_NS_DEFAULT_FROM]];
        [specs addObject:[self s4e_time:S4E_L(@"To", @"До") key:kS4ENSTo fallback:S4E_NS_DEFAULT_TO]];
    }

    [specs addObject:S4EGroup(nil, nil)];
    [specs addObject:[PSSpecifier preferenceSpecifierNamed:S4E_L(@"Manually Enable Until Tomorrow", @"Вручную включить до завтра") target:self
                                                       set:@selector(s4e_setManual:specifier:) get:@selector(s4e_manual:)
                                                    detail:nil cell:PSSwitchCell edit:nil]];

    [specs addObject:S4EGroup(S4E_L(@"Color Temperature", @"Цветовая температура"),
                              S4E_L(@"Less Warm to the left, More Warm to the right.", @"Менее тепло — влево, более тепло — вправо."))];
    PSSpecifier *slider = [PSSpecifier preferenceSpecifierNamed:nil target:self set:@selector(s4e_setValue:specifier:)
                                                            get:@selector(s4e_value:) detail:nil cell:PSSliderCell edit:nil];
    [slider setProperty:kS4ENSWarmth forKey:@"s4eKey"];
    [slider setProperty:@(S4E_NS_DEFAULT_WARMTH) forKey:@"s4eDefault"];
    [slider setProperty:@0.05 forKey:@"min"];
    [slider setProperty:@1 forKey:@"max"];
    [specs addObject:slider];
    return specs;
}

- (PSSpecifier *)s4e_time:(NSString *)name key:(NSString *)key fallback:(int)fallback {
    NSMutableArray *values = [NSMutableArray array];
    NSMutableArray *titles = [NSMutableArray array];
    for (int minutes = 0; minutes < 24 * 60; minutes += 30) {
        [values addObject:@(minutes)];
        [titles addObject:[NSString stringWithFormat:@"%02d:%02d", minutes / 60, minutes % 60]];
    }
    return [self s4e_choice:name key:key values:values titles:titles fallback:@(fallback)];
}

- (void)s4e_setValue:(id)value specifier:(PSSpecifier *)spec {
    [super s4e_setValue:value specifier:spec];
    if ([[spec propertyForKey:@"s4eKey"] isEqualToString:kS4ENSScheduled])
        [self s4e_refresh]; // show or hide the From and To rows
}

- (id)s4e_manual:(PSSpecifier *)spec {
    return @(S4ENSActive(S4EPrefsRead() ?: @{}, [NSDate date]));
}

- (void)s4e_setManual:(id)value specifier:(PSSpecifier *)spec {
    S4EPrefsSetValues(S4ENSManualChanges(S4EPrefsRead() ?: @{}, [value boolValue], [NSDate date]));
}

@end

#pragma mark - Items in native Settings sections (as in newer iOS)
//
// Night Shift goes to Brightness & Wallpaper, Low Power Mode and Battery Health to General → Usage,
// Bold Text to Accessibility. Sections are recognized by their contents: the internal names of
// iOS 6 sections haven't been verified on a device. If a section isn't recognized, the item stays only
// on the Skeuo4Ever screen, and the Settings Sections screen shows what is inside each section.

#define kS4ENativeSettings @"NativeSettings"
#define S4E_SECTIONS_DIR @"/Library/Skeuo4Ever/Sections"

// Text in a section plist: a plain string or { en = …; ru = …; }
static NSString *S4ESectionText(id value) {
    if ([value isKindOfClass:[NSDictionary class]])
        value = value[S4EIsRussian() ? @"ru" : @"en"] ?: value[@"en"];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}
#define S4E_PANE_LOG @"settings-panes.plist"
#define S4E_NATIVE_ID @"IOS6REVIVE_NATIVE"

typedef enum { S4EPaneNone, S4EPaneUsage, S4EPaneBrightness, S4EPaneAccessibility } S4EPane;

// Target for the injected switches: a foreign list doesn't know our s4e_value:/s4e_setValue:specifier:.
@interface S4ESettingsBridge : NSObject
@end

@implementation S4ESettingsBridge
+ (instancetype)shared {
    static S4ESettingsBridge *bridge;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bridge = [[S4ESettingsBridge alloc] init];
    });
    return bridge;
}

- (id)s4e_value:(PSSpecifier *)spec {
    return S4EValueFor(spec);
}

- (void)s4e_setValue:(id)value specifier:(PSSpecifier *)spec {
    S4EApplySetting(spec, value);
}
@end

static PSSpecifier *S4ESpecifierWithKey(NSArray *specs, NSString *key) {
    for (PSSpecifier *spec in specs)
        if ([[spec propertyForKey:@"key"] isEqual:key])
            return spec;
    return nil;
}

static S4EPane S4EPaneOf(PSListController *controller, NSArray *specs) {
    NSString *name = NSStringFromClass([controller class]);
    if (S4ESpecifierWithKey(specs, @"SBShowBatteryPercentage"))
        return S4EPaneUsage;
    if (S4ESpecifierWithKey(specs, @"BKEnableALS") || [name rangeOfString:@"Brightness"].location != NSNotFound)
        return S4EPaneBrightness;
    if ([name isEqualToString:@"AccessibilitySettingsController"])
        return S4EPaneAccessibility;
    return S4EPaneNone;
}

// End of a section's first group: the index of the second group header.
static NSUInteger S4EEndOfFirstGroup(NSArray *specs) {
    NSUInteger start = (specs.count && [specs[0] cellType] == PSGroupCell) ? 1 : 0;
    for (NSUInteger i = start; i < specs.count; i++)
        if ([specs[i] cellType] == PSGroupCell)
            return i;
    return specs.count;
}

// A whole new array through setSpecifiers:, so the table reloads completely. Inserting row by row
// before the table's first load can crash Settings on the row count check.
static void S4EInsertSpecifiers(PSListController *controller, NSArray *added, NSUInteger index) {
    NSMutableArray *specs = [S4ESpecifiers(controller) mutableCopy];
    index = MIN(index, specs.count);
    [specs insertObjects:added atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(index, added.count)]];
    [controller setSpecifiers:specs];
}

static void S4EInjectNative(PSListController *controller) {
    NSArray *specs = S4ESpecifiers(controller);
    if (!specs.count || [controller specifierForID:S4E_NATIVE_ID] || !S4EBool(S4EPrefsRead(), kS4ENativeSettings, YES))
        return;
    S4ESettingsBridge *bridge = [S4ESettingsBridge shared];
    switch (S4EPaneOf(controller, specs)) {
    case S4EPaneUsage: {
        // Right under Battery Percentage, like the Battery section in iOS 9
        if (!S4EFeatureInstalled(@"S4EBattery"))
            return;
        PSSpecifier *lowPower = S4EMakeSwitch(bridge, controller, S4E_L(@"Low Power Mode", @"Энергосбережение"), kS4ELowPower, NO);
        lowPower.identifier = S4E_NATIVE_ID;
        PSSpecifier *health = S4EMakeLink(bridge, S4E_L(@"Battery Health", @"Состояние аккумулятора"), [S4EBatteryHealthController class]);
        NSUInteger anchor = [specs indexOfObject:S4ESpecifierWithKey(specs, @"SBShowBatteryPercentage")];
        S4EInsertSpecifiers(controller, @[lowPower, health], anchor + 1);
        break;
    }
    case S4EPaneBrightness: {
        // As a separate group under brightness, like in iOS 10
        if (!S4EFeatureInstalled(@"S4ENightShift"))
            return;
        PSSpecifier *group = S4EGroup(nil, nil);
        group.identifier = S4E_NATIVE_ID;
        PSSpecifier *nightShift = S4EMakeLink(bridge, @"Night Shift", [S4ENightShiftController class]);
        S4EInsertSpecifiers(controller, @[group, nightShift], S4EEndOfFirstGroup(specs));
        break;
    }
    case S4EPaneAccessibility: {
        // At the end of the first group, Vision
        if (!S4EFeatureInstalled(@"S4EBoldText"))
            return;
        PSSpecifier *bold = S4EMakeSwitch(bridge, controller, S4E_L(@"Bold Text", @"Жирный шрифт"), kS4EBoldText, NO);
        bold.identifier = S4E_NATIVE_ID;
        S4EInsertSpecifiers(controller, @[bold], S4EEndOfFirstGroup(specs));
        break;
    }
    case S4EPaneNone:
        break;
    }
}

// Log of the recently opened sections: class, title and rows (name, ID, settings key).
static void S4ELogPane(PSListController *controller) {
    NSString *name = NSStringFromClass([controller class]);
    if ([name hasPrefix:@"S4E"])
        return;
    NSMutableArray *rows = [NSMutableArray array];
    for (PSSpecifier *spec in S4ESpecifiers(controller)) {
        if (rows.count >= 40)
            break;
        [rows addObject:@{
            @"name": spec.name ?: @"",
            @"id": spec.identifier ?: @"",
            @"key": [spec propertyForKey:@"key"] ?: @"",
            @"group": @(spec.cellType == PSGroupCell),
        }];
    }
    NSString *title = controller.title ?: [controller specifier].name ?: @"";
    NSString *path = S4EDataPath(S4E_PANE_LOG);
    NSMutableArray *log = [NSMutableArray arrayWithContentsOfFile:path] ?: [NSMutableArray array];
    for (NSDictionary *entry in [log copy])
        if ([entry[@"class"] isEqual:name])
            [log removeObject:entry];
    [log insertObject:@{@"class": name, @"title": title, @"rows": rows} atIndex:0];
    while (log.count > 12)
        [log removeLastObject];
    [log writeToFile:path atomically:YES];
}

static void (*orig_PSListController_viewWillAppear)(PSListController *, SEL, BOOL);
static void hook_PSListController_viewWillAppear(PSListController *self, SEL _cmd, BOOL animated) {
    orig_PSListController_viewWillAppear(self, _cmd, animated);
    S4EInjectNative(self);
    S4ELogPane(self);
}

@interface S4EPaneLogController : S4EListController
@end

@implementation S4EPaneLogController

- (NSMutableArray *)s4e_buildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];
    NSArray *log = [NSArray arrayWithContentsOfFile:S4EDataPath(S4E_PANE_LOG)];
    [specs addObject:S4EGroup(nil, log.count
        ? S4E_L(@"Recently opened Settings sections and how they are built inside. If a Skeuo4Ever item didn't show up "
                @"in the right section, open that section, come back here and send a screenshot.",
                @"Последние открытые разделы Настроек и их внутреннее устройство. Если пункт Skeuo4Ever не появился "
                @"в нужном разделе, открой этот раздел, вернись сюда и пришли скриншот.")
        : S4E_L(@"Nothing here yet: open the Settings sections you need and come back here.",
                @"Пока пусто: открой нужные разделы Настроек и вернись сюда."))];
    for (NSDictionary *entry in log) {
        [specs addObject:S4EGroup([NSString stringWithFormat:@"%@ · %@", entry[@"title"], entry[@"class"]], nil)];
        for (NSDictionary *row in entry[@"rows"]) {
            NSString *label = [row[@"group"] boolValue] ? [@"▸ " stringByAppendingString:row[@"name"]] : row[@"name"];
            NSString *detail = [row[@"key"] length] ? row[@"key"] : row[@"id"];
            [specs addObject:[self s4e_info:label value:detail]];
        }
    }
    return specs;
}

@end

#pragma mark - Main screen

@interface S4ERootListController : S4EListController
@end

@implementation S4ERootListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Skeuo4Ever";
}

- (NSMutableArray *)s4e_buildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];

    if (S4EFeatureInstalled(@"S4ESwipeBack")) {
        [specs addObject:S4EGroup(nil, S4E_L(@"Swipe from the left edge of the screen to go back to the previous screen.",
                                             @"Проведите пальцем от левого края экрана, чтобы вернуться на предыдущий экран."))];
        [specs addObject:[self s4e_switch:S4E_L(@"Swipe Back", @"Смахивание назад") key:kS4ESwipeBack fallback:YES]];
    }

    if (S4EFeatureInstalled(@"S4EControlCenter")) {
        [specs addObject:S4EGroup(nil, S4E_L(@"Swipe up from the bottom edge of the screen to open Control Center. "
                                             @"You can change the gesture in Activator: the “Control Center” action in the Skeuo4Ever section.",
                                             @"Проведите вверх от нижнего края экрана, чтобы открыть Пункт управления. "
                                             @"Жест можно сменить в Activator: действие «Пункт управления» в разделе Skeuo4Ever."))];
        [specs addObject:[self s4e_switch:S4E_L(@"Control Center", @"Пункт управления") key:@"ControlCenter" fallback:YES]];
    }

    if (S4EFeatureInstalled(@"S4EBattery")) {
        [specs addObject:S4EGroup(nil, S4E_L(@"Low Power Mode temporarily reduces power consumption until iPhone is charged: "
                                             @"the screen gets dimmer and Auto-Lock is set to one minute. "
                                             @"It turns off automatically when the battery charges to 80%.",
                                             @"Режим энергосбережения временно снижает расход энергии, пока iPhone не будет заряжен: "
                                             @"экран становится темнее, а автоблокировка срабатывает через минуту. "
                                             @"При зарядке до 80 % режим выключится сам."))];
        [specs addObject:[self s4e_switch:S4E_L(@"Low Power Mode", @"Энергосбережение") key:kS4ELowPower fallback:NO]];
        [specs addObject:S4EGroup(nil, nil)];
        [specs addObject:[self s4e_link:S4E_L(@"Battery Health", @"Состояние аккумулятора") detail:[S4EBatteryHealthController class]]];
    }

    if (S4EFeatureInstalled(@"S4ENightShift")) {
        [specs addObject:S4EGroup(nil, nil)];
        [specs addObject:[self s4e_link:@"Night Shift" detail:[S4ENightShiftController class]]];
    }

    if (S4EFeatureInstalled(@"S4EBoldText")) {
        [specs addObject:S4EGroup(nil, S4E_L(@"Changing this setting restarts SpringBoard and all apps.",
                                             @"После изменения SpringBoard и все программы перезапустятся."))];
        PSSpecifier *bold = [self s4e_switch:S4E_L(@"Bold Text", @"Жирный шрифт") key:kS4EBoldText fallback:NO];
        bold.identifier = @"BOLD_TEXT";
        [specs addObject:bold];
    }

    if (S4EFeatureInstalled(@"S4ENewSash")) {
        [specs addObject:S4EGroup(nil, S4E_L(@"The “New” sash on the icon of a newly installed app — not only from the App Store, "
                                             @"but also from an ipa or Cydia. It disappears after the first launch.",
                                             @"Лента «Новое» на иконке только что установленной программы — не только из App Store, "
                                             @"но и из ipa или Cydia. Исчезает после первого запуска."))];
        [specs addObject:[self s4e_switch:S4E_L(@"New App Sash", @"Лента «Новое»") key:kS4ENewSash fallback:YES]];
    }

    if (S4EFeatureInstalled(@"S4EDesktopSite"))
        [specs addObject:S4EGroup(@"Safari", S4E_L(@"To open the desktop version of a website, tap Share in Safari "
                                                   @"and choose “Request Desktop Site”.",
                                                   @"Чтобы открыть полную версию сайта, нажмите в Safari «Поделиться» "
                                                   @"и выберите «Полная версия»."))];

    // Sections that packages bring themselves: /Library/Skeuo4Ever/Sections/*.plist
    // { order, title?, footer?, cells = ({ title, key, default }) }, so the core needs no update for a new feature
    NSMutableArray *sections = [NSMutableArray array];
    for (NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:S4E_SECTIONS_DIR error:NULL]) {
        NSDictionary *section = [file.pathExtension isEqualToString:@"plist"]
            ? [NSDictionary dictionaryWithContentsOfFile:[S4E_SECTIONS_DIR stringByAppendingPathComponent:file]] : nil;
        if ([section isKindOfClass:[NSDictionary class]])
            [sections addObject:section];
    }
    [sections sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [@([a[@"order"] intValue]) compare:@([b[@"order"] intValue])];
    }];
    for (NSDictionary *section in sections) {
        [specs addObject:S4EGroup(S4ESectionText(section[@"title"]), S4ESectionText(section[@"footer"]))];
        for (NSDictionary *cell in section[@"cells"])
            if (S4ESectionText(cell[@"title"]) && [cell[@"key"] isKindOfClass:[NSString class]])
                [specs addObject:[self s4e_switch:S4ESectionText(cell[@"title"]) key:cell[@"key"] fallback:[cell[@"default"] boolValue]]];
    }

    [specs addObject:S4EGroup(nil, S4E_L(@"Items also appear where they live in newer iOS: Night Shift in Brightness & Wallpaper, "
                                         @"Low Power Mode in General → Usage, Bold Text in Accessibility.",
                                         @"Пункты появятся и там, где они в новых iOS: Night Shift — в «Яркость и обои», "
                                         @"энергосбережение — в «Основные → Статистика», жирный шрифт — в «Универсальный доступ»."))];
    [specs addObject:[self s4e_switch:S4E_L(@"Show in Settings Sections", @"Пункты в разделах Настроек") key:kS4ENativeSettings fallback:YES]];
    [specs addObject:[self s4e_link:S4E_L(@"Settings Sections", @"Разделы Настроек") detail:[S4EPaneLogController class]]];

    [specs addObject:S4EGroup(nil, nil)];
    [specs addObject:[self s4e_choice:S4E_L(@"Language", @"Язык") key:kS4ELanguage values:@[@"auto", @"en", @"ru"]
                              titles:@[S4E_L(@"Automatic", @"Автоматически"), @"English", @"Русский"] fallback:@"auto"]];

    [specs addObject:S4EGroup(nil, S4E_L(@"Skeuo4Ever brings features of modern iOS to iOS 6 — built from glass, linen, leather "
                                         @"and glossy buttons, as if iOS 7 had never gone flat. Skeuomorphism forever.",
                                         @"Skeuo4Ever переносит функции новых iOS на iOS 6 — из стекла, льна, кожи и глянцевых "
                                         @"кнопок, как будто iOS 7 так и не стала плоской. Скевоморфизм навсегда."))];
    return specs;
}

@end

#pragma mark - Entry at the root of Settings

static UIImage *S4ESettingsIcon(void) {
    const CGFloat size = 29;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();

    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size, size) cornerRadius:5.5] addClip];

    // Sky-blue background
    CGFloat sky[] = {0.45, 0.78, 0.99, 1, 0.10, 0.44, 0.84, 1};
    CGGradientRef skyGradient = CGGradientCreateWithColorComponents(space, sky, NULL, 2);
    CGContextDrawLinearGradient(ctx, skyGradient, CGPointZero, CGPointMake(0, size), 0);
    CGGradientRelease(skyGradient);

    // A white infinity sign — skeuomorphism forever — with a soft shadow, like iOS 6 icon glyphs
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, 1), 1.5, [UIColor colorWithWhite:0 alpha:0.35].CGColor);
    CGContextBeginTransparencyLayer(ctx, NULL);
    [[UIColor whiteColor] set];
    // Lemniscate of Bernoulli: x = a·cos t / (1 + sin² t), y = a·sin t·cos t / (1 + sin² t)
    const CGPoint center = CGPointMake(size / 2, size / 2);
    const CGFloat a = 10.5;
    UIBezierPath *infinity = [UIBezierPath bezierPath];
    for (int i = 0; i <= 96; i++) {
        CGFloat t = 2 * M_PI * i / 96, sine = sinf(t), cosine = cosf(t), d = 1 + sine * sine;
        CGPoint point = CGPointMake(center.x + a * cosine / d, center.y + a * 1.15f * sine * cosine / d);
        if (i == 0)
            [infinity moveToPoint:point];
        else
            [infinity addLineToPoint:point];
    }
    infinity.lineWidth = 2.6;
    infinity.lineJoinStyle = kCGLineJoinRound;
    [infinity stroke];
    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);

    // Gloss on top
    CGContextSaveGState(ctx);
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(-size * 0.5, -size * 0.75, size * 2, size * 1.25)] addClip];
    CGFloat gloss[] = {1, 1, 1, 0.45, 1, 1, 1, 0.08};
    CGGradientRef glossGradient = CGGradientCreateWithColorComponents(space, gloss, NULL, 2);
    CGContextDrawLinearGradient(ctx, glossGradient, CGPointZero, CGPointMake(0, size * 0.5), 0);
    CGGradientRelease(glossGradient);
    CGContextRestoreGState(ctx);

    CGColorSpaceRelease(space);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static void S4EInsertSettingsEntry(PSListController *root) {
    NSArray *current = S4ESpecifiers(root);
    if (!current)
        return;
    NSMutableArray *specs = [current isKindOfClass:[NSMutableArray class]] ? (NSMutableArray *)current : [current mutableCopy];

    PSSpecifier *entry = [PSSpecifier preferenceSpecifierNamed:@"Skeuo4Ever" target:root set:NULL get:NULL
                                                        detail:[S4ERootListController class] cell:PSLinkCell edit:nil];
    entry.identifier = @"IOS6REVIVE";
    [entry setProperty:S4ESettingsIcon() forKey:@"iconImage"];

    // At the end of the General, Sounds, Brightness & Wallpaper, Privacy group, like PreferenceLoader.
    int group = 0, row = 0;
    NSUInteger index;
    if ([root respondsToSelector:@selector(getGroup:row:ofSpecifierID:)] && [root getGroup:&group row:&row ofSpecifierID:@"General"]) {
        index = (NSUInteger)[root indexOfGroup:group] + [[root specifiersInGroup:group] count];
    } else {
        [specs addObject:[PSSpecifier emptyGroupSpecifier]];
        index = specs.count;
    }
    [specs insertObject:entry atIndex:MIN(index, specs.count)];

    if (specs != current)
        S4ESetSpecifiersStorage(root, specs);
}

static id (*orig_PrefsListController_specifiers)(PSListController *, SEL);

static id hook_PrefsListController_specifiers(PSListController *self, SEL _cmd) {
    BOOL firstLoad = S4ESpecifiers(self) == nil;
    id result = orig_PrefsListController_specifiers(self, _cmd);
    if (firstLoad)
        S4EInsertSettingsEntry(self);
    return S4ESpecifiers(self) ?: result;
}

__attribute__((constructor)) static void S4ESettingsInit(void) {
    @autoreleasepool {
        S4E_HOOK(objc_getClass("PrefsListController"), @selector(specifiers),
                hook_PrefsListController_specifiers, &orig_PrefsListController_specifiers);
        S4E_HOOK(objc_getClass("PSListController"), @selector(viewWillAppear:),
                hook_PSListController_viewWillAppear, &orig_PSListController_viewWillAppear);
    }
}
