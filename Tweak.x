#import <substrate.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "fishhook.h"
#import "ZipHandler.h"

#define VERSION "1.3"

static NSArray* getActiveResourcePacks(void);
static NSString* findFileInPack(NSString* packId, NSString* subpack, NSString* relativePath);
static NSDictionary *packRootCache = nil;

// data path
static NSString* getResourcePacksPath(void) {
    NSString *docPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    return [docPath stringByAppendingPathComponent:@"games/com.mojang/resource_packs"];
}

// fopen hook
static FILE* (*orig_fopen)(const char *path, const char *mode);

FILE* hook_fopen(const char *path, const char *mode) {
    if (path != NULL) {
        NSString *nsPath = [NSString stringWithUTF8String:path];
        
        // load whole renderer folder in pack
        if ([nsPath containsString:@"data/renderer"]) {
            NSRange rendererRange = [nsPath rangeOfString:@"/renderer/"];
            if (rendererRange.location != NSNotFound) {
                NSString *relativePath = [nsPath substringFromIndex:rendererRange.location + 1];
                
                NSString *customFile = findFileInPack(nil, nil, relativePath);
                if (customFile && [[NSFileManager defaultManager] fileExistsAtPath:customFile]) {
                    NSLog(@"[HynisPatcher] ✅ Pack: %@", customFile);
                    return orig_fopen([customFile UTF8String], mode);
                }
            }
        }
    }
    return orig_fopen(path, mode);
}

// get active pack lists
static NSArray* getActiveResourcePacks(void) {
    NSString *docPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    NSString *globalPacksPath = [docPath stringByAppendingPathComponent:@"games/com.mojang/minecraftpe/global_resource_packs.json"];
    
    NSData *data = [NSData dataWithContentsOfFile:globalPacksPath];
    if (!data) return nil;
    
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

static void buildPackRootCache(void) {
    NSString *resPacks = getResourcePacksPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableDictionary *cache = [NSMutableDictionary dictionary];
    
    NSArray *rootContents = [fm contentsOfDirectoryAtPath:resPacks error:nil];
    if (!rootContents) {
        packRootCache = cache;
        return;
    }
    
    NSMutableArray *candidates = [NSMutableArray array];
    
    for (NSString *item in rootContents) {
        NSString *itemPath = [resPacks stringByAppendingPathComponent:item];
        BOOL isDir = NO;
        [fm fileExistsAtPath:itemPath isDirectory:&isDir];
        
        if (isDir) {
            [candidates addObject:item];
            for (NSString *sub in [fm contentsOfDirectoryAtPath:itemPath error:nil]) {
                NSString *subPath = [itemPath stringByAppendingPathComponent:sub];
                if ([fm fileExistsAtPath:subPath isDirectory:&isDir] && isDir) {
                    [candidates addObject:[NSString stringWithFormat:@"%@/%@", item, sub]];
                }
            }
        } else {
            if (isArchivePack(itemPath)) {
                [candidates addObject:item];
            }
        }
    }
    
    for (NSString *candidate in candidates) {
        NSString *fullPath = [resPacks stringByAppendingPathComponent:candidate];
        NSDictionary *manifest = nil;
        
        if (isArchivePack(fullPath)) {
            NSData *manifestData = readFileFromZip(fullPath, @"manifest.json");
            if (manifestData) {
                manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil];
            }
        } else {
            NSString *manifestPath = [fullPath stringByAppendingPathComponent:@"manifest.json"];
            NSData *data = [NSData dataWithContentsOfFile:manifestPath];
            if (data) {
                manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            }
        }
        
        if (!manifest) continue;
        
        NSString *uuid = manifest[@"header"][@"uuid"];
        if (uuid) cache[uuid] = fullPath;
        
        for (NSDictionary *mod in manifest[@"modules"]) {
            NSString *modUuid = mod[@"uuid"];
            if (modUuid) cache[modUuid] = fullPath;
        }
    }
    
    packRootCache = cache;
    NSLog(@"[HynisPatcher] Cache built: %lu packs", (unsigned long)cache.count);
}

