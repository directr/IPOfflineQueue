/*
IPOfflineQueue.m
Created by Marco Arment on 8/30/11.

If this is useful to you, please consider integrating send-to-Instapaper support
in your app if it makes sense to do so. Details: http://www.instapaper.com/api

Copyright (c) 2011, Marco Arment
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of Marco Arment nor the names of any contributors may 
      be used to endorse or promote products derived from this software without 
      specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL MARCO ARMENT BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

(You may know this as the New BSD License.)

*/

#import "IPOfflineQueue.h"
#define kMaxRetrySeconds 10

// Debug logging: change to #if 1 to enable
#if 0
#define IPOfflineQueueDebugLog( s, ... ) NSLog(s, ##__VA_ARGS__ )
#else
#define IPOfflineQueueDebugLog( s, ... )
#endif

static NSMutableDictionary *_activeQueues = nil;

@implementation IPOfflineQueue
@synthesize delegate;
@synthesize name;

#pragma mark - SQLite utilities

- (int)stepQuery:(sqlite3_stmt *)stmt
{
    int ret;    
    // Try direct first
    ret = sqlite3_step(stmt);
    if (ret != SQLITE_BUSY && ret != SQLITE_LOCKED) return ret;
    
    int max_seconds = kMaxRetrySeconds;
    while (max_seconds > 0) {
        IPOfflineQueueDebugLog(@"[IPOfflineQueue] SQLITE BUSY - retrying...");
        sleep(1);
        max_seconds--;
        ret = sqlite3_step(stmt);
        if (ret != SQLITE_BUSY && ret != SQLITE_LOCKED) return ret;
    }
    
    [[NSException exceptionWithName:@"IPOfflineQueueDatabaseException" 
        reason:@"SQLITE BUSY for too long" userInfo:nil
    ] raise];
    
    return ret;
}

- (void)executeRawQuery:(NSString *)query
{
    const char *query_cstr = [query cStringUsingEncoding:NSUTF8StringEncoding];
    int ret = sqlite3_exec(db, query_cstr, NULL, NULL, NULL);
    if (ret != SQLITE_BUSY && ret != SQLITE_LOCKED) return;

    IPOfflineQueueDebugLog(@"[IPOfflineQueue] SQLITE BUSY - retrying...");
    [NSThread sleepForTimeInterval:0.1];
    ret = sqlite3_exec(db, query_cstr, NULL, NULL, NULL);
    if (ret != SQLITE_BUSY && ret != SQLITE_LOCKED) return;
    
    int max_seconds = kMaxRetrySeconds;
    while (max_seconds > 0) {
        IPOfflineQueueDebugLog(@"[IPOfflineQueue] SQLITE BUSY - retrying in 1 second...");
        
        sleep(1);
        max_seconds--;
        ret = sqlite3_exec(db, query_cstr, NULL, NULL, NULL);
        if (ret != SQLITE_BUSY && ret != SQLITE_LOCKED) return;
    }

    [[NSException exceptionWithName:@"IPOfflineQueueDatabaseException" 
        reason:@"SQLITE BUSY for too long" userInfo:nil
    ] raise];
}

#pragma mark - Initialization and schema management

