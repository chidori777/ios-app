#import "HAEntityDetailViewController.h"
#import "HAStateLocalizer.h"
#import "HAStrings.h"
#import "HAEntity.h"
#import "HATheme.h"
#import "HAIconMapper.h"
#import "HAEntityDisplayHelper.h"
#import "HAConnectionManager.h"
#import "HABottomSheetPresentationController.h"
#import "HAHistoryManager.h"
#import "HAGraphView.h"
#import "HAAttributeRowView.h"
#import "HAEntityDetailSection.h"
#import "HAHeatingAnalysis.h"

static const CGFloat kGrabberWidth = 36.0;
static const CGFloat kGrabberHeight = 5.0;
static const CGFloat kHeaderPadding = 16.0;
static const CGFloat kIconSize = 28.0;
static const CGFloat kGraphHeight = 160.0;

@interface HAEntityDetailViewController () <HAGraphViewDelegate>
@property (nonatomic, strong, readwrite) UIScrollView *scrollView;
@property (nonatomic, strong, readwrite) UIStackView *contentStack;

// Header elements
@property (nonatomic, strong) UIView *grabberView;
@property (nonatomic, strong) UILabel *iconLabel;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UIButton *closeButton;

// History section
@property (nonatomic, strong) UISegmentedControl *historySegment;
@property (nonatomic, strong) HAGraphView *graphView;
@property (nonatomic, strong) UIActivityIndicatorView *graphSpinner;
@property (nonatomic, strong) UIView *historyContainer;

// Domain controls section
@property (nonatomic, strong) id<HAEntityDetailSection> domainSection;
@property (nonatomic, strong) UIView *domainSectionView;

// Attributes section
@property (nonatomic, strong) UIStackView *attributesStack;

// Zoom re-fetch
@property (nonatomic, strong) NSTimer *zoomFetchTimer;
@property (nonatomic, assign) NSTimeInterval pendingZoomStart;
@property (nonatomic, assign) NSTimeInterval pendingZoomEnd;

// Custom date range
@property (nonatomic, strong) UIView *datePickerContainer;
@property (nonatomic, strong) NSDate *customStartDate;
@property (nonatomic, strong) NSDate *customEndDate;

// Guards
@property (nonatomic, assign) BOOL hasLoadedInitialHistory;
/// "Show outdoor" checkbox above custom graphs, and the thermostat summary.
@property (nonatomic, strong) UIButton *outdoorToggle;
@property (nonatomic, strong) UILabel *climateSummaryLabel;
/// Incremented per custom graph load so stale async results are dropped.
@property (nonatomic, assign) NSUInteger customGraphGeneration;
@end

@implementation HAEntityDetailViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    // Use the non-gradient cell color — the detail sheet is presented modally
    // over the dashboard, not composited over the gradient background.
    self.view.backgroundColor = [HATheme effectiveDarkMode]
        ? [UIColor colorWithRed:0.12 green:0.13 blue:0.16 alpha:1.0]
        : [UIColor whiteColor];
    [self setupGrabber];
    [self setupHeader];
    [self setupScrollView];
    [self setupDomainSection];
    [self setupHistorySection];
    [self setupAttributesSection];
    [self updateHeaderWithEntity:self.entity];

    // Observe entity state changes
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(entityDidUpdate:)
                                                 name:HAConnectionManagerEntityDidUpdateNotification
                                               object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    // Link scroll view to bottom sheet presentation controller for pan-to-dismiss coordination
    if ([self.presentationController isKindOfClass:[HABottomSheetPresentationController class]]) {
        HABottomSheetPresentationController *sheet = (HABottomSheetPresentationController *)self.presentationController;
        sheet.trackedScrollView = self.scrollView;
    }

    // Load history on first appear only (iOS 15 sheets re-trigger viewDidAppear on detent changes)
    if (!self.hasLoadedInitialHistory) {
        self.hasLoadedInitialHistory = YES;
        [self loadHistory];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Setup

- (void)setupGrabber {
    // iOS 15+ uses UISheetPresentationController with its own grabber, so skip custom grabber
    if (@available(iOS 15.0, *)) {
        return;
    }

    self.grabberView = [[UIView alloc] init];
    self.grabberView.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.4];
    self.grabberView.layer.cornerRadius = kGrabberHeight / 2.0;
    self.grabberView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.grabberView];

    [NSLayoutConstraint activateConstraints:@[
        [self.grabberView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8],
        [self.grabberView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.grabberView.widthAnchor constraintEqualToConstant:kGrabberWidth],
        [self.grabberView.heightAnchor constraintEqualToConstant:kGrabberHeight],
    ]];
}

- (void)setupHeader {
    // Icon
    self.iconLabel = [[UILabel alloc] init];
    self.iconLabel.font = [HAIconMapper mdiFontOfSize:kIconSize];
    self.iconLabel.textAlignment = NSTextAlignmentCenter;
    self.iconLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.iconLabel];

    // Name
    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    self.nameLabel.textColor = [HATheme primaryTextColor];
    self.nameLabel.numberOfLines = 2;
    self.nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.nameLabel];

    // State
    self.stateLabel = [[UILabel alloc] init];
    self.stateLabel.font = [UIFont systemFontOfSize:14];
    self.stateLabel.textColor = [HATheme secondaryTextColor];
    self.stateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.stateLabel];

    // Close button
    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.closeButton setTitle:@"\u2715" forState:UIControlStateNormal];
    self.closeButton.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightMedium];
    [self.closeButton setTitleColor:[HATheme secondaryTextColor] forState:UIControlStateNormal];
    [self.closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    self.closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.closeButton];

    CGFloat topOffset = 8 + kGrabberHeight + 12;

    [NSLayoutConstraint activateConstraints:@[
        [self.iconLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:kHeaderPadding],
        [self.iconLabel.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:topOffset],
        [self.iconLabel.widthAnchor constraintEqualToConstant:kIconSize + 4],
        [self.iconLabel.heightAnchor constraintEqualToConstant:kIconSize + 4],

        [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.iconLabel.trailingAnchor constant:10],
        [self.nameLabel.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:topOffset],
        [self.nameLabel.trailingAnchor constraintEqualToAnchor:self.closeButton.leadingAnchor constant:-8],

        [self.stateLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [self.stateLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:2],
        [self.stateLabel.trailingAnchor constraintEqualToAnchor:self.nameLabel.trailingAnchor],

        [self.closeButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-kHeaderPadding],
        [self.closeButton.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:topOffset],
        [self.closeButton.widthAnchor constraintEqualToConstant:32],
        [self.closeButton.heightAnchor constraintEqualToConstant:32],
    ]];
}

