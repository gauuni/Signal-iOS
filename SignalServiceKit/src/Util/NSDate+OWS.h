//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

NS_ASSUME_NONNULL_BEGIN

// These NSTimeInterval constants provide simplified durations for readability.
extern const NSTimeInterval kMinuteInterval;
extern const NSTimeInterval kHourInterval;
extern const NSTimeInterval kDayInterval;
extern const NSTimeInterval kWeekInterval;
extern const NSTimeInterval kMonthInterval;

#define kSecondInMs 1000
#define kMinuteInMs (kSecondInMs * 60)
#define kHourInMs (kMinuteInMs * 60)
#define kDayInMs (kHourInMs * 24)
#define kWeekInMs (kDayInMs * 7)
#define kMonthInMs (kDayInMs * 30)

@interface NSDate (OWS)

+ (uint64_t)ows_millisecondTimeStamp;
+ (NSDate *)ows_dateWithMillisecondsSince1970:(uint64_t)milliseconds;
+ (uint64_t)ows_millisecondsSince1970ForDate:(NSDate *)date;

- (BOOL)isAfterDate:(NSDate *)otherDate;
- (BOOL)isBeforeDate:(NSDate *)otherDate;

@end

NS_ASSUME_NONNULL_END
