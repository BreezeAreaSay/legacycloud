// Экран «iOS6Revive» в Настройках: пункт в корне, переключатели всех функций, Night Shift
// и состояние аккумулятора.
// Собран из родных ячеек Preferences.framework iOS 6, поэтому выглядит как системный.

#import "IRShared.h"
#import "IRPrivate.h"
#import "IRNightShift.h"
#include <dlfcn.h>
#include <mach/mach.h>
#include <sys/sysctl.h>

#pragma mark - Хранилище спецификаторов

static void **IRSpecifiersSlot(PSListController *controller) {
    Ivar ivar = class_getInstanceVariable(objc_getClass("PSListController"), "_specifiers");
    if (!ivar)
        return NULL;
    return (void **)((uint8_t *)(__bridge void *)controller + ivar_getOffset(ivar));
}

static NSArray *IRSpecifiers(PSListController *controller) {
    void **slot = IRSpecifiersSlot(controller);
    return slot ? (__bridge NSArray *)*slot : nil;
}

// Пишем ivar напрямую, как это делают бандлы настроек: Preferences.framework сам освободит его в dealloc.
static void IRSetSpecifiersStorage(PSListController *controller, NSArray *specifiers) {
    void **slot = IRSpecifiersSlot(controller);
    if (!slot) {
        [controller setSpecifiers:specifiers];
        return;
    }
    void *old = *slot;
    *slot = specifiers ? (void *)CFBridgingRetain(specifiers) : NULL;
    if (old)
        CFRelease(old);
}

static BOOL IRFeatureInstalled(NSString *dylib) {
    NSString *path = [IR_DYLIB_DIR stringByAppendingPathComponent:[dylib stringByAppendingPathExtension:@"dylib"]];
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

static PSSpecifier *IRGroup(NSString *title, NSString *footer) {
    PSSpecifier *group = title ? [PSSpecifier groupSpecifierWithName:title] : [PSSpecifier emptyGroupSpecifier];
    if (footer)
        [group setProperty:footer forKey:@"footerText"];
    return group;
}

#pragma mark - Подтверждение (UIAlertView держит делегата слабо)

@interface IRAlertDelegate : NSObject <UIAlertViewDelegate>
@property(nonatomic, copy) void (^handler)(BOOL confirmed);
@end

static NSMutableSet *gActiveAlerts;

@implementation IRAlertDelegate
+ (void)showTitle:(NSString *)title message:(NSString *)message confirm:(NSString *)confirm handler:(void (^)(BOOL))handler {
    IRAlertDelegate *delegate = [[IRAlertDelegate alloc] init];
    delegate.handler = handler;
    if (!gActiveAlerts)
        gActiveAlerts = [NSMutableSet set];
    [gActiveAlerts addObject:delegate];
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title message:message delegate:delegate
                                          cancelButtonTitle:@"Отменить" otherButtonTitles:confirm, nil];
    [alert show];
}

- (void)alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex {
    if (self.handler)
        self.handler(buttonIndex != alertView.cancelButtonIndex);
    [gActiveAlerts removeObject:self];
}
@end

#pragma mark - Значения переключателей

// «Жирный шрифт» требует перезапуска SpringBoard, поэтому спрашиваем подтверждение — как iOS 7.
// irOwner — список, в котором стоит переключатель: при отмене возвращаем его на место.
static void IRApplySetting(PSSpecifier *spec, id value) {
    NSString *key = [spec propertyForKey:@"irKey"];
    if (![key isEqualToString:kIRBoldText]) {
        IRPrefsSet(key, value);
        return;
    }
    PSListController *owner = [[spec propertyForKey:@"irOwner"] nonretainedObjectValue];
    // Сильная ссылка намеренно: блок живёт только до закрытия алерта, а __weak-переменная
    // на armv7 требует таблиц исключений SjLj, которых нет в заглушках SDK.
    [IRAlertDelegate showTitle:nil
                       message:@"Чтобы применить этот параметр, SpringBoard и все программы будут перезапущены."
                       confirm:@"Продолжить"
                       handler:^(BOOL confirmed) {
                           if (!confirmed) {
                               [owner reloadSpecifier:spec];
                               return;
                           }
                           IRPrefsSet(kIRBoldText, value);
                           notify_post(IR_NOTIFY_RESPRING);
                       }];
}