- (void)setupScrollView {
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.showsVerticalScrollIndicator = YES;
    [self.view addSubview:self.scrollView];

    self.contentStack = [[UIStackView alloc] init];
    self.contentStack.axis = UILayoutConstraintAxisVertical;
    self.contentStack.spacing = 16;
    self.contentStack.alignment = UIStackViewAlignmentFill;
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.contentStack];

    CGFloat headerBottom = 8 + kGrabberHeight + 12 + kIconSize + 4 + 20 + 12;

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:headerBottom],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.contentStack.topAnchor constraintEqualToAnchor:self.scrollView.topAnchor constant:8],
        [self.contentStack.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor constant:kHeaderPadding],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:self.scrollView.trailingAnchor constant:-kHeaderPadding],
        [self.contentStack.bottomAnchor constraintEqualToAnchor:self.scrollView.bottomAnchor constant:-16],
        [self.contentStack.widthAnchor constraintEqualToAnchor:self.scrollView.widthAnchor constant:-2 * kHeaderPadding],
    ]];
}

- (void)setupHistorySection {
    // Container view wrapping segment control + graph + spinner
    self.historyContainer = [[UIView alloc] init];
    self.historyContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentStack addArrangedSubview:self.historyContainer];
    // Light sheets stay focused on the controls: no on/off history bar.
    self.historyContainer.hidden = [[self.entity domain] isEqualToString:@"light"] && self.graphEntities.count <= 1;
    [self setupCustomGraphControls];

    // Segmented control: 1h, 6h, 24h (default), 7d
    BOOL frenchUI = [[HAStateLocalizer lastResolvedLanguageCode] hasPrefix:@"fr"];
    self.historySegment = [[UISegmentedControl alloc] initWithItems:frenchUI
        ? @[@"1 h", @"6 h", @"24 h", @"7 j", @"Choisir"]
        : @[@"1h", @"6h", @"24h", @"7d", @"Custom"]];
    // Default segment: pick the smallest segment that covers the card's hours_to_show
    if (self.hoursToShow > 0) {
        if (self.hoursToShow <= 1) self.historySegment.selectedSegmentIndex = 0;       // 1h
        else if (self.hoursToShow <= 6) self.historySegment.selectedSegmentIndex = 1;   // 6h
        else if (self.hoursToShow <= 24) self.historySegment.selectedSegmentIndex = 2;  // 24h
        else self.historySegment.selectedSegmentIndex = 3;                               // 7d
    } else {
        self.historySegment.selectedSegmentIndex = 2; // 24h default
    }
    self.historySegment.translatesAutoresizingMaskIntoConstraints = NO;
    // Style for dark background: light text, themed tint
    if (@available(iOS 13.0, *)) {
        self.historySegment.selectedSegmentTintColor = [UIColor colorWithWhite:0.3 alpha:1.0];
        self.historySegment.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
        NSDictionary *normalAttrs = @{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.7 alpha:1.0]};
        NSDictionary *selectedAttrs = @{NSForegroundColorAttributeName: [UIColor whiteColor]};
        [self.historySegment setTitleTextAttributes:normalAttrs forState:UIControlStateNormal];
        [self.historySegment setTitleTextAttributes:selectedAttrs forState:UIControlStateSelected];
    } else {
        self.historySegment.tintColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    }
    [self.historySegment addTarget:self action:@selector(historySegmentChanged:) forControlEvents:UIControlEventValueChanged];
    [self.historyContainer addSubview:self.historySegment];

    // Graph view
    self.graphView = [[HAGraphView alloc] init];
    self.graphView.translatesAutoresizingMaskIntoConstraints = NO;
    self.graphView.backgroundColor = [UIColor clearColor];
    self.graphView.showAxisLabels = YES;
    self.graphView.inspectionEnabled = YES;
    self.graphView.delegate = self;
    [self.historyContainer addSubview:self.graphView];

    // Activity indicator centered on graph
    self.graphSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    self.graphSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.graphSpinner.hidesWhenStopped = YES;
    [self.historyContainer addSubview:self.graphSpinner];

    [NSLayoutConstraint activateConstraints:@[
        [self.historySegment.topAnchor constraintEqualToAnchor:self.historyContainer.topAnchor],
        [self.historySegment.leadingAnchor constraintEqualToAnchor:self.historyContainer.leadingAnchor],
        [self.historySegment.trailingAnchor constraintEqualToAnchor:self.historyContainer.trailingAnchor],

        [self.graphView.topAnchor constraintEqualToAnchor:self.historySegment.bottomAnchor constant:8],
        [self.graphView.leadingAnchor constraintEqualToAnchor:self.historyContainer.leadingAnchor],
        [self.graphView.trailingAnchor constraintEqualToAnchor:self.historyContainer.trailingAnchor],
        [self.graphView.heightAnchor constraintEqualToConstant:kGraphHeight],
        [self.graphView.bottomAnchor constraintEqualToAnchor:self.historyContainer.bottomAnchor],

        [self.graphSpinner.centerXAnchor constraintEqualToAnchor:self.graphView.centerXAnchor],
        [self.graphSpinner.centerYAnchor constraintEqualToAnchor:self.graphView.centerYAnchor],
    ]];
}

#pragma mark - Domain Section

- (void)setupDomainSection {
    if (!self.entity) return;

    __weak typeof(self) weakSelf = self;
    HADetailServiceBlock serviceBlock = ^(NSString *service, NSString *domain, NSDictionary *data, NSString *entityId) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(entityDetail:didCallService:inDomain:withData:entityId:)]) {
            [strongSelf.delegate entityDetail:strongSelf didCallService:service inDomain:domain withData:data entityId:entityId];
        }
    };

    self.domainSection = [HAEntityDetailSectionFactory sectionForEntity:self.entity serviceBlock:serviceBlock];
    if (self.domainSection) {
        self.domainSectionView = [self.domainSection viewForEntity:self.entity];
        if (self.domainSectionView) {
            [self.contentStack insertArrangedSubview:self.domainSectionView atIndex:0];
        }
    }
}

#pragma mark - Attributes

