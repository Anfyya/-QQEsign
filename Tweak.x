
// QQESign — 免越狱轻松签版 (NT架构)
// 防撤回 / 闪照保存+无限查看 / 自定义设备名+电量
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
static BOOL   pref_flashSave      = YES;
static BOOL   pref_fakeDevice     = NO;
static NSString *pref_deviceName  = @"iPhone 16 Pro";
static BOOL   pref_fakeBattery    = NO;
static float  pref_batteryLevel   = 0.80f;
static BOOL   pref_isCharging     = NO;

static NSUserDefaults *tweakDefaults(void) {
    static NSUserDefaults *ud = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ud = [[NSUserDefaults alloc] initWithSuiteName:kPrefSuite];
        [ud registerDefaults:@{
            @"antiRevoke":     @YES,
            @"flashUnlimited": @YES,
            @"flashSave":      @YES,
            @"fakeDevice":     @NO,
            @"deviceName":     @"iPhone 16 Pro",
            @"fakeBattery":    @NO,
            @"batteryLevel":   @0.80f,
            @"isCharging":     @NO,
        }];
    });
    return ud;
}

static void qqesignClearModelAntiRecallRuntimeCache(void);

static void loadPrefs(void) {
    NSUserDefaults *ud = tweakDefaults();
    pref_antiRevoke     = [ud boolForKey:@"antiRevoke"];
    pref_flashUnlimited = [ud boolForKey:@"flashUnlimited"];
    pref_flashSave      = [ud boolForKey:@"flashSave"];
    pref_fakeDevice     = [ud boolForKey:@"fakeDevice"];
    pref_fakeBattery    = [ud boolForKey:@"fakeBattery"];
    pref_batteryLevel   = [ud floatForKey:@"batteryLevel"];
    pref_isCharging     = [ud boolForKey:@"isCharging"];
    NSString *name = [ud stringForKey:@"deviceName"];
    if (name.length > 0) pref_deviceName = name;
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
    _sectionTitles = @[@"消息防撤回", @"闪照设置", @"自定义设备名", @"自定义电量", @"关于"];
    _sections = @[
        @[@{@"title": @"开启防撤回", @"key": @"antiRevoke", @"type": @"switch"}],
        @[
            @{@"title": @"无限次查看闪照", @"key": @"flashUnlimited", @"type": @"switch"},
            @{@"title": @"自动保存闪照到相册", @"key": @"flashSave", @"type": @"switch"},
        ],
        @[
            @{@"title": @"启用自定义设备名", @"key": @"fakeDevice", @"type": @"switch"},
            @{@"title": @"设备名称", @"key": @"deviceName", @"type": @"text"},
        ],
        @[
            @{@"title": @"启用自定义电量", @"key": @"fakeBattery", @"type": @"switch"},
            @{@"title": @"电量 (0~100)", @"key": @"batteryLevel", @"type": @"number"},
            @{@"title": @"模拟充电中", @"key": @"isCharging", @"type": @"switch"},
        ],
        @[@{@"title": @"QQESign v2.0\n适配NT架构 · 防撤回 · 闪照解锁\n自定义设备名与电量", @"type": @"info"}],
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
            tf.placeholder = @"iPhone 16 Pro";
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
        QQELog(@"[QQESign] 防撤回开关关闭：本轮运行缓存已清空，后续撤回放行");
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



// ─────────────────────────────────────────────
#pragma mark - 1.1 Model anti-recall (persistent, no mark)
// ─────────────────────────────────────────────
// 这套是实际生效的 NT 模型层防撤回：
//   - 缓存所有非撤回态 OCMsgRecord.elements（文字/图片/视频/链接等）
//   - 当同一 key 被改成撤回态 5/4 或 recallTime 非 0 时，恢复原 elements + 原类型
//   - 不再添加【防撤回】文字标识
//   - 默认最多持久化 1000 条；开关关闭时完全放行

static const NSUInteger kQQEModelAntiRecallMaxItems = 1000;
static const NSTimeInterval kQQEModelAntiRecallTTL = 30 * 60;

static QQEOrigVoidOneObj gQQEOrigOCMsgRecordSetElements = NULL;
typedef void (*QQEOrigVoidSetRecallTime)(id, SEL, unsigned long long);
static QQEOrigVoidSetRecallTime gQQEOrigOCMsgRecordSetRecallTime = NULL;
static BOOL gQQEModelAntiRecallHooksInstalled = NO;

static NSMutableDictionary<NSString *, NSMutableDictionary *> *gQQEModelAntiRecallCache = nil;
static NSMutableArray<NSString *> *gQQEModelAntiRecallOrder = nil;
static NSMutableDictionary<NSString *, NSMutableDictionary *> *gQQEModelAntiRecallDisk = nil;
static BOOL gQQEModelAntiRecallDiskLoaded = NO;
static BOOL gQQEModelAntiRecallSaveScheduled = NO;

static Ivar qqeFindIvarInHierarchy(Class cls, const char *name) {
    if (!cls || !name) return NULL;
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        Ivar iv = class_getInstanceVariable(c, name);
        if (iv) return iv;
    }
    return NULL;
}

static long long qqeReadNumericIvar(id obj, const char *name) {
    if (!obj || !name) return 0;
    Ivar iv = qqeFindIvarInHierarchy([obj class], name);
    if (!iv) return 0;
    const char *type = ivar_getTypeEncoding(iv);
    uint8_t *base = (uint8_t *)(__bridge void *)obj;
    uint8_t *addr = base + ivar_getOffset(iv);
    if (!type || !type[0]) return 0;

    @try {
        switch (type[0]) {
            case 'c': return *(char *)addr;
            case 'C': return *(unsigned char *)addr;
            case 's': return *(short *)addr;
            case 'S': return *(unsigned short *)addr;
            case 'i': return *(int *)addr;
            case 'I': return *(unsigned int *)addr;
            case 'l': return *(long *)addr;
            case 'L': return *(unsigned long *)addr;
            case 'q': return *(long long *)addr;
            case 'Q': return (long long)(*(unsigned long long *)addr);
            case 'B': return *(BOOL *)addr;
            case '@': {
                id v = object_getIvar(obj, iv);
                if ([v respondsToSelector:@selector(longLongValue)]) return [v longLongValue];
                return 0;
            }
            default: return 0;
        }
    } @catch (__unused NSException *e) {
        return 0;
    }
}

static NSString *qqeReadObjectIvarString(id obj, const char *name) {
    if (!obj || !name) return @"";
    Ivar iv = qqeFindIvarInHierarchy([obj class], name);
    if (!iv) return @"";
    const char *type = ivar_getTypeEncoding(iv);
    @try {
        if (type && type[0] == '@') {
            id v = object_getIvar(obj, iv);
            if (!v) return @"";
            return [v description] ?: @"";
        }
        long long n = qqeReadNumericIvar(obj, name);
        return [NSString stringWithFormat:@"%lld", n];
    } @catch (__unused NSException *e) {
        return @"";
    }
}

static void qqeWriteNumericIvar(id obj, const char *name, long long value) {
    if (!obj || !name) return;
    Ivar iv = qqeFindIvarInHierarchy([obj class], name);
    if (!iv) return;
    const char *type = ivar_getTypeEncoding(iv);
    uint8_t *base = (uint8_t *)(__bridge void *)obj;
    uint8_t *addr = base + ivar_getOffset(iv);
    if (!type || !type[0]) return;

    @try {
        switch (type[0]) {
            case 'c': *(char *)addr = (char)value; break;
            case 'C': *(unsigned char *)addr = (unsigned char)value; break;
            case 's': *(short *)addr = (short)value; break;
            case 'S': *(unsigned short *)addr = (unsigned short)value; break;
            case 'i': *(int *)addr = (int)value; break;
            case 'I': *(unsigned int *)addr = (unsigned int)value; break;
            case 'l': *(long *)addr = (long)value; break;
            case 'L': *(unsigned long *)addr = (unsigned long)value; break;
            case 'q': *(long long *)addr = (long long)value; break;
            case 'Q': *(unsigned long long *)addr = (unsigned long long)value; break;
            case 'B': *(BOOL *)addr = (BOOL)value; break;
            case '@': object_setIvar(obj, iv, @(value)); break;
            default: break;
        }
    } @catch (__unused NSException *e) {
    }
}

static void qqeWriteObjectIvar(id obj, const char *name, id value) {
    if (!obj || !name) return;
    Ivar iv = qqeFindIvarInHierarchy([obj class], name);
    if (!iv) return;
    const char *type = ivar_getTypeEncoding(iv);
    if (!type || type[0] != '@') return;
    @try { object_setIvar(obj, iv, value); } @catch (__unused NSException *e) {}
}

static NSString *qqeModelRecordKey(id record) {
    NSString *peer = qqeReadObjectIvarString(record, "_peerUid");
    long long msgId = qqeReadNumericIvar(record, "_msgId");
    long long msgRandom = qqeReadNumericIvar(record, "_msgRandom");
    long long msgSeq = qqeReadNumericIvar(record, "_msgSeq");
    if (peer.length == 0 || msgId == 0 || msgRandom == 0) return nil;
    return [NSString stringWithFormat:@"p=%@|i=%lld|r=%lld|s=%lld", peer, msgId, msgRandom, msgSeq];
}

static NSString *qqeModelBrief(id record) {
    return [NSString stringWithFormat:@"%lld/%lld id=%lld r=%lld s=%lld",
            qqeReadNumericIvar(record, "_msgType"),
            qqeReadNumericIvar(record, "_subMsgType"),
            qqeReadNumericIvar(record, "_msgId"),
            qqeReadNumericIvar(record, "_msgRandom"),
            qqeReadNumericIvar(record, "_msgSeq")];
}

static BOOL qqeModelIsRecallRecord(id record) {
    return qqeReadNumericIvar(record, "_msgType") == 5 && qqeReadNumericIvar(record, "_subMsgType") == 4;
}

static BOOL qqeModelIsCacheableRecord(id record, id elements) {
    if (!record || !elements || qqeModelIsRecallRecord(record)) return NO;
    if (qqeReadNumericIvar(record, "_msgId") == 0 || qqeReadNumericIvar(record, "_msgRandom") == 0) return NO;
    if (![elements respondsToSelector:@selector(count)]) return NO;
    @try {
        NSUInteger n = (NSUInteger)[elements count];
        return n > 0 && n < 80;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

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
    if (data.length == 0) return nil;
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        return [NSKeyedUnarchiver unarchiveObjectWithData:data];
#pragma clang diagnostic pop
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static void qqeEnsureModelCacheLoaded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gQQEModelAntiRecallCache = [NSMutableDictionary dictionary];
        gQQEModelAntiRecallOrder = [NSMutableArray array];
        NSDictionary *disk = [NSDictionary dictionaryWithContentsOfFile:qqeModelCachePath()];
        gQQEModelAntiRecallDisk = disk ? [disk mutableCopy] : [NSMutableDictionary dictionary];
        gQQEModelAntiRecallDiskLoaded = YES;
    });
}