- (id)initWithName:(NSString *)n delegate:(id<IPOfflineQueueDelegate>)d
{
    if ( (self = [super init]) ) {
        @synchronized([self class]) {
            if (_activeQueues) {
                if ([_activeQueues objectForKey:n]) {
                    [[NSException exceptionWithName:@"IPOfflineQueueDuplicateNameException" 
                        reason:[NSString stringWithFormat:@"[IPOfflineQueue] Queue already exists with name: %@", n] userInfo:nil
                    ] raise];
                }
                
                [_activeQueues setObject:n forKey:n];
            } else {
                _activeQueues = [[NSMutableDictionary alloc] initWithObjectsAndKeys:n, n, nil];
            }
        }
        
        halt = NO;
        halted = NO;
        autoResumeInterval = 0;
        name = n;
        self.delegate = d;
        
        NSString *dbPath = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.queue", n]
        ];
        
        if (sqlite3_open([dbPath cStringUsingEncoding:NSUTF8StringEncoding], &db) != SQLITE_OK) {
            [[NSException exceptionWithName:@"IPOfflineQueueDatabaseException" 
                reason:@"Failed to open database" userInfo:nil
            ] raise];
        }

        sqlite3_stmt *stmt;
        if (sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'queue'", -1, &stmt, NULL) != SQLITE_OK) {
            [[NSException exceptionWithName:@"IPOfflineQueueDatabaseException" 
                reason:@"Failed to read table info from database" userInfo:nil
            ] raise];
        }

        int existingTables = [self stepQuery:stmt] == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : 0;
        sqlite3_finalize(stmt);
        
        if (existingTables < 1) {
            IPOfflineQueueDebugLog(@"[IPOfflineQueue] Creating new schema");
            [self executeRawQuery:@"CREATE TABLE queue (params BLOB NOT NULL, visibleAt REAL)"];
        }
        
        insertQueue = dispatch_queue_create([[NSString stringWithFormat:@"%@-ipofflinequeue-inserts", n] UTF8String], 0);
        updateThreadEmptyLock = [[NSConditionLock alloc] initWithCondition:0];
        updateThreadPausedLock = [[NSConditionLock alloc] initWithCondition:0];
        updateThreadTerminatingLock = [[NSConditionLock alloc] initWithCondition:0];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(tryToAutoResume) name:@"kNetworkReachabilityChangedNotification" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(tryToAutoResume) name:UIApplicationDidBecomeActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(syncInserts) name:UIApplicationWillResignActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(halt) name:UIApplicationWillTerminateNotification object:nil];
        
        [NSThread detachNewThreadSelector:@selector(queueThreadMain:) toTarget:self withObject:nil];
    }
    return self;
}

- (void)dealloc
{
    [self halt];

    IPOfflineQueueDebugLog(@"queue dealloc: cleaning up");
    sqlite3_close(db);
    updateThreadEmptyLock = nil;
    updateThreadPausedLock = nil;
    updateThreadTerminatingLock = nil;
    
    @synchronized([self class]) { [_activeQueues removeObjectForKey:self.name]; }
    
    self.delegate = nil;
}

- (void)tryToAutoResume
{
    if ([updateThreadPausedLock condition] && 
        (! self.delegate || [self.delegate offlineQueueShouldAutomaticallyResume:self])
    ) {
        // Don't want to block notification-handling, so dispatch this
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [updateThreadPausedLock lock];
            [updateThreadPausedLock unlockWithCondition:0];
        });
    }
}

- (void)autoResumeTimerFired:(NSTimer*)theTimer { [self tryToAutoResume]; }

- (void)delayWorkTimerFired:(NSTimer*)theTimer { [self tryToAutoResume]; }

#pragma mark - Queue control

- (void)enqueueActionWithUserInfo:(NSDictionary *)userInfo
{
    [self enqueueActionWithUserInfo:userInfo visibleAt:nil];
}

- (void)enqueueActionWithUserInfo:(NSDictionary *)userInfo visibleAt:(NSDate*)visibleAt
{
    // This is done with GCD so queue-add operations return to the caller as quickly as possible.
    // Using the custom insertQueue ensures that actions are always inserted (and executed) in order.
    
    dispatch_async(insertQueue, ^{
        [updateThreadEmptyLock lock];
        NSMutableData *data = [[NSMutableData alloc] init];
        NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initForWritingWithMutableData:data];
        [archiver encodeObject:userInfo forKey:@"userInfo"];
        [archiver finishEncoding];

        sqlite3_stmt *stmt;
        if (sqlite3_prepare_v2(db, "INSERT INTO queue (params, visibleAt) VALUES (?, ?)", -1, &stmt, NULL) != SQLITE_OK) {
            [[NSException exceptionWithName:@"IPOfflineQueueDatabaseException" 
                reason:@"Failed to prepare enqueue-insert statement" userInfo:nil
            ] raise];
        }
        
        sqlite3_bind_blob(stmt, 1, [data bytes], [data length], SQLITE_TRANSIENT);
        if(visibleAt)
        {
            sqlite3_bind_double(stmt, 2, [visibleAt timeIntervalSince1970]);
            [self setDelayWorkUntilAtMost:visibleAt];
        }
        else
        {
            sqlite3_bind_double(stmt, 2, 0.0);
        }
        if ([self stepQuery:stmt] != SQLITE_DONE) {
            [[NSException exceptionWithName:@"IPOfflineQueueDatabaseException" 
                reason:@"Failed to insert new queued item" userInfo:nil
            ] raise];
        }
        sqlite3_finalize(stmt);
                
        [updateThreadEmptyLock unlockWithCondition:0];
    });
}

