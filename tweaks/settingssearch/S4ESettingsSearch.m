// Search in Settings (iOS 9), built the iOS 6 way: the native search bar heads the root list of Settings,
// results appear in the native search display with the path to each item and the icon of its section, and
// tapping a result walks there — section by section, as if tapped by hand. A switch or other in-place
// setting is scrolled to and highlighted, like iOS 9 does.
//
// The index is built on the first search: the live root list (Apple sections, app settings, tweaks)
// plus the plists the sections are made of — Preferences.app, /System/Library/PreferenceBundles and
// /Library/PreferenceBundles — two levels deep, with names localized from the same bundles. Skeuo4Ever's
// own section is indexed from its live controller.

#import "S4EShared.h"
#import "S4EPrivate.h"

#define kS4ESettingsSearch @"SettingsSearch"

static const void *kS4ESearchKey = &kS4ESearchKey;
static const NSUInteger kS4EMaxDepth = 3;
static const NSUInteger kS4EMaxResults = 60;

@interface PSSpecifier (S4ESettingsSearch)
- (Class)detailControllerClass;
- (NSDictionary *)properties;
@end

@interface PSListController (S4ESettingsSearch)
- (NSIndexPath *)indexPathForSpecifier:(PSSpecifier *)specifier;
- (NSMutableArray *)s4e_buildSpecifiers;
@end

#pragma mark - Index

@interface S4ESearchEntry : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSArray *trail; // titles of the sections on the way
@property(nonatomic, copy) NSArray *path;  // steps from the root: { id, title }
@property(nonatomic, strong) UIImage *icon;
@end

@implementation S4ESearchEntry
@end

static BOOL S4EIsLink(int cellType, BOOL hasDetail) {
    return hasDetail || cellType == PSLinkCell || cellType == PSLinkListCell;
}

// Preference bundles live in two places: Apple's and the ones tweaks install
static NSBundle *S4EPreferenceBundle(NSString *name) {
    if (!name.length)
        return nil;
    NSString *file = [name hasSuffix:@".bundle"] ? name : [name stringByAppendingPathExtension:@"bundle"];
    for (NSString *folder in @[@"/System/Library/PreferenceBundles", @"/Library/PreferenceBundles"]) {
        NSBundle *bundle = [NSBundle bundleWithPath:[folder stringByAppendingPathComponent:file]];
        if (bundle)
            return bundle;
    }
    return nil;
}

// The plist a section is built from. Sections don't say which one they load, so try the usual names:
// the identifier, the label, the bundle name, the controller name without "Controller", and "Root".
static NSDictionary *S4ESectionPlist(NSArray *names, NSArray *bundles, NSMutableSet *visited, NSBundle **outBundle, NSString **outTable) {
    for (NSBundle *bundle in bundles) {
        for (NSString *name in names) {
            if (!name.length || [name isEqualToString:@"Info"])
                continue;
            NSString *path = [bundle pathForResource:name ofType:@"plist"];
            if (!path || [visited containsObject:path])
                continue;
            NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
            if (![plist[@"items"] isKindOfClass:[NSArray class]])
                continue;
            [visited addObject:path];
            *outBundle = bundle;
            *outTable = name;
            return plist;
        }
    }
    return nil;
}

// Sections loaded from a plist keep only the icon's file name until their cell is drawn
static UIImage *S4ESpecifierIcon(PSSpecifier *spec) {
    UIImage *image = [spec propertyForKey:@"iconImage"];
    if ([image isKindOfClass:[UIImage class]])
        return image;
    NSString *name = [spec propertyForKey:@"icon"];
    if (![name isKindOfClass:[NSString class]] || !name.length)
        return nil;
    NSString *bundleName = [spec propertyForKey:@"bundle"];
    NSBundle *bundle = [bundleName isKindOfClass:[NSString class]] ? S4EPreferenceBundle(bundleName) : nil;
    if (!bundle)
        return [UIImage imageNamed:name];
    NSString *base = [name stringByDeletingPathExtension];
    for (NSString *file in @[[base stringByAppendingString:@"@2x"], base]) {
        NSString *path = [bundle pathForResource:file ofType:@"png"];
        if (path)
            return [UIImage imageWithData:[NSData dataWithContentsOfFile:path] scale:[file hasSuffix:@"@2x"] ? 2 : 1];
    }
    return nil;
}

