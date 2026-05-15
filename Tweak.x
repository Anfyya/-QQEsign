
// QQESign — 免越狱轻松签版 (NT架构)
// 防撤回持久化 / 闪照无限查看 / 自定义电量
// Target: com.tencent.mqq (arm64) — sideload injection

%config(generator=internal)

// ═══════════════════════════════════════════════════
// 架构说明 (NT QQ)
// ═══════════════════════════════════════════════════
// QQ NT 架构已将大量逻辑迁移至 Swift，ObjC 层只保留了
// 部分 bridge 类。以下 hook 点均经过 ObjC classlist 验证，
// 确认在当前版本 QQ 二进制中实际存在。
//
// 防撤回：
//   保守稳定版：移除全局 selector 扫描与宽泛类名匹配，
//   仅保留主序中已确认存在、且 type encoding 已核对的显式 hook。
//   同时将安装时机后移，减少 ctor 阶段全局扫描导致的开屏闪退风险。
//
// 闪照：
//   OCPicElement / QQBasePhoto.isFlashPic 返回 NO 即可解除
//   所有闪照限制（倒计时、保存限制、次数限制）。
//   NT Swift VC 的 hideFlashImgPreview / finishFlashImgPreview
//   也可拦截使图片不消失。
// ═══════════════════════════════════════════════════

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Photos/Photos.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

// ─────────────────────────────────────────────
#pragma mark - Preferences (sandbox-safe)
// ─────────────────────────────────────────────

static NSString *const kPrefSuite = @"com.qqesign.prefs";

static BOOL   pref_antiRevoke     = YES;
static BOOL   pref_flashUnlimited = YES;
static BOOL   pref_qzoneAdBlock   = YES;
static BOOL   pref_fakeBattery    = NO;
static float  pref_batteryLevel   = 0.80f;
static BOOL   pref_isCharging     = NO;

// 主页头像侧边抽屉入口屏蔽 (7 项, 默认全关)
static BOOL   pref_drawerHideAlbum    = NO;
static BOOL   pref_drawerHideFavorite = NO;
static BOOL   pref_drawerHideFiles    = NO;
static BOOL   pref_drawerHideWallet   = NO;
static BOOL   pref_drawerHideVip      = NO;
static BOOL   pref_drawerHideDecor    = NO;
static BOOL   pref_drawerHideFreedata = NO;

static NSUserDefaults *tweakDefaults(void) {
    static NSUserDefaults *ud = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ud = [[NSUserDefaults alloc] initWithSuiteName:kPrefSuite];
        [ud registerDefaults:@{
            @"antiRevoke":          @YES,
            @"flashUnlimited":      @YES,
            @"qzoneAdBlock":        @YES,
            @"fakeBattery":         @NO,
            @"batteryLevel":        @0.80f,
            @"isCharging":          @NO,
            @"drawerHideAlbum":     @NO,
            @"drawerHideFavorite":  @NO,
            @"drawerHideFiles":     @NO,
            @"drawerHideWallet":    @NO,
            @"drawerHideVip":       @NO,
            @"drawerHideDecor":     @NO,
            @"drawerHideFreedata":  @NO,
        }];
    });
    return ud;
}

static void qqesignClearModelAntiRecallRuntimeCache(void);
static void qqesignInstallQZoneAdHooks(const char *reason);
static void qqesignInstallDrawerHooks(const char *reason);
static void qqesignDrawerClearAllBlockedModels(void);

static void loadPrefs(void) {
    NSUserDefaults *ud = tweakDefaults();
    pref_antiRevoke     = [ud boolForKey:@"antiRevoke"];
    pref_flashUnlimited = [ud boolForKey:@"flashUnlimited"];
    pref_qzoneAdBlock   = [ud boolForKey:@"qzoneAdBlock"];
    pref_fakeBattery    = [ud boolForKey:@"fakeBattery"];
    pref_batteryLevel   = [ud floatForKey:@"batteryLevel"];
    pref_isCharging     = [ud boolForKey:@"isCharging"];
    pref_drawerHideAlbum    = [ud boolForKey:@"drawerHideAlbum"];
    pref_drawerHideFavorite = [ud boolForKey:@"drawerHideFavorite"];
    pref_drawerHideFiles    = [ud boolForKey:@"drawerHideFiles"];
    pref_drawerHideWallet   = [ud boolForKey:@"drawerHideWallet"];
    pref_drawerHideVip      = [ud boolForKey:@"drawerHideVip"];
    pref_drawerHideDecor    = [ud boolForKey:@"drawerHideDecor"];
    pref_drawerHideFreedata = [ud boolForKey:@"drawerHideFreedata"];
}

static NSString *qqesignRuntimeLogPath(void) {
    static NSString *path = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *base = dirs.firstObject ?: NSTemporaryDirectory();
        path = [base stringByAppendingPathComponent:@"qqesign_runtime.log"];
    });
    return path;
}

static void qqesignAppendLogLine(NSString *line) {
    if (line.length == 0) return;
    static dispatch_queue_t logQueue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logQueue = dispatch_queue_create("com.qqesign.runtime.log", DISPATCH_QUEUE_SERIAL);
    });

    dispatch_async(logQueue, ^{
        NSString *path = qqesignRuntimeLogPath();
        if (path.length == 0) return;
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) {
            [fm createFileAtPath:path contents:nil attributes:nil];
        }
        NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        if (!data) return;

        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [data writeToFile:path atomically:YES];
            return;
        }
        @try {
            [fh seekToEndOfFile];
            [fh writeData:data];
        } @catch (__unused NSException *e) {
        } @finally {
            [fh closeFile];
        }
    });
}

static void qqesignLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void qqesignLog(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (msg.length == 0) return;

    NSString *line = [NSString stringWithFormat:@"[%@] %@", [NSDate date], msg];
    NSLog(@"%@", line);
    qqesignAppendLogLine(line);
}

#define QQELog(...) qqesignLog(__VA_ARGS__)
#define NSLog(...) qqesignLog(__VA_ARGS__)

// ─────────────────────────────────────────────
#pragma mark - Helpers
// ─────────────────────────────────────────────

static void saveImageToCameraRoll(UIImage *image) {
    if (!image) return;
    PHAuthorizationStatus s = [PHPhotoLibrary authorizationStatus];
    BOOL ok = (s == PHAuthorizationStatusAuthorized);
    if (@available(iOS 14.0, *)) ok = ok || (s == PHAuthorizationStatusLimited);
    if (!ok) return;
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromImage:image];
    } completionHandler:^(BOOL success, NSError *err) {
        NSLog(@"[QQESign] 闪照保存%@", success ? @"成功" : ([NSString stringWithFormat:@"失败: %@", err]));
    }];
}

static UIImage *findImageInView(UIView *root) {
    if ([root isKindOfClass:[UIImageView class]]) {
        UIImage *img = ((UIImageView *)root).image;
        if (img) return img;
    }
    for (UIView *sub in root.subviews) {
        UIImage *img = findImageInView(sub);
        if (img) return img;
    }
    return nil;
}

static UIWindow *activeForegroundWindow(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
            for (UIWindow *w in ws.windows) {
                if (!w.hidden) return w;
            }
        }
    }
    return [UIApplication sharedApplication].keyWindow;
}

// ─────────────────────────────────────────────
#pragma mark - In-App Settings UI
// ─────────────────────────────────────────────

@interface QQESignSettingsController : UITableViewController
@end

@implementation QQESignSettingsController {
    NSArray<NSArray<NSDictionary *> *> *_sections;
    NSArray<NSString *> *_sectionTitles;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"QQESign 设置";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(dismissSelf)];
    [self rebuildSections];
}

- (void)rebuildSections {
    _sectionTitles = @[@"消息防撤回", @"闪照设置", @"主页入口屏蔽", @"自定义电量", @"关于"];
    _sections = @[
        @[
            @{@"title": @"开启防撤回", @"key": @"antiRevoke", @"type": @"switch"},
            @{@"title": @"好友动态精准去广告", @"key": @"qzoneAdBlock", @"type": @"switch"},
        ],
        @[@{@"title": @"无限次查看闪照", @"key": @"flashUnlimited", @"type": @"switch"}],
        @[
            @{@"title": @"隐藏「相册」",     @"key": @"drawerHideAlbum",    @"type": @"switch"},
            @{@"title": @"隐藏「收藏」",     @"key": @"drawerHideFavorite", @"type": @"switch"},
            @{@"title": @"隐藏「文件」",     @"key": @"drawerHideFiles",    @"type": @"switch"},
            @{@"title": @"隐藏「钱包」",     @"key": @"drawerHideWallet",   @"type": @"switch"},
            @{@"title": @"隐藏「会员中心」", @"key": @"drawerHideVip",      @"type": @"switch"},
            @{@"title": @"隐藏「个性装扮」", @"key": @"drawerHideDecor",    @"type": @"switch"},
            @{@"title": @"隐藏「免流量」",   @"key": @"drawerHideFreedata", @"type": @"switch"},
        ],
        @[
            @{@"title": @"启用自定义电量", @"key": @"fakeBattery", @"type": @"switch"},
            @{@"title": @"电量 (0~100)", @"key": @"batteryLevel", @"type": @"number"},
            @{@"title": @"模拟充电中", @"key": @"isCharging", @"type": @"switch"},
        ],
        @[@{@"title": @"QQESign v2.2\n适配NT架构 · 防撤回持久化 · 闪照无限查看\n自定义电量", @"type": @"info"}],
    ];
}

- (void)dismissSelf { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return _sections.count; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return _sectionTitles[s]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _sections[s].count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *item = _sections[ip.section][ip.row];
    NSString *type = item[@"type"], *key = item[@"key"];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.textLabel.text = item[@"title"];
    cell.textLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if ([type isEqualToString:@"switch"]) {
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [tweakDefaults() boolForKey:key];
        sw.tag = ip.section * 100 + ip.row;
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    } else if ([type isEqualToString:@"text"]) {
        cell.detailTextLabel.text = [tweakDefaults() stringForKey:key] ?: @"";
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if ([type isEqualToString:@"number"]) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f%%", [tweakDefaults() floatForKey:key] * 100];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *item = _sections[ip.section][ip.row];
    NSString *type = item[@"type"], *key = item[@"key"];
    if ([type isEqualToString:@"text"]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:item[@"title"] message:nil preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = [tweakDefaults() stringForKey:key];
            tf.placeholder = @"iPhone 17 Pro Max";
        }];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            NSString *val = a.textFields.firstObject.text;
            if (val.length > 0) {
                [tweakDefaults() setObject:val forKey:key];
                [tweakDefaults() synchronize];
                loadPrefs();
                [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
            }
        }]];
        [self presentViewController:a animated:YES completion:nil];
    } else if ([type isEqualToString:@"number"]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:item[@"title"] message:@"输入 0~100 之间的整数" preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = [NSString stringWithFormat:@"%.0f", [tweakDefaults() floatForKey:key] * 100];
            tf.keyboardType = UIKeyboardTypeNumberPad;
            tf.placeholder = @"80";
        }];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            float f = [a.textFields.firstObject.text floatValue] / 100.0f;
            f = MAX(0, MIN(1, f));
            [tweakDefaults() setFloat:f forKey:key];
            [tweakDefaults() synchronize];
            loadPrefs();
            [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
        }]];
        [self presentViewController:a animated:YES completion:nil];
    }
}

- (void)switchChanged:(UISwitch *)sw {
    NSDictionary *item = _sections[sw.tag / 100][sw.tag % 100];
    NSString *key = item[@"key"];
    [tweakDefaults() setBool:sw.on forKey:key];
    [tweakDefaults() synchronize];
    loadPrefs();
    if ([key isEqualToString:@"antiRevoke"] && !sw.on) {
        qqesignClearModelAntiRecallRuntimeCache();
        QQELog(@"[QQESign] 防撤回开关关闭：运行缓存和持久化缓存已清空，后续撤回放行");
    }
    if ([key hasPrefix:@"drawerHide"]) {
        // 抽屉入口屏蔽开关变化: 清空已标记 model, 下次抽屉重新展开时按新设置评估
        qqesignDrawerClearAllBlockedModels();
    }
}

