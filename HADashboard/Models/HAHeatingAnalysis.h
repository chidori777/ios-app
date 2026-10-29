#import <Foundation/Foundation.h>

@class HAEntity;

/// Helpers that derive graph series and heating statistics from raw entity
/// history entries (see -[HAHistoryManager fetchRawHistoryForEntityId:...]):
/// each entry is @{@"timestamp": epoch, @"state": NSString, @"attributes": NSDictionary}.
@interface HAHeatingAnalysis : NSObject

/// Numeric graph points (@{@"value", @"timestamp"}) for one attribute
/// (e.g. current_temperature, temperature). Non-numeric values are skipped.
+ (NSArray<NSDictionary *> *)pointsForAttribute:(NSString *)attribute fromEntries:(NSArray<NSDictionary *> *)entries;

/// Periods where the thermostat was actually heating (hvac_action == heating),
/// as @{@"start": epoch, @"end": epoch}. The last open period ends at endTime.
+ (NSArray<NSDictionary *> *)heatingRangesFromEntries:(NSArray<NSDictionary *> *)entries endTime:(NSTimeInterval)endTime;

/// Total heating seconds of those ranges, clipped to [start, end].
+ (NSTimeInterval)heatingSecondsInRanges:(NSArray<NSDictionary *> *)ranges start:(NSTimeInterval)start end:(NSTimeInterval)end;

/// "2 h 15", "45 min", "0 min".
+ (NSString *)formattedDuration:(NSTimeInterval)seconds;

/// Outdoor sensor for a device class ("temperature" / "humidity"): a sensor
/// whose id or name mentions outside/exterior. Nil when none exists.
+ (HAEntity *)outdoorSensorForDeviceClass:(NSString *)deviceClass;

/// First weather.* entity, used as outdoor fallback (attributes temperature/humidity).
+ (HAEntity *)weatherEntity;

/// Humidity sensor paired with a temperature sensor (same id with
/// _temperature replaced by _humidity), or nil.
+ (HAEntity *)humiditySiblingOfEntity:(HAEntity *)temperatureEntity;

@end