static void qqePruneModelCacheLocked(void) {
    qqeEnsureModelCacheLoaded();
    NSDate *now = [NSDate date];

    while (gQQEModelAntiRecallOrder.count > kQQEModelAntiRecallMaxItems * 2) {
        [gQQEModelAntiRecallOrder removeObjectAtIndex:0];
    }

    while (gQQEModelAntiRecallCache.count > kQQEModelAntiRecallMaxItems && gQQEModelAntiRecallOrder.count > 0) {
        NSString *oldKey = gQQEModelAntiRecallOrder.firstObject;
        [gQQEModelAntiRecallOrder removeObjectAtIndex:0];
        if (oldKey.length == 0) continue;
        [gQQEModelAntiRecallCache removeObjectForKey:oldKey];
        [gQQEModelAntiRecallDisk removeObjectForKey:oldKey];
    }

    NSArray<NSString *> *keys = gQQEModelAntiRecallDisk.allKeys;
    for (NSString *key in keys) {
        NSDictionary *entry = gQQEModelAntiRecallDisk[key];
        NSDate *ts = [entry isKindOfClass:[NSDictionary class]] ? entry[@"ts"] : nil;
        if ([ts isKindOfClass:[NSDate class]] && [now timeIntervalSinceDate:ts] > kQQEModelAntiRecallTTL) {
            [gQQEModelAntiRecallDisk removeObjectForKey:key];
            [gQQEModelAntiRecallCache removeObjectForKey:key];
        }
    }

    if (gQQEModelAntiRecallDisk.count > kQQEModelAntiRecallMaxItems) {
        NSArray<NSString *> *sorted = [gQQEModelAntiRecallDisk keysSortedByValueUsingComparator:^NSComparisonResult(id a, id b) {
            NSDate *ta = [a isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)a)[@"ts"] : nil;
            NSDate *tb = [b isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)b)[@"ts"] : nil;
            return [(ta ?: [NSDate distantPast]) compare:(tb ?: [NSDate distantPast])];
        }];
        NSUInteger removeCount = gQQEModelAntiRecallDisk.count - kQQEModelAntiRecallMaxItems;
        for (NSUInteger i = 0; i < removeCount && i < sorted.count; i++) {
            NSString *key = sorted[i];
            [gQQEModelAntiRecallDisk removeObjectForKey:key];
            [gQQEModelAntiRecallCache removeObjectForKey:key];
        }
    }
}