@end

static void showQQESignSettings(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = activeForegroundWindow();
        if (!win) return;
        UIViewController *root = win.rootViewController;
        while (root.presentedViewController) root = root.presentedViewController;
        UITableViewStyle style = UITableViewStyleGrouped;
        if (@available(iOS 13.0, *)) style = UITableViewStyleInsetGrouped;
        QQESignSettingsController *vc = [[QQESignSettingsController alloc] initWithStyle:style];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [root presentViewController:nav animated:YES completion:nil];
    });
}

static void addESignButton(UIViewController *vc, SEL action) {
    if (!vc) return;
    for (UIBarButtonItem *item in vc.navigationItem.rightBarButtonItems) {
        if ([item.title isEqualToString:@"ESign"]) return;
    }
    if ([vc.navigationItem.rightBarButtonItem.title isEqualToString:@"ESign"]) return;
    UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:@"ESign"
                                                            style:UIBarButtonItemStylePlain
                                                           target:vc
                                                           action:action];
    NSMutableArray *items = [vc.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
    [items addObject:btn];
    vc.navigationItem.rightBarButtonItems = items;
}



#pragma mark - 0.5 Model anti-recall persistent cache

static NSMutableDictionary<NSString *, NSMutableDictionary *> *gQQEModelAntiRecallRuntime = nil;
static NSMutableDictionary<NSString *, NSMutableDictionary *> *gQQEModelAntiRecallDisk = nil;
static dispatch_queue_t gQQEModelAntiRecallPersistQueue = nil;
static const NSUInteger kQQEModelAntiRecallMaxItems = 1000;

static NSString *qqeModelCachePath(void) {
    static NSString *path = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *base = dirs.firstObject ?: NSTemporaryDirectory();
        path = [base stringByAppendingPathComponent:@"qqesign_antirevoke_model_cache.plist"];
    });
    return path;
}

static void qqeEnsureModelCacheLoaded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gQQEModelAntiRecallRuntime = [NSMutableDictionary dictionary];
        NSDictionary *disk = [NSDictionary dictionaryWithContentsOfFile:qqeModelCachePath()];
        gQQEModelAntiRecallDisk = disk ? [disk mutableCopy] : [NSMutableDictionary dictionary];
        gQQEModelAntiRecallPersistQueue = dispatch_queue_create("com.qqesign.antirecall.persist", DISPATCH_QUEUE_SERIAL);
        QQELog(@"[QQESign] 防撤回持久化缓存加载：%lu 条", (unsigned long)gQQEModelAntiRecallDisk.count);
    });
}

static void qqePersistModelCacheAsync(void) {
    qqeEnsureModelCacheLoaded();
    NSDictionary *snapshot = nil;
    @synchronized (gQQEModelAntiRecallDisk) {
        snapshot = [gQQEModelAntiRecallDisk copy];
    }
    dispatch_async(gQQEModelAntiRecallPersistQueue, ^{
        [snapshot writeToFile:qqeModelCachePath() atomically:YES];
    });
}

static void qqeTrimModelCacheLocked(void) {
    if (gQQEModelAntiRecallDisk.count <= kQQEModelAntiRecallMaxItems) return;
    NSArray<NSString *> *keys = [gQQEModelAntiRecallDisk keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSTimeInterval ta = [a[@"ts"] doubleValue];
        NSTimeInterval tb = [b[@"ts"] doubleValue];
        if (ta < tb) return NSOrderedAscending;
        if (ta > tb) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    NSUInteger removeCount = gQQEModelAntiRecallDisk.count - kQQEModelAntiRecallMaxItems;
    for (NSUInteger i = 0; i < removeCount && i < keys.count; i++) {
        [gQQEModelAntiRecallDisk removeObjectForKey:keys[i]];
        [gQQEModelAntiRecallRuntime removeObjectForKey:keys[i]];
    }
}

static Ivar qqeFindIvar(Class cls, const char *name) {
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        Ivar iv = class_getInstanceVariable(c, name);
        if (iv) return iv;
    }
    return NULL;
}

static id qqeObjectIvar(id obj, const char *name) {
    if (!obj || !name) return nil;
    Ivar iv = qqeFindIvar([obj class], name);
    if (!iv) return nil;
    const char *type = ivar_getTypeEncoding(iv);
    if (!type || type[0] != '@') return nil;
    @try { return object_getIvar(obj, iv); } @catch (__unused NSException *e) { return nil; }
}

static long long qqeIntegerIvar(id obj, const char *name) {
    if (!obj || !name) return 0;
    Ivar iv = qqeFindIvar([obj class], name);
    if (!iv) return 0;
    const char *type = ivar_getTypeEncoding(iv);
    ptrdiff_t off = ivar_getOffset(iv);
    uint8_t *base = (uint8_t *)(__bridge void *)obj;
    if (!type) return 0;
    switch (type[0]) {
        case 'q': return *(long long *)(base + off);
        case 'Q': return (long long)*(unsigned long long *)(base + off);
        case 'l': return *(long *)(base + off);
        case 'L': return (long long)*(unsigned long *)(base + off);
        case 'i': return *(int *)(base + off);
        case 'I': return (long long)*(unsigned int *)(base + off);
        case 's': return *(short *)(base + off);
        case 'S': return (long long)*(unsigned short *)(base + off);
        case 'c': return *(char *)(base + off);
        case 'C': return (long long)*(unsigned char *)(base + off);
        case 'B': return *(BOOL *)(base + off);
        default: return 0;
    }
}

static void qqeSetIntegerIvar(id obj, const char *name, long long value) {
    if (!obj || !name) return;
    Ivar iv = qqeFindIvar([obj class], name);
    if (!iv) return;
    const char *type = ivar_getTypeEncoding(iv);
    ptrdiff_t off = ivar_getOffset(iv);
    uint8_t *base = (uint8_t *)(__bridge void *)obj;
    if (!type) return;
    switch (type[0]) {
        case 'q': *(long long *)(base + off) = value; break;
        case 'Q': *(unsigned long long *)(base + off) = (unsigned long long)value; break;
        case 'l': *(long *)(base + off) = (long)value; break;
        case 'L': *(unsigned long *)(base + off) = (unsigned long)value; break;
        case 'i': *(int *)(base + off) = (int)value; break;
        case 'I': *(unsigned int *)(base + off) = (unsigned int)value; break;
        case 's': *(short *)(base + off) = (short)value; break;
        case 'S': *(unsigned short *)(base + off) = (unsigned short)value; break;
        case 'c': *(char *)(base + off) = (char)value; break;
        case 'C': *(unsigned char *)(base + off) = (unsigned char)value; break;
        case 'B': *(BOOL *)(base + off) = (BOOL)value; break;
        default: break;
    }
}

static void qqeSetObjectIvar(id obj, const char *name, id value) {
    if (!obj || !name) return;
    Ivar iv = qqeFindIvar([obj class], name);
    if (!iv) return;
    const char *type = ivar_getTypeEncoding(iv);
    if (!type || type[0] != '@') return;
    @try { object_setIvar(obj, iv, value); } @catch (__unused NSException *e) {}
}

static NSString *qqeSafeString(id obj) {
    if (!obj) return @"";
    if ([obj isKindOfClass:[NSString class]]) return obj;
    return [obj description] ?: @"";
}

static NSString *qqeRecordKeyForModelAntiRecall(id record) {
    if (!record) return nil;
    NSString *peer = qqeSafeString(qqeObjectIvar(record, "_peerUid"));
    NSString *sender = qqeSafeString(qqeObjectIvar(record, "_senderUid"));
    long long msgId = qqeIntegerIvar(record, "_msgId");
    long long msgRandom = qqeIntegerIvar(record, "_msgRandom");
    long long msgSeq = qqeIntegerIvar(record, "_msgSeq");
    long long msgTime = qqeIntegerIvar(record, "_msgTime");
    if (msgId == 0 || msgRandom == 0) return nil;
    return [NSString stringWithFormat:@"peer=%@|sender=%@|id=%lld|random=%lld|seq=%lld|time=%lld", peer, sender, msgId, msgRandom, msgSeq, msgTime];
}

static BOOL qqeIsRecallModelRecord(id record) {
    return qqeIntegerIvar(record, "_msgType") == 5 && qqeIntegerIvar(record, "_subMsgType") == 4;
}

static BOOL qqeIsCacheableModelRecord(id record, id elements) {
    if (!record || !elements || qqeIsRecallModelRecord(record)) return NO;
    if (qqeIntegerIvar(record, "_msgId") == 0 || qqeIntegerIvar(record, "_msgRandom") == 0) return NO;
    if (![elements respondsToSelector:@selector(count)]) return NO;
    NSUInteger count = 0;
    @try { count = (NSUInteger)[elements count]; } @catch (__unused NSException *e) { count = 0; }
    return count > 0 && count < 80;
}

