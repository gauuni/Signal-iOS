//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "OWSBackup.h"
#import "OWSBackupExportJob.h"
#import "OWSBackupImportJob.h"
#import "Signal-Swift.h"
#import <Curve25519Kit/Randomness.h>
#import <SignalServiceKit/YapDatabaseConnection+OWS.h>

NSString *const NSNotificationNameBackupStateDidChange = @"NSNotificationNameBackupStateDidChange";

NSString *const OWSPrimaryStorage_OWSBackupCollection = @"OWSPrimaryStorage_OWSBackupCollection";
NSString *const OWSBackup_IsBackupEnabledKey = @"OWSBackup_IsBackupEnabledKey";
NSString *const OWSBackup_BackupKeyKey = @"OWSBackup_BackupKeyKey";
NSString *const OWSBackup_LastExportSuccessDateKey = @"OWSBackup_LastExportSuccessDateKey";
NSString *const OWSBackup_LastExportFailureDateKey = @"OWSBackup_LastExportFailureDateKey";

NS_ASSUME_NONNULL_BEGIN

// TODO: Observe Reachability.
@interface OWSBackup () <OWSBackupJobDelegate>

@property (nonatomic, readonly) YapDatabaseConnection *dbConnection;

// This property should only be accessed on the main thread.
@property (nonatomic, nullable) OWSBackupExportJob *backupExport;

// This property should only be accessed on the main thread.
@property (nonatomic, nullable) OWSBackupImportJob *backupImport;

@property (nonatomic, nullable) NSString *backupExportDescription;
@property (nonatomic, nullable) NSNumber *backupExportProgress;

@property (nonatomic, nullable) NSString *backupImportDescription;
@property (nonatomic, nullable) NSNumber *backupImportProgress;

@end

#pragma mark -

@implementation OWSBackup

@synthesize dbConnection = _dbConnection;

+ (instancetype)sharedManager
{
    static OWSBackup *sharedMyManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedMyManager = [[self alloc] initDefault];
    });
    return sharedMyManager;
}

- (instancetype)initDefault
{
    OWSPrimaryStorage *primaryStorage = [OWSPrimaryStorage sharedManager];

    return [self initWithPrimaryStorage:primaryStorage];
}

- (instancetype)initWithPrimaryStorage:(OWSPrimaryStorage *)primaryStorage
{
    self = [super init];

    if (!self) {
        return self;
    }

    OWSAssert(primaryStorage);

    _dbConnection = primaryStorage.newDatabaseConnection;

    _backupExportState = OWSBackupState_Idle;
    _backupImportState = OWSBackupState_Idle;

    OWSSingletonAssert();

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setup
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidBecomeActive:)
                                                 name:OWSApplicationDidBecomeActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(registrationStateDidChange)
                                                 name:RegistrationStateDidChangeNotification
                                               object:nil];

    // We want to start a backup if necessary on app launch, but app launch is a
    // busy time and it's important to remain responsive, so wait a few seconds before
    // starting the backup.
    //
    // TODO: Make this period longer.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self ensureBackupExportState];
    });
}

- (void)setBackupPrivateKey:(NSData *)value
{
    OWSAssert(value);

    // TODO: This should eventually be the backup key stored in the Signal Service
    //       and retrieved with the backup PIN.  It will eventually be stored in
    //       the keychain.
    [self.dbConnection setObject:value
                          forKey:OWSBackup_BackupKeyKey
                    inCollection:OWSPrimaryStorage_OWSBackupCollection];
}

- (nullable NSData *)backupPrivateKey
{
    NSData *_Nullable result =
        [self.dbConnection objectForKey:OWSBackup_BackupKeyKey inCollection:OWSPrimaryStorage_OWSBackupCollection];
    if (!result) {
        // TODO: This is temporary measure until we have proper private key
        //       storage in the service.
        const NSUInteger kBackupPrivateKeyLength = 32;
        result = [Randomness generateRandomBytes:kBackupPrivateKeyLength];
        [self setBackupPrivateKey:result];
    }
    OWSAssert(result);
    OWSAssert([result isKindOfClass:[NSData class]]);
    return result;
}

#pragma mark - Backup Export

- (void)setLastExportSuccessDate:(NSDate *)value
{
    OWSAssert(value);

    [self.dbConnection setDate:value
                        forKey:OWSBackup_LastExportSuccessDateKey
                  inCollection:OWSPrimaryStorage_OWSBackupCollection];
}

- (nullable NSDate *)lastExportSuccessDate
{
    return [self.dbConnection dateForKey:OWSBackup_LastExportSuccessDateKey
                            inCollection:OWSPrimaryStorage_OWSBackupCollection];
}

- (void)setLastExportFailureDate:(NSDate *)value
{
    OWSAssert(value);

    [self.dbConnection setDate:value
                        forKey:OWSBackup_LastExportFailureDateKey
                  inCollection:OWSPrimaryStorage_OWSBackupCollection];
}