static void qqeScheduleModelCacheSaveLocked(void) {
    if (gQQEModelAntiRecallSaveScheduled) return;
    gQQEModelAntiRecallSaveScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @synchronized (gQQEModelAntiRecallDisk ?: (id)[NSObject class]) {
            gQQEModelAntiRecallSaveScheduled = NO;
            if (!gQQEModelAntiRecallDiskLoaded) return;
            [gQQEModelAntiRecallDisk writeToFile:qqeModelCachePath() atomically:YES];
        }
    });
}

static NSString *qqeTextFromNSStringLike(id value) {
    if (!value) return @"";
    @try {
        if ([value isKindOfClass:[NSString class]]) return value;
        if ([value respondsToSelector:@selector(string)]) {
            id s = [value performSelector:@selector(string)];
            if ([s isKindOfClass:[NSString class]]) return s;
        }
        return [value description] ?: @"";
    } @catch (__unused NSException *e) {
        return @"";
    }
}

static NSString *qqeTextFromTextElement(id textElement) {
    if (!textElement) return @"";
    SEL sels[] = { sel_registerName("content"), sel_registerName("swizzled_content"), sel_registerName("displayText") };
    for (NSUInteger i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
        if (![textElement respondsToSelector:sels[i]]) continue;
        @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id value = [textElement performSelector:sels[i]];
#pragma clang diagnostic pop
            NSString *text = qqeTextFromNSStringLike(value);
            if (text.length > 0 && text.length < 800) return text;
        } @catch (__unused NSException *e) {}
    }
    return @"";
}