static NSData *qqeArchiveElements(id elements) {
    if (!elements) return nil;
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        return [NSKeyedArchiver archivedDataWithRootObject:elements];
#pragma clang diagnostic pop
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static id qqeUnarchiveElements(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0) return nil;
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        return [NSKeyedUnarchiver unarchiveObjectWithData:data];
#pragma clang diagnostic pop
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static void qqeCacheModelRecord(id record, id elements) {
    if (!pref_antiRevoke || !qqeIsCacheableModelRecord(record, elements)) return;
    NSString *key = qqeRecordKeyForModelAntiRecall(record);
    if (key.length == 0) return;
    qqeEnsureModelCacheLoaded();

    NSData *data = qqeArchiveElements(elements);
    NSNumber *msgType = @(qqeIntegerIvar(record, "_msgType"));
    NSNumber *subMsgType = @(qqeIntegerIvar(record, "_subMsgType"));
    NSNumber *ts = @([[NSDate date] timeIntervalSince1970]);

    NSMutableDictionary *runtimeEntry = [NSMutableDictionary dictionary];
    runtimeEntry[@"elements"] = elements;
    if (data) runtimeEntry[@"data"] = data;
    runtimeEntry[@"msgType"] = msgType;
    runtimeEntry[@"subMsgType"] = subMsgType;
    runtimeEntry[@"ts"] = ts;

    @synchronized (gQQEModelAntiRecallDisk) {
        gQQEModelAntiRecallRuntime[key] = runtimeEntry;
        if (data) {
            NSMutableDictionary *diskEntry = [NSMutableDictionary dictionary];
            diskEntry[@"data"] = data;
            diskEntry[@"msgType"] = msgType;
            diskEntry[@"subMsgType"] = subMsgType;
            diskEntry[@"ts"] = ts;
            gQQEModelAntiRecallDisk[key] = diskEntry;
        }
        qqeTrimModelCacheLocked();
    }
    if (data) qqePersistModelCacheAsync();
}

static NSMutableDictionary *qqeLookupModelRecord(NSString *key) {
    if (key.length == 0) return nil;
    qqeEnsureModelCacheLoaded();
    @synchronized (gQQEModelAntiRecallDisk) {
        NSMutableDictionary *runtime = gQQEModelAntiRecallRuntime[key];
        if (runtime[@"elements"]) return runtime;

        NSDictionary *disk = gQQEModelAntiRecallDisk[key];
        NSData *data = disk[@"data"];
        id elements = qqeUnarchiveElements(data);
        if (!elements) return nil;
        NSMutableDictionary *entry = [disk mutableCopy];
        entry[@"elements"] = elements;
        gQQEModelAntiRecallRuntime[key] = entry;
        return entry;
    }
}

static BOOL qqeRestoreModelRecord(id record, NSMutableDictionary *entry) {
    if (!record || !entry) return NO;
    id elements = entry[@"elements"];
    if (!elements) return NO;
    qqeSetIntegerIvar(record, "_msgType", [entry[@"msgType"] longLongValue]);
    qqeSetIntegerIvar(record, "_subMsgType", [entry[@"subMsgType"] longLongValue]);
    qqeSetIntegerIvar(record, "_recallTime", 0);
    qqeSetObjectIvar(record, "_msgEventInfo", nil);
    qqeSetObjectIvar(record, "_elements", elements);
    return YES;
}

static void qqesignClearModelAntiRecallRuntimeCache(void) {
    qqeEnsureModelCacheLoaded();
    @synchronized (gQQEModelAntiRecallDisk) {
        [gQQEModelAntiRecallRuntime removeAllObjects];
        [gQQEModelAntiRecallDisk removeAllObjects];
    }
    [[NSFileManager defaultManager] removeItemAtPath:qqeModelCachePath() error:nil];
}

%hook OCMsgRecord

- (void)setElements:(id)elements {
    if (pref_antiRevoke) {
        if (qqeIsCacheableModelRecord(self, elements)) {
            qqeCacheModelRecord(self, elements);
        } else if (qqeIsRecallModelRecord(self)) {
            NSString *key = qqeRecordKeyForModelAntiRecall(self);
            NSMutableDictionary *entry = qqeLookupModelRecord(key);
            if (entry && qqeRestoreModelRecord(self, entry)) {
                QQELog(@"[QQESign] 模型层防撤回恢复 elements: %@", key);
                id restoredElements = entry[@"elements"];
                %orig(restoredElements);
                return;
            }
        }
    }
    %orig(elements);
}

- (void)setRecallTime:(long long)recallTime {
    if (pref_antiRevoke && recallTime != 0) {
        NSString *key = qqeRecordKeyForModelAntiRecall(self);
        NSMutableDictionary *entry = qqeLookupModelRecord(key);
        if (entry && qqeRestoreModelRecord(self, entry)) {
            QQELog(@"[QQESign] 模型层防撤回清除 recallTime: %@", key);
            %orig(0);
            return;
        }
    }
    %orig(recallTime);
}

%end

#pragma mark - 1. Anti-recall runtime hooks (NT QQ)

// 这段为折中合并版：
// 1) 采用 txt 中更准确的“普通撤回主链”判断：
//    QQMessageRecallNetEngine.parseC2CRecallNotify...
//      -> QQMessageRecallModule.convertRecallItemToMsg...
//      -> QQMessageDecouplingBridge.recallMessagePair:
//      -> NTAIOGrayTipsOtherLinkRecallHandle.grayTipsEvent...
// 2) 不再把 handleSideAccountRecallNotify... 当成“普通消息总入口”，
//    仅作为 side-account / 特殊分支保留。
// 3) 同时保留此前代码里几个已经在主程序中确认存在、且对表现层补漏有帮助的显式 hook：
//    GroupEmotionManager.recallMessagePair:
//    NTAIOChat.onReceiveRecallMsgNotification:
//    QQAIOCell.updateCellViewRecall
//    NudgeActionManager.insertRecallGrayTips2AioIfneed:isGroup:
//    以及少量 RichMedia / ChatFiles / GPro / FloatEar / Guild 分发点。
// 4) 不做全量类扫描，不做宽泛 selector 补挂。

typedef struct {
    Class cls;
    SEL sel;
    IMP orig;
} QQESignRecallHookRecord;

static QQESignRecallHookRecord gQQESignRecallHooks[64];
static NSUInteger gQQESignRecallHookCount = 0;

typedef BOOL (*QQEOrigBoolRecallNetParse)(id, SEL, const void *, int, int, void *);
typedef id   (*QQEOrigIdRecallModuleFull)(id, SEL, const void *, int, int, unsigned long long, BOOL *);
typedef id   (*QQEOrigIdRecallConvert)(id, SEL, const void *, void *, int, unsigned long long);
typedef id   (*QQEOrigIdIntBool)(id, SEL, int, BOOL);
typedef void (*QQEOrigVoidOneObj)(id, SEL, id);
typedef void (*QQEOrigVoidTwoObj)(id, SEL, id, id);
typedef void (*QQEOrigVoidThreeObj)(id, SEL, id, id, id);
typedef void (*QQEOrigVoidZeroArg)(id, SEL);
typedef BOOL (*QQEOrigBoolZeroArg)(id, SEL);
typedef BOOL (*QQEOrigBoolOneObj)(id, SEL, id);
typedef void (*QQEOrigVoidOneBool)(id, SEL, BOOL);
typedef void (*QQEOrigVoidOneObjBool)(id, SEL, id, BOOL);
typedef void (*QQEOrigVoidGrayTip)(id, SEL, id, id, id, unsigned int);
typedef void (*QQEOrigVoidMsgRecall3)(id, SEL, int, id, unsigned long long);
typedef void (*QQEOrigVoidGuildPush)(id, SEL, long long, long long, long long, int, id, id, id, id, int);
typedef id   (*QQEOrigIdGrayTipElementInit)(id, SEL, NSInteger, id, id, id, id, id, id, id, id, id, id, id, id, id, id);

static NSUInteger gQQESignRecallGrayTipElementBlockedCount = 0;

typedef struct {
    const char *className;
    const char *selName;
    const char *typeEncoding;
    IMP newImp;
    const char *tag;
} QQESignRecallMethodSpec;

typedef int (*QQEDobbyHookFn)(void *target, void *replace, void **origin);

typedef struct {
    const uint8_t *textBytes;
    size_t textSize;
    uintptr_t textAddr;
    const char *cstringBytes;
    size_t cstringSize;
    uintptr_t cstringAddr;
    intptr_t slide;
    const char *imageName;
} QQESignQQImageInfo;

typedef uintptr_t (*QQEKernelRecallEntryFn)(void *x0, const void *x1, const void *x2, const void *x3);
typedef uintptr_t (*QQEMsgRecallMgrEntryFn)(void *x0, void *x1, void *x2, void *x3, void *x4, void *x5, void *x6, void *x7);

static QQEDobbyHookFn gQQEDobbyHook = NULL;

static QQEKernelRecallEntryFn gQQEOrigKernelRecallMsgFromC2CAndGroup = NULL;
static QQEKernelRecallEntryFn gQQEOrigKernelGetRecallMsgsByMsgId = NULL;
static QQEMsgRecallMgrEntryFn gQQEOrigMsgRecallMgrRecallMsg = NULL;

static uintptr_t gQQEHookAddrKernelRecallMsgFromC2CAndGroup = 0;
static uintptr_t gQQEHookAddrKernelGetRecallMsgsByMsgId = 0;
static uintptr_t gQQEHookAddrMsgRecallMgrRecallMsg = 0;
static BOOL gQQEInlineHookFinalized = NO;

static BOOL qqesignHasSuffix(const char *full, const char *suffix) {
    if (!full || !suffix) return NO;
    size_t fullLen = strlen(full);
    size_t suffixLen = strlen(suffix);
    if (fullLen < suffixLen) return NO;
    return (strncmp(full + (fullLen - suffixLen), suffix, suffixLen) == 0);
}

static size_t qqesignBoundedCStringLength(const char *s, size_t maxLen) {
    if (!s) return 0;
    size_t n = 0;
    while (n < maxLen && s[n] != '\0') n++;
    return n;
}

static BOOL qqesignResolveInlineHookBackend(void) {
    if (gQQEDobbyHook) return YES;

    gQQEDobbyHook = (QQEDobbyHookFn)dlsym(RTLD_DEFAULT, "DobbyHook");
    if (gQQEDobbyHook) return YES;

    static const char *const dylibs[] = {
        "/usr/lib/libdobby.dylib",
        "/usr/lib/libDobby.dylib",
    };
    for (NSUInteger i = 0; i < sizeof(dylibs) / sizeof(dylibs[0]); i++) {
        void *h = dlopen(dylibs[i], RTLD_NOW);
        if (!h) continue;
        gQQEDobbyHook = (QQEDobbyHookFn)dlsym(h, "DobbyHook");
        if (gQQEDobbyHook) return YES;
    }
    return NO;
}

static BOOL qqesignInstallInlineHook(void *target, void *replacement, void **origin, const char *tag) {
    if (!target || !replacement) return NO;
    if (!qqesignResolveInlineHookBackend()) {
        NSLog(@"[QQESign] inline hook 后端未就绪(%s): 需要 DobbyHook", (tag ? tag : "unknown"));
        return NO;
    }

    if (gQQEDobbyHook) {
        int rc = gQQEDobbyHook(target, replacement, origin);
        if (rc == 0) {
            NSLog(@"[QQESign] inline hook 安装成功(Dobby): %s target=%p", (tag ? tag : "unknown"), target);
            return YES;
        }
        NSLog(@"[QQESign] inline hook 安装失败(Dobby rc=%d): %s target=%p", rc, (tag ? tag : "unknown"), target);
    }

    NSLog(@"[QQESign] inline hook 安装失败: %s target=%p", (tag ? tag : "unknown"), target);
    return NO;
}

static BOOL qqesignLoadQQImageInfo(QQESignQQImageInfo *info) {
    if (!info) return NO;
    memset(info, 0, sizeof(*info));

    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (!(qqesignHasSuffix(name, "/QQ") || strstr(name, "/QQ.app/QQ"))) continue;

        const struct mach_header *mh = _dyld_get_image_header(i);
        if (!mh || mh->magic != MH_MAGIC_64) continue;
        const struct mach_header_64 *mh64 = (const struct mach_header_64 *)mh;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);

        const struct load_command *lc = (const struct load_command *)((const uint8_t *)mh64 + sizeof(struct mach_header_64));
        for (uint32_t c = 0; c < mh64->ncmds; c++) {
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
                if (strncmp(seg->segname, "__TEXT", 16) == 0) {
                    const struct section_64 *sec = (const struct section_64 *)(seg + 1);
                    for (uint32_t s = 0; s < seg->nsects; s++) {
                        if (strncmp(sec[s].sectname, "__text", 16) == 0) {
                            info->textAddr = (uintptr_t)(sec[s].addr + slide);
                            info->textBytes = (const uint8_t *)info->textAddr;
                            info->textSize = (size_t)sec[s].size;
                        } else if (strncmp(sec[s].sectname, "__cstring", 16) == 0) {
                            info->cstringAddr = (uintptr_t)(sec[s].addr + slide);
                            info->cstringBytes = (const char *)info->cstringAddr;
                            info->cstringSize = (size_t)sec[s].size;
                        }
                    }
                }
            }
            lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
        }

        info->slide = slide;
        info->imageName = name;
        if (info->textBytes && info->textSize > 0 && info->cstringBytes && info->cstringSize > 0) {
            return YES;
        }
    }
    return NO;
}

static int64_t qqesignSignExtend(uint64_t value, unsigned bits) {
    if (bits == 0 || bits >= 64) return (int64_t)value;
    uint64_t mask = (1ULL << bits) - 1ULL;
    value &= mask;
    uint64_t sign = 1ULL << (bits - 1);
    return (int64_t)((value ^ sign) - sign);
}

static BOOL qqesignDecodeAdrpAndAdd(uintptr_t pc, uint32_t adrpInsn, uint32_t addInsn, uintptr_t *outTarget) {
    if (!outTarget) return NO;
    if ((adrpInsn & 0x9F000000u) != 0x90000000u) return NO;
    if ((addInsn & 0xFFC00000u) != 0x91000000u) return NO;

    uint32_t adrpReg = adrpInsn & 0x1Fu;
    uint32_t addDst = addInsn & 0x1Fu;
    uint32_t addSrc = (addInsn >> 5) & 0x1Fu;
    if (addDst != adrpReg || addSrc != adrpReg) return NO;

    uint64_t immlo = (adrpInsn >> 29) & 0x3u;
    uint64_t immhi = (adrpInsn >> 5) & 0x7FFFFu;
    int64_t adrpImm = qqesignSignExtend((immhi << 2) | immlo, 21) << 12;
    uintptr_t page = (pc & ~(uintptr_t)0xFFFULL);
    uintptr_t base = (uintptr_t)((int64_t)page + adrpImm);

    uint32_t imm12 = (addInsn >> 10) & 0xFFFu;
    uint32_t shift = (addInsn >> 22) & 0x3u;
    if (shift > 1u) return NO;
    uintptr_t addImm = (uintptr_t)imm12 << (shift ? 12 : 0);
    *outTarget = base + addImm;
    return YES;
}

