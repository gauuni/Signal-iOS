//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "OWSBackupStorage.h"
#import "OWSFileSystem.h"
#import "OWSStorage+Subclass.h"

NS_ASSUME_NONNULL_BEGIN

@interface OWSBackupStorage ()

@property (atomic) BOOL areAsyncRegistrationsComplete;
@property (atomic) BOOL areSyncRegistrationsComplete;

@property (nonatomic, readonly) NSString *databaseDirPath;
@property (nonatomic, readonly) BackupStorageKeySpecBlock keySpecBlock;

@end

#pragma mark -

@implementation OWSBackupStorage

- (instancetype)initBackupStorageWithDatabaseDirPath:(NSString *)databaseDirPath
                                        keySpecBlock:(BackupStorageKeySpecBlock)keySpecBlock
{
    OWSAssert(databaseDirPath.length > 0);
    OWSAssert(keySpecBlock);
    OWSAssert([OWSFileSystem ensureDirectoryExists:databaseDirPath]);

    self = [super initStorage];

    if (self) {
        _databaseDirPath = databaseDirPath;
        _keySpecBlock = keySpecBlock;

        [self loadDatabase];
    }

    return self;
}

- (void)loadDatabase
{
    [super loadDatabase];

    [self protectFiles];
}

- (void)resetStorage
{
    [super resetStorage];
}

- (void)runSyncRegistrations
{
    runSyncRegistrationsForStorage(self);

    // See comments on OWSDatabaseConnection.
    //
    // In the absence of finding documentation that can shed light on the issue we've been
    // seeing, this issue only seems to affect sync and not async registrations.  We've always
    // been opening write transactions before the async registrations complete without negative
    // consequences.
    OWSAssert(!self.areSyncRegistrationsComplete);
    self.areSyncRegistrationsComplete = YES;
}

- (void)runAsyncRegistrationsWithCompletion:(void (^_Nonnull)(void))completion
{
    OWSAssert(completion);

    runAsyncRegistrationsForStorage(self);

    DDLogVerbose(@"%@ async registrations enqueued.", self.logTag);

    // Block until all async registrations are complete.
    //
    // NOTE: This has to happen on the "registration connection" for this
    //       database.
    YapDatabaseConnection *dbConnection = self.registrationConnection;
    OWSAssert(self.registrationConnection);
    [dbConnection flushTransactionsWithCompletionQueue:dispatch_get_main_queue()
                                       completionBlock:^{
                                           OWSAssert(!self.areAsyncRegistrationsComplete);

                                           DDLogVerbose(@"%@ async registrations complete.", self.logTag);

                                           self.areAsyncRegistrationsComplete = YES;

                                           completion();
                                       }];
}

- (void)protectFiles
{
    [self logFileSizes];

    // Protect the entire new database directory.
    [OWSFileSystem protectFileOrFolderAtPath:self.databaseDirPath];
}

+ (NSString *)databaseFilename
{
    return @"SignalBackup.sqlite";
}

- (NSString *)databaseFilename
{
    return OWSBackupStorage.databaseFilename;
}

- (NSString *)databaseFilename_SHM
{
    return [self.databaseFilename stringByAppendingString:@"-shm"];
}

- (NSString *)databaseFilename_WAL
{
    return [self.databaseFilename stringByAppendingString:@"-wal"];
}

- (NSString *)databaseFilePath
{
    return [self.databaseDirPath stringByAppendingPathComponent:self.databaseFilename];
}

- (NSString *)databaseFilePath_SHM
{
    return [self.databaseDirPath stringByAppendingPathComponent:self.databaseFilename_SHM];
}

- (NSString *)databaseFilePath_WAL
{
    return [self.databaseDirPath stringByAppendingPathComponent:self.databaseFilename_WAL];
}

- (NSData *)databaseKeySpec
{
    OWSAssert(self.keySpecBlock);

    return self.keySpecBlock();
}

- (void)ensureDatabaseKeySpecExists
{
    // Do nothing.
}

@end

NS_ASSUME_NONNULL_END
