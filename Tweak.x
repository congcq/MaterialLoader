#import <substrate.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdatomic.h>
#import <dlfcn.h>

#import "fishhook.h"
#import "ZipHandler.h"

#ifdef DEBUG
#define HLog(...) NSLog(__VA_ARGS__)
#else
#define HLog(...)
#endif

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

// Cache snapshots (immutable) guarded by a concurrent queue.
// - packRootCache: uuid -> packRootPath (directory or archive path)
// - rendererPackIds: uuids that contain a "renderer/" folder (root or subpacks)
static NSDictionary *packRootCache = nil;
static NSSet<NSString *> *rendererPackIds = nil;
static dispatch_queue_t gPackCacheQueue = nil;
static atomic_bool gPackCacheRebuildScheduled = ATOMIC_VAR_INIT(false);

// Active packs cache (global_resource_packs.json) + resolved renderer file cache.
static NSArray *gActivePacksCache = nil;
static NSDate *gActivePacksMTime = nil;
static NSNumber *gActivePacksSize = nil;
static CFAbsoluteTime gActivePacksLastStatCheck = 0.0;
static NSMutableDictionary<NSString *, id> *gResolvedRendererPathCache = nil; // relativePath -> NSString | NSNull

// data path
static NSString* getResourcePacksPath(void) {
    NSString *docPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    return [docPath stringByAppendingPathComponent:@"games/com.mojang/resource_packs"];
}

static NSString* getGlobalPacksPath(void) {
    NSString *docPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    return [docPath stringByAppendingPathComponent:@"games/com.mojang/minecraftpe/global_resource_packs.json"];
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
                    HLog(@"[HynisLoader] ✅ Pack: %@", customFile);
                    return orig_fopen([customFile UTF8String], mode);
                }
            }
        }
    }
    return orig_fopen(path, mode);
}

// get active pack lists
static NSArray* getActiveResourcePacks(void) {
    // Stat calls are cheap, but still avoid doing them *too* often on fopen hot-path.
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gActivePacksCache && (now - gActivePacksLastStatCheck) < 0.25) {
        return gActivePacksCache;
    }
    gActivePacksLastStatCheck = now;

    NSString *globalPacksPath = getGlobalPacksPath();
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:globalPacksPath error:nil];
    if (!attrs) return gActivePacksCache;

    NSDate *mtime = attrs[NSFileModificationDate];
    NSNumber *size = attrs[NSFileSize];

    __block BOOL unchanged = NO;
    if (gPackCacheQueue) {
        dispatch_sync(gPackCacheQueue, ^{
            unchanged = (gActivePacksCache != nil &&
                         ((gActivePacksMTime == mtime) || [gActivePacksMTime isEqualToDate:mtime]) &&
                         ((gActivePacksSize == size) || [gActivePacksSize isEqualToNumber:size]));
        });
    } else {
        unchanged = (gActivePacksCache != nil &&
                     ((gActivePacksMTime == mtime) || [gActivePacksMTime isEqualToDate:mtime]) &&
                     ((gActivePacksSize == size) || [gActivePacksSize isEqualToNumber:size]));
    }

    if (unchanged) {
        return gActivePacksCache;
    }

    NSData *data = [NSData dataWithContentsOfFile:globalPacksPath];
    if (!data) return gActivePacksCache;

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSArray class]]) return gActivePacksCache;

    NSArray *packs = (NSArray *)json;

    if (gPackCacheQueue) {
        dispatch_barrier_async(gPackCacheQueue, ^{
            gActivePacksCache = packs;
            gActivePacksMTime = mtime;
            gActivePacksSize = size;
            [gResolvedRendererPathCache removeAllObjects]; // active selection changed -> invalidate resolved paths
        });
    } else {
        gActivePacksCache = packs;
        gActivePacksMTime = mtime;
        gActivePacksSize = size;
        [gResolvedRendererPathCache removeAllObjects];
    }

    return packs;
}

static BOOL directoryPackHasRenderer(NSString *packRoot) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;

    NSString *rootRenderer = [packRoot stringByAppendingPathComponent:@"renderer"];
    if ([fm fileExistsAtPath:rootRenderer isDirectory:&isDir] && isDir) return YES;

    NSString *subpacksRoot = [packRoot stringByAppendingPathComponent:@"subpacks"];
    if (![fm fileExistsAtPath:subpacksRoot isDirectory:&isDir] || !isDir) return NO;

    NSArray *subs = [fm contentsOfDirectoryAtPath:subpacksRoot error:nil];
    if (!subs) return NO;
    for (NSString *sp in subs) {
        NSString *spRenderer = [[subpacksRoot stringByAppendingPathComponent:sp] stringByAppendingPathComponent:@"renderer"];
        if ([fm fileExistsAtPath:spRenderer isDirectory:&isDir] && isDir) return YES;
    }
    return NO;
}