static uintptr_t qqesignFindFunctionStart(const QQESignQQImageInfo *info, uintptr_t refPc) {
    if (!info || !info->textBytes || info->textSize < 8) return 0;
    if (refPc < info->textAddr || refPc >= info->textAddr + info->textSize) return 0;

    const uint32_t *insn = (const uint32_t *)info->textBytes;
    size_t count = info->textSize / sizeof(uint32_t);
    size_t idx = (refPc - info->textAddr) / sizeof(uint32_t);

    size_t backLimit = 256; // 1KB window
    if (idx < backLimit) backLimit = idx;

    for (size_t back = 0; back <= backLimit; back++) {
        size_t pos = idx - back;
        if (pos + 1 >= count) break;

        uint32_t i0 = insn[pos];
        uint32_t i1 = insn[pos + 1];
        if ((i0 & 0xFFC003FFu) == 0xA98003FDu && (i1 & 0xFFC003FFu) == 0x910003FDu) {
            return info->textAddr + pos * sizeof(uint32_t);
        }
    }
    return 0;
}

static uintptr_t qqesignFindFunctionByMarkerPrefix(const QQESignQQImageInfo *info,
                                                   const char *markerPrefix,
                                                   const char *tag) {
    if (!info || !info->cstringBytes || !info->textBytes || !markerPrefix) return 0;

    size_t prefixLen = strlen(markerPrefix);
    const char *base = info->cstringBytes;
    size_t off = 0;
    while (off < info->cstringSize) {
        size_t left = info->cstringSize - off;
        size_t len = qqesignBoundedCStringLength(base + off, left);
        if (len == 0) {
            off++;
            continue;
        }

        if (len >= prefixLen && strncmp(base + off, markerPrefix, prefixLen) == 0) {
            uintptr_t markerAddr = info->cstringAddr + off;
            const uint32_t *insn = (const uint32_t *)info->textBytes;
            size_t count = info->textSize / sizeof(uint32_t);

            for (size_t i = 0; i + 1 < count; i++) {
                uintptr_t pc = info->textAddr + i * sizeof(uint32_t);
                uintptr_t target = 0;
                if (!qqesignDecodeAdrpAndAdd(pc, insn[i], insn[i + 1], &target)) continue;
                if (target != markerAddr) continue;

                uintptr_t fn = qqesignFindFunctionStart(info, pc);
                if (fn) {
                    NSLog(@"[QQESign] 定位 C++ 函数成功(%s): marker=%s markerAddr=%p fn=%p",
                          (tag ? tag : "inline-find"),
                          markerPrefix,
                          (void *)markerAddr,
                          (void *)fn);
                    return fn;
                }
            }
        }
        off += len + 1;
    }

    NSLog(@"[QQESign] 定位 C++ 函数失败(%s): marker=%s", (tag ? tag : "inline-find"), markerPrefix);
    return 0;
}

static uintptr_t qqesignInlineKernelRecallMsgFromC2CAndGroup(void *x0, const void *x1, const void *x2, const void *x3) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] inline-C++ 拦截 KernelMsgService::recallMsgFromC2CAndGroup");
        return 0;
    }
    if (gQQEOrigKernelRecallMsgFromC2CAndGroup) {
        return gQQEOrigKernelRecallMsgFromC2CAndGroup(x0, x1, x2, x3);
    }
    return 0;
}

static uintptr_t qqesignInlineKernelGetRecallMsgsByMsgId(void *x0, const void *x1, const void *x2, const void *x3) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] inline-C++ 拦截 KernelMsgService::getRecallMsgsByMsgId");
        return 0;
    }
    if (gQQEOrigKernelGetRecallMsgsByMsgId) {
        return gQQEOrigKernelGetRecallMsgsByMsgId(x0, x1, x2, x3);
    }
    return 0;
}

static uintptr_t qqesignInlineMsgRecallMgrRecallMsg(void *x0,
                                                    void *x1,
                                                    void *x2,
                                                    void *x3,
                                                    void *x4,
                                                    void *x5,
                                                    void *x6,
                                                    void *x7) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] inline-C++ 拦截 MsgRecallMgr::RecallMsg");
        return 0;
    }
    if (gQQEOrigMsgRecallMgrRecallMsg) {
        return gQQEOrigMsgRecallMgrRecallMsg(x0, x1, x2, x3, x4, x5, x6, x7);
    }
    return 0;
}

static NSUInteger qqesignInstallKernelInlineHooksPass(const char *reason) {
    NSUInteger installed = 0;
    if (gQQEInlineHookFinalized) return 0;
    BOOL attempted = NO;

    if (!qqesignResolveInlineHookBackend()) {
        NSLog(@"[QQESign] %s inline-C++ hook 未启用: 未找到 DobbyHook",
              (reason ? reason : "anti-recall"));
        return 0;
    }

    QQESignQQImageInfo imageInfo;
    if (!qqesignLoadQQImageInfo(&imageInfo)) {
        NSLog(@"[QQESign] %s inline-C++ hook 未启用: 无法定位 QQ 主程序 __text/__cstring",
              (reason ? reason : "anti-recall"));
        return 0;
    }

    if (gQQEHookAddrKernelRecallMsgFromC2CAndGroup == 0) {
        attempted = YES;
        uintptr_t target = qqesignFindFunctionByMarkerPrefix(&imageInfo,
                                                             "ZN2nt7wrapper16KernelMsgService24recallMsgFromC2CAndGroup",
                                                             "kernel-recall-from-c2c-group");
        if (target && qqesignInstallInlineHook((void *)target,
                                               (void *)qqesignInlineKernelRecallMsgFromC2CAndGroup,
                                               (void **)&gQQEOrigKernelRecallMsgFromC2CAndGroup,
                                               "KernelMsgService::recallMsgFromC2CAndGroup")) {
            gQQEHookAddrKernelRecallMsgFromC2CAndGroup = target;
            installed++;
        }
    }

    if (gQQEHookAddrKernelGetRecallMsgsByMsgId == 0) {
        attempted = YES;
        uintptr_t target = qqesignFindFunctionByMarkerPrefix(&imageInfo,
                                                             "ZN2nt7wrapper16KernelMsgService20getRecallMsgsByMsgId",
                                                             "kernel-get-recall-msgs-by-id");
        if (target && qqesignInstallInlineHook((void *)target,
                                               (void *)qqesignInlineKernelGetRecallMsgsByMsgId,
                                               (void **)&gQQEOrigKernelGetRecallMsgsByMsgId,
                                               "KernelMsgService::getRecallMsgsByMsgId")) {
            gQQEHookAddrKernelGetRecallMsgsByMsgId = target;
            installed++;
        }
    }

    if (gQQEHookAddrMsgRecallMgrRecallMsg == 0) {
        attempted = YES;
        uintptr_t target = qqesignFindFunctionByMarkerPrefix(&imageInfo,
                                                             "MsgRecallMgr::RecallMsg",
                                                             "msg-recall-mgr-recall-msg");
        if (target && qqesignInstallInlineHook((void *)target,
                                               (void *)qqesignInlineMsgRecallMgrRecallMsg,
                                               (void **)&gQQEOrigMsgRecallMgrRecallMsg,
                                               "MsgRecallMgr::RecallMsg")) {
            gQQEHookAddrMsgRecallMgrRecallMsg = target;
            installed++;
        }
    }

    if (installed > 0) {
        NSLog(@"[QQESign] %s 本轮新增 inline-C++ 防撤回 Hook: %lu",
              (reason ? reason : "anti-recall"),
              (unsigned long)installed);
    }
    if (attempted) {
        gQQEInlineHookFinalized = YES;
    }
    return installed;
}

static BOOL qqesignIsRecallNotificationName(NSString *name) {
    if (name.length == 0) return NO;
    static NSSet<NSString *> *exact = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        exact = [NSSet setWithArray:@[
            @"__QQReceiveRecallMsgNotification__",
            @"__QQReceiveRecallForVideoStopNotification__",
            @"__QQReceiveRecallFormFileNotification__",
            @"__QQGProReceiveRecallMsgNotifications__",
        ]];
    });
    if ([exact containsObject:name]) return YES;
    if ([name hasPrefix:@"__QQReceiveRecall"] || [name hasPrefix:@"QQReceiveRecall"] || [name hasPrefix:@"__QQGProReceiveRecall"]) return YES;
    if ([name rangeOfString:@"Recall" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    if ([name rangeOfString:@"Revoke" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}

static BOOL qqesignRecallHookExists(Class cls, SEL sel) {
    for (NSUInteger i = 0; i < gQQESignRecallHookCount; i++) {
        if (gQQESignRecallHooks[i].cls == cls && gQQESignRecallHooks[i].sel == sel) {
            return YES;
        }
    }
    return NO;
}

static void qqesignAddRecallHookRecord(Class cls, SEL sel, IMP orig) {
    if (!cls || !sel || !orig) return;
    if (qqesignRecallHookExists(cls, sel)) return;
    if (gQQESignRecallHookCount >= (sizeof(gQQESignRecallHooks) / sizeof(gQQESignRecallHooks[0]))) return;
    gQQESignRecallHooks[gQQESignRecallHookCount].cls = cls;
    gQQESignRecallHooks[gQQESignRecallHookCount].sel = sel;
    gQQESignRecallHooks[gQQESignRecallHookCount].orig = orig;
    gQQESignRecallHookCount++;
}

static IMP qqesignLookupRecallOriginal(id self, SEL _cmd) {
    if (!self || !_cmd) return NULL;
    for (Class cls = object_getClass(self); cls; cls = class_getSuperclass(cls)) {
        for (NSUInteger i = 0; i < gQQESignRecallHookCount; i++) {
            if (gQQESignRecallHooks[i].cls == cls && gQQESignRecallHooks[i].sel == _cmd) {
                return gQQESignRecallHooks[i].orig;
            }
        }
    }
    return NULL;
}

static Method qqesignFindOwnInstanceMethod(Class cls, SEL sel) {
    if (!cls || !sel) return NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            found = methods[i];
            break;
        }
    }
    if (methods) free(methods);
    return found;
}

static BOOL qqesignSwizzleRecallMethodOnClass(Class cls,
                                              const char *selName,
                                              const char *typeEncoding,
                                              IMP newImp,
                                              const char *tag) {
    if (!cls || !selName || !newImp) return NO;

    SEL sel = sel_registerName(selName);
    Method method = qqesignFindOwnInstanceMethod(cls, sel);
    if (!method) return NO;
    if (qqesignRecallHookExists(cls, sel)) return NO;

    if (typeEncoding) {
        const char *actualType = method_getTypeEncoding(method);
        if (!actualType || strcmp(actualType, typeEncoding) != 0) return NO;
    }

    IMP orig = method_getImplementation(method);
    if (!orig || orig == newImp) return NO;

    qqesignAddRecallHookRecord(cls, sel, orig);
    method_setImplementation(method, newImp);

    NSLog(@"[QQESign] 安装防撤回 Hook: %s -[%s %s]",
          (tag ? tag : "anti-recall"),
          class_getName(cls),
          selName);
    return YES;
}

static BOOL qqesignRecallNetEngineBlocker(id self,
                                          SEL _cmd,
                                          const void *data,
                                          int bufferLen,
                                          int subcmd,
                                          void *model) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回解析: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return NO;
    }
    QQEOrigBoolRecallNetParse orig = (QQEOrigBoolRecallNetParse)qqesignLookupRecallOriginal(self, _cmd);
    return orig ? orig(self, _cmd, data, bufferLen, subcmd, model) : NO;
}