static PSSpecifier *IRMakeSwitch(id target, PSListController *owner, NSString *name, NSString *key, BOOL fallback) {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name target:target set:@selector(ir_setValue:specifier:)
                                                          get:@selector(ir_value:) detail:nil cell:PSSwitchCell edit:nil];
    [spec setProperty:key forKey:@"irKey"];
    [spec setProperty:@(fallback) forKey:@"irDefault"];
    [spec setProperty:[NSValue valueWithNonretainedObject:owner] forKey:@"irOwner"];
    return spec;
}

static PSSpecifier *IRMakeLink(id target, NSString *name, Class detail) {
    return [PSSpecifier preferenceSpecifierNamed:name target:target set:NULL get:NULL detail:detail cell:PSLinkCell edit:nil];
}

static id IRValueFor(PSSpecifier *spec) {
    id value = IRPrefsRead()[[spec propertyForKey:@"irKey"]];
    return value ?: [spec propertyForKey:@"irDefault"];
}

#pragma mark - Базовый список

@interface IRListController : PSListController
- (NSMutableArray *)ir_buildSpecifiers;
@end

@implementation IRListController

- (NSArray *)specifiers {
    if (!IRSpecifiers(self))
        IRSetSpecifiersStorage(self, [self ir_buildSpecifiers]);
    return IRSpecifiers(self);
}

- (NSMutableArray *)ir_buildSpecifiers {
    return [NSMutableArray array];
}

- (void)ir_refresh {
    [self setSpecifiers:[self ir_buildSpecifiers]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self ir_refresh];
}

- (PSSpecifier *)ir_switch:(NSString *)name key:(NSString *)key fallback:(BOOL)fallback {
    return IRMakeSwitch(self, self, name, key, fallback);
}

- (PSSpecifier *)ir_link:(NSString *)name detail:(Class)detail {
    return IRMakeLink(self, name, detail);
}

- (PSSpecifier *)ir_info:(NSString *)name value:(NSString *)value {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name target:self set:NULL get:@selector(ir_infoValue:)
                                                       detail:nil cell:PSTitleValueCell edit:nil];
    [spec setProperty:value forKey:@"irValue"];
    return spec;
}

- (id)ir_infoValue:(PSSpecifier *)spec {
    return [spec propertyForKey:@"irValue"];
}

- (id)ir_value:(PSSpecifier *)spec {
    return IRValueFor(spec);
}

- (void)ir_setValue:(id)value specifier:(PSSpecifier *)spec {
    IRApplySetting(spec, value);
}

@end

#pragma mark - Состояние аккумулятора (iOS 11.3)

typedef mach_port_t ir_io_object_t;
typedef CFMutableDictionaryRef (*IRIOServiceMatching_t)(const char *);
typedef ir_io_object_t (*IRIOServiceGetMatchingService_t)(mach_port_t, CFDictionaryRef);
typedef kern_return_t (*IRIORegistryEntryCreateCFProperties_t)(ir_io_object_t, CFMutableDictionaryRef *, CFAllocatorRef, uint32_t);
typedef kern_return_t (*IRIOObjectRelease_t)(ir_io_object_t);

static NSDictionary *IRBatteryInfo(void) {
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!iokit)
        return nil;
    IRIOServiceMatching_t matching = (IRIOServiceMatching_t)dlsym(iokit, "IOServiceMatching");
    IRIOServiceGetMatchingService_t getService = (IRIOServiceGetMatchingService_t)dlsym(iokit, "IOServiceGetMatchingService");
    IRIORegistryEntryCreateCFProperties_t copyProperties = (IRIORegistryEntryCreateCFProperties_t)dlsym(iokit, "IORegistryEntryCreateCFProperties");
    IRIOObjectRelease_t release = (IRIOObjectRelease_t)dlsym(iokit, "IOObjectRelease");
    if (!matching || !getService || !copyProperties || !release)
        return nil;

    ir_io_object_t service = getService(MACH_PORT_NULL, matching("IOPMPowerSource"));
    if (!service)
        return nil;
    CFMutableDictionaryRef properties = NULL;
    kern_return_t result = copyProperties(service, &properties, kCFAllocatorDefault, 0);
    release(service);
    if (result != KERN_SUCCESS || !properties)
        return nil;
    return CFBridgingRelease(properties);
}