- (nullable NSDate *)lastExportFailureDate
{
    return [self.dbConnection dateForKey:OWSBackup_LastExportFailureDateKey
                            inCollection:OWSPrimaryStorage_OWSBackupCollection];
}

- (BOOL)isBackupEnabled
{
    return [self.dbConnection boolForKey:OWSBackup_IsBackupEnabledKey
                            inCollection:OWSPrimaryStorage_OWSBackupCollection
                            defaultValue:NO];
}

- (void)setIsBackupEnabled:(BOOL)value
{
    [self.dbConnection setBool:value
                        forKey:OWSBackup_IsBackupEnabledKey
                  inCollection:OWSPrimaryStorage_OWSBackupCollection];

    if (!value) {
        [self.dbConnection removeObjectForKey:OWSBackup_LastExportSuccessDateKey
                                 inCollection:OWSPrimaryStorage_OWSBackupCollection];
        [self.dbConnection removeObjectForKey:OWSBackup_LastExportFailureDateKey
                                 inCollection:OWSPrimaryStorage_OWSBackupCollection];
    }

    [self postDidChangeNotification];

    [self ensureBackupExportState];
}

- (BOOL)shouldHaveBackupExport
{
    if (!self.isBackupEnabled) {
        return NO;
    }
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        // Only start backups when app is in the background.
        return NO;
    }
    if (![TSAccountManager isRegistered]) {
        return NO;
    }
    NSDate *_Nullable lastExportSuccessDate = self.lastExportSuccessDate;
    NSDate *_Nullable lastExportFailureDate = self.lastExportFailureDate;
    // Wait N hours before retrying after a success.
    //
    // TODO: Use actual values in production.
    //    const NSTimeInterval kRetryAfterSuccess = 24 * kHourInterval;
    const NSTimeInterval kRetryAfterSuccess = 0;
    if (lastExportSuccessDate && fabs(lastExportSuccessDate.timeIntervalSinceNow) < kRetryAfterSuccess) {
        return NO;
    }
    // Wait N hours before retrying after a failure.
    //
    // TODO: Use actual values in production.
    //    const NSTimeInterval kRetryAfterFailure = 6 * kHourInterval;
    const NSTimeInterval kRetryAfterFailure = 0;
    if (lastExportFailureDate && fabs(lastExportFailureDate.timeIntervalSinceNow) < kRetryAfterFailure) {
        return NO;
    }
    // Don't export backup if there's an import in progress.
    //
    // This conflict shouldn't occur in production since we won't enable backup
    // export until an import is complete, but this could happen in development.
    if (self.backupImport) {
        return NO;
    }

    // TODO: There's other conditions that affect this decision,
    // e.g. Reachability, wifi v. cellular, etc.
    return YES;
}

- (void)ensureBackupExportState
{
    OWSAssertIsOnMainThread();

    // Start or abort a backup export if neccessary.
    if (!self.shouldHaveBackupExport && self.backupExport) {
        [self.backupExport cancel];
        self.backupExport = nil;
    } else if (self.shouldHaveBackupExport && !self.backupExport) {
        self.backupExport =
            [[OWSBackupExportJob alloc] initWithDelegate:self primaryStorage:[OWSPrimaryStorage sharedManager]];
        [self.backupExport startAsync];
    }

    // Update the state flag.
    OWSBackupState backupExportState = OWSBackupState_Idle;
    if (self.backupExport) {
        backupExportState = OWSBackupState_InProgress;
    } else {
        NSDate *_Nullable lastExportSuccessDate = self.lastExportSuccessDate;
        NSDate *_Nullable lastExportFailureDate = self.lastExportFailureDate;
        if (!lastExportSuccessDate && !lastExportFailureDate) {
            backupExportState = OWSBackupState_Idle;
        } else if (lastExportSuccessDate && lastExportFailureDate) {
            backupExportState = ([lastExportSuccessDate compare:lastExportFailureDate] ? OWSBackupState_Succeeded
                                                                                       : OWSBackupState_Failed);
        } else if (lastExportSuccessDate) {
            backupExportState = OWSBackupState_Succeeded;
        } else if (lastExportFailureDate) {
            backupExportState = OWSBackupState_Failed;
        } else {
            OWSFail(@"%@ unexpected condition.", self.logTag);
        }
    }

    BOOL stateDidChange = _backupExportState != backupExportState;
    _backupExportState = backupExportState;
    if (stateDidChange) {
        [self postDidChangeNotification];
    }
}

#pragma mark - Backup Import

