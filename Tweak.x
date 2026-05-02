#import <substrate.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "fishhook.h"

#define VERSION "1.2"

static NSArray* getActiveResourcePacks(void);
static NSString* findFileInPack(NSString* packId, NSString* subpack, NSString* fileName);
static NSDictionary *packRootCache = nil;

// data path
static NSString* getResourcePacksPath(void) {
    NSString *docPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    return [docPath stringByAppendingPathComponent:@"games/com.mojang/resource_packs"];
}

// hook fopen
FILE* (*orig_fopen)(const char *path, const char *mode);
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
    
    NSArray *rootFolders = [fm contentsOfDirectoryAtPath:resPacks error:nil];
    NSMutableArray *allCandidates = [rootFolders mutableCopy];
    
    for (NSString *folder in rootFolders) {
        NSString *folderPath = [resPacks stringByAppendingPathComponent:folder];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:folderPath isDirectory:&isDir] && isDir) {
            for (NSString *sub in [fm contentsOfDirectoryAtPath:folderPath error:nil]) {
                NSString *subPath = [folderPath stringByAppendingPathComponent:sub];
                if ([fm fileExistsAtPath:subPath isDirectory:&isDir] && isDir) {
                    [allCandidates addObject:[NSString stringWithFormat:@"%@/%@", folder, sub]];
                }
            }
        }
    }
    
    // map uuid to path
    for (NSString *candidate in allCandidates) {
        NSString *manifestPath = [[resPacks stringByAppendingPathComponent:candidate] stringByAppendingPathComponent:@"manifest.json"];
        NSData *data = [NSData dataWithContentsOfFile:manifestPath];
        if (!data) continue;
        
        NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!manifest) continue;
        
        NSString *uuid = manifest[@"header"][@"uuid"];
        if (uuid) {
            cache[uuid] = [resPacks stringByAppendingPathComponent:candidate];
        }
        for (NSDictionary *mod in manifest[@"modules"]) {
            if (mod[@"uuid"]) {
                cache[mod[@"uuid"]] = [resPacks stringByAppendingPathComponent:candidate];
            }
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
        
        // subpacks
        if ([sp isEqualToString:@"default"]) {
            // default subpack: we find subpacks/default/renderer first. if it does not exist, fallback to renderer folder
            NSString *defaultPath = [[packRoot stringByAppendingPathComponent:@"subpacks/default"] stringByAppendingPathComponent:relativePath];
            if ([fm fileExistsAtPath:defaultPath]) {
                return defaultPath;
            }
        } else {
            // another subpack
            NSString *subpackPath = [[packRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"subpacks/%@", sp]] stringByAppendingPathComponent:relativePath];
            if ([fm fileExistsAtPath:subpackPath]) {
                return subpackPath;
            }
        }
        

        NSString *rootPath = [packRoot stringByAppendingPathComponent:relativePath];
        if ([fm fileExistsAtPath:rootPath]) {
            return rootPath;
        }
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