// Паспортная ёмкость — на случай, если контроллер питания её не отдаёт.
static double IRDesignCapacityForModel(void) {
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

@interface IRBatteryHealthController : IRListController
@end

@implementation IRBatteryHealthController

- (NSMutableArray *)ir_buildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];
    NSDictionary *info = IRBatteryInfo();
    double maxCapacity = IRDouble(info, @"MaxCapacity", 0);
    double design = IRDouble(info, @"DesignCapacity", 0);
    if (design <= 0)
        design = IRDesignCapacityForModel();

    if (maxCapacity <= 0 || design <= 0) {
        [specs addObject:IRGroup(nil, @"Не удалось получить данные об аккумуляторе.")];
        return specs;
    }

    // На старых iOS MaxCapacity отдаётся в мА·ч; если пришли проценты — берём как есть.
    double health = maxCapacity <= 100 ? maxCapacity : MIN(100.0, maxCapacity / design * 100.0);

    [specs addObject:IRGroup(nil, @"Аккумуляторы iPhone, как и все аккумуляторы, — расходный материал: "
                                   @"по мере химического старения их ёмкость снижается.")];
    NSString *capacityFooter = health >= 80
        ? @"Это ёмкость аккумулятора относительно нового. Чем она ниже, тем меньше iPhone работает от одной зарядки."
        : @"Состояние аккумулятора значительно ухудшилось. Замените аккумулятор, чтобы вернуть прежнее время работы.";
    [specs addObject:IRGroup(nil, capacityFooter)];
    [specs addObject:[self ir_info:@"Максимальная ёмкость" value:[NSString stringWithFormat:@"%.0f %%", health]]];

    [specs addObject:IRGroup(@"Подробнее", nil)];
    double cycles = IRDouble(info, @"CycleCount", -1);
    if (cycles >= 0)
        [specs addObject:[self ir_info:@"Циклы перезарядки" value:[NSString stringWithFormat:@"%.0f", cycles]]];
    if (maxCapacity > 100)
        [specs addObject:[self ir_info:@"Ёмкость сейчас" value:[NSString stringWithFormat:@"%.0f мА·ч", maxCapacity]]];
    [specs addObject:[self ir_info:@"Паспортная ёмкость" value:[NSString stringWithFormat:@"%.0f мА·ч", design]]];
    double temperature = IRDouble(info, @"Temperature", 0);
    if (temperature > 0 && temperature < 10000)
        [specs addObject:[self ir_info:@"Температура" value:[NSString stringWithFormat:@"%.1f °C", temperature / 100.0]]];
    return specs;
}

@end

#pragma mark - Night Shift (iOS 9.3)

@interface IRNightShiftController : IRListController
@end

@implementation IRNightShiftController

- (NSMutableArray *)ir_buildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];
    NSDictionary *prefs = IRPrefsRead() ?: @{};

    NSString *footer = @"Night Shift автоматически смещает цвета дисплея к тёплому краю спектра после наступления темноты. "
                       @"Это может улучшить качество сна.";
    if (IRBool(prefs, @"NightShiftUnsupported", NO))
        footer = @"На этом устройстве не удалось прочитать гамма-таблицу дисплея, поэтому Night Shift выключен.";
    [specs addObject:IRGroup(nil, footer)];
    [specs addObject:[self ir_switch:@"Запланировано" key:kIRNSScheduled fallback:NO]];
    if (IRBool(prefs, kIRNSScheduled, NO)) {
        [specs addObject:[self ir_time:@"С" key:kIRNSFrom fallback:IR_NS_DEFAULT_FROM]];
        [specs addObject:[self ir_time:@"До" key:kIRNSTo fallback:IR_NS_DEFAULT_TO]];
    }

    [specs addObject:IRGroup(nil, nil)];
    [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"Вручную включить до завтра" target:self
                                                       set:@selector(ir_setManual:specifier:) get:@selector(ir_manual:)
                                                    detail:nil cell:PSSwitchCell edit:nil]];

    [specs addObject:IRGroup(@"Цветовая температура", @"Менее тепло — влево, более тепло — вправо.")];
    PSSpecifier *slider = [PSSpecifier preferenceSpecifierNamed:nil target:self set:@selector(ir_setValue:specifier:)
                                                            get:@selector(ir_value:) detail:nil cell:PSSliderCell edit:nil];
    [slider setProperty:kIRNSWarmth forKey:@"irKey"];
    [slider setProperty:@(IR_NS_DEFAULT_WARMTH) forKey:@"irDefault"];
    [slider setProperty:@0.05 forKey:@"min"];
    [slider setProperty:@1 forKey:@"max"];
    [specs addObject:slider];
    return specs;
}