static NSString *qqeTextFromMsgElement(id msgElement) {
    if (!msgElement) return @"";
    SEL textSel = sel_registerName("textElement");
    if ([msgElement respondsToSelector:textSel]) {
        @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id te = [msgElement performSelector:textSel];
#pragma clang diagnostic pop
            NSString *text = qqeTextFromTextElement(te);
            if (text.length > 0 && text.length < 800) return text;
        } @catch (__unused NSException *e) {}
    }
    SEL qsdSel = sel_registerName("qsd_retriveContent");
    if ([msgElement respondsToSelector:qsdSel]) {
        @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id v = [msgElement performSelector:qsdSel];
#pragma clang diagnostic pop
            NSString *text = qqeTextFromNSStringLike(v);
            if (text.length > 0 && text.length < 800) return text;
        } @catch (__unused NSException *e) {}
    }
    return @"";
}

static NSString *qqeTextFromElements(id elements) {
    if (![elements respondsToSelector:@selector(count)] || ![elements respondsToSelector:@selector(objectAtIndex:)]) return @"";
    @try {
        NSUInteger n = MIN((NSUInteger)[elements count], (NSUInteger)80);
        for (NSUInteger i = 0; i < n; i++) {
            id e = [elements objectAtIndex:i];
            NSString *text = qqeTextFromMsgElement(e);
            if (text.length > 0 && text.length < 800) return text;
        }
    } @catch (__unused NSException *e) {}
    return @"";
}

static NSMutableDictionary *qqeLookupModelCacheEntry(NSString *key) {
    if (key.length == 0) return nil;
    qqeEnsureModelCacheLoaded();
    @synchronized (gQQEModelAntiRecallCache) {
        NSMutableDictionary *entry = gQQEModelAntiRecallCache[key];
        if (entry) return entry;

        NSDictionary *diskEntry = gQQEModelAntiRecallDisk[key];
        if (![diskEntry isKindOfClass:[NSDictionary class]]) return nil;
        NSData *data = diskEntry[@"elementsData"];
        id elements = [data isKindOfClass:[NSData class]] ? qqeUnarchiveElements(data) : nil;
        if (!elements) return nil;

        entry = [@{
            @"elements": elements,
            @"msgType": diskEntry[@"msgType"] ?: @0,
            @"subMsgType": diskEntry[@"subMsgType"] ?: @0,
            @"text": diskEntry[@"text"] ?: @"",
        } mutableCopy];
        gQQEModelAntiRecallCache[key] = entry;
        [gQQEModelAntiRecallOrder addObject:key];
        return entry;
    }
}