static BOOL archivePackHasRenderer(NSString *archivePath) {
    FILE *f = fopen([archivePath UTF8String], "rb");
    if (!f) return NO;

    BOOL found = NO;
    uint8_t buf[1024];

    // Scan local file headers like ZipHandler does, but only to detect renderer paths.
    while (fread(buf, 1, 4, f) == 4) {
        uint32_t signature = *(uint32_t*)buf;
        if (signature != 0x04034b50) break;

        if (fread(buf, 1, 26, f) != 26) break;
        uint16_t nameLen  = *(uint16_t*)(buf + 22);
        uint16_t extraLen = *(uint16_t*)(buf + 24);
        uint32_t compSize = *(uint32_t*)(buf + 14);

        char name[512] = {0};
        if (nameLen > 0 && nameLen < sizeof(name)) {
            if (fread(name, 1, nameLen, f) != nameLen) break;
        } else {
            // Name too long for our buffer; skip it safely.
            fseek(f, nameLen, SEEK_CUR);
        }
        fseek(f, extraLen, SEEK_CUR);

        if (name[0] != '\0') {
            NSString *fileName = [NSString stringWithUTF8String:name];
            if ([fileName hasPrefix:@"renderer/"]) {
                found = YES;
                break;
            }
            // subpacks/<any>/renderer/...
            NSRange r = [fileName rangeOfString:@"/renderer/"];
            if (r.location != NSNotFound && [fileName hasPrefix:@"subpacks/"]) {
                found = YES;
                break;
            }
        }

        fseek(f, compSize, SEEK_CUR);
    }

    fclose(f);
    return found;
}

static void buildPackRootCache(void) {
    NSString *resPacks = getResourcePacksPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableDictionary *cache = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *rendererIds = [NSMutableSet set];
    
    NSArray *rootContents = [fm contentsOfDirectoryAtPath:resPacks error:nil];
    if (!rootContents) {
        if (gPackCacheQueue) {
            dispatch_barrier_async(gPackCacheQueue, ^{
                packRootCache = cache;
                rendererPackIds = rendererIds;
                [gResolvedRendererPathCache removeAllObjects];
            });
        } else {
            packRootCache = cache;
            rendererPackIds = rendererIds;
            [gResolvedRendererPathCache removeAllObjects];
        }
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
        BOOL hasRenderer = NO;
        
        if (isArchivePack(fullPath)) {
            NSData *manifestData = readFileFromZip(fullPath, @"manifest.json");
            if (manifestData) {
                manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil];
            }
            hasRenderer = archivePackHasRenderer(fullPath);
        } else {
            NSString *manifestPath = [fullPath stringByAppendingPathComponent:@"manifest.json"];
            NSData *data = [NSData dataWithContentsOfFile:manifestPath];
            if (data) {
                manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            }
            hasRenderer = directoryPackHasRenderer(fullPath);
        }
        
        if (!manifest) continue;
        
        NSString *uuid = manifest[@"header"][@"uuid"];
        if (uuid) {
            cache[uuid] = fullPath;
            if (hasRenderer) [rendererIds addObject:uuid];
        }
        
        for (NSDictionary *mod in manifest[@"modules"]) {
            NSString *modUuid = mod[@"uuid"];
            if (modUuid) {
                cache[modUuid] = fullPath;
                if (hasRenderer) [rendererIds addObject:modUuid];
            }
        }
    }
    
    if (gPackCacheQueue) {
        dispatch_barrier_async(gPackCacheQueue, ^{
            packRootCache = cache;
            rendererPackIds = rendererIds;
            [gResolvedRendererPathCache removeAllObjects];
        });
    } else {
        packRootCache = cache;
        rendererPackIds = rendererIds;
        [gResolvedRendererPathCache removeAllObjects];
    }
    HLog(@"[HynisLoader] Cache built: %lu ids (%lu with renderer)",
          (unsigned long)cache.count, (unsigned long)rendererIds.count);
}