- (PSSpecifier *)ir_time:(NSString *)name key:(NSString *)key fallback:(int)fallback {
    NSMutableArray *values = [NSMutableArray array];
    NSMutableArray *titles = [NSMutableArray array];
    for (int minutes = 0; minutes < 24 * 60; minutes += 30) {
        [values addObject:@(minutes)];
        [titles addObject:[NSString stringWithFormat:@"%02d:%02d", minutes / 60, minutes % 60]];
    }
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name target:self set:@selector(ir_setValue:specifier:)
                                                          get:@selector(ir_value:) detail:NSClassFromString(@"PSListItemsController")
                                                         cell:PSLinkListCell edit:nil];
    [spec setValues:values titles:titles];
    [spec setProperty:key forKey:@"irKey"];
    [spec setProperty:@(fallback) forKey:@"irDefault"];
    return spec;
}

- (void)ir_setValue:(id)value specifier:(PSSpecifier *)spec {
    [super ir_setValue:value specifier:spec];
    if ([[spec propertyForKey:@"irKey"] isEqualToString:kIRNSScheduled])
        [self ir_refresh]; // показать или спрятать строки «С» и «До»
}

- (id)ir_manual:(PSSpecifier *)spec {
    return @(IRNSActive(IRPrefsRead() ?: @{}, [NSDate date]));
}

- (void)ir_setManual:(id)value specifier:(PSSpecifier *)spec {
    IRPrefsSetValues(IRNSManualChanges(IRPrefsRead() ?: @{}, [value boolValue], [NSDate date]));
}

@end

#pragma mark - Пункты в родных разделах Настроек (как в новых iOS)
//
// Night Shift — в «Яркость и обои», энергосбережение и состояние аккумулятора — в «Основные → Статистика»,
// жирный шрифт — в «Универсальный доступ». Разделы узнаём по их содержимому: внутренние имена
// разделов iOS 6 на устройстве не проверены. Если раздел не узнан, пункт остаётся только
// на экране iOS6Revive, а экран «Разделы Настроек» показывает, что внутри у каждого раздела.

#define kIRNativeSettings @"NativeSettings"
#define IR_SECTIONS_DIR @"/Library/iOS6Revive/Sections"
#define IR_PANE_LOG @"settings-panes.plist"
#define IR_NATIVE_ID @"IOS6REVIVE_NATIVE"

typedef enum { IRPaneNone, IRPaneUsage, IRPaneBrightness, IRPaneAccessibility } IRPane;

// Цель для встроенных переключателей: чужой список не знает наших ir_value:/ir_setValue:specifier:.
@interface IRSettingsBridge : NSObject
@end

@implementation IRSettingsBridge
+ (instancetype)shared {
    static IRSettingsBridge *bridge;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bridge = [[IRSettingsBridge alloc] init];
    });
    return bridge;
}

- (id)ir_value:(PSSpecifier *)spec {
    return IRValueFor(spec);
}

- (void)ir_setValue:(id)value specifier:(PSSpecifier *)spec {
    IRApplySetting(spec, value);
}
@end

static PSSpecifier *IRSpecifierWithKey(NSArray *specs, NSString *key) {
    for (PSSpecifier *spec in specs)
        if ([[spec propertyForKey:@"key"] isEqual:key])
            return spec;
    return nil;
}

static IRPane IRPaneOf(PSListController *controller, NSArray *specs) {
    NSString *name = NSStringFromClass([controller class]);
    if (IRSpecifierWithKey(specs, @"SBShowBatteryPercentage"))
        return IRPaneUsage;
    if (IRSpecifierWithKey(specs, @"BKEnableALS") || [name rangeOfString:@"Brightness"].location != NSNotFound)
        return IRPaneBrightness;
    if ([name isEqualToString:@"AccessibilitySettingsController"])
        return IRPaneAccessibility;
    return IRPaneNone;
}

// Конец первой группы раздела: индекс второго заголовка группы.
static NSUInteger IREndOfFirstGroup(NSArray *specs) {
    NSUInteger start = (specs.count && [specs[0] cellType] == PSGroupCell) ? 1 : 0;
    for (NSUInteger i = start; i < specs.count; i++)
        if ([specs[i] cellType] == PSGroupCell)
            return i;
    return specs.count;
}