- (void)filterActionsUsingBlock:(IPOfflineQueueFilterBlock)filterBlock
{
    // This is intentionally fuzzy and its deletions are not guaranteed (not protected from race conditions).
    // The idea is, for instance, for redundant requests not to be executed, such as "update list from server".
    // Obviously, multiple updates all in a row are redundant, but you also want to be able to queue them
    // periodically without worrying that a bunch are already in the queue.
    //
    // With this simple, quick-and-dirty method, you can e.g. delete any existing "update" requests before
    // adding a new one.

    dispatch_async(insertQueue, ^{
        sqlite3_stmt *selectStmt = NULL;
        sqlite3_stmt *deleteStmt = NULL;
        
        if (sqlite3_prepare_v2(db, "SELECT ROWID, params FROM queue ORDER BY ROWID", -1, &selectStmt, NULL) != SQLITE_OK) {
            [[NSException exceptionWithName:@"IPOfflineQueueDatabaseException" 
                                     reason:@"Failed to prepare queue-item-filter-loop statement" userInfo:nil
              ] raise];
        }
        
        int queryResult;

        while ( (queryResult = [self stepQuery:selectStmt]) == SQLITE_ROW) {
            sqlite_uint64 rowid = sqlite3_column_int64(selectStmt, 0);
            NSData *blobData = [NSData dataWithBytes:sqlite3_column_blob(selectStmt, 1) length:sqlite3_column_bytes(selectStmt, 1)];
            
            NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingWithData:blobData];
            NSDictionary *userInfo = [unarchiver decodeObjectForKey:@"userInfo"];
            [unarchiver finishDecoding];
            
            if (filterBlock(userInfo) == IPOfflineQueueFilterResultAttemptToDelete) {
                if (! deleteStmt && sqlite3_prepare_v2(db, "DELETE FROM queue WHERE ROWID = ?", -1, &deleteStmt, NULL) != SQLITE_OK) {
                    [[NSException exceptionWithName:@"IPOfflineQueueDatabaseException" 
                                             reason:@"Failed to prepare queue-item-delete statement from filter" userInfo:nil
                    ] raise];
                }
                
                sqlite3_bind_int64(deleteStmt, 1, rowid);
                if ([self stepQuery:deleteStmt] != SQLITE_DONE) {
                    [[NSException exceptionWithName:@"IPOfflineQueueDatabaseException" 
                                             reason:@"Failed to delete queued item after execution from filter" userInfo:nil
                    ] raise];
                }
                sqlite3_reset(deleteStmt);
            }
        }
        
        sqlite3_finalize(selectStmt);
        if (deleteStmt) sqlite3_finalize(deleteStmt);
    });
}

- (void)clear
{
    dispatch_sync(insertQueue, ^{
        [updateThreadEmptyLock lock];
        [self executeRawQuery:@"DELETE FROM queue"];
        [updateThreadEmptyLock unlockWithCondition:1];
    });
}

- (void)pause
{
    [updateThreadPausedLock lock];
    [updateThreadPausedLock unlockWithCondition:1];
}

- (void)resume
{
    [updateThreadPausedLock lock];
    [updateThreadPausedLock unlockWithCondition:0];
}

- (void)syncInserts
{
    // Ensure all inserts are written to database before application terminates
    
    UIApplication *application = [UIApplication sharedApplication];
    UIBackgroundTaskIdentifier backgroundTaskIdentifier = UIBackgroundTaskInvalid;
    
    if (application.applicationState == UIApplicationStateInactive ||
        application.applicationState == UIApplicationStateBackground
    ) {
		backgroundTaskIdentifier = [application beginBackgroundTaskWithExpirationHandler:^{ 
            if (backgroundTaskIdentifier != UIBackgroundTaskInvalid) [application endBackgroundTask:backgroundTaskIdentifier];
        }];
    }
    
    dispatch_sync(insertQueue, ^{ });

    if (backgroundTaskIdentifier != UIBackgroundTaskInvalid) [application endBackgroundTask:backgroundTaskIdentifier];
}