static id qqesignRecallModuleFullBlocker(id self,
                                         SEL _cmd,
                                         const void *data,
                                         int bufferLen,
                                         int subcmd,
                                         unsigned long long uin,
                                         BOOL *tracelessFlag) {
    if (pref_antiRevoke && tracelessFlag) *tracelessFlag = NO;
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截侧路撤回入口: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return nil;
    }
    QQEOrigIdRecallModuleFull orig = (QQEOrigIdRecallModuleFull)qqesignLookupRecallOriginal(self, _cmd);
    return orig ? orig(self, _cmd, data, bufferLen, subcmd, uin, tracelessFlag) : nil;
}

static id qqesignRecallConvertBlocker(id self,
                                      SEL _cmd,
                                      const void *recallItem,
                                      void *recallModel,
                                      int msgType,
                                      unsigned long long bindUin) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回转换: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return nil;
    }
    QQEOrigIdRecallConvert orig = (QQEOrigIdRecallConvert)qqesignLookupRecallOriginal(self, _cmd);
    return orig ? orig(self, _cmd, recallItem, recallModel, msgType, bindUin) : nil;
}

static void qqesignRecallBridgeBlocker(id self, SEL _cmd, id recallPair) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回落库: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return;
    }
    QQEOrigVoidOneObj orig = (QQEOrigVoidOneObj)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, recallPair);
}

static void qqesignRecallOneObjectBlocker(id self, SEL _cmd, id arg1) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回入口: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return;
    }
    QQEOrigVoidOneObj orig = (QQEOrigVoidOneObj)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, arg1);
}

static void qqesignRecallThreeObjectBlocker(id self, SEL _cmd, id arg1, id arg2, id arg3) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回拉取链路: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return;
    }
    QQEOrigVoidThreeObj orig = (QQEOrigVoidThreeObj)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, arg1, arg2, arg3);
}

static void qqesignRecallZeroArgBlocker(id self, SEL _cmd) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回零参入口: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return;
    }
    QQEOrigVoidZeroArg orig = (QQEOrigVoidZeroArg)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd);
}

static BOOL qqesignRecallBoolZeroArgBlocker(id self, SEL _cmd) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 清空撤回标记: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return NO;
    }
    QQEOrigBoolZeroArg orig = (QQEOrigBoolZeroArg)qqesignLookupRecallOriginal(self, _cmd);
    return orig ? orig(self, _cmd) : NO;
}

static BOOL qqesignRecallBoolOneObjectBlocker(id self, SEL _cmd, id arg1) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回布尔入口: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return NO;
    }
    QQEOrigBoolOneObj orig = (QQEOrigBoolOneObj)qqesignLookupRecallOriginal(self, _cmd);
    return orig ? orig(self, _cmd, arg1) : NO;
}

static void qqesignRecallBoolSetterBlocker(id self, SEL _cmd, BOOL flag) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 阻止写入撤回标记: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return;
    }
    QQEOrigVoidOneBool orig = (QQEOrigVoidOneBool)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, flag);
}

static void qqesignRecallOneObjectBoolBlocker(id self, SEL _cmd, id arg1, BOOL arg2) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回入口: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return;
    }
    QQEOrigVoidOneObjBool orig = (QQEOrigVoidOneObjBool)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, arg1, arg2);
}

static id qqesignRecallDecouplingPushBlocker(id self, SEL _cmd, int pushType, BOOL isRecallPush) {
    if (pref_antiRevoke && isRecallPush) {
        NSLog(@"[QQESign] 拦截撤回 push 标识生成: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return nil;
    }
    QQEOrigIdIntBool orig = (QQEOrigIdIntBool)qqesignLookupRecallOriginal(self, _cmd);
    return orig ? orig(self, _cmd, pushType, isRecallPush) : nil;
}

static void qqesignRecallGrayTipBlocker(id self,
                                        SEL _cmd,
                                        id model,
                                        id vc,
                                        id contact,
                                        unsigned int busiId) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回灰条: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return;
    }
    QQEOrigVoidGrayTip orig = (QQEOrigVoidGrayTip)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, model, vc, contact, busiId);
}

static id qqesignRecallGrayTipElementInitBlocker(id self,
                                                 SEL _cmd,
                                                 NSInteger subElementType,
                                                 id revokeElement,
                                                 id proclamationElement,
                                                 id emojiReplyElement,
                                                 id groupElement,
                                                 id buddyElement,
                                                 id feedMsgElement,
                                                 id essenceElement,
                                                 id xmlElement,
                                                 id fileReceiptElement,
                                                 id localGrayTipElement,
                                                 id blockGrayTipElement,
                                                 id aioOpGrayTipElement,
                                                 id jsonGrayTipElement,
                                                 id walletGrayTipElement) {
    if (pref_antiRevoke && revokeElement) {
        gQQESignRecallGrayTipElementBlockedCount++;
        if (gQQESignRecallGrayTipElementBlockedCount <= 8 ||
            (gQQESignRecallGrayTipElementBlockedCount % 50) == 0) {
            NSLog(@"[QQESign] 拦截 NTQQ 撤回灰条构造 #%lu: -[%@ %@] subType=%ld",
                  (unsigned long)gQQESignRecallGrayTipElementBlockedCount,
                  NSStringFromClass([self class]),
                  NSStringFromSelector(_cmd),
                  (long)subElementType);
        }
        return nil;
    }

    QQEOrigIdGrayTipElementInit orig = (QQEOrigIdGrayTipElementInit)qqesignLookupRecallOriginal(self, _cmd);
    return orig ? orig(self,
                       _cmd,
                       subElementType,
                       revokeElement,
                       proclamationElement,
                       emojiReplyElement,
                       groupElement,
                       buddyElement,
                       feedMsgElement,
                       essenceElement,
                       xmlElement,
                       fileReceiptElement,
                       localGrayTipElement,
                       blockGrayTipElement,
                       aioOpGrayTipElement,
                       jsonGrayTipElement,
                       walletGrayTipElement) : nil;
}

static void qqesignRecallMsgRecall3Blocker(id self, SEL _cmd, int arg1, id arg2, unsigned long long arg3) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回入口: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return;
    }
    QQEOrigVoidMsgRecall3 orig = (QQEOrigVoidMsgRecall3)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, arg1, arg2, arg3);
}

static void qqesignRecallGuildPushBlocker(id self,
                                          SEL _cmd,
                                          long long arg1,
                                          long long arg2,
                                          long long arg3,
                                          int arg4,
                                          id arg5,
                                          id arg6,
                                          id arg7,
                                          id arg8,
                                          int arg9) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回入口: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return;
    }
    QQEOrigVoidGuildPush orig = (QQEOrigVoidGuildPush)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9);
}

static void qqesignRecallNotifPostOneBlocker(id self, SEL _cmd, id notification) {
    NSString *name = nil;
    if ([notification respondsToSelector:@selector(name)]) {
        name = ((NSNotification *)notification).name;
    }
    if (pref_antiRevoke && qqesignIsRecallNotificationName(name)) {
        NSLog(@"[QQESign] 拦截撤回通知派发: -[%@ %@] %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd), name);
        return;
    }
    QQEOrigVoidOneObj orig = (QQEOrigVoidOneObj)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, notification);
}

static void qqesignRecallNotifPostTwoBlocker(id self, SEL _cmd, id name, id object) {
    NSString *notifName = [name isKindOfClass:[NSString class]] ? (NSString *)name : nil;
    if (pref_antiRevoke && qqesignIsRecallNotificationName(notifName)) {
        NSLog(@"[QQESign] 拦截撤回通知派发: -[%@ %@] %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd), notifName);
        return;
    }
    QQEOrigVoidTwoObj orig = (QQEOrigVoidTwoObj)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, name, object);
}

static void qqesignRecallNotifPostThreeBlocker(id self, SEL _cmd, id name, id object, id userInfo) {
    NSString *notifName = [name isKindOfClass:[NSString class]] ? (NSString *)name : nil;
    if (pref_antiRevoke && qqesignIsRecallNotificationName(notifName)) {
        NSLog(@"[QQESign] 拦截撤回通知派发: -[%@ %@] %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd), notifName);
        return;
    }
    QQEOrigVoidThreeObj orig = (QQEOrigVoidThreeObj)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, name, object, userInfo);
}

