#import <Foundation/Foundation.h>
#import <stdio.h>
#import <unistd.h>
#import <stdlib.h>

#import "ChengIOSBackup.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        setenv("CHENG_ROOT_HELPER", "1", 1);
        setuid(0);
        setgid(0);
        if (argc < 4) {
            fprintf(stderr, "usage: chengiosroot <op> <in.plist> <out.plist>\n");
            return 2;
        }
        NSString *op = [NSString stringWithUTF8String:argv[1]];
        NSString *inPath = [NSString stringWithUTF8String:argv[2]];
        NSString *outPath = [NSString stringWithUTF8String:argv[3]];
        NSDictionary *input = [NSDictionary dictionaryWithContentsOfFile:inPath] ?: @{};
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        result[@"ok"] = @NO;
        result[@"uid"] = @(geteuid());
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
            if (!result[@"ok"]) {
                result[@"ok"] = @NO;
            }
        }
        if (![result writeToFile:outPath atomically:YES]) {
            return 3;
        }
        return [result[@"ok"] boolValue] ? 0 : 1;
    }
}
