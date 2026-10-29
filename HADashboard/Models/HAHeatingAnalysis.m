#import "HAHeatingAnalysis.h"
#import "HAEntity.h"
#import "HAConnectionManager.h"

@implementation HAHeatingAnalysis

+ (NSArray<NSDictionary *> *)pointsForAttribute:(NSString *)attribute fromEntries:(NSArray<NSDictionary *> *)entries {
    NSMutableArray *points = [NSMutableArray arrayWithCapacity:entries.count];
    id lastValue = nil;
    for (NSDictionary *entry in entries) {
        NSDictionary *attrs = entry[@"attributes"];
        id raw = [attrs isKindOfClass:[NSDictionary class]] ? attrs[attribute] : nil;
        if (![raw isKindOfClass:[NSNumber class]] && ![raw isKindOfClass:[NSString class]]) continue;
        if ([raw isKindOfClass:[NSString class]]) {
            NSString *str = raw;
            if (str.length == 0 || [str isEqualToString:@"unknown"] || [str isEqualToString:@"unavailable"]) continue;
        }
        // Skip repeats: attribute history has one entry per attribute change of
        // any kind, most of which leave this attribute unchanged.
        if (lastValue && [lastValue isEqual:raw]) continue;
        lastValue = raw;
        [points addObject:@{@"value": @([raw doubleValue]), @"timestamp": entry[@"timestamp"]}];
    }
    // Close the series at the last entry so a flat line reaches "now".
    NSDictionary *lastEntry = entries.lastObject;
    NSDictionary *lastPoint = points.lastObject;
    if (lastPoint && lastEntry && [lastEntry[@"timestamp"] doubleValue] > [lastPoint[@"timestamp"] doubleValue]) {
        [points addObject:@{@"value": lastPoint[@"value"], @"timestamp": lastEntry[@"timestamp"]}];
    }
    return [points copy];
}

+ (NSArray<NSDictionary *> *)heatingRangesFromEntries:(NSArray<NSDictionary *> *)entries endTime:(NSTimeInterval)endTime {
    NSMutableArray *ranges = [NSMutableArray array];
    double openStart = -1;
    for (NSDictionary *entry in entries) {
        NSDictionary *attrs = entry[@"attributes"];
        id action = [attrs isKindOfClass:[NSDictionary class]] ? attrs[@"hvac_action"] : nil;
        BOOL heating = [action isKindOfClass:[NSString class]] && [(NSString *)action isEqualToString:@"heating"];
        double t = [entry[@"timestamp"] doubleValue];
        if (heating && openStart < 0) {
            openStart = t;
        } else if (!heating && openStart >= 0) {
            [ranges addObject:@{@"start": @(openStart), @"end": @(t)}];
            openStart = -1;
        }
    }
    if (openStart >= 0 && endTime > openStart) {
        [ranges addObject:@{@"start": @(openStart), @"end": @(endTime)}];
    }
    return [ranges copy];
}

+ (NSTimeInterval)heatingSecondsInRanges:(NSArray<NSDictionary *> *)ranges start:(NSTimeInterval)start end:(NSTimeInterval)end {
    NSTimeInterval total = 0;
    for (NSDictionary *range in ranges) {
        double s = MAX([range[@"start"] doubleValue], start);
        double e = MIN([range[@"end"] doubleValue], end);
        if (e > s) total += e - s;
    }
    return total;
}

+ (NSString *)formattedDuration:(NSTimeInterval)seconds {
    NSInteger minutes = (NSInteger)llround(seconds / 60.0);
    if (minutes < 60) return [NSString stringWithFormat:@"%ld min", (long)minutes];
    return [NSString stringWithFormat:@"%ld h %02ld", (long)(minutes / 60), (long)(minutes % 60)];
}

+ (BOOL)textMentionsOutside:(NSString *)text {
    NSString *lower = text.lowercaseString ?: @"";
    for (NSString *word in @[@"exterieur", @"extérieur", @"exterior", @"outdoor", @"outside", @"dehors"]) {
        if ([lower rangeOfString:word].location != NSNotFound) return YES;
    }
    return NO;
}

+ (HAEntity *)outdoorSensorForDeviceClass:(NSString *)deviceClass {
    NSDictionary<NSString *, HAEntity *> *all = [[HAConnectionManager sharedManager] allEntities];
    NSArray *sortedIds = [all.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *entityId in sortedIds) {
        if (![entityId hasPrefix:@"sensor."]) continue;
        HAEntity *entity = all[entityId];
        if (![[entity deviceClass] isEqualToString:deviceClass]) continue;
        if ([self textMentionsOutside:entityId] || [self textMentionsOutside:[entity friendlyName]]) return entity;
    }
    return nil;
}

+ (HAEntity *)weatherEntity {
    NSDictionary<NSString *, HAEntity *> *all = [[HAConnectionManager sharedManager] allEntities];
    NSArray *sortedIds = [all.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *entityId in sortedIds) {
        if ([entityId hasPrefix:@"weather."]) return all[entityId];
    }
    return nil;
}

+ (HAEntity *)humiditySiblingOfEntity:(HAEntity *)temperatureEntity {
    NSString *entityId = temperatureEntity.entityId;
    if (![entityId hasSuffix:@"_temperature"]) return nil;
    NSString *sibling = [[entityId substringToIndex:entityId.length - @"_temperature".length] stringByAppendingString:@"_humidity"];
    return [[HAConnectionManager sharedManager] entityForId:sibling];
}

@end