static NSUInteger qqesignInstallRecallHooksPass(const char *reason) {
    NSUInteger installed = 0;

    @try {
        static const QQESignRecallMethodSpec specs[] = {
            // 普通消息主链
            { "QQMessageRecallNetEngine", "parseC2CRecallNotify:bufferLen:subcmd:model:",
              "B40@0:8r^v16i24i28^{RecallModel=}32", (IMP)qqesignRecallNetEngineBlocker, "c2c-net" },
            { "QQMessageRecallModule", "convertRecallItemToMsg:recallModel:msgType:bindUin:",
              "@44@0:8^v16^v24i32Q36", (IMP)qqesignRecallConvertBlocker, "module-convert" },
            { "QQMessageDecouplingBridge", "recallMessagePair:",
              "v24@0:8@16", (IMP)qqesignRecallBridgeBlocker, "bridge-apply" },

            // 特殊分支保留
            { "QQMessageRecallModule", "handleSideAccountRecallNotify:bufferLen:subcmd:bindUin:tracelessFlag:",
              "@48@0:8r^v16i24i28Q32^B40", (IMP)qqesignRecallModuleFullBlocker, "side-account" },
            { "QQMessageDecouplingBridge", "generatePushUniqueIdentifier:isRecallPush:",
              "@24@0:8i16B20", (IMP)qqesignRecallDecouplingPushBlocker, "bridge-push-id" },
            { "OCIKernelMsgService", "getRecallMsgsByMsgId:msgIds:cb:",
              "v40@0:8@16@24@32", (IMP)qqesignRecallThreeObjectBlocker, "kernel-get-recall" },
            { "_TtC15NTKernelAdapter14MessageService", "getRecallMsgsWithPeer:msgIds:cb:",
              "v40@0:8@16@24@?32", (IMP)qqesignRecallThreeObjectBlocker, "swift-kernel-get-recall" },
            { "OCMsgRecallInfo", "isRecallNotify",
              "B16@0:8", (IMP)qqesignRecallBoolZeroArgBlocker, "msg-recall-flag" },
            { "OCMsgRecallInfo", "isTracelessRecall",
              "B16@0:8", (IMP)qqesignRecallBoolZeroArgBlocker, "msg-traceless-flag" },
            { "OCMsgRecallInfo", "setIsRecallNotify:",
              "v20@0:8B16", (IMP)qqesignRecallBoolSetterBlocker, "msg-recall-set" },
            { "OCMsgRecallInfo", "setIsTracelessRecall:",
              "v20@0:8B16", (IMP)qqesignRecallBoolSetterBlocker, "msg-traceless-set" },

            // 你现有代码里值得保留的显式补点
            { "GroupEmotionManager", "recallMessagePair:",
              "v24@0:8@16", (IMP)qqesignRecallBridgeBlocker, "group-emotion" },
            { "QQAIOCell", "updateCellViewRecall",
              "v16@0:8", (IMP)qqesignRecallZeroArgBlocker, "aio-cell-recall" },
            { "NudgeActionManager", "insertRecallGrayTips2AioIfneed:isGroup:",
              "v28@0:8@16B24", (IMP)qqesignRecallOneObjectBoolBlocker, "nudge-graytip" },

            // 少量明确可见的表现层补漏
            { "QQGProMsgPushManager", "msgRecallMsgNotication:",
              "v24@0:8@16", (IMP)qqesignRecallOneObjectBlocker, "gpro-push" },
            { "QQChatFilesRichMediaHandler", "findRecallModelAndRemove:",
              "B24@0:8@16", (IMP)qqesignRecallBoolOneObjectBlocker, "chat-files-richmedia" },
            { "QQChatFilesViewController", "msgRecallMsgNoti:",
              "v24@0:8@16", (IMP)qqesignRecallOneObjectBlocker, "chat-files" },
            { "QQChatFilesViewController", "showRecallAlert",
              "v16@0:8", (IMP)qqesignRecallZeroArgBlocker, "chat-files-alert" },
            { "QQRichMediaChatImagePhotoBrowserViewController", "msgRecallMsgNoti:",
              "v24@0:8@16", (IMP)qqesignRecallOneObjectBlocker, "richmedia-browser" },
            { "QQRichMediaChatImagePhotoBrowserViewController", "msgRecallMsgNotiForGProMsg:",
              "v24@0:8@16", (IMP)qqesignRecallOneObjectBlocker, "richmedia-gpro" },
            { "QQRichMediaChatImagePhotoBrowserViewController", "onFileRecallNofi:",
              "v24@0:8@16", (IMP)qqesignRecallOneObjectBlocker, "richmedia-file-recall" },
            { "QQRichMediaChatImagePhotoBrowserViewController", "showRecallAlert",
              "v16@0:8", (IMP)qqesignRecallZeroArgBlocker, "richmedia-alert" },

            // 浮层 / guild / UI 兜底
            { "_TtC15AIOPhotoBrowser31NTAIOPhotoBrowserViewController", "receiveRecallNotification:",
              "v24@0:8@16", (IMP)qqesignRecallOneObjectBlocker, "photo-browser-receive" },
            { "_TtC9NTAIOChat21NTStreamMsgAIOHandler", "receiveRecallNotification:",
              "v24@0:8@16", (IMP)qqesignRecallOneObjectBlocker, "stream-receive" },
            { "_TtC9NTAIOChat20NTAIOFloatEarManager", "onRecvRecallMsg:",
              "v24@0:8@16", (IMP)qqesignRecallOneObjectBlocker, "float-ear" },
            { "_TtC9NTAIOChat17NTAIOFloatEarPart", "recallMessageWithNotification:",
              "v24@0:8@16", (IMP)qqesignRecallOneObjectBlocker, "float-ear-part" },
            { "NTGuildMsgListener", "onMsgRecall:peerUid:seq:",
              "v36@0:8i16@20Q28", (IMP)qqesignRecallMsgRecall3Blocker, "guild-listener" },
            { "_TtC13GuildNTKernel20SWIKernelMsgListener", "onMsgRecall:peerUid:seq:",
              "v36@0:8i16@20Q28", (IMP)qqesignRecallMsgRecall3Blocker, "guild-swift-listener" },
            { "KTIKernelMsgListener", "onMsgRecall:peerUid:seq:",
              "v36@0:8i16@20Q28", (IMP)qqesignRecallMsgRecall3Blocker, "kti-listener" },
            { "GProSDKListener", "onPushRevokeGuild:operatorTinyId:memberTinyId:memberType:guildInfo:channelMap:uncategorizedChannels:categoryList:sourceType:",
              "v80@0:8q16q24q32i40@44@52@60@68i76", (IMP)qqesignRecallGuildPushBlocker, "guild-push" },

            // UI 灰条兜底
            { "NTAIOGrayTipsOtherLinkRecallHandle", "grayTipsEventWithModel:curVC:contact:busiId:",
              "v44@0:8@16@24@32I40", (IMP)qqesignRecallGrayTipBlocker, "gray-tip" },
            { "OCGrayTipElement", "initWithSubElementType:revokeElement:proclamationElement:emojiReplyElement:groupElement:buddyElement:feedMsgElement:essenceElement:xmlElement:fileReceiptElement:localGrayTipElement:blockGrayTipElement:aioOpGrayTipElement:jsonGrayTipElement:walletGrayTipElement:",
              NULL, (IMP)qqesignRecallGrayTipElementInitBlocker, "gray-tip-revoke-element" },
            { "NSNotificationCenter", "postNotification:",
              "v24@0:8@16", (IMP)qqesignRecallNotifPostOneBlocker, "notif-post-1" },
            { "NSNotificationCenter", "postNotificationName:object:",
              "v32@0:8@16@24", (IMP)qqesignRecallNotifPostTwoBlocker, "notif-post-2" },
            { "NSNotificationCenter", "postNotificationName:object:userInfo:",
              "v40@0:8@16@24@32", (IMP)qqesignRecallNotifPostThreeBlocker, "notif-post-3" },
        };

        for (NSUInteger i = 0; i < sizeof(specs) / sizeof(specs[0]); i++) {
            Class cls = objc_getClass(specs[i].className);
            if (!cls) continue;
            installed += qqesignSwizzleRecallMethodOnClass(cls,
                                                           specs[i].selName,
                                                           specs[i].typeEncoding,
                                                           specs[i].newImp,
                                                           specs[i].tag);
        }

        installed += qqesignInstallKernelInlineHooksPass(reason);
    } @catch (NSException *e) {
        NSLog(@"[QQESign] 防撤回安装异常: %@ %@", e.name, e.reason);
    }

    if (installed > 0) {
        NSLog(@"[QQESign] %s 本轮新增防撤回 Hook: %lu",
              (reason ? reason : "anti-recall"),
              (unsigned long)installed);
    } else {
        NSLog(@"[QQESign] %s 本轮未新增防撤回 Hook",
              (reason ? reason : "anti-recall"));
    }
    return installed;
}

static void qqesignRecallImageAdded(const struct mach_header *mh, intptr_t vmaddr_slide) {
    (void)mh;
    (void)vmaddr_slide;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        qqesignInstallRecallHooksPass("dyld-add-image");
        qqesignInstallQZoneAdHooks("dyld-add-image");
        qqesignInstallDrawerHooks("dyld-add-image");
    });
}

static void qqesignInstallRecallHooksWithRetry(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            qqesignInstallRecallHooksPass("delayed-ctor");
            qqesignInstallQZoneAdHooks("delayed-ctor");
            qqesignInstallDrawerHooks("delayed-ctor");
        });

        _dyld_register_func_for_add_image(qqesignRecallImageAdded);

        NSArray<NSNumber *> *delays = @[@3.0, @8.0, @15.0, @30.0, @60.0];
        for (NSNumber *delay in delays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                qqesignInstallRecallHooksPass("retry");
                qqesignInstallQZoneAdHooks("retry");
                qqesignInstallDrawerHooks("retry");
            });
        }
    });
}

#pragma mark - 2. 闪照 — ObjC层 (OCPicElement / QQBasePhoto)
// ─────────────────────────────────────────────
// 两个类均经过 ObjC classlist 解析确认，isFlashPic / setIsFlashPic: 均存在于方法表中。
// 返回 NO 后，QQ 不再对这条消息应用闪照限制（倒计时、保存限制等）。

%hook OCPicElement

- (BOOL)isFlashPic {
    return pref_flashUnlimited ? NO : %orig;
}

- (void)setIsFlashPic:(BOOL)val {
    %orig(pref_flashUnlimited ? NO : val);
}

%end

%hook QQBasePhoto

- (BOOL)isFlashPic {
    return pref_flashUnlimited ? NO : %orig;
}

- (void)setIsFlashPic:(BOOL)val {
    %orig(pref_flashUnlimited ? NO : val);
}

%end

// ─────────────────────────────────────────────
#pragma mark - 3. 闪照 — NT Swift VC 层
// ─────────────────────────────────────────────
// Swift 类通过 @objc 桥接暴露给 ObjC runtime（__DATA_CONST,__objc_classlist 确认）

// 闪照浏览器 VC：拦截"隐藏/结束预览"使图片不消失
%hook _TtC15AIOPhotoBrowser43NTAIOFlashPicturePhotoBrowserViewController

- (void)hideFlashImgPreview {
    if (pref_flashUnlimited) {
        NSLog(@"[QQESign] 阻止 hideFlashImgPreview");
        return;
    }
    %orig;
}

- (void)finishFlashImgPreview {
    if (pref_flashUnlimited) {
        NSLog(@"[QQESign] 阻止 finishFlashImgPreview");
        return;
    }
    %orig;
}

- (void)hideSecretPictureImage {
    if (pref_flashUnlimited) return;
    %orig;
}

- (void)viewDidLoad {
    %orig;
}

%end

// 闪照"秘密"遮罩视图：隐藏倒计时遮罩
%hook _TtC15AIOPhotoBrowser39NTAIOFlashPicturePhotoBrowserSecretView

- (void)layoutSubviews {
    %orig;
    if (pref_flashUnlimited) {
        UIView *view = (UIView *)self;
        view.hidden = YES;
        view.alpha = 0;
    }
}

// 允许正常触摸（不拦截截图等操作）
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if (pref_flashUnlimited) return;
    %orig;
}

%end

// ─────────────────────────────────────────────
#pragma mark - 4. 自定义电量
// ─────────────────────────────────────────────

%hook UIDevice

- (float)batteryLevel {
    return pref_fakeBattery ? pref_batteryLevel : %orig;
}

- (UIDeviceBatteryState)batteryState {
    if (pref_fakeBattery) {
        return pref_isCharging ? UIDeviceBatteryStateCharging : UIDeviceBatteryStateUnplugged;
    }
    return %orig;
}

%end

// ─────────────────────────────────────────────
#pragma mark - 4.5 QZone Feed Ad Block

static NSString *const kQQESignQZoneAdHex = @"6164766572746973656D656E74";

static Ivar qqesignFindIvar(Class cls, const char *name) {
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        Ivar iv = class_getInstanceVariable(c, name);
        if (iv) return iv;
    }
    return NULL;
}