- (void)setupAttributesSection {
    self.attributesStack = [[UIStackView alloc] init];
    self.attributesStack.axis = UILayoutConstraintAxisVertical;
    self.attributesStack.spacing = 0;
    self.attributesStack.alignment = UIStackViewAlignmentFill;
    self.attributesStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentStack addArrangedSubview:self.attributesStack];

    [self rebuildAttributes];
}

- (void)rebuildAttributes {
    // Remove old rows
    for (UIView *sub in self.attributesStack.arrangedSubviews) {
        [self.attributesStack removeArrangedSubview:sub];
        [sub removeFromSuperview];
    }

    // Simplified sheets: the raw attribute list (hvac_modes, min_temp, ...) is
    // developer-level detail and is no longer shown.
    self.attributesStack.hidden = YES;
    return;

    NSDictionary *attributes = self.entity.attributes;
    if (!attributes || attributes.count == 0) return;

    // Standard attributes to filter out
    static NSSet *filteredKeys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        filteredKeys = [NSSet setWithArray:@[
            HAAttrFriendlyName, HAAttrIcon, @"entity_picture", HAAttrUnitOfMeasurement,
            @"assumed_state", HAAttrSupportedFeatures, HAAttrDeviceClass,
        ]];
    });

    NSString *attribution = nil;

    NSArray *sortedKeys = [[attributes allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    for (NSString *key in sortedKeys) {
        if ([filteredKeys containsObject:key]) continue;

        id value = attributes[key];

        if ([key isEqualToString:@"attribution"]) {
            attribution = [self formatAttributeValue:value];
            continue;
        }

        NSString *displayKey = [self humanReadableKey:key];
        NSString *displayValue = [self formatAttributeValue:value];

        HAAttributeRowView *row = [[HAAttributeRowView alloc] init];
        [row configureWithKey:displayKey value:displayValue];
        [self.attributesStack addArrangedSubview:row];
    }

    // Attribution line at the bottom
    if (attribution.length > 0) {
        UILabel *attrLabel = [[UILabel alloc] init];
        attrLabel.text = attribution;
        attrLabel.font = [UIFont systemFontOfSize:11];
        attrLabel.textColor = [HATheme tertiaryTextColor];
        attrLabel.numberOfLines = 0;
        attrLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.attributesStack addArrangedSubview:attrLabel];
    }
}

- (NSString *)humanReadableKey:(NSString *)key {
    // Replace underscores with spaces and capitalize first letter
    NSString *spaced = [key stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    if (spaced.length > 0) {
        spaced = [[[spaced substringToIndex:1] uppercaseString] stringByAppendingString:[spaced substringFromIndex:1]];
    }
    return spaced;
}

- (NSString *)formatAttributeValue:(id)value {
    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        // Check if boolean
        if (strcmp([value objCType], @encode(BOOL)) == 0 ||
            strcmp([value objCType], @encode(char)) == 0) {
            return [value boolValue] ? @"Yes" : @"No";
        }
        // Format number
        double d = [value doubleValue];
        if (d == floor(d)) {
            return [NSString stringWithFormat:@"%ld", (long)[value integerValue]];
        }
        return [NSString stringWithFormat:@"%.1f", d];
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSArray *arr = value;
        NSMutableArray *strings = [NSMutableArray arrayWithCapacity:arr.count];
        for (id item in arr) {
            [strings addObject:[self formatAttributeValue:item]];
        }
        return [strings componentsJoinedByString:@", "];
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        return [NSString stringWithFormat:@"%@", value];
    }
    if ([value isKindOfClass:[NSNull class]] || value == nil) {
        return @"—";
    }
    return [NSString stringWithFormat:@"%@", value];
}

#pragma mark - History

- (NSInteger)selectedHoursBack {
    switch (self.historySegment.selectedSegmentIndex) {
        case 0: return 1;
        case 1: return 6;
        case 2: return 24;
        case 3: return 168; // 7 days
        default: return 24;
    }
}

- (BOOL)isStateBasedEntity {
    NSString *domain = [self.entity domain];
    static NSSet *stateBasedDomains = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stateBasedDomains = [NSSet setWithArray:@[
            @"binary_sensor", @"switch", @"input_boolean", @"light", @"fan",
            @"automation", @"script", @"person", @"device_tracker", @"lock",
            @"cover", @"alarm_control_panel", @"vacuum", @"media_player",
            @"siren", @"update", @"scene",
            @"climate", @"water_heater", @"humidifier", @"input_select",
        ]];
    });
    return [stateBasedDomains containsObject:domain];
}

#pragma mark - Custom graphs (thermostat, temperature / humidity)

- (BOOL)isClimateGraph {
    return [[self.entity domain] isEqualToString:@"climate"] && self.entity.attributes[@"current_temperature"] != nil;
}

- (NSString *)sensorGraphClass {
    if (![[self.entity domain] isEqualToString:@"sensor"]) return nil;
    NSString *dc = [self.entity deviceClass];
    return ([dc isEqualToString:@"temperature"] || [dc isEqualToString:@"humidity"]) ? dc : nil;
}

- (BOOL)usesCustomGraph {
    if (self.graphEntities.count > 1) return NO;
    return [self isClimateGraph] || [self sensorGraphClass] != nil;
}

- (NSString *)outdoorDeviceClass {
    NSString *dc = [self sensorGraphClass];
    return [dc isEqualToString:@"humidity"] ? @"humidity" : @"temperature";
}

- (BOOL)outdoorOverlayEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"HAGraphShowOutdoor"];
}

- (void)updateOutdoorToggleTitle {
    NSString *box = [self outdoorOverlayEnabled] ? @"☑" : @"☐";
    [self.outdoorToggle setTitle:[NSString stringWithFormat:@"%@  Afficher l'extérieur", box] forState:UIControlStateNormal];
}

- (void)outdoorToggleTapped {
    [[NSUserDefaults standardUserDefaults] setBool:![self outdoorOverlayEnabled] forKey:@"HAGraphShowOutdoor"];
    [self updateOutdoorToggleTitle];
    [self loadHistory];
}