static NSString* findPackRoot(NSString* packId) {
    __block NSDictionary *cacheSnap = nil;
    if (gPackCacheQueue) {
        dispatch_sync(gPackCacheQueue, ^{
            cacheSnap = packRootCache;
        });
    } else {
        cacheSnap = packRootCache;
    }

    NSString *cached = cacheSnap[packId];
    
    if (!cached) {
        // Avoid blocking the caller (fopen hot-path). Schedule a rebuild once.
        bool alreadyScheduled = atomic_exchange(&gPackCacheRebuildScheduled, true);
        if (!alreadyScheduled) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                buildPackRootCache();
                atomic_store(&gPackCacheRebuildScheduled, false);
            });
        }
    }
    
    return cached;
}

// find material.bin and vibrant visuals config files in renderer folder
static NSString* findFileInPack(NSString* packId, NSString* subpack, NSString* relativePath) {
    NSArray *activePacks = getActiveResourcePacks();
    if (!activePacks) return nil;
    
    NSFileManager *fm = [NSFileManager defaultManager];

    __block NSSet<NSString *> *rendererIdsSnap = nil;
    if (gPackCacheQueue) {
        dispatch_sync(gPackCacheQueue, ^{
            rendererIdsSnap = rendererPackIds;
        });
    } else {
        rendererIdsSnap = rendererPackIds;
    }

    // Fast path: resolved cache for current activePacks snapshot.
    __block id cachedResolved = nil;
    if (gPackCacheQueue) {
        dispatch_sync(gPackCacheQueue, ^{
            cachedResolved = gResolvedRendererPathCache[relativePath];
        });
    } else {
        cachedResolved = gResolvedRendererPathCache[relativePath];
    }
    if (cachedResolved) {
        if (cachedResolved == (id)[NSNull null]) return nil;
        if ([cachedResolved isKindOfClass:[NSString class]] && [fm fileExistsAtPath:(NSString *)cachedResolved]) {
            return (NSString *)cachedResolved;
        }
        // Stale entry (e.g. temp got wiped); fall through and recompute.
    }
    
    for (NSDictionary *pack in activePacks) {
        NSString *pid = packId ?: pack[@"pack_id"];
        NSString *sp = subpack ?: pack[@"subpack"] ?: @"default";
        if (!pid) continue;

        // If we have a renderer-only index, skip packs that can't override renderer files.
        if (rendererIdsSnap && ![rendererIdsSnap containsObject:pid]) {
            continue;
        }
        
        NSString *packRoot = findPackRoot(pid);
        if (!packRoot) continue;
        
        // archive pack (.zip/.mcpack)
        if (isArchivePack(packRoot)) {
            if (![sp isEqualToString:@"default"]) {
                NSString *subpackRelative = [NSString stringWithFormat:@"subpacks/%@/%@", sp, relativePath];
                NSString *tempFile = extractFileFromZip(packRoot, subpackRelative);
                if (tempFile) {
                    if (gPackCacheQueue) {
                        dispatch_barrier_async(gPackCacheQueue, ^{ gResolvedRendererPathCache[relativePath] = tempFile; });
                    } else {
                        gResolvedRendererPathCache[relativePath] = tempFile;
                    }
                    return tempFile;
                }
            }

            if ([sp isEqualToString:@"default"]) {
                NSString *defaultRelative = [NSString stringWithFormat:@"subpacks/default/%@", relativePath];
                NSString *tempFile = extractFileFromZip(packRoot, defaultRelative);
                if (tempFile) {
                    if (gPackCacheQueue) {
                        dispatch_barrier_async(gPackCacheQueue, ^{ gResolvedRendererPathCache[relativePath] = tempFile; });
                    } else {
                        gResolvedRendererPathCache[relativePath] = tempFile;
                    }
                    return tempFile;
                }
            }

            NSString *tempFile = extractFileFromZip(packRoot, relativePath);
            if (tempFile) {
                if (gPackCacheQueue) {
                    dispatch_barrier_async(gPackCacheQueue, ^{ gResolvedRendererPathCache[relativePath] = tempFile; });
                } else {
                    gResolvedRendererPathCache[relativePath] = tempFile;
                }
                return tempFile;
            }

            continue;
        }
        
        // directory pack
        if ([sp isEqualToString:@"default"]) {
            NSString *defaultPath = [[packRoot stringByAppendingPathComponent:@"subpacks/default"]
                                      stringByAppendingPathComponent:relativePath];
            if ([fm fileExistsAtPath:defaultPath]) {
                if (gPackCacheQueue) {
                    dispatch_barrier_async(gPackCacheQueue, ^{ gResolvedRendererPathCache[relativePath] = defaultPath; });
                } else {
                    gResolvedRendererPathCache[relativePath] = defaultPath;
                }
                return defaultPath;
            }
        } else {
            NSString *subpackPath = [[packRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"subpacks/%@", sp]]
                                      stringByAppendingPathComponent:relativePath];
            if ([fm fileExistsAtPath:subpackPath]) {
                if (gPackCacheQueue) {
                    dispatch_barrier_async(gPackCacheQueue, ^{ gResolvedRendererPathCache[relativePath] = subpackPath; });
                } else {
                    gResolvedRendererPathCache[relativePath] = subpackPath;
                }
                return subpackPath;
            }
        }
        
        NSString *rootPath = [packRoot stringByAppendingPathComponent:relativePath];
        if ([fm fileExistsAtPath:rootPath]) {
            if (gPackCacheQueue) {
                dispatch_barrier_async(gPackCacheQueue, ^{ gResolvedRendererPathCache[relativePath] = rootPath; });
            } else {
                gResolvedRendererPathCache[relativePath] = rootPath;
            }
            return rootPath;
        }
    }

    if (gPackCacheQueue) {
        dispatch_barrier_async(gPackCacheQueue, ^{ gResolvedRendererPathCache[relativePath] = (id)[NSNull null]; });
    } else {
        gResolvedRendererPathCache[relativePath] = (id)[NSNull null];
    }
    
    return nil;
}