static id qqesignObjectIvar(id obj, const char *name) {
    if (!obj || !name) return nil;
    @try {
        Ivar iv = qqesignFindIvar([obj class], name);
        return iv ? object_getIvar(obj, iv) : nil;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static id qqesignCallZeroArgObject(id obj, SEL sel) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
    @try {
        id (*imp)(id, SEL) = (id (*)(id, SEL))[obj methodForSelector:sel];
        return imp ? imp(obj, sel) : nil;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSString *qqesignStringValue(id value) {
    if (!value) return nil;
    if ([value isKindOfClass:[NSString class]]) return (NSString *)value;
    @try {
        return [value description];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSString *qqesignQZoneFeedKey(id model) {
    if (!model) return nil;

    NSString *key = qqesignStringValue(qqesignObjectIvar(model, "_feedskey"));
    if (key.length > 0) return key;

    key = qqesignStringValue(qqesignObjectIvar(model, "_feedsKey"));
    if (key.length > 0) return key;

    id comm = qqesignObjectIvar(model, "_comm");
    key = qqesignStringValue(qqesignObjectIvar(comm, "_feedskey"));
    if (key.length > 0) return key;

    key = qqesignStringValue(qqesignObjectIvar(comm, "_feedsKey"));
    if (key.length > 0) return key;

    key = qqesignStringValue(qqesignCallZeroArgObject(model, @selector(feedsKey)));
    if (key.length > 0) return key;

    key = qqesignStringValue(qqesignCallZeroArgObject(model, @selector(feedskey)));
    return key.length > 0 ? key : nil;
}

static BOOL qqesignIsQZoneHardAdModel(id model) {
    if (!pref_qzoneAdBlock || !model) return NO;
    NSString *key = qqesignQZoneFeedKey(model);
    if (key.length == 0) return NO;

    if ([key rangeOfString:kQQESignQZoneAdHex options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    if ([key rangeOfString:@"advertisement" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}

static id qqesignQZonePresenterFeedList(id presenter) {
    id list = qqesignCallZeroArgObject(presenter, @selector(feedModelList));
    if (list) return list;
    return qqesignObjectIvar(presenter, "_feedModelList");
}

static id qqesignQZonePresenterModelAtIndexPath(id presenter, NSIndexPath *indexPath) {
    if (!presenter || !indexPath) return nil;
    id list = qqesignQZonePresenterFeedList(presenter);
    if (![list respondsToSelector:@selector(count)] || ![list respondsToSelector:@selector(objectAtIndex:)]) return nil;

    NSUInteger row = indexPath.row;
    @try {
        NSUInteger count = [list count];
        if (row >= count) return nil;
        return [list objectAtIndex:row];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static void qqesignApplyQZoneMutedState(UIView *view, BOOL muted) {
    if (![view isKindOfClass:[UIView class]]) return;
    view.hidden = muted;
    view.alpha = muted ? 0.0 : 1.0;
    view.userInteractionEnabled = !muted;
    view.clipsToBounds = YES;
}

static void qqesignMuteQZoneAdCell(id cell, BOOL muted) {
    if (![cell isKindOfClass:[UITableViewCell class]]) return;
    UITableViewCell *tvCell = (UITableViewCell *)cell;
    qqesignApplyQZoneMutedState(tvCell, muted);
    qqesignApplyQZoneMutedState(tvCell.contentView, muted);
    qqesignApplyQZoneMutedState(tvCell.backgroundView, muted);
    qqesignApplyQZoneMutedState(tvCell.selectedBackgroundView, muted);
}

static void qqesignMuteQZoneAdLayoutView(id view, BOOL muted) {
    if (![view isKindOfClass:[UIView class]]) return;
    qqesignApplyQZoneMutedState((UIView *)view, muted);
}

static void qqesignLogQZoneAdBlock(id model, NSString *source) {
    (void)model;
    (void)source;
}

%group QZoneAdBlockController

%hook MQZoneActiveFeedViewController

- (CGFloat)qz_tableView:(id)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    id presenter = qqesignObjectIvar(self, "_feedListPresenter");
    id model = qqesignQZonePresenterModelAtIndexPath(presenter, indexPath);
    if (qqesignIsQZoneHardAdModel(model)) {
        qqesignLogQZoneAdBlock(model, @"height");
        return 0.01;
    }
    return %orig;
}

- (id)tableViewForGroupFeedCell:(id)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath withFeedModel:(id)model {
    id cell = %orig;
    BOOL isAd = qqesignIsQZoneHardAdModel(model);
    qqesignMuteQZoneAdCell(cell, isAd);
    if (isAd) qqesignLogQZoneAdBlock(model, @"group-cell");
    return cell;
}

%end

%end // %group QZoneAdBlockController

%group QZoneAdBlockPresenter

%hook QZFeedListPresenter

- (CGFloat)heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    id model = qqesignQZonePresenterModelAtIndexPath(self, indexPath);
    if (qqesignIsQZoneHardAdModel(model)) {
        qqesignLogQZoneAdBlock(model, @"presenter-height");
        return 0.01;
    }
    return %orig;
}

- (id)tableView:(id)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    id model = qqesignQZonePresenterModelAtIndexPath(self, indexPath);
    id cell = %orig;
    BOOL isAd = qqesignIsQZoneHardAdModel(model);
    qqesignMuteQZoneAdCell(cell, isAd);
    if (isAd) qqesignLogQZoneAdBlock(model, @"presenter-cell");
    return cell;
}

%end

%end // %group QZoneAdBlockPresenter

%group QZoneAdBlockCell

%hook QzoneFeedCell

- (void)setFeedModel:(id)model {
    %orig;
    BOOL isAd = qqesignIsQZoneHardAdModel(model);
    qqesignMuteQZoneAdCell(self, isAd);
    if (isAd) qqesignLogQZoneAdBlock(model, @"cell-model");
}

- (void)prepareForReuse {
    %orig;
    qqesignMuteQZoneAdCell(self, NO);
}

+ (CGFloat)heightWithDetailNewFeedModel:(id)model
                              indexPath:(NSIndexPath *)indexPath
                           isFamousZone:(BOOL)isFamousZone
                             isFirstRow:(BOOL)isFirstRow
                        realLastSection:(BOOL)realLastSection
                   isInVideoCommentView:(BOOL)isInVideoCommentView
                  isInCommentDetailView:(BOOL)isInCommentDetailView {
    if (qqesignIsQZoneHardAdModel(model)) {
        qqesignLogQZoneAdBlock(model, @"cell-detail-height");
        return 0.01;
    }
    return %orig;
}

+ (CGFloat)heightWithNewFeedModel:(id)model {
    if (qqesignIsQZoneHardAdModel(model)) {
        qqesignLogQZoneAdBlock(model, @"cell-height");
        return 0.01;
    }
    return %orig;
}

+ (CGFloat)heightWithNewFeedModel:(id)model param:(id)param {
    if (qqesignIsQZoneHardAdModel(model)) {
        qqesignLogQZoneAdBlock(model, @"cell-height-param");
        return 0.01;
    }
    return %orig;
}

%end

%end // %group QZoneAdBlockCell

%group QZoneAdBlockLayout

%hook QzoneFeedLayoutView

- (void)setFeedModel:(id)model {
    %orig;
    BOOL isAd = qqesignIsQZoneHardAdModel(model);
    qqesignMuteQZoneAdLayoutView(self, isAd);
    if (isAd) qqesignLogQZoneAdBlock(model, @"layout-model");
}

%end

%end // %group QZoneAdBlockLayout

static BOOL gQQESignQZoneControllerHooksInstalled = NO;
static BOOL gQQESignQZonePresenterHooksInstalled = NO;
static BOOL gQQESignQZoneCellHooksInstalled = NO;
static BOOL gQQESignQZoneLayoutHooksInstalled = NO;

static void qqesignInstallQZoneAdHooks(const char *reason) {
    BOOL installed = NO;

    if (!gQQESignQZoneControllerHooksInstalled &&
        objc_getClass("MQZoneActiveFeedViewController")) {
        gQQESignQZoneControllerHooksInstalled = YES;
        %init(QZoneAdBlockController);
        installed = YES;
    }

    if (!gQQESignQZonePresenterHooksInstalled &&
        objc_getClass("QZFeedListPresenter")) {
        gQQESignQZonePresenterHooksInstalled = YES;
        %init(QZoneAdBlockPresenter);
        installed = YES;
    }

    if (!gQQESignQZoneCellHooksInstalled &&
        objc_getClass("QzoneFeedCell")) {
        gQQESignQZoneCellHooksInstalled = YES;
        %init(QZoneAdBlockCell);
        installed = YES;
    }

    if (!gQQESignQZoneLayoutHooksInstalled &&
        objc_getClass("QzoneFeedLayoutView")) {
        gQQESignQZoneLayoutHooksInstalled = YES;
        %init(QZoneAdBlockLayout);
        installed = YES;
    }

    if (installed) {
        NSLog(@"[QQESign] %s 安装好友动态去广告 Hook 完成 controller=%d presenter=%d cell=%d layout=%d",
              reason ? reason : "qzone-ads",
              gQQESignQZoneControllerHooksInstalled,
              gQQESignQZonePresenterHooksInstalled,
              gQQESignQZoneCellHooksInstalled,
              gQQESignQZoneLayoutHooksInstalled);
    }
}

// ─────────────────────────────────────────────
#pragma mark - 4.6 主页头像侧边抽屉入口屏蔽

// 思路 (Frida 实测验证过):
//   1. drawer cell 类是 DrawerDynamicIconViewCell, 标签是 QUIBlendLabelView
//   2. 数据源是 QUIListView 的运行时子类 QUIListView_redPoint_extendClass_container,
//      子类重写 cellForRow 不调 super, 标题靠 _customGenerateCellBlock 闭包配置,
//      所以 model (NewDrawerListSingleLineConfig) 自身不存标题字符串
//   3. 关键时序: setText 是 cellForRow 调用栈内部触发的,
//      用一个全局 cellForRow context (currentPart + currentIndexPath) 接力
//   4. UITableView.reloadData hook 检测到 QUIListView_* 子类时,
//      用 runtime swizzle 动态拦截子类的 cellForRow (子类 install 时不存在)
//   5. heightForRow 在 QUIListView 基类, 不被子类 override, %hook 基类即可
//   6. begin/endUpdates 强制 UITableView 重新询问行高

static NSString *const kQQESignDrawerCellClass = @"DrawerDynamicIconViewCell";

// cellForRow 调用栈内的上下文 (单线程主队列, 不需要锁)
static __weak id qqesignDrawerCurrentPart = nil;
static NSIndexPath *qqesignDrawerCurrentIP = nil;

// 已标记屏蔽的 model 集合; weak key 自动随 model 释放
static NSMapTable<id, NSNumber *> *qqesignDrawerBlockedModels = nil;
// 已调度高度刷新的 tableView 防重 (weak)
static NSHashTable<UITableView *> *qqesignDrawerRefreshScheduled = nil;
// 已动态 swizzle 的子类名集合
static NSMutableSet<NSString *> *qqesignDrawerSubclassHooked = nil;
// 动态子类 cellForRow 的原始 IMP (一份, 实测只有一个子类 QUIListView_redPoint_extendClass_container)
static IMP qqesignDrawerSubclassOrigCellForRow = NULL;

static void qqesignDrawerEnsureState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        qqesignDrawerBlockedModels =
            [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory
                                  valueOptions:NSPointerFunctionsStrongMemory];
        qqesignDrawerRefreshScheduled = [NSHashTable weakObjectsHashTable];
        qqesignDrawerSubclassHooked = [NSMutableSet set];
    });
}

static BOOL qqesignDrawerAnyEnabled(void) {
    return pref_drawerHideAlbum || pref_drawerHideFavorite || pref_drawerHideFiles ||
           pref_drawerHideWallet || pref_drawerHideVip || pref_drawerHideDecor ||
           pref_drawerHideFreedata;
}

static BOOL qqesignDrawerShouldBlockText(NSString *text) {
    if (text.length == 0) return NO;
    if (pref_drawerHideAlbum    && [text isEqualToString:@"相册"]) return YES;
    if (pref_drawerHideFavorite && [text isEqualToString:@"收藏"]) return YES;
    if (pref_drawerHideFiles    && [text isEqualToString:@"文件"]) return YES;
    if (pref_drawerHideWallet   && ([text isEqualToString:@"钱包"] ||
                                    [text isEqualToString:@"QQ钱包"])) return YES;
    if (pref_drawerHideVip      && ([text isEqualToString:@"会员中心"] ||
                                    [text isEqualToString:@"QQ会员"] ||
                                    [text isEqualToString:@"超级会员"])) return YES;
    if (pref_drawerHideDecor    && ([text isEqualToString:@"个性装扮"] ||
                                    [text isEqualToString:@"装扮"])) return YES;
    if (pref_drawerHideFreedata && ([text isEqualToString:@"免流量"] ||
                                    [text isEqualToString:@"免流"])) return YES;
    return NO;
}

static void qqesignDrawerClearAllBlockedModels(void) {
    qqesignDrawerEnsureState();
    [qqesignDrawerBlockedModels removeAllObjects];
}

static UIView *qqesignDrawerFindAncestorCell(UIView *v) {
    UIView *cur = v;
    for (int i = 0; cur && i < 15; i++) {
        if ([NSStringFromClass([cur class]) isEqualToString:kQQESignDrawerCellClass]) return cur;
        cur = cur.superview;
    }
    return nil;
}

static UITableView *qqesignDrawerFindAncestorTableView(UIView *v) {
    UIView *cur = v;
    for (int i = 0; cur && i < 18; i++) {
        if ([cur isKindOfClass:[UITableView class]]) return (UITableView *)cur;
        cur = cur.superview;
    }
    return nil;
}

// 取 model: 优先 rowModelWithIndexPath: (QUIListView), 退到 itemWithIndexPath:
static id qqesignDrawerItemFromPart(id partObj, NSIndexPath *ip) {
    if (!partObj || !ip) return nil;
    SEL sels[] = { @selector(rowModelWithIndexPath:), @selector(itemWithIndexPath:) };
    for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
        if ([partObj respondsToSelector:sels[i]]) {
            @try {
                IMP imp = [partObj methodForSelector:sels[i]];
                id (*fn)(id, SEL, id) = (id (*)(id, SEL, id))imp;
                id r = fn(partObj, sels[i], ip);
                if (r) return r;
            } @catch (__unused NSException *e) {}
        }
    }
    return nil;
}

static void qqesignDrawerScheduleHeightRefresh(UITableView *tv) {
    if (!tv) return;
    qqesignDrawerEnsureState();
    if ([qqesignDrawerRefreshScheduled containsObject:tv]) return;
    [qqesignDrawerRefreshScheduled addObject:tv];

    __weak UITableView *weakTV = tv;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        UITableView *strong = weakTV;
        if (strong) {
            @try {
                [strong beginUpdates];
                [strong endUpdates];
            } @catch (__unused NSException *e) {}
            [qqesignDrawerRefreshScheduled removeObject:strong];
        }
    });
}

// 动态子类 cellForRow 替换 IMP
static id qqesignDrawerSubclassCellForRowReplacement(id self, SEL _cmd,
                                                     UITableView *tableView,
                                                     NSIndexPath *indexPath) {
    id prevPart = qqesignDrawerCurrentPart;
    NSIndexPath *prevIP = qqesignDrawerCurrentIP;
    qqesignDrawerCurrentPart = self;
    qqesignDrawerCurrentIP = indexPath;
    id result = nil;
    if (qqesignDrawerSubclassOrigCellForRow) {
        @try {
            id (*orig)(id, SEL, UITableView *, NSIndexPath *) =
                (id (*)(id, SEL, UITableView *, NSIndexPath *))qqesignDrawerSubclassOrigCellForRow;
            result = orig(self, _cmd, tableView, indexPath);
        } @catch (NSException *e) {
            qqesignDrawerCurrentPart = prevPart;
            qqesignDrawerCurrentIP = prevIP;
            @throw;
        }
    }
    qqesignDrawerCurrentPart = prevPart;
    qqesignDrawerCurrentIP = prevIP;
    return result;
}

static void qqesignDrawerInstallSubclassHook(NSString *className, UITableView *tvToReload) {
    if (!className || className.length == 0) return;
    qqesignDrawerEnsureState();
    if ([qqesignDrawerSubclassHooked containsObject:className]) return;

    Class cls = NSClassFromString(className);
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, @selector(tableView:cellForRowAtIndexPath:));
    if (!m) return;

    // 第一次 swizzle: 保存原 IMP, 替换. 同一个 IMP 即便后续多次子类也复用 (它们都从 QUIListView 继承基础逻辑,
    // 但运行时子类各自有自己的覆写 IMP). 暂时按 "只见过一种子类" 处理.
    if (!qqesignDrawerSubclassOrigCellForRow) {
        qqesignDrawerSubclassOrigCellForRow = method_getImplementation(m);
    }
    method_setImplementation(m, (IMP)qqesignDrawerSubclassCellForRowReplacement);
    [qqesignDrawerSubclassHooked addObject:className];
    NSLog(@"[QQESign] 抽屉子类 cellForRow 已动态拦截: %@", className);

    if (tvToReload && qqesignDrawerAnyEnabled()) {
        __weak UITableView *weakTV = tvToReload;
        dispatch_async(dispatch_get_main_queue(), ^{
            UITableView *strong = weakTV;
            if (strong) {
                @try { [strong reloadData]; } @catch (__unused NSException *e) {}
            }
        });
    }
}

%group QQESignDrawerLabel

%hook UILabel

- (void)setText:(NSString *)text {
    %orig;
    if (!qqesignDrawerAnyEnabled() || text.length == 0) return;
    if (!qqesignDrawerShouldBlockText(text)) return;

    UIView *cell = qqesignDrawerFindAncestorCell(self);
    if (!cell) return;

    // 软隐藏 (即便高度塌陷失败,视觉上也不可见)
    cell.hidden = YES;
    cell.alpha = 0;
    cell.userInteractionEnabled = NO;
    cell.clipsToBounds = YES;

    // 用 cellForRow context 反查 model
    id part = qqesignDrawerCurrentPart;
    NSIndexPath *ip = qqesignDrawerCurrentIP;
    if (!part || !ip) return;
    id item = qqesignDrawerItemFromPart(part, ip);
    if (!item) return;

    qqesignDrawerEnsureState();
    if ([qqesignDrawerBlockedModels objectForKey:item]) return;
    [qqesignDrawerBlockedModels setObject:@YES forKey:item];

    UITableView *tv = nil;
    if ([part respondsToSelector:@selector(tableView)]) {
        @try { tv = [part tableView]; } @catch (__unused NSException *e) {}
    }
    if (!tv) tv = qqesignDrawerFindAncestorTableView(cell);
    qqesignDrawerScheduleHeightRefresh(tv);
}

%end

%end // group QQESignDrawerLabel

%group QQESignDrawerCell

%hook DrawerDynamicIconViewCell

- (void)prepareForReuse {
    %orig;
    UIView *view = (UIView *)self;
    view.hidden = NO;
    view.alpha = 1.0;
    view.userInteractionEnabled = YES;
}

%end

%end // group QQESignDrawerCell

%group QQESignDrawerList

%hook QUIListView

// 基类 cellForRow: 即便子类不调 super, 该 hook 仍可在直接使用基类的场景生效
- (id)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    id prevPart = qqesignDrawerCurrentPart;
    NSIndexPath *prevIP = qqesignDrawerCurrentIP;
    qqesignDrawerCurrentPart = self;
    qqesignDrawerCurrentIP = indexPath;
    id cell = %orig;
    qqesignDrawerCurrentPart = prevPart;
    qqesignDrawerCurrentIP = prevIP;
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (qqesignDrawerAnyEnabled()) {
        id item = qqesignDrawerItemFromPart(self, indexPath);
        if (item) {
            qqesignDrawerEnsureState();
            if ([qqesignDrawerBlockedModels objectForKey:item]) return 0.01;
        }
    }
    return %orig;
}