// Новый массив целиком через setSpecifiers: — таблица перезагружается полностью. Построчная вставка
// до первой загрузки таблицы может уронить Настройки на проверке числа строк.
static void IRInsertSpecifiers(PSListController *controller, NSArray *added, NSUInteger index) {
    NSMutableArray *specs = [IRSpecifiers(controller) mutableCopy];
    index = MIN(index, specs.count);
    [specs insertObjects:added atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(index, added.count)]];
    [controller setSpecifiers:specs];
}

static void IRInjectNative(PSListController *controller) {
    NSArray *specs = IRSpecifiers(controller);
    if (!specs.count || [controller specifierForID:IR_NATIVE_ID] || !IRBool(IRPrefsRead(), kIRNativeSettings, YES))
        return;
    IRSettingsBridge *bridge = [IRSettingsBridge shared];
    switch (IRPaneOf(controller, specs)) {
    case IRPaneUsage: {
        // Сразу под «Заряд в процентах», как раздел «Аккумулятор» в iOS 9
        if (!IRFeatureInstalled(@"IRBattery"))
            return;
        PSSpecifier *lowPower = IRMakeSwitch(bridge, controller, @"Энергосбережение", kIRLowPower, NO);
        lowPower.identifier = IR_NATIVE_ID;
        PSSpecifier *health = IRMakeLink(bridge, @"Состояние аккумулятора", [IRBatteryHealthController class]);
        NSUInteger anchor = [specs indexOfObject:IRSpecifierWithKey(specs, @"SBShowBatteryPercentage")];
        IRInsertSpecifiers(controller, @[lowPower, health], anchor + 1);
        break;
    }
    case IRPaneBrightness: {
        // Отдельной группой под яркостью, как в iOS 10
        if (!IRFeatureInstalled(@"IRNightShift"))
            return;
        PSSpecifier *group = IRGroup(nil, nil);
        group.identifier = IR_NATIVE_ID;
        PSSpecifier *nightShift = IRMakeLink(bridge, @"Night Shift", [IRNightShiftController class]);
        IRInsertSpecifiers(controller, @[group, nightShift], IREndOfFirstGroup(specs));
        break;
    }
    case IRPaneAccessibility: {
        // В конец первой группы — «Зрение»
        if (!IRFeatureInstalled(@"IRBoldText"))
            return;
        PSSpecifier *bold = IRMakeSwitch(bridge, controller, @"Жирный шрифт", kIRBoldText, NO);
        bold.identifier = IR_NATIVE_ID;
        IRInsertSpecifiers(controller, @[bold], IREndOfFirstGroup(specs));
        break;
    }
    case IRPaneNone:
        break;
    }
}

// Журнал последних открытых разделов: класс, заголовок и строки (имя, ID, ключ настройки).
static void IRLogPane(PSListController *controller) {
    NSString *name = NSStringFromClass([controller class]);
    if ([name hasPrefix:@"IR"])
        return;
    NSMutableArray *rows = [NSMutableArray array];
    for (PSSpecifier *spec in IRSpecifiers(controller)) {
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
    NSString *path = IRDataPath(IR_PANE_LOG);
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
    IRInjectNative(self);
    IRLogPane(self);
}

@interface IRPaneLogController : IRListController
@end

@implementation IRPaneLogController

- (NSMutableArray *)ir_buildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];
    NSArray *log = [NSArray arrayWithContentsOfFile:IRDataPath(IR_PANE_LOG)];
    [specs addObject:IRGroup(nil, log.count
        ? @"Последние открытые разделы Настроек и их внутреннее устройство. Если пункт iOS6Revive не появился "
          @"в нужном разделе, открой этот раздел, вернись сюда и пришли скриншот."
        : @"Пока пусто: открой нужные разделы Настроек и вернись сюда.")];
    for (NSDictionary *entry in log) {
        [specs addObject:IRGroup([NSString stringWithFormat:@"%@ · %@", entry[@"title"], entry[@"class"]], nil)];
        for (NSDictionary *row in entry[@"rows"]) {
            NSString *label = [row[@"group"] boolValue] ? [@"▸ " stringByAppendingString:row[@"name"]] : row[@"name"];
            NSString *detail = [row[@"key"] length] ? row[@"key"] : row[@"id"];
            [specs addObject:[self ir_info:label value:detail]];
        }
    }
    return specs;
}