- (void)checkCanImportBackup:(OWSBackupBoolBlock)success failure:(OWSBackupErrorBlock)failure
{
    OWSAssertIsOnMainThread();

    DDLogInfo(@"%@ %s", self.logTag, __PRETTY_FUNCTION__);

    [OWSBackupAPI checkForManifestInCloudWithSuccess:^(BOOL value) {
        dispatch_async(dispatch_get_main_queue(), ^{
            success(value);
        });
    }
        failure:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                failure(error);
            });
        }];
}

- (void)tryToImportBackup
{
    OWSAssertIsOnMainThread();
    OWSAssert(!self.backupImport);

    // In development, make sure there's no export or import in progress.
    [self.backupExport cancel];
    self.backupExport = nil;
    [self.backupImport cancel];
    self.backupImport = nil;

    _backupImportState = OWSBackupState_InProgress;

    self.backupImport =
        [[OWSBackupImportJob alloc] initWithDelegate:self primaryStorage:[OWSPrimaryStorage sharedManager]];
    [self.backupImport startAsync];

    [self postDidChangeNotification];
}

- (void)cancelImportBackup
{
    [self.backupImport cancel];
    self.backupImport = nil;

    _backupImportState = OWSBackupState_Idle;

    [self postDidChangeNotification];
}

#pragma mark -

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    OWSAssertIsOnMainThread();

    [self ensureBackupExportState];
}

- (void)registrationStateDidChange
{
    OWSAssertIsOnMainThread();

    [self ensureBackupExportState];
}

#pragma mark - OWSBackupJobDelegate

// We use a delegate method to avoid storing this key in memory.
- (nullable NSData *)backupKey
{
    return self.backupPrivateKey;
}

- (void)backupJobDidSucceed:(OWSBackupJob *)backupJob
{
    OWSAssertIsOnMainThread();

    DDLogInfo(@"%@ %s.", self.logTag, __PRETTY_FUNCTION__);

    if (self.backupImport == backupJob) {
        self.backupImport = nil;

        _backupImportState = OWSBackupState_Succeeded;
    } else if (self.backupExport == backupJob) {
        self.backupExport = nil;

        [self setLastExportSuccessDate:[NSDate new]];

        [self ensureBackupExportState];
    } else {
        return;
    }

    [self postDidChangeNotification];
}

- (void)backupJobDidFail:(OWSBackupJob *)backupJob error:(NSError *)error
{
    OWSAssertIsOnMainThread();

    DDLogInfo(@"%@ %s: %@", self.logTag, __PRETTY_FUNCTION__, error);

    if (self.backupImport == backupJob) {
        self.backupImport = nil;

        _backupImportState = OWSBackupState_Failed;
    } else if (self.backupExport == backupJob) {
        self.backupExport = nil;

        [self setLastExportFailureDate:[NSDate new]];

        [self ensureBackupExportState];
    } else {
        return;
    }

    [self postDidChangeNotification];
}

- (void)backupJobDidUpdate:(OWSBackupJob *)backupJob
               description:(nullable NSString *)description
                  progress:(nullable NSNumber *)progress
{
    OWSAssertIsOnMainThread();

    DDLogInfo(@"%@ %s", self.logTag, __PRETTY_FUNCTION__);

    // TODO: Should we consolidate this state?
    BOOL didChange;
    if (self.backupImport == backupJob) {
        didChange = !([NSObject isNullableObject:self.backupImportDescription equalTo:description] &&
            [NSObject isNullableObject:self.backupImportProgress equalTo:progress]);

        self.backupImportDescription = description;
        self.backupImportProgress = progress;
    } else if (self.backupExport == backupJob) {
        didChange = !([NSObject isNullableObject:self.backupExportDescription equalTo:description] &&
            [NSObject isNullableObject:self.backupExportProgress equalTo:progress]);

        self.backupExportDescription = description;
        self.backupExportProgress = progress;
    } else {
        return;
    }

    if (didChange) {
        [self postDidChangeNotification];
    }
}

- (void)logBackupRecords
{
    OWSAssertIsOnMainThread();

    DDLogInfo(@"%@ %s", self.logTag, __PRETTY_FUNCTION__);

    [OWSBackupAPI fetchAllRecordNamesWithSuccess:^(NSArray<NSString *> *recordNames) {
        for (NSString *recordName in [recordNames sortedArrayUsingSelector:@selector(compare:)]) {
            DDLogInfo(@"%@ \t %@", self.logTag, recordName);
        }
        DDLogInfo(@"%@ record count: %zd", self.logTag, recordNames.count);
    }
        failure:^(NSError *error) {
            DDLogError(@"%@ Failed to retrieve backup records: %@", self.logTag, error);
        }];
}

#pragma mark - Notifications

- (void)postDidChangeNotification
{
    OWSAssertIsOnMainThread();

    [[NSNotificationCenter defaultCenter] postNotificationNameAsync:NSNotificationNameBackupStateDidChange
                                                             object:nil
                                                           userInfo:nil];
}

@end

NS_ASSUME_NONNULL_END
