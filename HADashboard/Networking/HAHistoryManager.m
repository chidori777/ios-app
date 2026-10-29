#import "HAHistoryManager.h"
#import "HADateUtils.h"
#import "HALog.h"
#import "HAAuthManager.h"
#import "HADemoDataProvider.h"
#import "NSMutableURLRequest+HAHelpers.h"

@interface HAHistoryManager ()
@property (nonatomic, strong) NSCache *cache;
@end

@implementation HAHistoryManager

+ (instancetype)sharedManager {
    static HAHistoryManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[HAHistoryManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cache = [[NSCache alloc] init];
        _cache.countLimit = 30;
        _cache.totalCostLimit = 2 * 1024 * 1024; // 2MB limit
    }
    return self;
}

#pragma mark - Public API (hoursBack convenience wrappers)

- (void)fetchHistoryForEntityId:(NSString *)entityId
                      hoursBack:(NSInteger)hours
                     completion:(void (^)(NSArray *, NSError *))completion {
    NSDate *endDate = [NSDate date];
    NSDate *startDate = [NSDate dateWithTimeIntervalSinceNow:-hours * 3600];
    [self fetchHistoryForEntityId:entityId
                        startDate:startDate
                          endDate:endDate
                        maxPoints:100
                       completion:completion];
}

- (void)fetchTimelineForEntityId:(NSString *)entityId
                       hoursBack:(NSInteger)hours
                      completion:(void (^)(NSArray *, NSError *))completion {
    NSDate *endDate = [NSDate date];
    NSDate *startDate = [NSDate dateWithTimeIntervalSinceNow:-hours * 3600];
    [self fetchTimelineForEntityId:entityId
                         startDate:startDate
                           endDate:endDate
                        completion:completion];
}

#pragma mark - Public API (absolute date range)

- (void)fetchHistoryForEntityId:(NSString *)entityId
                      startDate:(NSDate *)startDate
                        endDate:(NSDate *)endDate
                      maxPoints:(NSUInteger)maxPoints
                     completion:(void (^)(NSArray *, NSError *))completion {
    if (!entityId || !completion) return;

    // In demo mode, return fake history data
    if ([[HAAuthManager sharedManager] isDemoMode]) {
        NSInteger hours = (NSInteger)([endDate timeIntervalSinceDate:startDate] / 3600.0);
        if (hours < 1) hours = 24;
        NSArray *fakePoints = [[HADemoDataProvider sharedProvider] historyPointsForEntityId:entityId hoursBack:hours];
        ha_dispatchMainCompletion(completion, fakePoints, nil);
        return;
    }

    NSUInteger effectiveMax = (maxPoints == 0) ? 100 : maxPoints;
    long startEpoch = (long)[startDate timeIntervalSince1970];
    long endEpoch = (long)[endDate timeIntervalSince1970];
    NSString *cacheKey = [NSString stringWithFormat:@"%@_%ld_%ld", entityId, startEpoch, endEpoch];

    NSArray *cached = [self.cache objectForKey:cacheKey];
    if (cached) {
        ha_dispatchMainCompletion(completion, cached, nil);
        return;
    }

    NSURLRequest *request = [self requestForEntityId:entityId startDate:startDate endDate:endDate minimal:YES];
    if (!request) {
        ha_dispatchMainCompletion(completion, nil, [self errorWithMessage:@"Not configured"]);
        return;
    }

    NSUInteger capturedMax = effectiveMax;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            ha_dispatchMainCompletion(completion, nil, error);
            return;
        }

        NSArray *points = [HAHistoryManager parseHistoryData:data maxPoints:capturedMax];
        if (points.count > 0) {
            [self.cache setObject:points forKey:cacheKey];
        }

        ha_dispatchMainCompletion(completion, points, nil);
    }];
    [task resume];
}