static void qqePutModelCacheEntry(NSString *key, id record, id elements) {
    if (key.length == 0 || !record || !elements) return;
    qqeEnsureModelCacheLoaded();

    long long msgType = qqeReadNumericIvar(record, "_msgType");
    long long subMsgType = qqeReadNumericIvar(record, "_subMsgType");
    NSString *text = (msgType == 2 && subMsgType == 1) ? qqeTextFromElements(elements) : @"";
    id retainedElements = elements;

    NSMutableDictionary *entry = [@{
        @"elements": retainedElements ?: elements,
        @"msgType": @(msgType),
        @"subMsgType": @(subMsgType),
        @"text": text ?: @"",
    } mutableCopy];

    NSData *data = qqeArchiveElements(elements);
    @synchronized (gQQEModelAntiRecallCache) {
        if (!gQQEModelAntiRecallCache[key]) [gQQEModelAntiRecallOrder addObject:key];
        gQQEModelAntiRecallCache[key] = entry;

        if (data.length > 0) {
            gQQEModelAntiRecallDisk[key] = [@{
                @"elementsData": data,
                @"msgType": @(msgType),
                @"subMsgType": @(subMsgType),
                @"text": text ?: @"",
                @"ts": [NSDate date],
            } mutableCopy];
            qqePruneModelCacheLocked();
            qqeScheduleModelCacheSaveLocked();
        } else {
            qqePruneModelCacheLocked();
        }
    }
}

static void qqeRestoreRecordFromEntry(id record, NSDictionary *entry) {
    if (!record || !entry) return;
    NSNumber *msgType = entry[@"msgType"];
    NSNumber *subMsgType = entry[@"subMsgType"];
    qqeWriteNumericIvar(record, "_msgType", msgType.longLongValue);
    qqeWriteNumericIvar(record, "_subMsgType", subMsgType.longLongValue);
    qqeWriteNumericIvar(record, "_recallTime", 0);
    qqeWriteObjectIvar(record, "_msgEventInfo", nil);
}

static void qqeModelSetElements(id self, SEL _cmd, id elements) {
    if (!pref_antiRevoke || !self || !elements) {
        if (gQQEOrigOCMsgRecordSetElements) gQQEOrigOCMsgRecordSetElements(self, _cmd, elements);
        return;
    }

    @autoreleasepool {
        NSString *key = qqeModelRecordKey(self);
        if (qqeModelIsCacheableRecord(self, elements)) {
            if (key.length > 0) qqePutModelCacheEntry(key, self, elements);
            if (gQQEOrigOCMsgRecordSetElements) gQQEOrigOCMsgRecordSetElements(self, _cmd, elements);
            return;
        }

        if (qqeModelIsRecallRecord(self) && key.length > 0) {
            NSMutableDictionary *entry = qqeLookupModelCacheEntry(key);
            id cachedElements = entry[@"elements"];
            if (cachedElements) {
                qqeRestoreRecordFromEntry(self, entry);
                if (gQQEOrigOCMsgRecordSetElements) gQQEOrigOCMsgRecordSetElements(self, _cmd, cachedElements);
                QQELog(@"[QQESign] 模型层防撤回 setElements 恢复 %@ text=%@", qqeModelBrief(self), entry[@"text"] ?: @"<non-text>");
                return;
            }
        }
    }

    if (gQQEOrigOCMsgRecordSetElements) gQQEOrigOCMsgRecordSetElements(self, _cmd, elements);
}

static void qqeModelSetRecallTime(id self, SEL _cmd, unsigned long long recallTime) {
    if (!pref_antiRevoke || recallTime == 0 || !self) {
        if (gQQEOrigOCMsgRecordSetRecallTime) gQQEOrigOCMsgRecordSetRecallTime(self, _cmd, recallTime);
        return;
    }

    @autoreleasepool {
        NSString *key = qqeModelRecordKey(self);
        NSMutableDictionary *entry = qqeLookupModelCacheEntry(key);
        if (entry) {
            qqeRestoreRecordFromEntry(self, entry);
            if (gQQEOrigOCMsgRecordSetRecallTime) gQQEOrigOCMsgRecordSetRecallTime(self, _cmd, 0);
            QQELog(@"[QQESign] 模型层防撤回 recallTime 归零 %@ old=%llu", qqeModelBrief(self), recallTime);
            return;
        }
    }

    if (gQQEOrigOCMsgRecordSetRecallTime) gQQEOrigOCMsgRecordSetRecallTime(self, _cmd, recallTime);
}