- (void)setupCustomGraphControls {
    if (![self usesCustomGraph] || self.historyContainer.hidden) return;
    NSUInteger historyIndex = [self.contentStack.arrangedSubviews indexOfObject:self.historyContainer];
    if (historyIndex == NSNotFound) return;

    if ([self isClimateGraph]) {
        self.climateSummaryLabel = [[UILabel alloc] init];
        self.climateSummaryLabel.numberOfLines = 0;
        self.climateSummaryLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        self.climateSummaryLabel.textColor = [HATheme primaryTextColor];
        [self.contentStack insertArrangedSubview:self.climateSummaryLabel atIndex:historyIndex];
        historyIndex++;
        [self updateClimateSummary];
    }

    BOOL hasOutdoor = [HAHeatingAnalysis outdoorSensorForDeviceClass:[self outdoorDeviceClass]] != nil ||
                      [HAHeatingAnalysis weatherEntity] != nil;
    if (hasOutdoor) {
        self.outdoorToggle = [UIButton buttonWithType:UIButtonTypeSystem];
        self.outdoorToggle.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        self.outdoorToggle.titleLabel.font = [UIFont systemFontOfSize:15];
        [self.outdoorToggle setTitleColor:[HATheme primaryTextColor] forState:UIControlStateNormal];
        [self.outdoorToggle addTarget:self action:@selector(outdoorToggleTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.outdoorToggle.heightAnchor constraintEqualToConstant:32].active = YES;
        [self updateOutdoorToggleTitle];
        [self.contentStack insertArrangedSubview:self.outdoorToggle atIndex:historyIndex];
    }
}

/// Thermostat summary: measured temperature, setpoint, heating now or idle.
- (void)updateClimateSummary {
    if (!self.climateSummaryLabel) return;
    NSDictionary *a = self.entity.attributes;
    NSMutableArray *parts = [NSMutableArray array];
    if (a[@"current_temperature"]) [parts addObject:[NSString stringWithFormat:@"Température : %@ °C", a[@"current_temperature"]]];
    if (a[@"temperature"]) [parts addObject:[NSString stringWithFormat:@"Consigne : %@ °C", a[@"temperature"]]];
    NSString *action = [a[@"hvac_action"] isKindOfClass:[NSString class]] ? a[@"hvac_action"] : nil;
    if ([action isEqualToString:@"heating"]) [parts addObject:@"Chauffe en cours"];
    else if ([action isEqualToString:@"idle"]) [parts addObject:@"Au repos"];
    else if ([self.entity.state isEqualToString:@"off"]) [parts addObject:@"Arrêté"];
    NSString *planning = [self climatePlanningLine];
    if (planning) [parts addObject:planning];
    self.climateSummaryLabel.text = [parts componentsJoinedByString:@"\n"];
}

/// Heating schedule (HA schedule helper) linked by naming convention:
/// climate.thermostat_<room> <-> schedule.chauffage_<room>.
/// "Programme : Éco jusqu'à 11:30".
- (NSString *)climatePlanningLine {
    NSString *entityId = self.entity.entityId;
    NSString *prefix = @"climate.thermostat_";
    if (![entityId hasPrefix:prefix]) return nil;
    NSString *scheduleId = [@"schedule.chauffage_" stringByAppendingString:[entityId substringFromIndex:prefix.length]];
    HAEntity *schedule = [[HAConnectionManager sharedManager] entityForId:scheduleId];
    if (!schedule) return nil;
    static NSDictionary *presetNames;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        presetNames = @{@"comfort": @"Confort", @"eco": @"Éco", @"home": @"Maison", @"away": @"Absent",
                        @"sleep": @"Nuit", @"boost": @"Boost", @"none": @"Aucun", @"activity": @"Activité"};
    });
    id preset = schedule.attributes[@"preset"];
    NSString *mode = [preset isKindOfClass:[NSString class]] ? (presetNames[preset] ?: preset) : nil;
    if (!mode) mode = [schedule.state isEqualToString:@"on"] ? @"actif" : @"hors plage";
    NSString *line = [NSString stringWithFormat:@"Programme : %@", mode];
    id next = schedule.attributes[@"next_event"];
    if ([next isKindOfClass:[NSString class]] && [(NSString *)next length] >= 16) {
        // ISO 8601 with local offset ("2026-10-29T11:30:00+01:00"): HH:mm is chars 11-15.
        line = [line stringByAppendingFormat:@" jusqu'à %@", [(NSString *)next substringWithRange:NSMakeRange(11, 5)]];
    }
    return line;
}

- (NSDictionary *)seriesWithPoints:(NSArray *)points color:(UIColor *)color label:(NSString *)label unit:(NSString *)unit {
    return @{@"points": points, @"color": color, @"label": label, @"unit": unit ?: @""};
}