%end

%end // group QQESignDrawerList

%group QQESignDrawerReload

%hook UITableView

- (void)reloadData {
    %orig;
    if (!qqesignDrawerAnyEnabled()) return;
    @try {
        id ds = [self dataSource];
        if (!ds) return;
        NSString *dsName = NSStringFromClass([ds class]);
        if (![dsName hasPrefix:@"QUIListView_"]) return;
        qqesignDrawerInstallSubclassHook(dsName, self);
    } @catch (__unused NSException *e) {}
}

%end

%end // group QQESignDrawerReload

static BOOL gQQESignDrawerLabelHooksInstalled = NO;
static BOOL gQQESignDrawerCellHooksInstalled = NO;
static BOOL gQQESignDrawerListHooksInstalled = NO;
static BOOL gQQESignDrawerReloadHooksInstalled = NO;

static void qqesignInstallDrawerHooks(const char *reason) {
    qqesignDrawerEnsureState();
    BOOL installed = NO;

    if (!gQQESignDrawerLabelHooksInstalled) {
        gQQESignDrawerLabelHooksInstalled = YES;
        %init(QQESignDrawerLabel);
        installed = YES;
    }
    if (!gQQESignDrawerReloadHooksInstalled) {
        gQQESignDrawerReloadHooksInstalled = YES;
        %init(QQESignDrawerReload);
        installed = YES;
    }
    if (!gQQESignDrawerCellHooksInstalled && objc_getClass("DrawerDynamicIconViewCell")) {
        gQQESignDrawerCellHooksInstalled = YES;
        %init(QQESignDrawerCell);
        installed = YES;
    }
    if (!gQQESignDrawerListHooksInstalled && objc_getClass("QUIListView")) {
        gQQESignDrawerListHooksInstalled = YES;
        %init(QQESignDrawerList);
        installed = YES;
    }

    if (installed) {
        NSLog(@"[QQESign] %s 抽屉入口屏蔽 Hook 安装 label=%d reload=%d cell=%d list=%d",
              reason ? reason : "drawer-hide",
              gQQESignDrawerLabelHooksInstalled,
              gQQESignDrawerReloadHooksInstalled,
              gQQESignDrawerCellHooksInstalled,
              gQQESignDrawerListHooksInstalled);
    }
}

#pragma mark - 5. 设置入口
// ─────────────────────────────────────────────

// NT 版 QQ 设置页（__DATA_CONST,__objc_classlist 中存在）
%hook QQNewSettingsViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    addESignButton((UIViewController *)self, @selector(qqesign_openSettings));
}

%new
- (void)qqesign_openSettings { showQQESignSettings(); }

%end

%hook QQSettingsBaseViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    addESignButton((UIViewController *)self, @selector(qqesign_openSettings));
}

%new
- (void)qqesign_openSettings { showQQESignSettings(); }

%end

// 后备：摇一摇打开设置
%hook UIWindow

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    %orig;
    if (motion == UIEventSubtypeMotionShake) showQQESignSettings();
}

%end

// ─────────────────────────────────────────────
#pragma mark - 6. 网络层防撤回 (SSLRead Hook)
// ─────────────────────────────────────────────

typedef OSStatus (*QQESSLReadOriginalFn)(void *context, void *data, size_t dataLength, size_t *processed);
static QQESSLReadOriginalFn orig_SSLRead = NULL;

static OSStatus hooked_SSLRead(void *context, void *data, size_t dataLength, size_t *processed) {
    OSStatus ret = orig_SSLRead(context, data, dataLength, processed);
    if (ret == noErr && processed && *processed > 0 && pref_antiRevoke) {
        uint8_t *buf = (uint8_t *)data;
        size_t n = *processed;
        for (size_t i = 0; i + 3 < n; i++) {
            if (buf[i] == 0x08) {
                uint32_t cmd = 0; int shift = 0; size_t j = i + 1;
                while (j < n && (buf[j] & 0x80) && shift < 28) { cmd |= (uint32_t)(buf[j] & 0x7F) << shift; shift += 7; j++; }
                if (j < n) cmd |= (uint32_t)(buf[j] & 0x7F) << shift;
                if (cmd == 0x210 || cmd == 0x211) {
                    QQELog(@"🔒 SSLRead拦截撤回 cmd=0x%X sz=%zu", cmd, n);
                    memset(buf, 0, n); *processed = 0; return errSSLClosedNoNotify;
                }
            }
            if (n - i >= 6 && (memcmp(buf + i, "recall", 6) == 0 || memcmp(buf + i, "revoke", 6) == 0 || memcmp(buf + i, "Recall", 6) == 0)) {
                QQELog(@"🔒 SSLRead拦截撤回文本 sz=%zu", n);
                memset(buf, 0, n); *processed = 0; return errSSLClosedNoNotify;
            }
        }
    }
    return ret;
}

static void qqesign_installNetworkHooks(void) {
    if (!qqesignResolveInlineHookBackend()) { QQELog(@"⚠️ 网络层未安装:Dobby不可用"); return; }
    void *h = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW | RTLD_GLOBAL);
    if (!h) { QQELog(@"⚠️ Security.framework加载失败"); return; }
    void *sslRead = dlsym(h, "SSLRead");
    if (!sslRead) { QQELog(@"⚠️ SSLRead符号未找到"); dlclose(h); return; }
    int rc = gQQEDobbyHook(sslRead, (void *)hooked_SSLRead, (void **)&orig_SSLRead);
    if (rc == 0) QQELog(@"✅ SSLRead Hook已安装 %p", sslRead);
    else QQELog(@"❌ SSLRead Hook失败 rc=%d", rc);
}

// ─────────────────────────────────────────────
#pragma mark - Constructor
// ─────────────────────────────────────────────

%ctor {
    @autoreleasepool {
        loadPrefs();
        %init;
        NSLog(@"[QQESign] runtime log file: %@", qqesignRuntimeLogPath());
        qqesignInstallRecallHooksWithRetry();
        qqesign_installNetworkHooks(); // ★ 网络层SSLRead拦截
        NSLog(@"[QQESign] v2.3 Loaded (NT架构) antiRevoke=%d flashUnlimited=%d qzoneAd=%d fakeBatt=%d drawerHide=%d",
              pref_antiRevoke, pref_flashUnlimited, pref_qzoneAdBlock, pref_fakeBattery,
              (pref_drawerHideAlbum || pref_drawerHideFavorite || pref_drawerHideFiles ||
               pref_drawerHideWallet || pref_drawerHideVip || pref_drawerHideDecor ||
               pref_drawerHideFreedata));
    }
}