static NSString *S4EStripSuffix(NSString *name) {
    for (NSString *suffix in @[@"ListController", @"Controller", @"Settings"])
        if ([name hasSuffix:suffix] && name.length > suffix.length)
            return [name substringToIndex:name.length - suffix.length];
    return name;
}

@interface S4ESettingsIndex : NSObject
- (NSArray *)buildFromRoot:(PSListController *)root;
@end

@implementation S4ESettingsIndex {
    NSMutableArray *_entries;
    NSMutableSet *_visited;
}

- (void)addTitle:(NSString *)title step:(NSDictionary *)step trail:(NSArray *)trail path:(NSArray *)path icon:(UIImage *)icon {
    S4ESearchEntry *entry = [[S4ESearchEntry alloc] init];
    entry.title = title;
    entry.trail = trail;
    entry.path = [path arrayByAddingObject:step];
    entry.icon = icon;
    [_entries addObject:entry];
}

// Items of a section described by the names it may be stored under
- (void)addItemsForNames:(NSArray *)names bundleName:(NSString *)bundleName context:(NSBundle *)context
                   trail:(NSArray *)trail path:(NSArray *)path icon:(UIImage *)icon depth:(NSUInteger)depth {
    if (depth > kS4EMaxDepth)
        return;
    NSBundle *preferenceBundle = S4EPreferenceBundle(bundleName);
    NSArray *bundles = preferenceBundle ? @[preferenceBundle] : @[context ?: [NSBundle mainBundle], [NSBundle mainBundle]];
    NSBundle *bundle = nil;
    NSString *table = nil;
    NSDictionary *plist = S4ESectionPlist(names, bundles, _visited, &bundle, &table);
    for (NSDictionary *item in plist[@"items"]) {
        if (![item isKindOfClass:[NSDictionary class]])
            continue;
        NSString *label = item[@"label"];
        NSString *cell = item[@"cell"];
        if (![label isKindOfClass:[NSString class]] || !label.length || [cell isEqual:@"PSGroupCell"])
            continue;
        NSString *title = [bundle localizedStringForKey:label value:label table:table];
        NSString *identifier = [item[@"id"] isKindOfClass:[NSString class]] ? item[@"id"] : label;
        NSDictionary *step = @{@"id": identifier, @"title": title};
        [self addTitle:title step:step trail:trail path:path icon:icon];
        BOOL link = [cell isEqual:@"PSLinkCell"] || [cell isEqual:@"PSLinkListCell"] || item[@"detail"] || item[@"bundle"];
        if (link) {
            NSString *detail = [item[@"detail"] isKindOfClass:[NSString class]] ? item[@"detail"] : nil;
            NSString *childBundle = [item[@"bundle"] isKindOfClass:[NSString class]] ? item[@"bundle"] : nil;
            [self addItemsForNames:@[identifier, label, childBundle ?: @"", detail ?: @"", S4EStripSuffix(detail ?: @""), @"Root"]
                        bundleName:childBundle context:bundle trail:[trail arrayByAddingObject:title]
                              path:[path arrayByAddingObject:step] icon:icon depth:depth + 1];
        }
    }
}