- (NSTimeInterval)autoResumeInterval { return autoResumeInterval; }

- (void)setAutoResumeInterval:(NSTimeInterval)newInterval
{
    if (autoResumeInterval == newInterval) return;
    autoResumeInterval = newInterval;
    
    // Ensure that this always runs on the main thread for simple timer scheduling
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized(self) {
            if (autoResumeTimer) {
                [autoResumeTimer invalidate];
                autoResumeTimer = nil;
            }

            if (newInterval > 0) {
                autoResumeTimer = [NSTimer scheduledTimerWithTimeInterval:newInterval target:self selector:@selector(autoResumeTimerFired:) userInfo:nil repeats:YES];
            } else {
                autoResumeTimer = nil;
            }
        }
    });
}

- (void)setDelayWorkUntilAtMost:(NSDate*)date
{
    if (date == delayWorkUntil) return;
    
    if(date > delayWorkUntil)
    {
        // Already scheduled to delay work
        return;
    }
    
    // Ensure that this always runs on the main thread for simple timer scheduling
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized(self) {
            if (delayedWorkTimer) {
                [delayedWorkTimer invalidate];
                delayedWorkTimer = nil;
            }
            
            NSTimeInterval interval = [date timeIntervalSinceNow];
            if(interval <= 0)
            {
                // Ready to fire right now
                delayWorkUntil = nil;
                [self tryToAutoResume];
            }
            else
            {
                delayedWorkTimer = [NSTimer scheduledTimerWithTimeInterval:interval target:self selector:@selector(delayWorkTimerFired:) userInfo:nil repeats:NO];
            }
        }
    });
}

#pragma mark - Queue thread