/// Loads the custom graph for [start, end]: one request per source, assembled when all return.
- (void)loadCustomGraphFrom:(NSDate *)start to:(NSDate *)end {
    NSUInteger generation = ++self.customGraphGeneration;
    HAHistoryManager *mgr = [HAHistoryManager sharedManager];
    dispatch_group_t group = dispatch_group_create();
    NSMutableDictionary *results = [NSMutableDictionary dictionary];
    NSTimeInterval endEpoch = [end timeIntervalSince1970];
    NSString *unitTemp = @"°C";
    NSUInteger maxPoints = [HAGraphView maxPointsForDevice];

    if ([self isClimateGraph]) {
        dispatch_group_enter(group);
        [mgr fetchRawHistoryForEntityId:self.entity.entityId startDate:start endDate:end completion:^(NSArray *entries, NSError *error) {
            NSArray *safe = entries ?: @[];
            @synchronized (results) {
                results[@"current"] = [HAHeatingAnalysis pointsForAttribute:@"current_temperature" fromEntries:safe];
                results[@"target"] = [HAHeatingAnalysis pointsForAttribute:@"temperature" fromEntries:safe];
                results[@"bands"] = [HAHeatingAnalysis heatingRangesFromEntries:safe endTime:endEpoch];
            }
            dispatch_group_leave(group);
        }];
    } else {
        dispatch_group_enter(group);
        [mgr fetchHistoryForEntityId:self.entity.entityId startDate:start endDate:end maxPoints:maxPoints completion:^(NSArray *points, NSError *error) {
            @synchronized (results) { if (points) results[@"self"] = points; }
            dispatch_group_leave(group);
        }];
        HAEntity *humidity = [[self sensorGraphClass] isEqualToString:@"temperature"] ? [HAHeatingAnalysis humiditySiblingOfEntity:self.entity] : nil;
        if (humidity) {
            dispatch_group_enter(group);
            [mgr fetchHistoryForEntityId:humidity.entityId startDate:start endDate:end maxPoints:maxPoints completion:^(NSArray *points, NSError *error) {
                @synchronized (results) { if (points) results[@"humidity"] = points; }
                dispatch_group_leave(group);
            }];
        }
    }

    if (self.outdoorToggle && [self outdoorOverlayEnabled]) {
        NSString *dc = [self outdoorDeviceClass];
        HAEntity *outdoor = [HAHeatingAnalysis outdoorSensorForDeviceClass:dc];
        HAEntity *weather = outdoor ? nil : [HAHeatingAnalysis weatherEntity];
        if (outdoor) {
            dispatch_group_enter(group);
            [mgr fetchHistoryForEntityId:outdoor.entityId startDate:start endDate:end maxPoints:maxPoints completion:^(NSArray *points, NSError *error) {
                @synchronized (results) { if (points) results[@"outdoor"] = points; }
                dispatch_group_leave(group);
            }];
        } else if (weather) {
            dispatch_group_enter(group);
            [mgr fetchRawHistoryForEntityId:weather.entityId startDate:start endDate:end completion:^(NSArray *entries, NSError *error) {
                @synchronized (results) { results[@"outdoor"] = [HAHeatingAnalysis pointsForAttribute:dc fromEntries:entries ?: @[]]; }
                dispatch_group_leave(group);
            }];
        }
    }

    __weak typeof(self) weakSelf = self;
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf.customGraphGeneration) return;
        [strongSelf.graphSpinner stopAnimating];
        UIColor *blue = [UIColor colorWithRed:0.29 green:0.48 blue:0.85 alpha:1.0];
        UIColor *yellow = [UIColor colorWithRed:0.95 green:0.71 blue:0.16 alpha:1.0];
        UIColor *green = [UIColor colorWithRed:0.30 green:0.78 blue:0.40 alpha:1.0];
        UIColor *lightBlue = [UIColor colorWithRed:0.30 green:0.65 blue:0.95 alpha:1.0];
        UIColor *red = [UIColor colorWithRed:0.92 green:0.26 blue:0.24 alpha:1.0];
        BOOL humidityMode = [[strongSelf sensorGraphClass] isEqualToString:@"humidity"];
        NSMutableArray *series = [NSMutableArray array];
        if ([strongSelf isClimateGraph]) {
            NSArray *current = results[@"current"];
            NSArray *target = results[@"target"];
            if (current.count > 1) [series addObject:[strongSelf seriesWithPoints:current color:blue label:@"Température" unit:unitTemp]];
            if (target.count > 1) [series addObject:[strongSelf seriesWithPoints:target color:yellow label:@"Consigne" unit:unitTemp]];
        } else {
            NSArray *own = results[@"self"];
            NSArray *hum = results[@"humidity"];
            if (own.count > 1) {
                [series addObject:[strongSelf seriesWithPoints:own
                                                         color:(humidityMode ? lightBlue : green)
                                                         label:(humidityMode ? @"Humidité" : @"Température")
                                                          unit:(humidityMode ? @"%" : unitTemp)]];
            }
            if (hum.count > 1) [series addObject:[strongSelf seriesWithPoints:hum color:lightBlue label:@"Humidité" unit:@"%"]];
        }
        NSArray *outdoor = results[@"outdoor"];
        if (outdoor.count > 1) {
            [series addObject:[strongSelf seriesWithPoints:outdoor color:red label:@"Extérieur" unit:(humidityMode ? @"%" : unitTemp)]];
        }

        strongSelf.graphView.dataSeries = series.count > 0 ? series : nil;
        strongSelf.graphView.highlightRanges = series.count > 0 ? results[@"bands"] : nil;
    });
}

- (void)loadHistory {
    if (!self.entity) return;

    // Clear previous data
    self.graphView.dataPoints = nil;
    self.graphView.dataSeries = nil;
    self.graphView.timelineData = nil;
    [self.graphSpinner startAnimating];

    if (self.historyContainer.hidden) {
        [self.graphSpinner stopAnimating];
        return;
    }

    if ([self usesCustomGraph]) {
        NSDate *endDate = [NSDate date];
        NSDate *startDate = [NSDate dateWithTimeIntervalSinceNow:-[self selectedHoursBack] * 3600];
        if (self.historySegment.selectedSegmentIndex == 4 && self.customStartDate && self.customEndDate) {
            startDate = self.customStartDate;
            endDate = self.customEndDate;
        }
        [self loadCustomGraphFrom:startDate to:endDate];
        return;
    }

    // Multi-entity: parallel fetch all entities
    if (self.graphEntities.count > 1) {
        [self loadMultiEntityHistory];
        return;
    }

    // Single-entity path (unchanged)
    // Custom date range
    if (self.historySegment.selectedSegmentIndex == 4 && self.customStartDate && self.customEndDate) {
        NSTimeInterval duration = [self.customEndDate timeIntervalSinceDate:self.customStartDate];
        NSUInteger maxPoints = (duration < 7200) ? 250 : 100;
        NSUInteger deviceMax = [HAGraphView maxPointsForDevice];
        if (maxPoints > deviceMax) maxPoints = deviceMax;
        NSString *entityId = self.entity.entityId;
        __weak typeof(self) weakSelf = self;

        if ([self isStateBasedEntity]) {
            [[HAHistoryManager sharedManager] fetchTimelineForEntityId:entityId
                                                            startDate:self.customStartDate
                                                              endDate:self.customEndDate
                                                           completion:^(NSArray *segments, NSError *error) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf.graphSpinner stopAnimating];
                if (segments.count > 0) {
                    strongSelf.graphView.timelineData = @[@{@"segments": segments, @"label": [strongSelf.entity friendlyName] ?: entityId, @"entityId": entityId}];
                }
            }];
        } else {
            [[HAHistoryManager sharedManager] fetchHistoryForEntityId:entityId
                                                           startDate:self.customStartDate
                                                             endDate:self.customEndDate
                                                           maxPoints:maxPoints
                                                          completion:^(NSArray *points, NSError *error) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf.graphSpinner stopAnimating];
                if (points.count > 0) strongSelf.graphView.dataPoints = points;
            }];
        }
        return;
    }

    NSInteger hours = [self selectedHoursBack];
    NSString *entityId = self.entity.entityId;
    __weak typeof(self) weakSelf = self;

    if ([self isStateBasedEntity]) {
        [[HAHistoryManager sharedManager] fetchTimelineForEntityId:entityId
                                                        hoursBack:hours
                                                       completion:^(NSArray *segments, NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.graphSpinner stopAnimating];

            if (segments.count > 0) {
                strongSelf.graphView.timelineData = @[@{
                    @"segments": segments,
                    @"label": [strongSelf.entity friendlyName] ?: entityId,
                    @"entityId": entityId,
                }];
            }
        }];
    } else {
        [[HAHistoryManager sharedManager] fetchHistoryForEntityId:entityId
                                                       hoursBack:hours
                                                      completion:^(NSArray *points, NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.graphSpinner stopAnimating];

            if (points.count > 0) {
                strongSelf.graphView.dataPoints = points;
            }
        }];
    }
}