- (NSArray *)buildFromRoot:(PSListController *)root {
    _entries = [NSMutableArray array];
    _visited = [NSMutableSet set];
    for (PSSpecifier *spec in [root specifiers]) {
        if (spec.cellType == PSGroupCell || !spec.name.length)
            continue;
        NSDictionary *step = @{@"id": spec.identifier ?: spec.name, @"title": spec.name};
        UIImage *icon = S4ESpecifierIcon(spec);
        [self addTitle:spec.name step:step trail:@[] path:@[] icon:icon];

        Class detail = [spec respondsToSelector:@selector(detailControllerClass)] ? [spec detailControllerClass] : Nil;
        NSString *detailName = detail ? NSStringFromClass(detail) : @"";
        if ([detailName hasPrefix:@"S4E"]) {
            // Our own section: its rows come from code, so ask the controller itself
            PSListController *ours = [[detail alloc] init];
            NSArray *rows = [ours respondsToSelector:@selector(s4e_buildSpecifiers)] ? [ours s4e_buildSpecifiers] : nil;
            for (PSSpecifier *row in rows)
                if (row.cellType != PSGroupCell && row.name.length)
                    [self addTitle:row.name step:@{@"id": row.identifier ?: row.name, @"title": row.name}
                             trail:@[spec.name] path:@[step] icon:icon];
            continue;
        }
        NSString *bundleName = [spec propertyForKey:@"bundle"];
        NSString *label = [spec propertyForKey:@"label"];
        [self addItemsForNames:@[spec.identifier ?: @"", [label isKindOfClass:[NSString class]] ? label : @"", bundleName ?: @"",
                                 detailName, S4EStripSuffix(detailName), @"Root"]
                    bundleName:[bundleName isKindOfClass:[NSString class]] ? bundleName : nil context:[NSBundle mainBundle]
                         trail:@[spec.name] path:@[step] icon:icon depth:1];
    }
    // The same setting can be reached twice (a section and its own plist): keep the first
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *unique = [NSMutableArray array];
    for (S4ESearchEntry *entry in _entries) {
        NSString *key = [[entry.trail arrayByAddingObject:entry.title] componentsJoinedByString:@"›"];
        if (![seen containsObject:key]) {
            [seen addObject:key];
            [unique addObject:entry];
        }
    }
    return unique;
}

@end

#pragma mark - Search

@interface S4ESettingsSearch : NSObject <UISearchDisplayDelegate, UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) UISearchBar *bar;
@property(nonatomic, strong) UISearchDisplayController *display;
- (instancetype)initWithRoot:(PSListController *)root;
@end

@implementation S4ESettingsSearch {
    PSListController *__unsafe_unretained _root; // the root list owns us
    NSArray *_index;
    NSArray *_results;
}

- (instancetype)initWithRoot:(PSListController *)root {
    if ((self = [super init])) {
        _root = root;
        _bar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, root.view.bounds.size.width, 44)];
        _bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        _bar.autocorrectionType = UITextAutocorrectionTypeNo;
        _bar.autocapitalizationType = UITextAutocapitalizationTypeNone;
        _display = [[UISearchDisplayController alloc] initWithSearchBar:_bar contentsController:root];
        _display.delegate = self;
        _display.searchResultsDataSource = self;
        _display.searchResultsDelegate = self;
    }
    return self;
}

- (void)searchDisplayControllerWillBeginSearch:(UISearchDisplayController *)controller {
    // The index is built once per visit to Settings: sections change when apps and tweaks are installed
    if (!_index)
        _index = [[[S4ESettingsIndex alloc] init] buildFromRoot:_root];
}

- (BOOL)searchDisplayController:(UISearchDisplayController *)controller shouldReloadTableForSearchString:(NSString *)query {
    query = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!query.length) {
        _results = @[];
        return YES;
    }
    NSStringCompareOptions options = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    NSMutableArray *scored = [NSMutableArray array];
    for (S4ESearchEntry *entry in _index) {
        NSRange range = [entry.title rangeOfString:query options:options];
        if (range.location == NSNotFound)
            continue;
        // A match at the start of the name beats one at the start of a word, which beats one inside a word;
        // shallower settings come first
        BOOL wordStart = range.location == 0 || [[NSCharacterSet whitespaceCharacterSet]
                                                    characterIsMember:[entry.title characterAtIndex:range.location - 1]];
        NSUInteger score = (range.location == 0 ? 0 : wordStart ? 1 : 2) * 10 + entry.trail.count;
        [scored addObject:@[@(score), entry]];
    }
    [scored sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        NSComparisonResult byScore = [a[0] compare:b[0]];
        return byScore != NSOrderedSame ? byScore : [[a[1] title] localizedCaseInsensitiveCompare:[b[1] title]];
    }];
    NSMutableArray *results = [NSMutableArray array];
    for (NSArray *pair in scored) {
        if (results.count == kS4EMaxResults)
            break;
        [results addObject:pair[1]];
    }
    _results = results;
    return YES;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _results.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"S4EResult"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"S4EResult"];
    S4ESearchEntry *entry = _results[indexPath.row];
    cell.textLabel.text = entry.title;
    cell.detailTextLabel.text = entry.trail.count ? [entry.trail componentsJoinedByString:@" › "] : nil;
    cell.imageView.image = entry.icon;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    S4ESearchEntry *entry = _results[indexPath.row];
    [self.display setActive:NO animated:YES];
    // Let the search slide away before walking into the sections
    NSArray *path = entry.path;
    PSListController *root = _root;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * (int64_t)NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [S4ESettingsSearch walkFrom:root steps:path index:0];
    });
}

