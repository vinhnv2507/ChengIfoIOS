#import <Foundation/Foundation.h>
#import <stdio.h>
#import <unistd.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>

#import "ChengIOSBackup.h"

static void CIChmodPath(NSString *path, int mode) {
    if (path.length == 0) {
        return;
    }
    const char *raw = path.fileSystemRepresentation;
    if (raw) {
        chmod(raw, mode);
        lchown(raw, 501, 501);
    }
}

static NSDictionary *CIExecuteOp(NSString *op, NSDictionary *input) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"ok"] = @NO;
    result[@"uid"] = @(geteuid());
    result[@"daemon"] = @(getenv("CHENG_DAEMON") != NULL);
    NSError *error = nil;
    if ([op isEqualToString:@"backup"]) {
        NSDictionary *meta = ChengIOSCreateBackup(input[@"name"], input[@"bundles"], [input[@"includeAppData"] boolValue], &error);
        result[@"ok"] = @(meta != nil);
        if (meta) {
            result[@"meta"] = meta;
        }
    } else if ([op isEqualToString:@"restore"]) {
        BOOL ok = ChengIOSRestoreBackup(input[@"backupID"], [input[@"restoreProfile"] boolValue], [input[@"restoreAppData"] boolValue], &error);
        result[@"ok"] = @(ok);
        NSDictionary *stats = ChengIOSLastRestoreStats();
        if (stats.count > 0) {
            result[@"restoreStats"] = stats;
        }
    } else if ([op isEqualToString:@"erase"]) {
        NSDictionary *erase = ChengIOSEraseBundles(input[@"bundles"], &error);
        result[@"ok"] = @YES;
        result[@"result"] = erase ?: @{};
    } else if ([op isEqualToString:@"erase-safari"]) {
        NSDictionary *erase = ChengIOSEraseSafari(&error);
        result[@"ok"] = @YES;
        result[@"result"] = erase ?: @{};
    } else {
        result[@"error"] = @"bad op";
    }
    if (error) {
        result[@"error"] = error.localizedDescription ?: @"error";
        if (![result[@"ok"] boolValue]) {
            result[@"ok"] = @NO;
        }
    }
    return result;
}

static NSArray<NSString *> *CIInboxDirs(void) {
    return @[
        @"/var/mobile/Media/ChengIOS/.work/inbox",
        @"/private/var/mobile/Media/ChengIOS/.work/inbox"
    ];
}

static void CIWriteHeartbeat(void) {
    NSArray<NSString *> *roots = @[
        @"/var/mobile/Media/ChengIOS/.work",
        @"/private/var/mobile/Media/ChengIOS/.work"
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *root in roots) {
        [fm createDirectoryAtPath:[root stringByAppendingPathComponent:@"inbox"] withIntermediateDirectories:YES attributes:nil error:nil];
        CIChmodPath(root, 0777);
        CIChmodPath([root stringByAppendingPathComponent:@"inbox"], 0777);
        NSString *alive = [root stringByAppendingPathComponent:@"daemon.alive"];
        [@"ok" writeToFile:alive atomically:YES encoding:NSUTF8StringEncoding error:nil];
        CIChmodPath(alive, 0666);
    }
}

static void CIProcessInbox(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *inbox in CIInboxDirs()) {
        BOOL dir = NO;
        if (![fm fileExistsAtPath:inbox isDirectory:&dir] || !dir) {
            continue;
        }
        NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:inbox error:nil] ?: @[];
        for (NSString *name in names) {
            if (![name hasSuffix:@"-in.plist"]) {
                continue;
            }
            NSString *stamp = [name substringToIndex:name.length - 9];
            NSString *inPath = [inbox stringByAppendingPathComponent:name];
            NSString *outPath = [inbox stringByAppendingPathComponent:[stamp stringByAppendingString:@"-out.plist"]];
            if ([fm fileExistsAtPath:outPath]) {
                continue;
            }
            NSDictionary *input = [NSDictionary dictionaryWithContentsOfFile:inPath];
            if (![input isKindOfClass:[NSDictionary class]]) {
                [fm removeItemAtPath:inPath error:nil];
                continue;
            }
            NSString *op = input[@"op"];
            NSDictionary *result = CIExecuteOp(op, input);
            NSString *tmp = [outPath stringByAppendingString:@".tmp"];
            if ([result writeToFile:tmp atomically:YES]) {
                CIChmodPath(tmp, 0666);
                [fm removeItemAtPath:outPath error:nil];
                [fm moveItemAtPath:tmp toPath:outPath error:nil];
                CIChmodPath(outPath, 0666);
            }
            [fm removeItemAtPath:inPath error:nil];
        }
    }
}

static int CIRunDaemon(void) {
    setenv("CHENG_ROOT_HELPER", "1", 1);
    setenv("CHENG_DAEMON", "1", 1);
    while (1) {
        @autoreleasepool {
            setuid(0);
            setgid(0);
            if (geteuid() == 0) {
                CIWriteHeartbeat();
                CIProcessInbox();
            }
        }
        usleep(400000);
    }
    return 0;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        setenv("CHENG_ROOT_HELPER", "1", 1);
        setuid(0);
        setgid(0);
        if (argc >= 2 && strcmp(argv[1], "daemon") == 0) {
            return CIRunDaemon();
        }
        if (argc < 4) {
            fprintf(stderr, "usage: chengiosroot <op> <in.plist> <out.plist>\n");
            fprintf(stderr, "       chengiosroot daemon\n");
            return 2;
        }
        NSString *op = [NSString stringWithUTF8String:argv[1]];
        NSString *inPath = [NSString stringWithUTF8String:argv[2]];
        NSString *outPath = [NSString stringWithUTF8String:argv[3]];
        NSDictionary *input = [NSDictionary dictionaryWithContentsOfFile:inPath] ?: @{};
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        result[@"ok"] = @NO;
        result[@"uid"] = @(geteuid());
        result[@"daemon"] = @NO;
        if (geteuid() != 0) {
            result[@"error"] = @"chengiosroot uid != 0";
            [result writeToFile:outPath atomically:YES];
            return 1;
        }
        NSDictionary *done = CIExecuteOp(op, input);
        if ([done isKindOfClass:[NSDictionary class]]) {
            result = [done mutableCopy];
        }
        result[@"uid"] = @(geteuid());
        if (![result writeToFile:outPath atomically:YES]) {
            return 3;
        }
        return [result[@"ok"] boolValue] ? 0 : 1;
    }
}