- (void)loadMultiEntityHistory {
    NSArray *graphEntities = [self.graphEntities copy];
    HAHistoryManager *mgr = [HAHistoryManager sharedManager];
    BOOL isTimeline = [self isStateBasedEntity];
    __weak typeof(self) weakSelf = self;

    NSMutableArray *results = [NSMutableArray arrayWithCapacity:graphEntities.count];
    for (NSUInteger i = 0; i < graphEntities.count; i++) {
        [results addObject:[NSNull null]];
    }

    dispatch_group_t group = dispatch_group_create();

    // Determine time range
    NSDate *startDate = nil;
    NSDate *endDate = nil;
    if (self.historySegment.selectedSegmentIndex == 4 && self.customStartDate && self.customEndDate) {
        startDate = self.customStartDate;
        endDate = self.customEndDate;
    }

    NSInteger hours = [self selectedHoursBack];

    for (NSUInteger i = 0; i < graphEntities.count; i++) {
        NSDictionary *info = graphEntities[i];
        NSString *entityId = info[@"entityId"];
        NSUInteger capturedIndex = i;

        dispatch_group_enter(group);
        if (isTimeline) {
            if (startDate && endDate) {
                [mgr fetchTimelineForEntityId:entityId startDate:startDate endDate:endDate completion:^(NSArray *segments, NSError *error) {
                    if (segments.count > 0) {
                        @synchronized(results) { results[capturedIndex] = segments; }
                    }
                    dispatch_group_leave(group);
                }];
            } else {
                [mgr fetchTimelineForEntityId:entityId hoursBack:hours completion:^(NSArray *segments, NSError *error) {
                    if (segments.count > 0) {
                        @synchronized(results) { results[capturedIndex] = segments; }
                    }
                    dispatch_group_leave(group);
                }];
            }
        } else {
            if (startDate && endDate) {
                [mgr fetchHistoryForEntityId:entityId startDate:startDate endDate:endDate maxPoints:200 completion:^(NSArray *points, NSError *error) {
                    if (points.count > 0) {
                        @synchronized(results) { results[capturedIndex] = points; }
                    }
                    dispatch_group_leave(group);
                }];
            } else {
                [mgr fetchHistoryForEntityId:entityId hoursBack:hours completion:^(NSArray *points, NSError *error) {
                    if (points.count > 0) {
                        @synchronized(results) { results[capturedIndex] = points; }
                    }
                    dispatch_group_leave(group);
                }];
            }
        }
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.graphSpinner stopAnimating];

        if (isTimeline) {
            NSMutableArray *timelineEntries = [NSMutableArray array];
            for (NSUInteger i = 0; i < graphEntities.count; i++) {
                NSArray *segments = results[i];
                if (![segments isKindOfClass:[NSArray class]] || segments.count == 0) continue;
                NSDictionary *info = graphEntities[i];
                [timelineEntries addObject:@{
                    @"segments": segments,
                    @"label": info[@"label"] ?: @"",
                    @"entityId": info[@"entityId"] ?: @"",
                }];
            }
            if (timelineEntries.count > 0) {
                strongSelf.graphView.timelineData = timelineEntries;
            }
        } else {
            NSMutableArray *dataSeries = [NSMutableArray array];
            for (NSUInteger i = 0; i < graphEntities.count; i++) {
                NSArray *points = results[i];
                if (![points isKindOfClass:[NSArray class]] || points.count == 0) continue;
                NSDictionary *info = graphEntities[i];
                [dataSeries addObject:@{
                    @"points": points,
                    @"color": info[@"color"],
                    @"label": info[@"label"],
                    @"unit": info[@"unit"] ?: @"",
                }];
            }
            if (dataSeries.count > 0) {
                strongSelf.graphView.dataSeries = dataSeries;
            }
        }
    });
}

- (void)historySegmentChanged:(UISegmentedControl *)sender {
    if (sender.selectedSegmentIndex == 4) {
        [self showDateRangePicker];
        return;
    }
    [self hideDateRangePicker];
    // resetZoom fires the zoom delegate which schedules a re-fetch for the OLD range.
    // Cancel that timer after resetZoom to prevent it from overwriting our new fetch.
    [self.graphView resetZoom];
    [self.zoomFetchTimer invalidate];
    self.zoomFetchTimer = nil;
    [self loadHistory];
}

#pragma mark - Custom Date Range Picker