// One section per step, as if tapped by hand; the last step is opened, or scrolled to and highlighted
+ (void)walkFrom:(PSListController *)controller steps:(NSArray *)steps index:(NSUInteger)index {
    if (index >= steps.count || ![controller isKindOfClass:objc_getClass("PSListController")])
        return;
    NSDictionary *step = steps[index];
    PSSpecifier *spec = [controller specifierForID:step[@"id"]];
    if (!spec) {
        // Identifiers from a plist and from the live list don't always agree; the shown name does
        for (PSSpecifier *candidate in [controller specifiers])
            if (candidate.cellType != PSGroupCell && [candidate.name isEqualToString:step[@"title"]])
                spec = candidate;
    }
    NSIndexPath *indexPath = spec && [controller respondsToSelector:@selector(indexPathForSpecifier:)] ? [controller indexPathForSpecifier:spec] : nil;
    UITableView *table = [controller respondsToSelector:@selector(table)] ? [controller table] : nil;
    if (!indexPath || !table)
        return;
    BOOL last = index + 1 == steps.count;
    BOOL link = S4EIsLink(spec.cellType, [spec respondsToSelector:@selector(detailControllerClass)] && [spec detailControllerClass]);
    [table scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionMiddle animated:!link];
    if (!link) {
        // A setting in place: highlight its row for a moment
        [table selectRowAtIndexPath:indexPath animated:YES scrollPosition:UITableViewScrollPositionNone];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1200 * (int64_t)NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [table deselectRowAtIndexPath:indexPath animated:YES];
        });
        return;
    }
    UINavigationController *navigation = controller.navigationController;
    [controller tableView:table didSelectRowAtIndexPath:indexPath];
    if (last)
        return;
    // Wait for the push to finish before going one level deeper
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 550 * (int64_t)NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        UIViewController *top = navigation.topViewController;
        if (top != controller)
            [S4ESettingsSearch walkFrom:(PSListController *)top steps:steps index:index + 1];
    });
}

@end

#pragma mark - Settings

static void (*orig_viewWillAppear)(PSListController *, SEL, BOOL);
static void hook_viewWillAppear(PSListController *self, SEL _cmd, BOOL animated) {
    orig_viewWillAppear(self, _cmd, animated);
    if (![self respondsToSelector:@selector(table)])
        return;
    UITableView *table = [self table];
    S4ESettingsSearch *search = objc_getAssociatedObject(self, kS4ESearchKey);
    BOOL enabled = S4EBool(S4EPrefsRead(), kS4ESettingsSearch, YES);
    if (!enabled) {
        if (search && table.tableHeaderView == search.bar)
            table.tableHeaderView = nil;
        objc_setAssociatedObject(self, kS4ESearchKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (!search) {
        search = [[S4ESettingsSearch alloc] initWithRoot:self];
        objc_setAssociatedObject(self, kS4ESearchKey, search, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    search.bar.placeholder = S4E_L(@"Search", @"Поиск");
    if (table.tableHeaderView != search.bar)
        table.tableHeaderView = search.bar;
}

__attribute__((constructor)) static void S4ESettingsSearchInit(void) {
    @autoreleasepool {
        if (!S4EIsProcess(@"com.apple.Preferences"))
            return;
        // The root list of Settings; its own viewWillAppear: is hooked in case it doesn't call super's
        Class root = objc_getClass("PrefsListController");
        if (root)
            S4E_HOOK(root, @selector(viewWillAppear:), hook_viewWillAppear, &orig_viewWillAppear);
    }
}