static NSUInteger qqesignInstallModelAntiRecallHooksPass(const char *reason) {
    if (gQQEModelAntiRecallHooksInstalled) return 0;
    Class cls = objc_getClass("OCMsgRecord");
    if (!cls) {
        QQELog(@"[QQESign] %s 模型层防撤回等待 OCMsgRecord", reason ?: "model-anti-recall");
        return 0;
    }

    NSUInteger installed = 0;
    SEL setElementsSel = sel_registerName("setElements:");
    Method setElementsMethod = class_getInstanceMethod(cls, setElementsSel);
    if (setElementsMethod) {
        gQQEOrigOCMsgRecordSetElements = (QQEOrigVoidOneObj)method_getImplementation(setElementsMethod);
        method_setImplementation(setElementsMethod, (IMP)qqeModelSetElements);
        installed++;
    }

    SEL setRecallTimeSel = sel_registerName("setRecallTime:");
    Method setRecallTimeMethod = class_getInstanceMethod(cls, setRecallTimeSel);
    if (setRecallTimeMethod) {
        gQQEOrigOCMsgRecordSetRecallTime = (QQEOrigVoidSetRecallTime)method_getImplementation(setRecallTimeMethod);
        method_setImplementation(setRecallTimeMethod, (IMP)qqeModelSetRecallTime);
        installed++;
    }

    gQQEModelAntiRecallHooksInstalled = (installed > 0);
    QQELog(@"[QQESign] %s 模型层防撤回 Hook 安装%@: %lu", reason ?: "model-anti-recall", gQQEModelAntiRecallHooksInstalled ? @"成功" : @"失败", (unsigned long)installed);
    return installed;
}

static void qqesignClearModelAntiRecallRuntimeCache(void) {
    qqeEnsureModelCacheLoaded();
    @synchronized (gQQEModelAntiRecallCache) {
        [gQQEModelAntiRecallCache removeAllObjects];
        [gQQEModelAntiRecallOrder removeAllObjects];
    }
}
static NSUInteger qqesignInstallRecallHooksPass(const char *reason) {
    // 新版默认使用模型层防撤回；旧的网络/通知/灰条上游拦截不再安装，避免开关无区别和链路冲突。
    return qqesignInstallModelAntiRecallHooksPass(reason);

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
    });
}

static void qqesignInstallRecallHooksWithRetry(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            qqesignInstallRecallHooksPass("delayed-ctor");
        });

        _dyld_register_func_for_add_image(qqesignRecallImageAdded);

        NSArray<NSNumber *> *delays = @[@3.0, @8.0, @15.0];
        for (NSNumber *delay in delays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                qqesignInstallRecallHooksPass("retry");
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
    if (pref_flashSave) {
        // 延迟后尝试从视图层级中抓取并保存图片
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *view = (UIView *)self;
            UIImage *img = findImageInView(view);
            if (img) saveImageToCameraRoll(img);
        });
    }
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
#pragma mark - 4. 自定义设备名 / 电量
// ─────────────────────────────────────────────

%hook UIDevice

- (NSString *)name {
    return pref_fakeDevice ? pref_deviceName : %orig;
}

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

typedef OSStatus (*QQESSLReadFunc)(void *, void *, size_t, size_t *);
static QQESSLReadFunc orig_SSLRead = NULL;

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
        NSLog(@"[QQESign] runtime log file: %@", qqesignRuntimeLogPath());
        qqesignInstallRecallHooksWithRetry();
        // 新版防撤回走 OCMsgRecord 模型层恢复，不再安装 SSLRead/上游撤回拦截，避免开关无区别和链路冲突。
        NSLog(@"[QQESign] v2.0 Loaded (NT架构) antiRevoke=%d flashUnlimited=%d flashSave=%d fakeDevice=%d fakeBatt=%d",
              pref_antiRevoke, pref_flashUnlimited, pref_flashSave,
              pref_fakeDevice, pref_fakeBattery);
    }
}