@end

#pragma mark - Главный экран

@interface IRRootListController : IRListController
@end

@implementation IRRootListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"iOS6Revive";
}

- (NSMutableArray *)ir_buildSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];

    if (IRFeatureInstalled(@"IRSwipeBack")) {
        [specs addObject:IRGroup(nil, @"Проведите пальцем от левого края экрана, чтобы вернуться на предыдущий экран.")];
        [specs addObject:[self ir_switch:@"Смахивание назад" key:kIRSwipeBack fallback:YES]];
    }

    if (IRFeatureInstalled(@"IRControlCenter")) {
        [specs addObject:IRGroup(nil, @"Проведите вверх от нижнего края экрана, чтобы открыть Пункт управления. "
                                      @"На экране блокировки он не открывается.")];
        [specs addObject:[self ir_switch:@"Пункт управления" key:@"ControlCenter" fallback:YES]];
    }

    if (IRFeatureInstalled(@"IRBattery")) {
        [specs addObject:IRGroup(nil, @"Режим энергосбережения временно снижает расход энергии, пока iPhone не будет заряжен: "
                                      @"экран становится темнее, а автоблокировка срабатывает через минуту. "
                                      @"При зарядке до 80 % режим выключится сам.")];
        [specs addObject:[self ir_switch:@"Энергосбережение" key:kIRLowPower fallback:NO]];
        [specs addObject:IRGroup(nil, nil)];
        [specs addObject:[self ir_link:@"Состояние аккумулятора" detail:[IRBatteryHealthController class]]];
    }

    if (IRFeatureInstalled(@"IRNightShift")) {
        [specs addObject:IRGroup(nil, nil)];
        [specs addObject:[self ir_link:@"Night Shift" detail:[IRNightShiftController class]]];
    }

    if (IRFeatureInstalled(@"IRBoldText")) {
        [specs addObject:IRGroup(nil, @"После изменения SpringBoard и все программы перезапустятся.")];
        PSSpecifier *bold = [self ir_switch:@"Жирный шрифт" key:kIRBoldText fallback:NO];
        bold.identifier = @"BOLD_TEXT";
        [specs addObject:bold];
    }

    if (IRFeatureInstalled(@"IRNewAppDot")) {
        [specs addObject:IRGroup(nil, @"Синяя точка рядом с названием только что установленной программы. "
                                      @"Исчезает после первого запуска.")];
        [specs addObject:[self ir_switch:@"Метки новых программ" key:kIRNewAppDot fallback:YES]];
    }

    if (IRFeatureInstalled(@"IRDesktopSite"))
        [specs addObject:IRGroup(@"Safari", @"Чтобы открыть полную версию сайта, нажмите в Safari «Поделиться» "
                                            @"и выберите «Полная версия».")];

    // Разделы, которые приносят сами пакеты: /Library/iOS6Revive/Sections/*.plist
    // { order, title?, footer?, cells = ({ title, key, default }) } — ядро не нужно обновлять ради новой функции
    NSMutableArray *sections = [NSMutableArray array];
    for (NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:IR_SECTIONS_DIR error:NULL]) {
        NSDictionary *section = [file.pathExtension isEqualToString:@"plist"]
            ? [NSDictionary dictionaryWithContentsOfFile:[IR_SECTIONS_DIR stringByAppendingPathComponent:file]] : nil;
        if ([section isKindOfClass:[NSDictionary class]])
            [sections addObject:section];
    }
    [sections sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [@([a[@"order"] intValue]) compare:@([b[@"order"] intValue])];
    }];
    for (NSDictionary *section in sections) {
        [specs addObject:IRGroup(section[@"title"], section[@"footer"])];
        for (NSDictionary *cell in section[@"cells"])
            if ([cell[@"title"] isKindOfClass:[NSString class]] && [cell[@"key"] isKindOfClass:[NSString class]])
                [specs addObject:[self ir_switch:cell[@"title"] key:cell[@"key"] fallback:[cell[@"default"] boolValue]]];
    }

    [specs addObject:IRGroup(nil, @"Пункты появятся и там, где они в новых iOS: Night Shift — в «Яркость и обои», "
                                  @"энергосбережение — в «Основные → Статистика», жирный шрифт — в «Универсальный доступ».")];
    [specs addObject:[self ir_switch:@"Пункты в разделах Настроек" key:kIRNativeSettings fallback:YES]];
    [specs addObject:[self ir_link:@"Разделы Настроек" detail:[IRPaneLogController class]]];

    [specs addObject:IRGroup(nil, @"iOS6Revive — функции новых iOS в стиле iOS 6.")];
    return specs;
}

