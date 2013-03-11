//
//  KHolder.m
//  KacheDemo
//
//  Created by jiajun on 7/25/12.
//  Copyright (c) 2012 __MyCompanyName__. All rights reserved.
//

#define Kache_Objects_Disk_Path         @"Caches/Kache_objects"

#import "KConfig.h"
#import "KHolder.h"
#import "KObject.h"
#import "KPool.h"
#import "KQueue.h"
#import "KUtil.h"

@interface KHolder ()

// 正在进行归档的状态位
@property (assign, atomic)      BOOL                        archiving;
@property (strong, atomic)      NSMutableArray              *keys;
@property (assign, nonatomic)   NSUInteger                  size;
@property (strong, nonatomic)   NSMutableDictionary         *objects;
@property (strong, nonatomic)   NSFileManager               *fileManager;

// 把数据写到磁盘
- (void)archiveData;

- (void)cleanExpiredObjects;

@end

@implementation KHolder

@synthesize fileManager = _fileManager;
// 缓存Key列表
@synthesize keys        = _keys;
// 缓存大小
@synthesize size        = _size;
// 缓存内容
@synthesize objects     = _objects;

#pragma mark - init

- (id)init
{
    self = [super init];
    if (self) {
        self.objects = [[NSMutableDictionary alloc] init];
        self.keys = [[NSMutableArray alloc] init];
        self.size = 0.0f;
        self.fileManager = [NSFileManager defaultManager];
        return self;
    }

    return nil;
}

#pragma mark - private

- (void)archiveData
{
    self.archiving = YES;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
	NSString *libDirectory = [paths objectAtIndex:0];
	NSString *path = [libDirectory stringByAppendingPathComponent:Kache_Objects_Disk_Path];
    BOOL isDirectory = NO;
    if (! [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory]) {
        [self.fileManager createDirectoryAtPath:path
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    }
    NSMutableArray *copiedKeys = [self.keys mutableCopy];
    while (0 < [copiedKeys count]) {
        // 归档至阈值一半的数据
        if ((ARCHIVING_THRESHOLD / 2) > self.size) {
            break;
        }
        NSString *key = [copiedKeys lastObject];
        NSString *filePath = [path stringByAppendingPathComponent:key];
        
        NSData *data = [self.objects objectForKey:key];
        [self.fileManager createFileAtPath:filePath contents:data attributes:nil];
        [self.objects removeObjectForKey:key];
        self.size -= data.length;
        [copiedKeys removeLastObject];
    }
    self.archiving = NO;
}

- (void)cleanExpiredObjects
{
    if (self.keys && 0 < [self.keys count]) {
        for (int i = 0; i < [self.keys count] - 1; i ++) {
            NSString *tmpKey = [self.keys objectAtIndex:i];
            KObject *leftObject = [self objectForKey:tmpKey];
            if ([leftObject expiredTimestamp] < [KUtil nowTimestamp]) {
                [self.keys removeObject:tmpKey];
                if ([[self.objects allKeys] containsObject:tmpKey]) {
                    [self.objects removeObjectForKey:tmpKey];
                }
                else {
                    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
                    NSString *libDirectory = [paths objectAtIndex:0];
                    NSString *path = [libDirectory stringByAppendingPathComponent:Kache_Objects_Disk_Path];
                    NSString *filePath = [path stringByAppendingPathComponent:tmpKey];
                    [self.fileManager removeItemAtPath:filePath error:nil];
                }
            }
            else {
                break;
            }
        }
    }
}

#pragma mark - public

- (void)removeObjectForKey:(NSString *)key {
    [self.keys removeObject:key];
    [self.objects removeObjectForKey:key];
}

- (void)setValue:(id)value forKey:(NSString *)key expiredAfter:(NSInteger)duration
{
    KObject *object = [[KObject alloc] initWithData:value andLifeDuration:duration];

    if (self.archiving) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
        NSString *libDirectory = [paths objectAtIndex:0];
        NSString *path = [libDirectory stringByAppendingPathComponent:Kache_Objects_Disk_Path];
        NSString *filePath = [path stringByAppendingPathComponent:key];
        [self.fileManager createFileAtPath:filePath contents:object.data attributes:nil];
    }
    else {
        [self.objects setValue:object.data forKey:key];
        self.size += [object size];
    }
    
    KObject *suchObject = [self objectForKey:key];

    // TODO sort the key by expired time.
    [self.keys removeObject:key];
    
    if (0 < [self.keys count]) {
        [self cleanExpiredObjects];

        for (int i = [self.keys count] - 1; i >= 0; i --) {
            NSString *tmpKey = [self.keys objectAtIndex:i];
            KObject *leftObject = [self objectForKey:tmpKey];
            // 过期时间越晚
            if ([leftObject expiredTimestamp] <= [suchObject expiredTimestamp]) {
                if (([self.keys count] - 1) == i) {
                    [self.keys addObject:key];
                }
                else {
                    [self.keys insertObject:key atIndex:i + 1];
                }
                break;
            }
        }
    }
    if (! [self.keys containsObject:key]) {
        [self.keys insertObject:key atIndex:0];
    }
    
    // 超过阈值，归档
    if ((! self.archiving)
        && 0 < ARCHIVING_THRESHOLD
        && ARCHIVING_THRESHOLD < self.size) {
        [self archiveData];
    }
}

- (id)valueForKey:(NSString *)key
{
    KObject *object = [self objectForKey:key];
    if (object && ! [object expired]) {
        return [object value];
    }
    // No such object.
    return nil;
}

- (KObject *)objectForKey:(NSString *)key
{
    if ([[self.objects allKeys] containsObject:key]) {
        return [[KObject alloc] initWithData:[self.objects objectForKey:key]];
    }
    else {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
        NSString *libDirectory = [paths objectAtIndex:0];
        NSString *path = [libDirectory stringByAppendingPathComponent:Kache_Objects_Disk_Path];
        NSString *filePath = [path stringByAppendingPathComponent:key];
        if ([self.fileManager fileExistsAtPath:filePath isDirectory:NO]) {
            [self.objects setValue:[NSData dataWithContentsOfFile:filePath] forKey:key];
            [self.fileManager removeItemAtPath:filePath error:nil];
            return [[KObject alloc] initWithData:[self.objects objectForKey:key]];
        }
    }
    
    return nil;
}

// Convert object to NSDictionary.
- (NSDictionary *)serialize
{
    return [NSDictionary dictionaryWithObjectsAndKeys:
            self.objects, @"objects",
            self.keys, @"keys",
            [NSString stringWithFormat:@"%d", self.size], @"size",
            nil];
}

// Convert NSDictionary to object.
- (void)unserializeFrom:(NSDictionary *)dict
{
    if ([[dict allKeys] containsObject:@"objects"]
        && [[dict allKeys] containsObject:@"keys"]
        && [[dict allKeys] containsObject:@"meta"]) {
        self.objects = [dict objectForKey:@"objects"];
        self.keys = [dict objectForKey:@"keys"];
        self.size = [[dict objectForKey:@"size"] intValue];
    }
}

@end