static NSString* findPackRoot(NSString* packId) {
    NSString *cached = packRootCache[packId];
    
    if (!cached) {
        NSLog(@"[HynisPatcher] Cache miss for %@, rebuilding...", packId);
        buildPackRootCache();
        cached = packRootCache[packId];
    }
    
    return cached;
}

// find material.bin and vibrant visuals config files in renderer folder
static NSString* findFileInPack(NSString* packId, NSString* subpack, NSString* relativePath) {
    NSArray *activePacks = getActiveResourcePacks();
    if (!activePacks) return nil;
    
    NSFileManager *fm = [NSFileManager defaultManager];
    
    for (NSDictionary *pack in activePacks) {
        NSString *pid = packId ?: pack[@"pack_id"];
        NSString *sp = subpack ?: pack[@"subpack"] ?: @"default";
        if (!pid) continue;
        
        NSString *packRoot = findPackRoot(pid);
        if (!packRoot) continue;
        
        // archive pack (.zip/.mcpack)
        if (isArchivePack(packRoot)) {
            if (![sp isEqualToString:@"default"]) {
                NSString *subpackRelative = [NSString stringWithFormat:@"subpacks/%@/%@", sp, relativePath];
                NSString *tempFile = extractFileFromZip(packRoot, subpackRelative);
                if (tempFile) return tempFile;
            }

            if ([sp isEqualToString:@"default"]) {
                NSString *defaultRelative = [NSString stringWithFormat:@"subpacks/default/%@", relativePath];
                NSString *tempFile = extractFileFromZip(packRoot, defaultRelative);
                if (tempFile) return tempFile;
            }

            NSString *tempFile = extractFileFromZip(packRoot, relativePath);
            if (tempFile) return tempFile;

            continue;
        }
        
        // directory pack
        if ([sp isEqualToString:@"default"]) {
            NSString *defaultPath = [[packRoot stringByAppendingPathComponent:@"subpacks/default"]
                                      stringByAppendingPathComponent:relativePath];
            if ([fm fileExistsAtPath:defaultPath]) return defaultPath;
        } else {
            NSString *subpackPath = [[packRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"subpacks/%@", sp]]
                                      stringByAppendingPathComponent:relativePath];
            if ([fm fileExistsAtPath:subpackPath]) return subpackPath;
        }
        
        NSString *rootPath = [packRoot stringByAppendingPathComponent:relativePath];
        if ([fm fileExistsAtPath:rootPath]) return rootPath;
    }
    
    return nil;
}

static void showDialog(NSString* title, NSString* message) {
    UIAlertController *alert = [UIAlertController 
        alertControllerWithTitle:title
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    
    UIWindow *gameWindow = nil;
    for (UIScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow) {
                    gameWindow = window;
                    break;
                }
            }
            if (!gameWindow) gameWindow = windowScene.windows.firstObject;
            break;
        }
    }
    
    if (!gameWindow) return;
    
    UIViewController *rootVC = gameWindow.rootViewController;
    while (rootVC.presentedViewController) {
        rootVC = rootVC.presentedViewController;
    }
    
    [rootVC presentViewController:alert animated:YES completion:nil];
}

%ctor {
    buildPackRootCache();
    
    struct rebinding fopen_rebinding = {"fopen", hook_fopen, (void *)&orig_fopen};
    rebind_symbols(&fopen_rebinding, 1);
    
    if (orig_fopen) {
        NSLog(@"[HynisPatcher] ✅ fopen hooked successfully");
    } else {
        NSLog(@"[HynisPatcher] ❌ Failed to hook fopen");
    }
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSString *title = @"Hynis Patcher";
        NSString *desc = [NSString stringWithFormat:@"Version: %s\nDeveloper: congcq\nNote: shader must be activated in global resource to work", VERSION];
        showDialog(title, desc);
    });
}