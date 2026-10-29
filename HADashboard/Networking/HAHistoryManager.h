#import <Foundation/Foundation.h>

/// Shared history data manager, extracted from HAGraphCardCell.
/// Fetches entity history via the HA REST API, parses responses,
/// downsamples to 100 points, and caches results.
@interface HAHistoryManager : NSObject

+ (instancetype)sharedManager;

/// Fetch numeric history data points for an entity.
/// Returns array of @{@"value": NSNumber, @"timestamp": NSNumber (epoch)}.
/// Uses cache when available.
- (void)fetchHistoryForEntityId:(NSString *)entityId
                      hoursBack:(NSInteger)hours
                     completion:(void (^)(NSArray *points, NSError *error))completion;

/// Fetch numeric history for explicit date range.
/// maxPoints controls downsample limit (pass 0 for default 100).
- (void)fetchHistoryForEntityId:(NSString *)entityId
                      startDate:(NSDate *)startDate
                        endDate:(NSDate *)endDate
                      maxPoints:(NSUInteger)maxPoints
                     completion:(void (^)(NSArray *points, NSError *error))completion;

/// Fetch state timeline segments for a state-based entity.
/// Returns array of @{@"state": NSString, @"start": NSNumber (epoch), @"end": NSNumber (epoch)}.
- (void)fetchTimelineForEntityId:(NSString *)entityId
                       hoursBack:(NSInteger)hours
                      completion:(void (^)(NSArray *segments, NSError *error))completion;

/// Fetch timeline for explicit date range.
- (void)fetchTimelineForEntityId:(NSString *)entityId
                       startDate:(NSDate *)startDate
                         endDate:(NSDate *)endDate
                      completion:(void (^)(NSArray *segments, NSError *error))completion;

/// Fetch numeric history of one attribute (e.g. a thermostat's
/// `current_temperature`). Same point format as fetchHistoryForEntityId:.
- (void)fetchAttributeHistoryForEntityId:(NSString *)entityId
                               attribute:(NSString *)attribute
                               startDate:(NSDate *)startDate
                                 endDate:(NSDate *)endDate
                              completion:(void (^)(NSArray *points, NSError *error))completion;

/// Fetch the full state history (state + attributes) of an entity, oldest first.
/// Returns array of @{@"timestamp": NSNumber (epoch, last_updated), @"state": NSString,
/// @"attributes": NSDictionary}. Not downsampled (callers derive series/durations).
- (void)fetchRawHistoryForEntityId:(NSString *)entityId
                         startDate:(NSDate *)startDate
                           endDate:(NSDate *)endDate
                        completion:(void (^)(NSArray<NSDictionary *> *entries, NSError *error))completion;

/// Clear all cached history data.
- (void)clearCache;

@end