- (void)fetchTimelineForEntityId:(NSString *)entityId
                       startDate:(NSDate *)startDate
                         endDate:(NSDate *)endDate
                      completion:(void (^)(NSArray *, NSError *))completion {
    if (!entityId || !completion) return;

    // In demo mode, return fake timeline data
    if ([[HAAuthManager sharedManager] isDemoMode]) {
        NSInteger hours = (NSInteger)([endDate timeIntervalSinceDate:startDate] / 3600.0);
        if (hours < 1) hours = 24;
        NSArray *fakeSegments = [[HADemoDataProvider sharedProvider] timelineSegmentsForEntityId:entityId hoursBack:hours];
        ha_dispatchMainCompletion(completion, fakeSegments, nil);
        return;
    }

    long startEpoch = (long)[startDate timeIntervalSince1970];
    long endEpoch = (long)[endDate timeIntervalSince1970];
    NSString *cacheKey = [NSString stringWithFormat:@"tl_%@_%ld_%ld", entityId, startEpoch, endEpoch];

    NSArray *cached = [self.cache objectForKey:cacheKey];
    if (cached) {
        ha_dispatchMainCompletion(completion, cached, nil);
        return;
    }

    NSURLRequest *request = [self requestForEntityId:entityId startDate:startDate endDate:endDate minimal:NO];
    if (!request) {
        ha_dispatchMainCompletion(completion, nil, [self errorWithMessage:@"Not configured"]);
        return;
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            ha_dispatchMainCompletion(completion, nil, error);
            return;
        }

        NSArray *segments = [HAHistoryManager parseHistoryStateData:data];
        if (segments.count > 0) {
            [self.cache setObject:segments forKey:cacheKey];
        }

        ha_dispatchMainCompletion(completion, segments, nil);
    }];
    [task resume];
}

- (void)clearCache {
    [self.cache removeAllObjects];
}

#pragma mark - Attribute history

- (void)fetchAttributeHistoryForEntityId:(NSString *)entityId
                               attribute:(NSString *)attribute
                               startDate:(NSDate *)startDate
                                 endDate:(NSDate *)endDate
                              completion:(void (^)(NSArray *, NSError *))completion {
    if (!entityId || !attribute || !completion) return;
    if ([[HAAuthManager sharedManager] isDemoMode]) {
        ha_dispatchMainCompletion(completion, @[], nil);
        return;
    }
    NSString *serverURL = [[HAAuthManager sharedManager] serverURL];
    NSString *token = [[HAAuthManager sharedManager] accessToken];
    if (!serverURL || !token) {
        ha_dispatchMainCompletion(completion, nil, [self errorWithMessage:@"Not configured"]);
        return;
    }
    long startEpoch = (long)[startDate timeIntervalSince1970];
    long endEpoch = (long)[endDate timeIntervalSince1970];
    NSString *cacheKey = [NSString stringWithFormat:@"%@#%@_%ld_%ld", entityId, attribute, startEpoch, endEpoch];
    NSArray *cached = [self.cache objectForKey:cacheKey];
    if (cached) {
        ha_dispatchMainCompletion(completion, cached, nil);
        return;
    }

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss";
    fmt.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    fmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    // Attributes are required here, and attribute-only changes (a new
    // current_temperature) are not "significant" state changes.
    NSString *urlStr = [NSString stringWithFormat:@"%@/api/history/period/%@?end_time=%@&filter_entity_id=%@&significant_changes_only=0",
                        serverURL, [fmt stringFromDate:startDate], [fmt stringFromDate:endDate], entityId];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        ha_dispatchMainCompletion(completion, nil, [self errorWithMessage:@"Bad URL"]);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request ha_setAuthHeaders:token];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            ha_dispatchMainCompletion(completion, nil, error);
            return;
        }
        NSArray *points = [HAHistoryManager parseAttributeHistoryData:data attribute:attribute maxPoints:150];
        if (points.count > 0) [self.cache setObject:points forKey:cacheKey];
        ha_dispatchMainCompletion(completion, points, nil);
    }];
    [task resume];
}