@end

#pragma mark - Пункт в корне Настроек

static UIImage *IRSettingsIcon(void) {
    const CGFloat size = 29;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();

    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size, size) cornerRadius:5.5] addClip];

    // Небесно-голубая подложка
    CGFloat sky[] = {0.45, 0.78, 0.99, 1, 0.10, 0.44, 0.84, 1};
    CGGradientRef skyGradient = CGGradientCreateWithColorComponents(space, sky, NULL, 2);
    CGContextDrawLinearGradient(ctx, skyGradient, CGPointZero, CGPointMake(0, size), 0);
    CGGradientRelease(skyGradient);

    // Белая «6» в круговой стрелке («оживление») с мягкой тенью, как у иконок iOS 6
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, 1), 1.5, [UIColor colorWithWhite:0 alpha:0.35].CGColor);
    CGContextBeginTransparencyLayer(ctx, NULL);
    [[UIColor whiteColor] set];

    const CGPoint center = CGPointMake(size / 2, size / 2);
    const CGFloat radius = 10, start = -M_PI_2 + 0.5, end = -M_PI_2 - 0.25;
    UIBezierPath *ring = [UIBezierPath bezierPathWithArcCenter:center radius:radius startAngle:start endAngle:end clockwise:YES];
    ring.lineWidth = 2.2;
    [ring stroke];

    CGPoint tip = CGPointMake(center.x + radius * cosf(end), center.y + radius * sinf(end));
    CGPoint tangent = CGPointMake(-sinf(end), cosf(end)), normal = CGPointMake(cosf(end), sinf(end));
    UIBezierPath *arrow = [UIBezierPath bezierPath];
    [arrow moveToPoint:CGPointMake(tip.x + tangent.x * 3.6, tip.y + tangent.y * 3.6)];
    [arrow addLineToPoint:CGPointMake(tip.x + normal.x * 3.2, tip.y + normal.y * 3.2)];
    [arrow addLineToPoint:CGPointMake(tip.x - normal.x * 3.2, tip.y - normal.y * 3.2)];
    [arrow closePath];
    [arrow fill];

    UIFont *font = [UIFont boldSystemFontOfSize:14];
    CGSize textSize = [@"6" sizeWithFont:font];
    [@"6" drawAtPoint:CGPointMake(center.x - textSize.width / 2, center.y - textSize.height / 2) withFont:font];
    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);

    // Глянец сверху
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

static void IRInsertSettingsEntry(PSListController *root) {
    NSArray *current = IRSpecifiers(root);
    if (!current)
        return;
    NSMutableArray *specs = [current isKindOfClass:[NSMutableArray class]] ? (NSMutableArray *)current : [current mutableCopy];

    PSSpecifier *entry = [PSSpecifier preferenceSpecifierNamed:@"iOS6Revive" target:root set:NULL get:NULL
                                                        detail:[IRRootListController class] cell:PSLinkCell edit:nil];
    entry.identifier = @"IOS6REVIVE";
    [entry setProperty:IRSettingsIcon() forKey:@"iconImage"];

    // В конец группы «Основные, Звуки, Яркость и обои, Конфиденциальность», как PreferenceLoader.
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
        IRSetSpecifiersStorage(root, specs);
}

static id (*orig_PrefsListController_specifiers)(PSListController *, SEL);

static id hook_PrefsListController_specifiers(PSListController *self, SEL _cmd) {
    BOOL firstLoad = IRSpecifiers(self) == nil;
    id result = orig_PrefsListController_specifiers(self, _cmd);
    if (firstLoad)
        IRInsertSettingsEntry(self);
    return IRSpecifiers(self) ?: result;
}

__attribute__((constructor)) static void IRSettingsInit(void) {
    @autoreleasepool {
        IR_HOOK(objc_getClass("PrefsListController"), @selector(specifiers),
                hook_PrefsListController_specifiers, &orig_PrefsListController_specifiers);
        IR_HOOK(objc_getClass("PSListController"), @selector(viewWillAppear:),
                hook_PSListController_viewWillAppear, &orig_PSListController_viewWillAppear);
    }
}