- (void)queueThreadMain:(id)userInfo
{
    UIApplication *application = [UIApplication sharedApplication];
    UIBackgroundTaskIdentifier backgroundTaskIdentifier = UIBackgroundTaskInvalid;
    sqlite3_stmt *selectStmt = NULL;
    sqlite3_stmt *deleteStmt = NULL;
    int queryResult;

    if (sqlite3_prepare_v2(db, "SELECT ROWID, params, visibleAt FROM queue ORDER BY ROWID LIMIT 1", -1, &selectStmt, NULL) != SQLITE_OK) {
        [[NSException exceptionWithName:@"IPOfflineQueueDatabaseException" 
            reason:@"Failed to prepare queue-item-select statement" userInfo:nil
        ] raise];
    }
    
    double delayUntil = DBL_MAX;
    
    while (! halt) {    
        backgroundTaskIdentifier = [application beginBackgroundTaskWithExpirationHandler:^{ 
            if (backgroundTaskIdentifier != UIBackgroundTaskInvalid) [application endBackgroundTask:backgroundTaskIdentifier];
        }];

        [updateThreadPausedLock lockWhenCondition:0];
        if (halt) {
            [updateThreadPausedLock unlock];
            if (backgroundTaskIdentifier != UIBackgroundTaskInvalid) [application endBackgroundTask:backgroundTaskIdentifier];
            break;
        }
        [updateThreadPausedLock unlock];
        
        [updateThreadEmptyLock lockWhenCondition:0];
        if (halt) {
            [updateThreadEmptyLock unlock];
            if (backgroundTaskIdentifier != UIBackgroundTaskInvalid) [application endBackgroundTask:backgroundTaskIdentifier];
            break;
        }
        
        if ( (queryResult = [self stepQuery:selectStmt]) != SQLITE_ROW) {
            if (queryResult == SQLITE_DONE) {
                // No more queued items
                sqlite3_reset(selectStmt);
                [updateThreadEmptyLock unlockWithCondition:1];
                if (backgroundTaskIdentifier != UIBackgroundTaskInvalid) [application endBackgroundTask:backgroundTaskIdentifier];
                continue;
            }
            
            // Some other error
            [[NSException exceptionWithName:@"IPOfflineQueueDatabaseException" 
                reason:@"Failed to select next queued item" userInfo:nil
            ] raise];
        }        
        [updateThreadEmptyLock unlockWithCondition:0];
        
        if ([updateThreadPausedLock condition]) {
            // Updater was paused while it was waiting for the empty lock
            sqlite3_reset(selectStmt);
            if (backgroundTaskIdentifier != UIBackgroundTaskInvalid) [application endBackgroundTask:backgroundTaskIdentifier];
            continue;
        }

        sqlite_uint64 rowid = sqlite3_column_int64(selectStmt, 0);
        NSData *blobData = [NSData dataWithBytes:sqlite3_column_blob(selectStmt, 1) length:sqlite3_column_bytes(selectStmt, 1)];
        double visibleAt = sqlite3_column_double(selectStmt, 2);
        sqlite3_reset(selectStmt);
        
        
        
        // Task is scheduled for delay and the delay time has not yet happened
        if(visibleAt > 0 && visibleAt > [[NSDate date] timeIntervalSince1970] )
        {
            // If operation is being delayed determine for how long it is being delayed
            // we will wait the minimum waiting time
            delayUntil = visibleAt < delayUntil ? visibleAt : delayUntil;
        }
        
        
        NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingWithData:blobData];
        NSDictionary *userInfo = [unarchiver decodeObjectForKey:@"userInfo"];
        [unarchiver finishDecoding];

        IPOfflineQueueResult result = [self.delegate offlineQueue:self executeActionWithUserInfo:userInfo];
        if (result == IPOfflineQueueResultSuccess) {
            if (! deleteStmt && sqlite3_prepare_v2(db, "DELETE FROM queue WHERE ROWID = ?", -1, &deleteStmt, NULL) != SQLITE_OK) {
                [[NSException exceptionWithName:@"IPOfflineQueueDatabaseException" 
                    reason:@"Failed to prepare queue-item-delete statement" userInfo:nil
                ] raise];
            }
            
            sqlite3_bind_int64(deleteStmt, 1, rowid);
            if ([self stepQuery:deleteStmt] != SQLITE_DONE) {
                [[NSException exceptionWithName:@"IPOfflineQueueDatabaseException" 
                    reason:@"Failed to delete queued item after execution" userInfo:nil
                ] raise];
            }
            sqlite3_reset(deleteStmt);

        } else if (result == IPOfflineQueueResultFailureShouldPauseQueue) {
            // Pause queue, retry action later
            [updateThreadPausedLock lock];
            [updateThreadPausedLock unlockWithCondition:1];
        }

        if (backgroundTaskIdentifier != UIBackgroundTaskInvalid) [application endBackgroundTask:backgroundTaskIdentifier];
    }
    
    IPOfflineQueueDebugLog(@"Queue thread halting");
    
    // Cleanup threadmain
    if (selectStmt) sqlite3_finalize(selectStmt);
    if (deleteStmt) sqlite3_finalize(deleteStmt);

    if(delayUntil != DBL_MAX)
    {
        // Have an active record we need to delay for
        [self setDelayWorkUntilAtMost:[NSDate dateWithTimeIntervalSince1970:delayUntil]];
    }
    
    [updateThreadTerminatingLock lock];
    [updateThreadTerminatingLock unlockWithCondition:1];
}

- (void)halt
{
    @synchronized(self) {
        if (halted) return;
        halted = YES;

        if ([NSThread isMainThread]) {
            if (autoResumeTimer) {
                [autoResumeTimer invalidate];
                autoResumeTimer = nil;
            }    
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                if (autoResumeTimer) {
                    [autoResumeTimer invalidate];
                    autoResumeTimer = nil;
                }
            });
        }
    }
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillTerminateNotification object:nil];    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"kNetworkReachabilityChangedNotification" object:nil];    
    halt = YES;
    
    // Sync inserts
    [self syncInserts];
    dispatch_release(insertQueue);

    IPOfflineQueueDebugLog(@"halt: halting exec thread");
    // Halt queue-execution thread
    halt = YES;
    [updateThreadPausedLock lock];
    [updateThreadPausedLock unlockWithCondition:0];
    [updateThreadEmptyLock lock];
    [updateThreadEmptyLock unlockWithCondition:0];
    
    [updateThreadTerminatingLock lockWhenCondition:1];
    [updateThreadTerminatingLock unlock];
    
    IPOfflineQueueDebugLog(@"halt: done");
}

@end