+ (NSArray *)parseAttributeHistoryData:(NSData *)data attribute:(NSString *)attribute maxPoints:(NSUInteger)maxPoints {
    if (!data.length) return @[];
    NSArray *result = nil;
    @try {
        result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    } @catch (NSException *e) {
        return @[];
    }
    if (![result isKindOfClass:[NSArray class]] || result.count == 0) return @[];
    NSArray *states = result.firstObject;
    if (![states isKindOfClass:[NSArray class]]) return @[];

    NSMutableArray *points = [NSMutableArray arrayWithCapacity:states.count];
    for (NSDictionary *entry in states) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *attrs = entry[@"attributes"];
        if (![attrs isKindOfClass:[NSDictionary class]]) continue;
        id raw = attrs[attribute];
        if (![raw isKindOfClass:[NSNumber class]] && ![raw isKindOfClass:[NSString class]]) continue;
        if ([raw isKindOfClass:[NSString class]] && [(NSString *)raw length] == 0) continue;
        double value = [raw doubleValue];
        // last_updated moves on attribute-only changes; last_changed does not.
        id rawTime = entry[@"last_updated"];
        if (![rawTime isKindOfClass:[NSString class]]) rawTime = entry[@"last_changed"];
        if (![rawTime isKindOfClass:[NSString class]]) continue;
        NSDate *date = [HADateUtils dateFromISO8601String:rawTime];
        if (!date) continue;
        [points addObject:@{@"value": @(value), @"timestamp": @([date timeIntervalSince1970])}];
    }
    if (maxPoints > 0 && points.count > maxPoints) {
        NSMutableArray *sampled = [NSMutableArray arrayWithCapacity:maxPoints + 1];
        double step = (double)points.count / (double)maxPoints;
        for (NSUInteger i = 0; i < maxPoints; i++) {
            NSUInteger idx = (NSUInteger)(i * step);
            if (idx < points.count) [sampled addObject:points[idx]];
        }
        [sampled addObject:points.lastObject];
        return [sampled copy];
    }
    return [points copy];
}

#pragma mark - Request Building

- (NSURLRequest *)requestForEntityId:(NSString *)entityId startDate:(NSDate *)startDate endDate:(NSDate *)endDate minimal:(BOOL)minimal {
    NSString *serverURL = [[HAAuthManager sharedManager] serverURL];
    NSString *token = [[HAAuthManager sharedManager] accessToken];
    if (!serverURL || !token) return nil;

    static NSDateFormatter *fmt;
    static dispatch_once_t fmtOnce;
    dispatch_once(&fmtOnce, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss";
        fmt.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        fmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    });
    NSString *startStr = [fmt stringFromDate:startDate];
    NSString *endStr = [fmt stringFromDate:endDate];

    NSString *urlStr;
    if (minimal) {
        urlStr = [NSString stringWithFormat:@"%@/api/history/period/%@?end_time=%@&filter_entity_id=%@&minimal_response&no_attributes",
                  serverURL, startStr, endStr, entityId];
    } else {
        urlStr = [NSString stringWithFormat:@"%@/api/history/period/%@?end_time=%@&filter_entity_id=%@&no_attributes",
                  serverURL, startStr, endStr, entityId];
    }

    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return nil;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request ha_setAuthHeaders:token];
    return request;
}