- (void)showDateRangePicker {
    if (self.datePickerContainer) return;

    self.customStartDate = [NSDate dateWithTimeIntervalSinceNow:-7 * 86400];
    self.customEndDate = [NSDate date];

    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    self.datePickerContainer = container;

    UILabel *fromLabel = [[UILabel alloc] init];
    fromLabel.text = HALocalizedString(@"cell.entity_detail.from_label", @"Label before the custom history range start-date button in the entity detail view.");
    fromLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    fromLabel.textColor = [HATheme secondaryTextColor];
    fromLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:fromLabel];

    UILabel *toLabel = [[UILabel alloc] init];
    toLabel.text = HALocalizedString(@"cell.entity_detail.to_label", @"Label before the custom history range end-date button in the entity detail view.");
    toLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    toLabel.textColor = [HATheme secondaryTextColor];
    toLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:toLabel];

    UIButton *applyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [applyBtn setTitle:HALocalizedString(@"action.apply", @"Button that applies a custom history date range in the entity detail view.") forState:UIControlStateNormal];
    [applyBtn setTitleColor:[UIColor colorWithRed:0.30 green:0.60 blue:1.00 alpha:1.0] forState:UIControlStateNormal];
    applyBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    applyBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [applyBtn addTarget:self action:@selector(applyCustomRange) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:applyBtn];

    if (@available(iOS 14.0, *)) {
        UIDatePicker *startPicker = [[UIDatePicker alloc] init];
        startPicker.datePickerMode = UIDatePickerModeDateAndTime;
        startPicker.preferredDatePickerStyle = UIDatePickerStyleCompact;
        startPicker.date = self.customStartDate;
        startPicker.maximumDate = [NSDate date];
        startPicker.translatesAutoresizingMaskIntoConstraints = NO;
        if (@available(iOS 13.0, *)) {
            startPicker.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        }
        [startPicker addTarget:self action:@selector(startDateChanged:) forControlEvents:UIControlEventValueChanged];
        [container addSubview:startPicker];

        UIDatePicker *endPicker = [[UIDatePicker alloc] init];
        endPicker.datePickerMode = UIDatePickerModeDateAndTime;
        endPicker.preferredDatePickerStyle = UIDatePickerStyleCompact;
        endPicker.date = self.customEndDate;
        endPicker.maximumDate = [NSDate date];
        endPicker.translatesAutoresizingMaskIntoConstraints = NO;
        if (@available(iOS 13.0, *)) {
            endPicker.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        }
        [endPicker addTarget:self action:@selector(endDateChanged:) forControlEvents:UIControlEventValueChanged];
        [container addSubview:endPicker];

        [NSLayoutConstraint activateConstraints:@[
            [fromLabel.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],
            [fromLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            [fromLabel.widthAnchor constraintEqualToConstant:40],
            [startPicker.centerYAnchor constraintEqualToAnchor:fromLabel.centerYAnchor],
            [startPicker.leadingAnchor constraintEqualToAnchor:fromLabel.trailingAnchor constant:4],
            [toLabel.topAnchor constraintEqualToAnchor:fromLabel.bottomAnchor constant:8],
            [toLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            [toLabel.widthAnchor constraintEqualToConstant:40],
            [endPicker.centerYAnchor constraintEqualToAnchor:toLabel.centerYAnchor],
            [endPicker.leadingAnchor constraintEqualToAnchor:toLabel.trailingAnchor constant:4],
            [applyBtn.topAnchor constraintEqualToAnchor:toLabel.bottomAnchor constant:8],
            [applyBtn.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
            [applyBtn.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-4],
            [container.heightAnchor constraintEqualToConstant:90],
        ]];
    } else {
        // iOS 9-13 fallback: date buttons
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateStyle = NSDateFormatterMediumStyle;
        fmt.timeStyle = NSDateFormatterShortStyle;

        UIButton *startBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [startBtn setTitle:[fmt stringFromDate:self.customStartDate] forState:UIControlStateNormal];
        startBtn.titleLabel.font = [UIFont systemFontOfSize:13];
        startBtn.translatesAutoresizingMaskIntoConstraints = NO;
        startBtn.tag = 200;
        [startBtn addTarget:self action:@selector(showStartDatePicker) forControlEvents:UIControlEventTouchUpInside];
        [container addSubview:startBtn];

        UIButton *endBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [endBtn setTitle:[fmt stringFromDate:self.customEndDate] forState:UIControlStateNormal];
        endBtn.titleLabel.font = [UIFont systemFontOfSize:13];
        endBtn.translatesAutoresizingMaskIntoConstraints = NO;
        endBtn.tag = 201;
        [endBtn addTarget:self action:@selector(showEndDatePicker) forControlEvents:UIControlEventTouchUpInside];
        [container addSubview:endBtn];

        [NSLayoutConstraint activateConstraints:@[
            [fromLabel.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],
            [fromLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            [startBtn.centerYAnchor constraintEqualToAnchor:fromLabel.centerYAnchor],
            [startBtn.leadingAnchor constraintEqualToAnchor:fromLabel.trailingAnchor constant:4],
            [toLabel.topAnchor constraintEqualToAnchor:fromLabel.bottomAnchor constant:8],
            [toLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            [endBtn.centerYAnchor constraintEqualToAnchor:toLabel.centerYAnchor],
            [endBtn.leadingAnchor constraintEqualToAnchor:toLabel.trailingAnchor constant:4],
            [applyBtn.topAnchor constraintEqualToAnchor:toLabel.bottomAnchor constant:8],
            [applyBtn.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
            [applyBtn.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-4],
            [container.heightAnchor constraintEqualToConstant:80],
        ]];
    }

    // Insert into content stack after historySegment
    NSUInteger segIndex = [self.contentStack.arrangedSubviews indexOfObject:self.historyContainer];
    if (segIndex != NSNotFound) {
        [self.contentStack insertArrangedSubview:container atIndex:segIndex];
    } else {
        [self.contentStack addArrangedSubview:container];
    }
}

- (void)hideDateRangePicker {
    if (self.datePickerContainer) {
        [self.contentStack removeArrangedSubview:self.datePickerContainer];
        [self.datePickerContainer removeFromSuperview];
        self.datePickerContainer = nil;
    }
}

- (void)startDateChanged:(UIDatePicker *)picker { self.customStartDate = picker.date; }
- (void)endDateChanged:(UIDatePicker *)picker { self.customEndDate = picker.date; }

- (void)showStartDatePicker { [self showFallbackDatePickerForStart:YES]; }
- (void)showEndDatePicker { [self showFallbackDatePickerForStart:NO]; }

- (void)showFallbackDatePickerForStart:(BOOL)isStart {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:isStart ? HALocalizedString(@"alert.date_picker.start_date_title", @"Action sheet title for the fallback start-date picker in the entity detail view.") : HALocalizedString(@"alert.date_picker.end_date_title", @"Action sheet title for the fallback end-date picker in the entity detail view.")
                                                                  message:@"\n\n\n\n\n\n\n\n\n"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    UIDatePicker *picker = [[UIDatePicker alloc] init];
    picker.datePickerMode = UIDatePickerModeDateAndTime;
    picker.date = isStart ? self.customStartDate : self.customEndDate;
    picker.maximumDate = [NSDate date];
    picker.frame = CGRectMake(10, 30, 300, 200);
    [alert.view addSubview:picker];

    [alert addAction:[UIAlertAction actionWithTitle:HALocalizedString(@"action.done", @"Confirm button, dismisses a date/value picker.") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (isStart) self.customStartDate = picker.date; else self.customEndDate = picker.date;
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateStyle = NSDateFormatterMediumStyle;
        fmt.timeStyle = NSDateFormatterShortStyle;
        UIButton *btn = [self.datePickerContainer viewWithTag:isStart ? 200 : 201];
        if ([btn isKindOfClass:[UIButton class]]) [btn setTitle:[fmt stringFromDate:picker.date] forState:UIControlStateNormal];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:HALocalizedString(@"action.cancel", @"Cancel button in alerts and action sheets throughout Settings.") style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.sourceView = self.datePickerContainer;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)applyCustomRange {
    if (!self.customStartDate || !self.customEndDate) return;
    [self loadHistory];
}

#pragma mark - Zoom Re-fetch (HAGraphViewDelegate)

- (void)graphView:(HAGraphView *)graphView didZoomToStartTime:(NSTimeInterval)startTime endTime:(NSTimeInterval)endTime {
    [self.zoomFetchTimer invalidate];
    self.pendingZoomStart = startTime;
    self.pendingZoomEnd = endTime;
    self.zoomFetchTimer = [NSTimer scheduledTimerWithTimeInterval:0.3 target:self selector:@selector(fetchZoomedHistory) userInfo:nil repeats:NO];
}

- (void)fetchZoomedHistory {
    NSTimeInterval duration = self.pendingZoomEnd - self.pendingZoomStart;
    NSUInteger maxPoints;
    if (duration < 1800)       maxPoints = 300;
    else if (duration < 7200)  maxPoints = 250;
    else if (duration < 21600) maxPoints = 200;
    else                       maxPoints = 100;
    NSUInteger deviceMax = [HAGraphView maxPointsForDevice];
    if (maxPoints > deviceMax) maxPoints = deviceMax;

    NSDate *start = [NSDate dateWithTimeIntervalSince1970:self.pendingZoomStart];
    NSDate *end = [NSDate dateWithTimeIntervalSince1970:self.pendingZoomEnd];
    __weak typeof(self) weakSelf = self;

    // Thermostats / temperature sensors: the generic numeric refetch finds no
    // numbers in a climate state ("heat") and used to blank the graph.
    if ([self usesCustomGraph]) {
        if (self.pendingZoomEnd > self.pendingZoomStart) [self loadCustomGraphFrom:start to:end];
        return;
    }

    // Multi-entity zoom refetch
    if (self.graphEntities.count > 1) {
        NSArray *graphEntities = [self.graphEntities copy];
        HAHistoryManager *mgr = [HAHistoryManager sharedManager];
        NSMutableArray *results = [NSMutableArray arrayWithCapacity:graphEntities.count];
        for (NSUInteger i = 0; i < graphEntities.count; i++) {
            [results addObject:[NSNull null]];
        }

        dispatch_group_t group = dispatch_group_create();
        for (NSUInteger i = 0; i < graphEntities.count; i++) {
            NSString *entityId = graphEntities[i][@"entityId"];
            NSUInteger capturedIndex = i;
            dispatch_group_enter(group);
            [mgr fetchHistoryForEntityId:entityId startDate:start endDate:end maxPoints:maxPoints completion:^(NSArray *points, NSError *error) {
                if (points.count > 0) {
                    @synchronized(results) { results[capturedIndex] = points; }
                }
                dispatch_group_leave(group);
            }];
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSMutableArray *dataSeries = [NSMutableArray array];
            for (NSUInteger i = 0; i < graphEntities.count; i++) {
                NSArray *points = results[i];
                if (![points isKindOfClass:[NSArray class]] || points.count == 0) continue;
                NSDictionary *info = graphEntities[i];
                [dataSeries addObject:@{
                    @"points": points,
                    @"color": info[@"color"],
                    @"label": info[@"label"],
                    @"unit": info[@"unit"] ?: @"",
                }];
            }
            if (dataSeries.count > 0) {
                strongSelf.graphView.dataSeries = dataSeries;
                strongSelf.graphView.visibleStartTime = strongSelf.pendingZoomStart;
                strongSelf.graphView.visibleEndTime = strongSelf.pendingZoomEnd;
            }
        });
        return;
    }

    // Single-entity zoom
    if ([self isStateBasedEntity]) {
        [[HAHistoryManager sharedManager] fetchTimelineForEntityId:self.entity.entityId
                                                        startDate:start
                                                          endDate:end
                                                       completion:^(NSArray *segments, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || !segments.count) return;
                NSArray *wrapped = @[@{@"segments": segments, @"label": strongSelf.entity.friendlyName ?: @"", @"entityId": strongSelf.entity.entityId}];
                strongSelf.graphView.timelineData = wrapped;
            });
        }];
    } else {
        [[HAHistoryManager sharedManager] fetchHistoryForEntityId:self.entity.entityId
                                                       startDate:start
                                                         endDate:end
                                                       maxPoints:maxPoints
                                                      completion:^(NSArray *points, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || !points) return;
                strongSelf.graphView.dataPoints = points;
                strongSelf.graphView.visibleStartTime = strongSelf.pendingZoomStart;
                strongSelf.graphView.visibleEndTime = strongSelf.pendingZoomEnd;
            });
        }];
    }
}