// Bottom-centered credit banner shown for BANNER_VISIBLE_SECONDS after launch.
#define BANNER_VISIBLE_SECONDS 20.0
static UIWindow *gLoadingBanner = nil;
static UIView *gLoadingBannerView = nil;
static CALayer *gLoadingBannerLayer = nil;

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

    // Reuse MCBE's existing window — a separate UIWindow above it breaks
    // game-style gesture handling.
    UIWindow *gameWindow = nil;
    for (UIWindow *w in scene.windows) {
        if (w.isKeyWindow) { gameWindow = w; break; }
    }
    if (!gameWindow) {
        for (UIWindow *w in scene.windows) {
            if (w.windowLevel == UIWindowLevelNormal) { gameWindow = w; break; }
        }
    }
    if (!gameWindow) return;

    // Attach to the window's CALayer, not the MTKView's CAMetalLayer.
    UIView *hostView = gameWindow;
    CALayer *hostLayer = gameWindow.layer;

    // Ensure we don't stack multiple banners.
    if (gLoadingBannerView) {
        [gLoadingBannerView removeFromSuperview];
        gLoadingBannerView = nil;
    }
    if (gLoadingBannerLayer) {
        [gLoadingBannerLayer removeFromSuperlayer];
        gLoadingBannerLayer = nil;
    }

    UIFont *nameFont    = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    UIFont *versionFont = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    UIFont *authorFont  = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
    UIFont *fpsFont     = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];

    UIColor *nameColor    = [UIColor colorWithRed:0.31 green:0.82 blue:0.77 alpha:1.0]; // teal
    UIColor *versionColor = [UIColor colorWithRed:0.96 green:0.88 blue:0.37 alpha:1.0]; // amber
    UIColor *authorColor  = [UIColor colorWithRed:0.70 green:0.74 blue:0.85 alpha:1.0]; // lavender-gray
    UIColor *fpsHighColor = [UIColor colorWithRed:0.40 green:0.85 blue:0.50 alpha:1.0]; // green = upgraded
    UIColor *fpsLowColor  = authorColor;                                                // grey = default 60

    // Effective FPS cap from HyniSwizzleFPS via dlsym; absent dylib → 60.
    int fpsCap = 60;
    int (*hsfps_effective_cap)(void) = dlsym(RTLD_DEFAULT, "HSFPS_EffectiveCap");
    if (hsfps_effective_cap) fpsCap = hsfps_effective_cap();

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
    [att appendAttributedString:[[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@" @ %dFPS", fpsCap]
            attributes:@{NSFontAttributeName: fpsFont,
                         NSForegroundColorAttributeName:
                             (fpsCap > 60 ? fpsHighColor : fpsLowColor)}]];

    // Bottom-centered just above the home-indicator graphic.
    UIEdgeInsets insets = gameWindow.safeAreaInsets;

    const CGFloat outerPadX = 12.0;
    const CGFloat bottomGap = 16.0;
    const CGFloat innerPadX = 18.0;
    const CGFloat innerPadY = 8.0;
    const CGFloat maxWidth = 460.0;

    CGSize hostSize = hostView.bounds.size;
    if (hostSize.width < 10.0 || hostSize.height < 10.0) {
        hostSize = gameWindow.bounds.size;
    }

    CGFloat availableWidth = MAX(0.0, hostSize.width - (insets.left + insets.right) - outerPadX * 2.0);
    CGFloat pillMaxWidth = MIN(maxWidth, availableWidth);

    CGRect textRect = [att boundingRectWithSize:CGSizeMake(MAX(0.0, pillMaxWidth - innerPadX * 2.0), CGFLOAT_MAX)
                                       options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                       context:nil];
    CGFloat pillW = MIN(pillMaxWidth, ceil(CGRectGetWidth(textRect)) + innerPadX * 2.0);
    CGFloat pillH = ceil(CGRectGetHeight(textRect)) + innerPadY * 2.0;

    CGFloat pillX = (hostSize.width - pillW) / 2.0;
    CGFloat pillY = hostSize.height - bottomGap - pillH;
    CGRect pillFrame = CGRectMake(pillX, pillY, pillW, pillH);

    CALayer *container = [CALayer layer];
    container.name = @"HLBannerContainer";
    container.frame = pillFrame;
    container.opacity = 0.0f;
    container.transform = CATransform3DMakeTranslation(0, 8, 0);
    container.masksToBounds = NO;

    CALayer *bg = [CALayer layer];
    bg.name = @"HLBannerBG";
    bg.frame = container.bounds;
    bg.backgroundColor = [UIColor colorWithRed:0.05 green:0.07 blue:0.10 alpha:0.78].CGColor;
    bg.cornerRadius = 14.0;
    bg.borderWidth = 1.0;
    bg.borderColor = [UIColor colorWithRed:0.31 green:0.82 blue:0.77 alpha:0.55].CGColor;
    bg.shadowColor = [UIColor blackColor].CGColor;
    bg.shadowOpacity = 0.35f;
    bg.shadowRadius = 8.0f;
    bg.shadowOffset = CGSizeMake(0, 2);
    bg.shadowPath = [UIBezierPath bezierPathWithRoundedRect:bg.bounds cornerRadius:bg.cornerRadius].CGPath;
    [container addSublayer:bg];

    CATextLayer *text = [CATextLayer layer];
    text.name = @"HLBannerText";
    text.contentsScale = [UIScreen mainScreen].scale;
    text.frame = CGRectMake(innerPadX, innerPadY, pillW - innerPadX * 2.0, pillH - innerPadY * 2.0);
    text.alignmentMode = kCAAlignmentCenter;
    text.wrapped = NO;
    text.truncationMode = kCATruncationEnd;
    text.string = att;
    [container addSublayer:text];

    [hostLayer addSublayer:container];

    gLoadingBannerLayer = container;

    [UIView animateWithDuration:0.45
                          delay:0.0
         usingSpringWithDamping:0.85
          initialSpringVelocity:0.0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        container.opacity = 1.0f;
        container.transform = CATransform3DIdentity;
    } completion:nil];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(BANNER_VISIBLE_SECONDS * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.6 animations:^{
            container.opacity = 0.0f;
            container.transform = CATransform3DMakeTranslation(0, 8, 0);
        } completion:^(BOOL finished) {
            gLoadingBannerView = nil;
            [gLoadingBannerLayer removeFromSuperlayer];
            gLoadingBannerLayer = nil;
            gLoadingBanner = nil;
        }];
    });
}

%ctor {
    gPackCacheQueue = dispatch_queue_create("com.hynisloader.packcache", DISPATCH_QUEUE_CONCURRENT);
    gResolvedRendererPathCache = [[NSMutableDictionary alloc] init];

    // Build caches in the background to avoid blocking app launch.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        buildPackRootCache();
    });
    
    struct rebinding fopen_rebinding = {"fopen", hook_fopen, (void *)&orig_fopen};
    rebind_symbols(&fopen_rebinding, 1);
    
    if (orig_fopen) {
        HLog(@"[HynisLoader] ✅ fopen hooked successfully");
    } else {
        HLog(@"[HynisLoader] ❌ Failed to hook fopen");
    }
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        showLoadingBanner();
    });
}