- (NSError *)errorWithMessage:(NSString *)message {
    return [NSError errorWithDomain:@"HAHistoryManager" code:-1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - Parsing (extracted from HAGraphCardCell)

+ (NSArray *)parseHistoryData:(NSData *)data {
    return [self parseHistoryData:data maxPoints:100];
}

+ (NSArray *)parseHistoryData:(NSData *)data maxPoints:(NSUInteger)maxPoints {
    if (maxPoints == 0) maxPoints = 100;
    if (!data || data.length == 0) return @[];

    NSError *jsonError = nil;
    NSArray *result = nil;
    @try {
        result = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    } @catch (NSException *e) {
        HALogE(@"history", @"JSON parse exception: %@", e.reason);
        return @[];
    }
    if (jsonError || ![result isKindOfClass:[NSArray class]] || result.count == 0) return @[];

    NSArray *states = result.firstObject;
    if (![states isKindOfClass:[NSArray class]]) return @[];

    NSMutableArray *points = [NSMutableArray arrayWithCapacity:states.count];

    for (NSDictionary *entry in states) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSString *stateStr = entry[@"state"];
        if (!stateStr || [stateStr isEqualToString:@"unknown"] || [stateStr isEqualToString:@"unavailable"]) continue;

        double value = [stateStr doubleValue];
        if (value == 0 && ![stateStr isEqualToString:@"0"] && ![stateStr hasPrefix:@"0."]) continue;

        id rawTime = entry[@"last_changed"];
        if (![rawTime isKindOfClass:[NSString class]]) rawTime = entry[@"last_updated"];
        NSString *timeStr = [rawTime isKindOfClass:[NSString class]] ? rawTime : nil;
        if (!timeStr) continue;

        NSDate *date = [HADateUtils dateFromISO8601String:timeStr];
        if (!date) continue;

        [points addObject:@{
            @"value": @(value),
            @"timestamp": @([date timeIntervalSince1970])
        }];
    }

    // Downsample to maxPoints for performance on older devices
    if (points.count > maxPoints) {
        NSMutableArray *sampled = [NSMutableArray arrayWithCapacity:maxPoints];
        double step = (double)points.count / (double)maxPoints;
        for (NSUInteger i = 0; i < maxPoints; i++) {
            NSUInteger idx = (NSUInteger)(i * step);
            if (idx < points.count) {
                [sampled addObject:points[idx]];
            }
        }
        [sampled addObject:points.lastObject];
        return [sampled copy];
    }

    return [points copy];
}

+ (NSArray *)parseHistoryStateData:(NSData *)data {
    if (!data || data.length == 0) return @[];

    NSError *jsonError = nil;
    NSArray *result = nil;
    @try {
        result = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    } @catch (NSException *e) {
        HALogE(@"history", @"Timeline JSON parse exception: %@", e.reason);
        return @[];
    }
    if (jsonError || ![result isKindOfClass:[NSArray class]] || result.count == 0) return @[];

    NSArray *states = result.firstObject;
    if (![states isKindOfClass:[NSArray class]] || states.count == 0) return @[];

    NSMutableArray *segments = [NSMutableArray array];
    NSString *prevState = nil;
    NSTimeInterval prevTimestamp = 0;

    for (NSDictionary *entry in states) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSString *stateStr = entry[@"state"];
        if (!stateStr) continue;

        id rawTime2 = entry[@"last_changed"];
        if (![rawTime2 isKindOfClass:[NSString class]]) rawTime2 = entry[@"last_updated"];
        NSString *timeStr = [rawTime2 isKindOfClass:[NSString class]] ? rawTime2 : nil;
        if (!timeStr) continue;

        NSDate *date = [HADateUtils dateFromISO8601String:timeStr];
        if (!date) continue;

        NSTimeInterval timestamp = [date timeIntervalSince1970];

        if (prevState && prevTimestamp > 0) {
            [segments addObject:@{
                @"state": prevState,
                @"start": @(prevTimestamp),
                @"end": @(timestamp),
            }];
        }

        prevState = stateStr;
        prevTimestamp = timestamp;
    }

    if (prevState && prevTimestamp > 0) {
        [segments addObject:@{
            @"state": prevState,
            @"start": @(prevTimestamp),
            @"end": @([[NSDate date] timeIntervalSince1970]),
        }];
    }

    return [segments copy];
}

@end