#pragma mark - Header Update

- (void)updateHeaderWithEntity:(HAEntity *)entity {
    if (!entity) return;

    NSString *glyph = [HAEntityDisplayHelper iconGlyphForEntity:entity];
    self.iconLabel.text = glyph;
    self.iconLabel.textColor = [HAEntityDisplayHelper iconColorForEntity:entity];

    // Multi-entity: show card title instead of single entity name
    if (self.graphTitle.length > 0) {
        self.nameLabel.text = self.graphTitle;
    } else {
        self.nameLabel.text = [entity friendlyName] ?: entity.entityId;
    }

    NSString *stateStr = [HAEntityDisplayHelper stateWithUnitForEntity:entity decimals:1];
    if (!stateStr.length) {
        // Defensive fallback for the (normally unreachable) case where the
        // primary path above returns empty -- still route through the
        // shared helper rather than the raw, untranslated HA state.
        stateStr = [HAEntityDisplayHelper formattedStateForEntity:entity decimals:1];
    }
    self.stateLabel.text = stateStr;
}

#pragma mark - Actions

- (void)closeTapped {
    if ([self.delegate respondsToSelector:@selector(entityDetailDidRequestDismiss:)]) {
        [self.delegate entityDetailDidRequestDismiss:self];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

#pragma mark - State Updates

- (void)entityDidUpdate:(NSNotification *)notification {
    HAEntity *updated = notification.userInfo[@"entity"];
    if (!updated || ![updated.entityId isEqualToString:self.entity.entityId]) return;

    self.entity = updated;
    [self updateHeaderWithEntity:updated];
    if (self.domainSection) {
        [self.domainSection updateWithEntity:updated];
    }
    [self rebuildAttributes];
    [self updateClimateSummary];
}

@end
