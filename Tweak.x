#import <substrate.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "fishhook.h"
#import "ZipHandler.h"

// HL_NAME / HL_VERSION / HL_AUTHOR are injected by the Makefile from `control`.
#ifndef HL_NAME
#define HL_NAME "HynisLoader"
#endif
#ifndef HL_VERSION
#define HL_VERSION "?"
#endif
#ifndef HL_AUTHOR
#define HL_AUTHOR "?"
#endif

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
                    NSLog(@"[HynisLoader] ✅ Pack: %@", customFile);
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
    NSLog(@"[HynisLoader] Cache built: %lu packs", (unsigned long)cache.count);
}

static NSString* findPackRoot(NSString* packId) {
    NSString *cached = packRootCache[packId];
    
    if (!cached) {
        NSLog(@"[HynisLoader] Cache miss for %@, rebuilding...", packId);
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

// Credit banner pinned to the top-left of Minecraft's window during the
// initial loading screen, then auto-dismissed before extended play.
//
// The banner is its own UIWindow above the game's window so it survives
// MCBE's view-hierarchy churn during launch. userInteractionEnabled = NO
// makes touches fall through to the game window underneath.
//
// Dismissal is time-based (BANNER_VISIBLE_SECONDS) rather than a hook on
// "loading complete" — fishhook can't see Mojang's internal lifecycle, and
// vtable-based detection of engine takeover would be a much larger change
// (see MCClient's known-limitations note on overlay scoping).
#define BANNER_VISIBLE_SECONDS 20.0
static UIWindow *gLoadingBanner = nil;

static UIWindowScene *findActiveWindowScene(void) {
    for (UIScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive ||
            scene.activationState == UISceneActivationStateForegroundInactive) {
            return (UIWindowScene *)scene;
        }
    }
    for (UIScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
        if ([scene isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)scene;
    }
    return nil;
}

static void showLoadingBanner(void) {
    UIWindowScene *scene = findActiveWindowScene();
    if (!scene) return;

    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.windowLevel = UIWindowLevelStatusBar + 100;
    window.backgroundColor = [UIColor clearColor];
    window.userInteractionEnabled = NO;

    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    window.rootViewController = vc;

    UIView *pill = [[UIView alloc] init];
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    pill.backgroundColor = [UIColor colorWithRed:0.05 green:0.07 blue:0.10 alpha:0.78];
    pill.layer.cornerRadius = 14.0;
    pill.layer.borderWidth = 1.0;
    pill.layer.borderColor = [UIColor colorWithRed:0.31 green:0.82 blue:0.77 alpha:0.55].CGColor;
    pill.layer.shadowColor = [UIColor blackColor].CGColor;
    pill.layer.shadowOpacity = 0.35;
    pill.layer.shadowRadius = 8.0;
    pill.layer.shadowOffset = CGSizeMake(0, 2);
    [vc.view addSubview:pill];

    UIFont *nameFont    = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    UIFont *versionFont = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    UIFont *authorFont  = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];

    UIColor *nameColor    = [UIColor colorWithRed:0.31 green:0.82 blue:0.77 alpha:1.0]; // teal
    UIColor *versionColor = [UIColor colorWithRed:0.96 green:0.88 blue:0.37 alpha:1.0]; // amber
    UIColor *authorColor  = [UIColor colorWithRed:0.70 green:0.74 blue:0.85 alpha:1.0]; // lavender-gray

    NSMutableAttributedString *att = [[NSMutableAttributedString alloc] init];
    [att appendAttributedString:[[NSAttributedString alloc]
        initWithString:@HL_NAME
            attributes:@{NSFontAttributeName: nameFont,
                         NSForegroundColorAttributeName: nameColor}]];
    [att appendAttributedString:[[NSAttributedString alloc]
        initWithString:@" v" HL_VERSION
            attributes:@{NSFontAttributeName: versionFont,
                         NSForegroundColorAttributeName: versionColor}]];
    [att appendAttributedString:[[NSAttributedString alloc]
        initWithString:@" by " HL_AUTHOR
            attributes:@{NSFontAttributeName: authorFont,
                         NSForegroundColorAttributeName: authorColor}]];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 1;
    label.attributedText = att;
    [pill addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [pill.leadingAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.leadingAnchor constant:12.0],
        [pill.topAnchor     constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor     constant:12.0],
        [label.topAnchor      constraintEqualToAnchor:pill.topAnchor      constant:8.0],
        [label.bottomAnchor   constraintEqualToAnchor:pill.bottomAnchor   constant:-8.0],
        [label.leadingAnchor  constraintEqualToAnchor:pill.leadingAnchor  constant:18.0],
        [label.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-18.0],
    ]];

    pill.alpha = 0.0;
    pill.transform = CGAffineTransformMakeTranslation(0, -8);

    window.hidden = NO;
    gLoadingBanner = window;

    [UIView animateWithDuration:0.45
                          delay:0.0
         usingSpringWithDamping:0.85
          initialSpringVelocity:0.0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        pill.alpha = 1.0;
        pill.transform = CGAffineTransformIdentity;
    } completion:nil];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(BANNER_VISIBLE_SECONDS * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.6 animations:^{
            pill.alpha = 0.0;
            pill.transform = CGAffineTransformMakeTranslation(0, -8);
        } completion:^(BOOL finished) {
            gLoadingBanner.hidden = YES;
            gLoadingBanner = nil;
        }];
    });
}

%ctor {
    buildPackRootCache();
    
    struct rebinding fopen_rebinding = {"fopen", hook_fopen, (void *)&orig_fopen};
    rebind_symbols(&fopen_rebinding, 1);
    
    if (orig_fopen) {
        NSLog(@"[HynisLoader] ✅ fopen hooked successfully");
    } else {
        NSLog(@"[HynisLoader] ❌ Failed to hook fopen");
    }
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        showLoadingBanner();
    });
}