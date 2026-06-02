
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
#import <objc/message.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdarg.h>

// ─────────────────────────────────────────────
#pragma mark - Preferences (sandbox-safe)
// ─────────────────────────────────────────────

static NSString *const kPrefSuite = @"com.qqesign.prefs";

static BOOL   pref_antiRevoke     = YES;
static BOOL   pref_flashUnlimited = YES;
static BOOL   pref_qzoneAdBlock   = YES;
static BOOL   pref_editText        = NO;   // 对方文本消息本地编辑（默认关）
static BOOL   pref_hideHomeSearch    = NO;
static BOOL   pref_hideContactSearch = NO;
static BOOL   pref_hideDynamicSearch = NO;
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
            @"editText":            @NO,
            @"hideHomeSearch":      @NO,
            @"hideContactSearch":   @NO,
            @"hideDynamicSearch":   @NO,
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
static BOOL qqesignQZoneAdHooksFullyInstalled(void);
static void qqesignInstallDrawerHooks(const char *reason);
static void qqesignDrawerClearAllBlockedModels(void);
static void qqesignInstallTopSearchHooks(const char *reason);

static BOOL qqesignAnyTopSearchEnabled(void) {
    return pref_hideHomeSearch || pref_hideContactSearch || pref_hideDynamicSearch;
}

static void qqesignResetTopSearchPrefsDefaultOffOnce(NSUserDefaults *ud) {
    if (!ud) return;
    // v2 key: force old stored top-search values back to OFF once for this safe build.
    if ([ud boolForKey:@"topSearchDefaultOffMigrated_v2"]) return;
    [ud setBool:NO forKey:@"hideHomeSearch"];
    [ud setBool:NO forKey:@"hideContactSearch"];
    [ud setBool:NO forKey:@"hideDynamicSearch"];
    [ud setBool:YES forKey:@"topSearchDefaultOffMigrated_v2"];
    [ud synchronize];
}

static void loadPrefs(void) {
    NSUserDefaults *ud = tweakDefaults();
    qqesignResetTopSearchPrefsDefaultOffOnce(ud);
    pref_antiRevoke     = [ud boolForKey:@"antiRevoke"];
    pref_flashUnlimited = [ud boolForKey:@"flashUnlimited"];
    pref_qzoneAdBlock   = [ud boolForKey:@"qzoneAdBlock"];
    pref_editText       = [ud boolForKey:@"editText"];
    pref_hideHomeSearch    = [ud boolForKey:@"hideHomeSearch"];
    pref_hideContactSearch = [ud boolForKey:@"hideContactSearch"];
    pref_hideDynamicSearch = [ud boolForKey:@"hideDynamicSearch"];
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

// 日志已全部移除：QQELog / NSLog 在本 tweak 内编译为空操作（无 console、无落盘）。
#define QQELog(...) do {} while (0)
#define NSLog(...) do {} while (0)

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

// ─────────────────────────────────────────────────────────────
#pragma mark - 颜色 / 工具
// ─────────────────────────────────────────────────────────────

static UIColor *QQEBlue(void) { // QQ 品牌蓝
    return [UIColor colorWithRed:0x0A/255.0 green:0x9B/255.0 blue:0xF0/255.0 alpha:1.0];
}

static UIColor *QQEHex(uint32_t rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF)/255.0
                           green:((rgb >> 8)  & 0xFF)/255.0
                            blue:((rgb)       & 0xFF)/255.0
                           alpha:1.0];
}

// dynamic 颜色：light / dark 各一
static UIColor *QQEDynamic(UIColor *light, UIColor *dark) {
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
            return tc.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
        }];
    }
    return light;
}

static void QQEContinuousCorners(UIView *v, CGFloat r) {
    v.layer.cornerRadius = r;
    if (@available(iOS 13.0, *)) v.layer.cornerCurve = kCACornerCurveContinuous;
}

// 语义色快捷方式（自动适配明暗）
static UIColor *QQETextPrimary(void)   { return [UIColor labelColor]; }
static UIColor *QQETextSecondary(void) { return [UIColor secondaryLabelColor]; }
static UIColor *QQESeparator(void)     { return [UIColor separatorColor]; }

// ─────────────────────────────────────────────────────────────
#pragma mark - 自定义电量滑块（30pt 圆角轨道 + QQ 蓝填充 + 白色拨钮）
// ─────────────────────────────────────────────────────────────

@interface QQEBatterySlider : UIControl
@property (nonatomic) float value;            // 0..1
@property (nonatomic, strong) UIView *track;
@property (nonatomic, strong) UIView *fill;
@property (nonatomic, strong) CAGradientLayer *fillGrad;
@property (nonatomic, strong) UIView *thumb;
@end

@implementation QQEBatterySlider

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _value = 0.8f;

        _track = [[UIView alloc] init];
        _track.backgroundColor = QQEDynamic([UIColor colorWithWhite:0.47 alpha:0.22],
                                            [UIColor colorWithWhite:0.47 alpha:0.32]);
        _track.userInteractionEnabled = NO;
        QQEContinuousCorners(_track, 15);
        [self addSubview:_track];

        _fill = [[UIView alloc] init];
        _fill.userInteractionEnabled = NO;
        _fill.clipsToBounds = YES;
        QQEContinuousCorners(_fill, 15);
        _fillGrad = [CAGradientLayer layer];
        _fillGrad.colors = @[ (id)QQEHex(0x2DC0FF).CGColor, (id)QQEHex(0x0A8FEE).CGColor ];
        _fillGrad.startPoint = CGPointMake(0.5, 0.0);
        _fillGrad.endPoint   = CGPointMake(0.5, 1.0);
        [_fill.layer addSublayer:_fillGrad];
        [self addSubview:_fill];

        _thumb = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 26, 26)];
        _thumb.backgroundColor = [UIColor whiteColor];
        _thumb.userInteractionEnabled = NO;
        _thumb.layer.cornerRadius = 13;
        _thumb.layer.shadowColor = [UIColor blackColor].CGColor;
        _thumb.layer.shadowOpacity = 0.22;
        _thumb.layer.shadowRadius = 4;
        _thumb.layer.shadowOffset = CGSizeMake(0, 2);
        [self addSubview:_thumb];

        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleSlide:)]];
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleSlide:)]];
    }
    return self;
}

- (void)setValue:(float)value { _value = MAX(0, MIN(1, value)); [self setNeedsLayout]; }

- (void)handleSlide:(UIGestureRecognizer *)g {
    CGFloat w = self.bounds.size.width;
    if (w <= 0) return;
    self.value = (float)([g locationInView:self].x / w);
    [self layoutIfNeeded];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = 30;
    self.track.frame = CGRectMake(0, 0, w, h);
    self.fill.frame = CGRectMake(0, 0, MAX(30, w * self.value), h);
    self.fillGrad.frame = self.fill.bounds;
    self.thumb.center = CGPointMake(MAX(13, MIN(w - 13, w * self.value)), h / 2);
}

- (CGSize)intrinsicContentSize { return CGSizeMake(UIViewNoIntrinsicMetric, 30); }

@end

// ─────────────────────────────────────────────────────────────
#pragma mark - 玻璃卡片（UIVisualEffectView + 描边 + 投影）
// ─────────────────────────────────────────────────────────────

@interface QQEGlassCard : UIView
@property (nonatomic, strong) UIVisualEffectView *blur;
@property (nonatomic, strong) UIStackView *stack;  // 行容器
@end

@implementation QQEGlassCard

- (instancetype)init {
    if ((self = [super init])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;

        // 投影承载在外层（blur clipsToBounds 会裁掉阴影）
        self.layer.shadowColor = [UIColor colorWithRed:0.08 green:0.16 blue:0.31 alpha:1].CGColor;
        self.layer.shadowOpacity = 0.10;
        self.layer.shadowRadius = 16;
        self.layer.shadowOffset = CGSizeMake(0, 8);

        UIBlurEffect *fx;
        if (@available(iOS 13.0, *)) fx = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
        else fx = [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
        _blur = [[UIVisualEffectView alloc] initWithEffect:fx];
        _blur.translatesAutoresizingMaskIntoConstraints = NO;
        _blur.clipsToBounds = YES;
        QQEContinuousCorners(_blur, 22);
        _blur.layer.borderWidth = 0.5;
        _blur.layer.borderColor = QQEDynamic([UIColor colorWithWhite:1 alpha:0.85],
                                             [UIColor colorWithWhite:1 alpha:0.10]).CGColor;
        [self addSubview:_blur];

        _stack = [[UIStackView alloc] init];
        _stack.axis = UILayoutConstraintAxisVertical;
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        [_blur.contentView addSubview:_stack];

        [NSLayoutConstraint activateConstraints:@[
            [_blur.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_blur.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_blur.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_blur.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_stack.topAnchor constraintEqualToAnchor:_blur.contentView.topAnchor],
            [_stack.bottomAnchor constraintEqualToAnchor:_blur.contentView.bottomAnchor],
            [_stack.leadingAnchor constraintEqualToAnchor:_blur.contentView.leadingAnchor],
            [_stack.trailingAnchor constraintEqualToAnchor:_blur.contentView.trailingAnchor],
        ]];
    }
    return self;
}

// dynamic borderColor 需在 trait 改变时刷新（CGColor 不会自动适配）
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    self.blur.layer.borderColor = QQEDynamic([UIColor colorWithWhite:1 alpha:0.85],
                                             [UIColor colorWithWhite:1 alpha:0.10]).CGColor;
}

@end

// ─────────────────────────────────────────────────────────────
#pragma mark - 背景壁纸（让玻璃有可折射的内容）
// ─────────────────────────────────────────────────────────────

@interface QQEWallpaperView : UIView
@property (nonatomic, strong) CAGradientLayer *base;
@property (nonatomic, strong) CAGradientLayer *glowL;
@property (nonatomic, strong) CAGradientLayer *glowR;
@end

@implementation QQEWallpaperView

- (instancetype)init {
    if ((self = [super init])) {
        _base = [CAGradientLayer layer];
        _base.startPoint = CGPointMake(0.5, 0);
        _base.endPoint   = CGPointMake(0.5, 1);
        [self.layer addSublayer:_base];

        _glowL = [CAGradientLayer layer];
        _glowL.type = kCAGradientLayerRadial;
        _glowL.startPoint = CGPointMake(0.18, -0.05);
        _glowL.endPoint   = CGPointMake(0.85, 0.55);
        [self.layer addSublayer:_glowL];

        _glowR = [CAGradientLayer layer];
        _glowR.type = kCAGradientLayerRadial;
        _glowR.startPoint = CGPointMake(0.92, 0.02);
        _glowR.endPoint   = CGPointMake(0.3, 0.5);
        [self.layer addSublayer:_glowR];

        [self refreshColors];
    }
    return self;
}

- (void)refreshColors {
    BOOL dark = NO;
    if (@available(iOS 13.0, *)) dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    if (dark) {
        self.base.colors  = @[ (id)QQEHex(0x0A0C11).CGColor, (id)QQEHex(0x050609).CGColor ];
        self.glowL.colors = @[ (id)QQEHex(0x14304F).CGColor, (id)[UIColor clearColor].CGColor ];
        self.glowR.colors = @[ (id)QQEHex(0x1A2740).CGColor, (id)[UIColor clearColor].CGColor ];
    } else {
        self.base.colors  = @[ (id)QQEHex(0xEEF3FA).CGColor, (id)QQEHex(0xE6ECF4).CGColor ];
        self.glowL.colors = @[ (id)QQEHex(0xCFE4FB).CGColor, (id)[UIColor clearColor].CGColor ];
        self.glowR.colors = @[ (id)QQEHex(0xDBEAFE).CGColor, (id)[UIColor clearColor].CGColor ];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.base.frame = self.bounds;
    self.glowL.frame = self.bounds;
    self.glowR.frame = self.bounds;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self refreshColors];
}

@end

// ─────────────────────────────────────────────────────────────
#pragma mark - 设置控制器
// ─────────────────────────────────────────────────────────────

@interface QQESignSettingsController : UIViewController <UIScrollViewDelegate>
@end

@implementation QQESignSettingsController {
    UIScrollView *_scroll;
    UIStackView  *_content;
    UIView       *_topBar;          // 自定义顶栏容器（覆盖在内容之上）
    UIVisualEffectView *_topBarBlur;// 顶栏磨砂背景（滚动时淡入）
    UIView       *_topBarHairline;  // 顶栏底部细分隔线
    UILabel      *_collapsedTitle;  // 折叠后的小标题 QQESign（滚动时淡入）
    CGFloat      _topBarHeight;     // 状态栏 + 44 行
    QQEBatterySlider *_batterySlider;
    UILabel *_batteryRowValue;
    UILabel *_batteryHeadValue;
    UILabel *_batteryHeadLabel;
    UIView  *_batterySliderRow;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor blackColor]; // 兜底，避免任何白底闪现

    // 背景壁纸（全屏铺满，包括状态栏与顶栏后面 —— 不再有割裂的白框）
    QQEWallpaperView *wall = [[QQEWallpaperView alloc] init];
    wall.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:wall];

    // 滚动容器（自己完全控制顶部 inset，不交给系统）
    _scroll = [[UIScrollView alloc] init];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.backgroundColor = [UIColor clearColor];
    _scroll.alwaysBounceVertical = YES;
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _scroll.delegate = self;
    [self.view addSubview:_scroll];

    _content = [[UIStackView alloc] init];
    _content.axis = UILayoutConstraintAxisVertical;
    _content.spacing = 26;
    _content.translatesAutoresizingMaskIntoConstraints = NO;
    [_scroll addSubview:_content];

    [NSLayoutConstraint activateConstraints:@[
        [wall.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [wall.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [wall.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [wall.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [_scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [_content.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor],
        [_content.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-28],
        [_content.leadingAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.leadingAnchor],
        [_content.trailingAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.trailingAnchor],
    ]];

    [self buildContent];
    [self buildTopBar];        // 顶栏最后加，保证盖在内容之上
    [self refreshBatteryEnabledState];
}

// 自定义顶栏：透明覆盖层，滚动时淡入磨砂 + 折叠小标题
- (void)buildTopBar {
    _topBar = [[UIView alloc] init];
    _topBar.translatesAutoresizingMaskIntoConstraints = NO;
    _topBar.userInteractionEnabled = NO;   // 不拦截触摸：顶栏空白区也能拖动滚动
    [self.view addSubview:_topBar];

    UIBlurEffect *fx;
    if (@available(iOS 13.0, *)) fx = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
    else fx = [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
    _topBarBlur = [[UIVisualEffectView alloc] initWithEffect:fx];
    _topBarBlur.translatesAutoresizingMaskIntoConstraints = NO;
    _topBarBlur.alpha = 0.0;               // 顶部透明，滚动后淡入
    [_topBar addSubview:_topBarBlur];

    _topBarHairline = [[UIView alloc] init];
    _topBarHairline.translatesAutoresizingMaskIntoConstraints = NO;
    _topBarHairline.backgroundColor = QQESeparator();
    _topBarHairline.alpha = 0.0;
    [_topBar addSubview:_topBarHairline];

    // 折叠小标题 QQESign（居中，滚动后淡入）
    _collapsedTitle = [[UILabel alloc] init];
    _collapsedTitle.text = @"QQESign";
    _collapsedTitle.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _collapsedTitle.textColor = QQETextPrimary();
    _collapsedTitle.textAlignment = NSTextAlignmentCenter;
    _collapsedTitle.alpha = 0.0;
    _collapsedTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [_topBar addSubview:_collapsedTitle];

    // 完成按钮（单独挂在 view 上，始终可点；右上）
    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    [done setTitle:@"完成" forState:UIControlStateNormal];
    [done setTitleColor:QQEBlue() forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [done addTarget:self action:@selector(dismissSelf) forControlEvents:UIControlEventTouchUpInside];
    done.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:done];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_topBar.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_topBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_topBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_topBar.bottomAnchor constraintEqualToAnchor:safe.topAnchor constant:44],

        [_topBarBlur.topAnchor constraintEqualToAnchor:_topBar.topAnchor],
        [_topBarBlur.bottomAnchor constraintEqualToAnchor:_topBar.bottomAnchor],
        [_topBarBlur.leadingAnchor constraintEqualToAnchor:_topBar.leadingAnchor],
        [_topBarBlur.trailingAnchor constraintEqualToAnchor:_topBar.trailingAnchor],

        [_topBarHairline.bottomAnchor constraintEqualToAnchor:_topBar.bottomAnchor],
        [_topBarHairline.leadingAnchor constraintEqualToAnchor:_topBar.leadingAnchor],
        [_topBarHairline.trailingAnchor constraintEqualToAnchor:_topBar.trailingAnchor],
        [_topBarHairline.heightAnchor constraintEqualToConstant:0.5],

        [_collapsedTitle.centerXAnchor constraintEqualToAnchor:_topBar.centerXAnchor],
        [_collapsedTitle.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_collapsedTitle.bottomAnchor constraintEqualToAnchor:_topBar.bottomAnchor],

        [done.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [done.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [done.heightAnchor constraintEqualToConstant:44],
    ]];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // 顶栏总高 = 状态栏安全区 + 44pt 行；据此设置滚动内容的顶部留白
    CGFloat barH = self.view.safeAreaInsets.top + 44.0;
    if (fabs(_topBarHeight - barH) > 0.5) {
        _topBarHeight = barH;
        UIEdgeInsets ins = _scroll.contentInset;
        ins.top = barH;
        _scroll.contentInset = ins;
        UIEdgeInsets si = _scroll.verticalScrollIndicatorInsets;
        si.top = barH;
        _scroll.verticalScrollIndicatorInsets = si;
        if (_scroll.contentOffset.y == 0 || _scroll.contentOffset.y == -_scroll.adjustedContentInset.top) {
            _scroll.contentOffset = CGPointMake(0, -barH);
        }
    }
}

// 状态栏样式跟随明暗（自动）
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleDefault; }

// 顶栏始终透明：上滑也不出现磨砂白条 / 折叠标题，保持沉浸式（与未滚动时一致）
- (void)scrollViewDidScroll:(UIScrollView *)sv {
    _topBarBlur.alpha = 0.0;
    _topBarHairline.alpha = 0.0;
    _collapsedTitle.alpha = 0.0;
}

// ── 构建全部内容 ─────────────────────────────────────────────
- (void)buildContent {
    // 大标题块：QQESign（大号）+ @Yjln（小号）—— 随内容滚动，上滑后折叠进顶栏
    [_content addArrangedSubview:[self largeTitleBlock]];

    // 1. 消息防撤回
    QQEGlassCard *c1 = [self cardWithRows:@[
        [self switchRowTitle:@"开启防撤回" sub:nil key:@"antiRevoke"],
        [self switchRowTitle:@"好友动态精准去广告" sub:nil key:@"qzoneAdBlock"],
        [self switchRowTitle:@"对方消息本地编辑" sub:@"仅本机显示，不会同步给对方" key:@"editText"],
    ]];
    [self addSection:@"消息防撤回" card:c1 footer:@"撤回的消息会保留在聊天中，仅本机可见。"];

    // 2. 闪照
    QQEGlassCard *c2 = [self cardWithRows:@[
        [self switchRowTitle:@"无限次查看闪照" sub:@"解除倒计时、保存与次数限制" key:@"flashUnlimited"],
    ]];
    [self addSection:@"闪照" card:c2 footer:nil];

    // 3. 顶部搜索栏屏蔽
    QQEGlassCard *c3 = [self cardWithRows:@[
        [self switchRowTitle:@"屏蔽首页搜索栏" sub:nil key:@"hideHomeSearch"],
        [self switchRowTitle:@"屏蔽联系人搜索栏" sub:nil key:@"hideContactSearch"],
        [self switchRowTitle:@"屏蔽动态搜索栏" sub:nil key:@"hideDynamicSearch"],
    ]];
    [self addSection:@"顶部搜索栏屏蔽" card:c3 footer:@"更改后需重启 QQ 后生效。"];

    // 4. 主页入口屏蔽
    QQEGlassCard *c4 = [self cardWithRows:@[
        [self switchRowTitle:@"隐藏「相册」"     sub:nil key:@"drawerHideAlbum"],
        [self switchRowTitle:@"隐藏「收藏」"     sub:nil key:@"drawerHideFavorite"],
        [self switchRowTitle:@"隐藏「文件」"     sub:nil key:@"drawerHideFiles"],
        [self switchRowTitle:@"隐藏「钱包」"     sub:nil key:@"drawerHideWallet"],
        [self switchRowTitle:@"隐藏「会员中心」" sub:nil key:@"drawerHideVip"],
        [self switchRowTitle:@"隐藏「个性装扮」" sub:nil key:@"drawerHideDecor"],
        [self switchRowTitle:@"隐藏「免流量」"   sub:nil key:@"drawerHideFreedata"],
    ]];
    [self addSection:@"主页入口屏蔽" card:c4 footer:@"隐藏头像侧边抽屉中不常用的入口。"];

    // 5. 自定义电量
    UIView *enableRow = [self switchRowTitle:@"启用自定义电量" sub:nil key:@"fakeBattery"];
    UIView *valueRow  = [self valueRowTitle:@"电量" valueOut:&_batteryRowValue];
    UIView *sliderRow = [self batterySliderRow];
    UIView *chargeRow = [self switchRowTitle:@"模拟充电中" sub:nil key:@"isCharging"];
    _batterySliderRow = sliderRow;
    QQEGlassCard *c5 = [self cardWithRows:@[ enableRow, valueRow, sliderRow, chargeRow ]];
    [self addSection:@"自定义电量" card:c5 footer:@"仅修改本机状态栏显示，不影响真实电量。"];

    // 6. 关于 —— 仅 QQESign / v2.4
    QQEGlassCard *c6 = [self cardWithRows:@[
        [self valueRowTitle:@"QQESign" detail:@"v2.4"],
    ]];
    [self addSection:@"关于" card:c6 footer:nil];

    // 底部小字
    UILabel *foot = [[UILabel alloc] init];
    foot.text = @"QQESign · 免越狱轻松签版 · 数据仅保存在本机";
    foot.font = [UIFont systemFontOfSize:11.5];
    foot.textColor = [UIColor tertiaryLabelColor];
    foot.textAlignment = NSTextAlignmentCenter;
    [_content addArrangedSubview:foot];
}

- (UIView *)largeTitleBlock {
    UILabel *main = [[UILabel alloc] init];
    main.text = @"QQESign";
    main.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
    main.textColor = QQETextPrimary();

    UILabel *sub = [[UILabel alloc] init];
    sub.text = @"@Yjln";
    sub.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    sub.textColor = QQETextSecondary();

    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[main, sub]];
    st.axis = UILayoutConstraintAxisVertical;
    st.spacing = 3;
    st.layoutMarginsRelativeArrangement = YES;
    // 顶部留 10pt（紧贴顶栏行下方），底部 6pt 接第一个分区
    st.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(10, 20, 6, 20);
    return st;
}

// 分区 = 顶部标题 + 卡片 + 可选脚注，整体左右边距 16
- (void)addSection:(NSString *)header card:(QQEGlassCard *)card footer:(NSString *)footer {
    UIStackView *sec = [[UIStackView alloc] init];
    sec.axis = UILayoutConstraintAxisVertical;
    sec.spacing = 8;
    sec.layoutMarginsRelativeArrangement = YES;
    sec.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(0, 16, 0, 16);

    if (header.length) {
        UILabel *h = [[UILabel alloc] init];
        h.text = header;
        h.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
        h.textColor = QQETextSecondary();
        UIStackView *wrap = [[UIStackView alloc] initWithArrangedSubviews:@[h]];
        wrap.layoutMarginsRelativeArrangement = YES;
        wrap.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(0, 4, 0, 4);
        [sec addArrangedSubview:wrap];
    }
    [sec addArrangedSubview:card];

    if (footer.length) {
        UILabel *f = [[UILabel alloc] init];
        f.text = footer;
        f.font = [UIFont systemFontOfSize:12.5];
        f.textColor = QQETextSecondary();
        f.numberOfLines = 0;
        UIStackView *wrap = [[UIStackView alloc] initWithArrangedSubviews:@[f]];
        wrap.layoutMarginsRelativeArrangement = YES;
        wrap.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(1, 4, 0, 4);
        [sec addArrangedSubview:wrap];
    }
    [_content addArrangedSubview:sec];
}

- (QQEGlassCard *)cardWithRows:(NSArray<UIView *> *)rows {
    QQEGlassCard *card = [[QQEGlassCard alloc] init];
    for (NSUInteger i = 0; i < rows.count; i++) {
        [card.stack addArrangedSubview:rows[i]];
        if (i < rows.count - 1) [card.stack addArrangedSubview:[self separator]];
    }
    return card;
}

// 行内分隔线（左侧与文字对齐：16pt）
- (UIView *)separator {
    UIView *line = [[UIView alloc] init];
    line.backgroundColor = QQESeparator();
    line.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *wrap = [[UIView alloc] init];
    [wrap addSubview:line];
    [NSLayoutConstraint activateConstraints:@[
        [line.heightAnchor constraintEqualToConstant:0.5],
        [line.topAnchor constraintEqualToAnchor:wrap.topAnchor],
        [line.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor],
        [line.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:16],
        [line.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor],
        [wrap.heightAnchor constraintEqualToConstant:0.5],
    ]];
    return wrap;
}

// ── 行：标题(+副标题) + 右侧 accessory（无图标）─────────────────
- (UIView *)baseRowTitle:(NSString *)title sub:(NSString *)sub accessory:(UIView *)accessory {
    UIView *row = [[UIView alloc] init];

    UILabel *titleL = [[UILabel alloc] init];
    titleL.text = title;
    titleL.font = [UIFont systemFontOfSize:16.5];
    titleL.textColor = QQETextPrimary();

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleL]];
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 2;
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    if (sub.length) {
        UILabel *subL = [[UILabel alloc] init];
        subL.text = sub;
        subL.font = [UIFont systemFontOfSize:12.5];
        subL.textColor = QQETextSecondary();
        subL.numberOfLines = 0;
        [textStack addArrangedSubview:subL];
    }

    [row addSubview:textStack];
    accessory.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:accessory];

    [NSLayoutConstraint activateConstraints:@[
        [textStack.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [textStack.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:accessory.leadingAnchor constant:-10],
        [accessory.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [accessory.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:54],
    ]];
    return row;
}

- (UIView *)switchRowTitle:(NSString *)title sub:(NSString *)sub key:(NSString *)key {
    UISwitch *sw = [[UISwitch alloc] init];
    sw.onTintColor = QQEBlue();
    sw.on = [tweakDefaults() boolForKey:key];
    objc_setAssociatedObject(sw, "qqeKey", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [sw addTarget:self action:@selector(switchToggled:) forControlEvents:UIControlEventValueChanged];
    return [self baseRowTitle:title sub:sub accessory:sw];
}

// 右侧静态文字（用于“关于：QQESign / v2.4”）
- (UIView *)valueRowTitle:(NSString *)title detail:(NSString *)detail {
    UILabel *val = [[UILabel alloc] init];
    val.font = [UIFont systemFontOfSize:16];
    val.textColor = QQETextSecondary();
    val.text = detail;
    return [self baseRowTitle:title sub:nil accessory:val];
}

// 右侧电量百分比（可更新）
- (UIView *)valueRowTitle:(NSString *)title valueOut:(UILabel * __strong *)out {
    UILabel *val = [[UILabel alloc] init];
    val.font = [UIFont systemFontOfSize:16];
    val.textColor = QQETextSecondary();
    val.text = [NSString stringWithFormat:@"%.0f%%", [tweakDefaults() floatForKey:@"batteryLevel"] * 100];
    if (out) *out = val;
    return [self baseRowTitle:title sub:nil accessory:val];
}

// 电量滑块整行
- (UIView *)batterySliderRow {
    UIView *row = [[UIView alloc] init];

    _batteryHeadLabel = [[UILabel alloc] init];
    _batteryHeadLabel.font = [UIFont systemFontOfSize:13];
    _batteryHeadLabel.textColor = QQETextSecondary();
    _batteryHeadLabel.translatesAutoresizingMaskIntoConstraints = NO;

    _batteryHeadValue = [[UILabel alloc] init];
    _batteryHeadValue.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _batteryHeadValue.textColor = QQETextPrimary();
    _batteryHeadValue.translatesAutoresizingMaskIntoConstraints = NO;

    _batterySlider = [[QQEBatterySlider alloc] init];
    _batterySlider.translatesAutoresizingMaskIntoConstraints = NO;
    _batterySlider.value = [tweakDefaults() floatForKey:@"batteryLevel"];
    [_batterySlider addTarget:self action:@selector(batteryChanged:) forControlEvents:UIControlEventValueChanged];

    [row addSubview:_batteryHeadLabel];
    [row addSubview:_batteryHeadValue];
    [row addSubview:_batterySlider];
    [self updateBatteryLabels];

    [NSLayoutConstraint activateConstraints:@[
        [_batteryHeadLabel.topAnchor constraintEqualToAnchor:row.topAnchor constant:4],
        [_batteryHeadLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [_batteryHeadValue.centerYAnchor constraintEqualToAnchor:_batteryHeadLabel.centerYAnchor],
        [_batteryHeadValue.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [_batterySlider.topAnchor constraintEqualToAnchor:_batteryHeadLabel.bottomAnchor constant:9],
        [_batterySlider.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [_batterySlider.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [_batterySlider.heightAnchor constraintEqualToConstant:30],
        [_batterySlider.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-14],
    ]];
    return row;
}

// ── 状态同步 ──────────────────────────────────────────────────
- (void)updateBatteryLabels {
    BOOL charging = [tweakDefaults() boolForKey:@"isCharging"];
    int pct = (int)roundf([tweakDefaults() floatForKey:@"batteryLevel"] * 100);
    _batteryHeadLabel.text = charging ? @"充电中" : @"电量";
    _batteryHeadValue.text = [NSString stringWithFormat:@"%d%%", pct];
    _batteryRowValue.text  = [NSString stringWithFormat:@"%d%%", pct];
}

- (void)refreshBatteryEnabledState {
    BOOL on = [tweakDefaults() boolForKey:@"fakeBattery"];
    _batterySliderRow.alpha = on ? 1.0 : 0.4;
    _batterySlider.userInteractionEnabled = on;
}

// ── 交互回调 ──────────────────────────────────────────────────
- (void)switchToggled:(UISwitch *)sw {
    NSString *key = objc_getAssociatedObject(sw, "qqeKey");
    if (!key) return;
    [tweakDefaults() setBool:sw.on forKey:key];
    [tweakDefaults() synchronize];
    loadPrefs();

    if ([key isEqualToString:@"antiRevoke"] && !sw.on) qqesignClearModelAntiRecallRuntimeCache();
    if ([key hasPrefix:@"drawerHide"])                 qqesignDrawerClearAllBlockedModels();
    if ([key isEqualToString:@"fakeBattery"])          [self refreshBatteryEnabledState];
    if ([key isEqualToString:@"isCharging"])           [self updateBatteryLabels];
    // 顶部搜索栏开关：更改后需重启 QQ 生效（与原逻辑一致，不即时安装 hook）
}

- (void)batteryChanged:(QQEBatterySlider *)slider {
    float f = MAX(0, MIN(1, slider.value));
    [tweakDefaults() setFloat:f forKey:@"batteryLevel"];
    [tweakDefaults() synchronize];
    loadPrefs();
    [self updateBatteryLabels];
}

- (void)dismissSelf { [self dismissViewControllerAnimated:YES completion:nil]; }

@end

// ─────────────────────────────────────────────────────────────
#pragma mark - 入口
// ─────────────────────────────────────────────────────────────

static void showQQESignSettings(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow) { win = w; break; }
                }
                if (win) break;
            }
        }
        if (!win) win = [UIApplication sharedApplication].keyWindow;
        if (!win) return;

        UIViewController *root = win.rootViewController;
        while (root.presentedViewController) root = root.presentedViewController;

        QQESignSettingsController *vc = [[QQESignSettingsController alloc] init];
        // 自定义顶栏，无需系统导航栏：直接全屏呈现（壁纸铺满，无白框、无标题栏延迟）
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        vc.modalPresentationCapturesStatusBarAppearance = YES;
        [root presentViewController:vc animated:YES completion:nil];
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

static BOOL qqesignQZoneAdHooksFullyInstalled(void) {
    return gQQESignQZoneControllerHooksInstalled &&
           gQQESignQZonePresenterHooksInstalled &&
           gQQESignQZoneCellHooksInstalled &&
           gQQESignQZoneLayoutHooksInstalled;
}

static void qqesignInstallQZoneAdHooks(const char *reason) {
    if (qqesignQZoneAdHooksFullyInstalled()) return;

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

%group QZoneAdBlockLazyEntry

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!qqesignQZoneAdHooksFullyInstalled()) {
        qqesignInstallQZoneAdHooks("view-did-appear");
    }
    // top-search hooks are installed only once after launch, not from viewDidAppear.
}

%end

%end // %group QZoneAdBlockLazyEntry

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
    if (!qqesignQZoneAdHooksFullyInstalled()) {
        qqesignInstallQZoneAdHooks("table-reload");
    }
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


// ─────────────────────────────────────────────
#pragma mark - 4.7 顶部搜索栏屏蔽：首页 / 联系人 / 动态
// ─────────────────────────────────────────────

static NSMutableSet<NSValue *> *qqesignHomeMarkedObjects = nil;

static IMP qqesignOrigQUISearchDidMoveToSuperview = NULL;
static IMP qqesignOrigQUISearchDidMoveToWindow = NULL;
static IMP qqesignOrigHomeWrapperDidMoveToSuperview = NULL;
static IMP qqesignOrigHomeWrapperLayoutSubviews = NULL;
static IMP qqesignOrigHomeHeaderHeight = NULL;
static IMP qqesignOrigTableSetHeader = NULL;

static NSMutableSet<NSString *> *qqesignRelationLayoutHookedClasses = nil;
static NSMapTable<id, NSValue *> *qqesignRelationLastBounds = nil;
static NSHashTable<id> *qqesignRelationFixingObjects = nil;

static NSString *qqesignObjClassName(id obj) {
    if (!obj) return @"";
    @try { return NSStringFromClass([obj class]) ?: @""; }
    @catch (__unused NSException *e) { return @""; }
}

static BOOL qqesignObjClassContains(id obj, NSString *needle) {
    return [qqesignObjClassName(obj) rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL qqesignClassNameContains(Class cls, NSString *needle) {
    if (!cls) return NO;
    NSString *name = NSStringFromClass(cls) ?: @"";
    return [name rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static void qqesignSearchEnsureState(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        qqesignHomeMarkedObjects = [NSMutableSet set];
        qqesignRelationLayoutHookedClasses = [NSMutableSet set];
        qqesignRelationLastBounds = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory
                                                           valueOptions:NSPointerFunctionsStrongMemory];
        qqesignRelationFixingObjects = [NSHashTable weakObjectsHashTable];
    });
}

static NSValue *qqesignObjPtrKey(id obj) {
    return [NSValue valueWithPointer:(__bridge const void *)(obj)];
}

static BOOL qqesignClassOwnsInstanceMethod(Class cls, SEL sel);

static BOOL qqesignHookInstanceMethod(Class cls, SEL sel, IMP newImp, IMP *origOut) {
    if (!cls || !sel || !newImp) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;

    IMP oldImp = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    if (origOut && !*origOut) *origOut = oldImp;

    if (qqesignClassOwnsInstanceMethod(cls, sel)) {
        method_setImplementation(m, newImp);
        return YES;
    }

    // If the method is inherited, add an override on this exact class.
    // This avoids replacing UIView/UIScrollView implementations globally.
    return class_addMethod(cls, sel, newImp, types);
}

static BOOL qqesignClassOwnsInstanceMethod(Class cls, SEL sel) {
    if (!cls || !sel) return NO;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL owns = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            owns = YES;
            break;
        }
    }
    if (methods) free(methods);
    return owns;
}

static id qqesignSuperview(id view) {
    if (!view || ![view respondsToSelector:@selector(superview)]) return nil;
    @try { return [view superview]; }
    @catch (__unused NSException *e) { return nil; }
}

static NSArray<UIView *> *qqesignSubviews(UIView *view, NSUInteger maxCount) {
    if (![view isKindOfClass:[UIView class]]) return @[];
    @try {
        NSArray *subs = [view subviews] ?: @[];
        if (subs.count <= maxCount) return subs;
        return [subs subarrayWithRange:NSMakeRange(0, maxCount)];
    } @catch (__unused NSException *e) {
        return @[];
    }
}

static BOOL qqesignIsQUISearchBar(id view) {
    return qqesignObjClassContains(view, @"QUISearchBar");
}

static BOOL qqesignViewHasQUISearchBar(UIView *view, NSInteger depth) {
    if (!view || depth > 4) return NO;
    if (qqesignIsQUISearchBar(view)) return YES;
    for (UIView *sub in qqesignSubviews(view, 24)) {
        if (qqesignViewHasQUISearchBar(sub, depth + 1)) return YES;
    }
    return NO;
}

static id qqesignFindAncestor(id view, NSString *needle, NSInteger maxDepth) {
    id cur = view;
    for (NSInteger i = 0; cur && i < maxDepth; i++) {
        if (qqesignObjClassContains(cur, needle)) return cur;
        cur = qqesignSuperview(cur);
    }
    return nil;
}

static void qqesignHideView(UIView *view) {
    if (![view isKindOfClass:[UIView class]]) return;
    @try {
        view.hidden = YES;
        view.alpha = 0.0;
        view.userInteractionEnabled = NO;
    } @catch (__unused NSException *e) {}
}

static void qqesignSetViewFrame(UIView *view, CGRect frame) {
    if (![view isKindOfClass:[UIView class]]) return;
    @try { view.frame = frame; }
    @catch (__unused NSException *e) {}
}

static void qqesignSetFlexibleSize(UIView *view) {
    if (![view isKindOfClass:[UIView class]]) return;
    @try { view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; }
    @catch (__unused NSException *e) {}
}

// ───── 首页 ─────

static id qqesignNearestHomeListFromWrapper(id wrapper) {
    id cur = qqesignSuperview(wrapper);
    for (NSInteger i = 0; cur && i < 10; i++) {
        if (qqesignObjClassContains(cur, @"NTMsgListViewDeprecated")) return cur;
        cur = qqesignSuperview(cur);
    }
    return nil;
}

static id qqesignNearestReloadableAncestor(id view) {
    id cur = view;
    for (NSInteger i = 0; cur && i < 10; i++) {
        @try {
            if ([cur respondsToSelector:@selector(reloadData)]) return cur;
        } @catch (__unused NSException *e) {}
        cur = qqesignSuperview(cur);
    }
    return nil;
}

static void qqesignReloadIfPossible(id obj) {
    if (!obj) return;
    @try {
        if ([obj respondsToSelector:@selector(reloadData)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [obj performSelector:@selector(reloadData)];
#pragma clang diagnostic pop
        }
    } @catch (__unused NSException *e) {}
}

static BOOL qqesignCollapseHomeWrapper(UIView *wrapper, const char *source) {
    if (![wrapper isKindOfClass:[UIView class]]) return NO;
    qqesignHideView(wrapper);
    wrapper.clipsToBounds = YES;

    @try {
        CGRect f = wrapper.frame;
        if (CGRectGetHeight(f) > 1.0 || fabs(CGRectGetMinY(f)) > 1.0) {
            f.origin.y = 0;
            f.size.height = 0.01;
            qqesignSetViewFrame(wrapper, f);
            QQELog(@"[QQESign] home search wrapper collapsed src=%s class=%@", source ?: "", qqesignObjClassName(wrapper));
        }

        for (UIView *sub in qqesignSubviews(wrapper, 16)) {
            qqesignHideView(sub);
            CGRect sf = sub.frame;
            if (CGRectGetHeight(sf) > 1.0) {
                sf.origin.y = 0;
                sf.size.height = 0.01;
                qqesignSetViewFrame(sub, sf);
            }
        }
    } @catch (__unused NSException *e) {}

    return YES;
}

static void qqesignMarkHomeListFromWrapper(UIView *wrapper, const char *source) {
    if (!pref_hideHomeSearch || !wrapper) return;
    qqesignSearchEnsureState();
    qqesignCollapseHomeWrapper(wrapper, source);

    id list = qqesignNearestHomeListFromWrapper(wrapper);
    if (list) {
        [qqesignHomeMarkedObjects addObject:qqesignObjPtrKey(list)];
    }

    id reloadable = qqesignNearestReloadableAncestor(wrapper);
    if (reloadable) {
        [qqesignHomeMarkedObjects addObject:qqesignObjPtrKey(reloadable)];
    }

    if (!list && !reloadable) return;

    for (NSInteger idx = 0; idx < 3; idx++) {
        NSTimeInterval delay = (idx == 0) ? 0.0 : (idx == 1 ? 0.08 : 0.24);
        __weak UIView *weakWrapper = wrapper;
        __weak id weakList = list;
        __weak id weakReloadable = reloadable;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *strongWrapper = weakWrapper;
            if (strongWrapper) qqesignCollapseHomeWrapper(strongWrapper, source);
            qqesignReloadIfPossible(weakList);
            if (weakReloadable && weakReloadable != weakList) qqesignReloadIfPossible(weakReloadable);
        });
    }
}

static BOOL qqesignHandleHomeSearchBar(UIView *bar, const char *source) {
    if (!pref_hideHomeSearch || !bar) return NO;
    UIView *wrapper = qqesignFindAncestor(bar, @"NTListViewHeaderWrapper", 8);
    if (![wrapper isKindOfClass:[UIView class]]) return NO;
    if (!qqesignViewHasQUISearchBar(wrapper, 0)) return NO;

    qqesignCollapseHomeWrapper(wrapper, source);
    qqesignMarkHomeListFromWrapper(wrapper, source);
    return YES;
}

static void qqesignHomeWrapperDidMoveReplacement(id selfObj, SEL _cmd) {
    if (qqesignOrigHomeWrapperDidMoveToSuperview) {
        ((void (*)(id, SEL))qqesignOrigHomeWrapperDidMoveToSuperview)(selfObj, _cmd);
    }
    if (pref_hideHomeSearch && [selfObj isKindOfClass:[UIView class]] && qqesignViewHasQUISearchBar(selfObj, 0)) {
        qqesignMarkHomeListFromWrapper(selfObj, "home-wrapper-didMove");
    }
}

static void qqesignHomeWrapperLayoutReplacement(id selfObj, SEL _cmd) {
    if (qqesignOrigHomeWrapperLayoutSubviews) {
        ((void (*)(id, SEL))qqesignOrigHomeWrapperLayoutSubviews)(selfObj, _cmd);
    }
    if (pref_hideHomeSearch && [selfObj isKindOfClass:[UIView class]] && qqesignViewHasQUISearchBar(selfObj, 0)) {
        qqesignCollapseHomeWrapper(selfObj, "home-wrapper-layout");
    }
}

static CGFloat qqesignHomeHeaderHeightReplacement(id selfObj, SEL _cmd, id collectionView, NSInteger section) {
    if (pref_hideHomeSearch) {
        qqesignSearchEnsureState();
        if ([qqesignHomeMarkedObjects containsObject:qqesignObjPtrKey(selfObj)] ||
            [qqesignHomeMarkedObjects containsObject:qqesignObjPtrKey(collectionView)]) {
            return 0.01;
        }
    }

    if (qqesignOrigHomeHeaderHeight) {
        return ((CGFloat (*)(id, SEL, id, NSInteger))qqesignOrigHomeHeaderHeight)(selfObj, _cmd, collectionView, section);
    }
    return 0.0;
}

// ───── 动态 ─────

static BOOL qqesignIsDynamicTable(id table) {
    return qqesignObjClassContains(table, @"QQDynamicPluginTableView");
}

static BOOL qqesignRemoveDynamicHeaderIfNeeded(UITableView *table, const char *source) {
    if (!pref_hideDynamicSearch || ![table isKindOfClass:[UITableView class]]) return NO;
    if (!qqesignIsDynamicTable(table)) return NO;

    UIView *header = nil;
    @try { header = table.tableHeaderView; } @catch (__unused NSException *e) {}
    if (!header || !qqesignViewHasQUISearchBar(header, 0)) return NO;

    qqesignHideView(header);
    @try { table.tableHeaderView = nil; } @catch (__unused NSException *e) {}
    QQELog(@"[QQESign] dynamic search header removed src=%s", source ?: "");
    return YES;
}

static void qqesignTableSetHeaderReplacement(UITableView *selfObj, SEL _cmd, UIView *header) {
    if (pref_hideDynamicSearch && qqesignIsDynamicTable(selfObj) && header && qqesignViewHasQUISearchBar(header, 0)) {
        qqesignHideView(header);
        if (qqesignOrigTableSetHeader) {
            ((void (*)(id, SEL, id))qqesignOrigTableSetHeader)(selfObj, _cmd, nil);
        }
        QQELog(@"[QQESign] dynamic setTableHeaderView blocked");
        return;
    }

    if (qqesignOrigTableSetHeader) {
        ((void (*)(id, SEL, id))qqesignOrigTableSetHeader)(selfObj, _cmd, header);
    }
}

// ───── 联系人 ─────

static BOOL qqesignIsRelationSearchContext(UIView *bar) {
    if (!pref_hideContactSearch || !bar) return NO;
    id cur = qqesignSuperview(bar);
    for (NSInteger i = 0; cur && i < 8; i++) {
        if (qqesignObjClassContains(cur, @"QQRelationTabScrollView")) return YES;
        cur = qqesignSuperview(cur);
    }
    return NO;
}

static UIView *qqesignRelationContainerFromBar(UIView *bar) {
    id cur = qqesignSuperview(bar);
    for (NSInteger i = 0; cur && i < 8; i++) {
        if (qqesignObjClassContains(cur, @"QQRelationTabScrollView") && [cur isKindOfClass:[UIView class]]) {
            return cur;
        }
        cur = qqesignSuperview(cur);
    }
    return nil;
}

static void qqesignHideRelationBar(UIView *bar, UIView *relation, const char *source) {
    if (![bar isKindOfClass:[UIView class]] || ![relation isKindOfClass:[UIView class]]) return;
    qqesignHideView(bar);
    CGRect rb = relation.bounds;
    if (CGRectGetWidth(rb) <= 0 || CGRectGetHeight(rb) <= 0) rb = relation.frame;
    if (CGRectGetWidth(rb) <= 0) rb.size.width = [UIScreen mainScreen].bounds.size.width;
    bar.frame = CGRectMake(0, 0, rb.size.width, 0.01);
}

static void qqesignTuneScrollView(UIScrollView *scroll) {
    if (![scroll isKindOfClass:[UIScrollView class]]) return;
    @try {
        UIEdgeInsets inset = scroll.contentInset;
        if (fabs(inset.top) > 0.5) {
            inset.top = 0;
            scroll.contentInset = inset;
        }
        UIEdgeInsets indicator = scroll.scrollIndicatorInsets;
        if (fabs(indicator.top) > 0.5) {
            indicator.top = 0;
            scroll.scrollIndicatorInsets = indicator;
        }
        CGPoint off = scroll.contentOffset;
        if (off.y < 0 && off.y > -180) {
            off.y = 0;
            scroll.contentOffset = off;
        }
    } @catch (__unused NSException *e) {}
}

static void qqesignFindRelationBarAndContent(UIView *relation, UIView **outBar, UIView **outContent) {
    if (outBar) *outBar = nil;
    if (outContent) *outContent = nil;
    if (![relation isKindOfClass:[UIView class]]) return;

    NSArray *subs = qqesignSubviews(relation, 16);
    UIView *bar = nil;
    UIView *content = nil;

    for (UIView *v in subs) {
        if (qqesignIsQUISearchBar(v)) {
            bar = v;
            break;
        }
    }

    for (UIView *v in subs) {
        if (v == bar) continue;
        NSString *name = qqesignObjClassName(v);
        if ([name rangeOfString:@"_UIScrollViewScrollIndicator"].location != NSNotFound) continue;
        content = v;
        break;
    }

    if (outBar) *outBar = bar;
    if (outContent) *outContent = content;
}

static void qqesignFillRelationContentChildren(UIView *content, const char *source) {
    if (![content isKindOfClass:[UIView class]]) return;
    CGRect cb = content.bounds;
    if (CGRectGetWidth(cb) <= 0 || CGRectGetHeight(cb) <= 0) cb = content.frame;
    if (CGRectGetWidth(cb) <= 0 || CGRectGetHeight(cb) <= 0) return;

    for (UIView *v in qqesignSubviews(content, 16)) {
        NSString *name = qqesignObjClassName(v);
        if ([name rangeOfString:@"_UIScrollViewScrollIndicator"].location != NSNotFound) continue;

        if ([v isKindOfClass:[UIScrollView class]]) {
            qqesignTuneScrollView((UIScrollView *)v);
        }

        CGRect f = v.frame;
        BOOL shouldFill = [v isKindOfClass:[UIScrollView class]] ||
                          (CGRectGetMinY(f) > 0 && CGRectGetMinY(f) < 180 && fabs(CGRectGetHeight(f) - CGRectGetHeight(cb)) < 220);
        if (!shouldFill) continue;

        if (fabs(CGRectGetMinX(f)) < 2 &&
            fabs(CGRectGetMinY(f)) < 2 &&
            fabs(CGRectGetWidth(f) - CGRectGetWidth(cb)) < 2 &&
            fabs(CGRectGetHeight(f) - CGRectGetHeight(cb)) < 2) {
            continue;
        }

        qqesignSetViewFrame(v, CGRectMake(0, 0, CGRectGetWidth(cb), CGRectGetHeight(cb)));
        qqesignSetFlexibleSize(v);
    }
}

static BOOL qqesignFixRelationView(UIView *relation, const char *source) {
    if (!pref_hideContactSearch || ![relation isKindOfClass:[UIView class]]) return NO;
    if (!qqesignObjClassContains(relation, @"QQRelationTabScrollView")) return NO;

    qqesignSearchEnsureState();
    if ([qqesignRelationFixingObjects containsObject:relation]) return NO;
    [qqesignRelationFixingObjects addObject:relation];

    @try {
        CGRect rb = relation.bounds;
        if (CGRectGetWidth(rb) <= 0 || CGRectGetHeight(rb) <= 0) rb = relation.frame;
        if (CGRectGetWidth(rb) <= 0 || CGRectGetHeight(rb) <= 0) {
            [qqesignRelationFixingObjects removeObject:relation];
            return NO;
        }

        [qqesignRelationLastBounds setObject:[NSValue valueWithCGRect:rb] forKey:relation];

        UIView *bar = nil;
        UIView *content = nil;
        qqesignFindRelationBarAndContent(relation, &bar, &content);
        if (!bar || !content) {
            [qqesignRelationFixingObjects removeObject:relation];
            return NO;
        }

        qqesignHideRelationBar(bar, relation, source);

        CGRect cf = content.frame;
        BOOL needFill = fabs(CGRectGetMinX(cf)) > 1 ||
                        fabs(CGRectGetMinY(cf)) > 1 ||
                        fabs(CGRectGetWidth(cf) - CGRectGetWidth(rb)) > 2 ||
                        fabs(CGRectGetHeight(cf) - CGRectGetHeight(rb)) > 2;

        if (needFill) {
            qqesignSetViewFrame(content, CGRectMake(0, 0, CGRectGetWidth(rb), CGRectGetHeight(rb)));
            qqesignSetFlexibleSize(content);
            QQELog(@"[QQESign] relation search content filled src=%s class=%@", source ?: "", qqesignObjClassName(content));
        }

        qqesignFillRelationContentChildren(content, source);
        [qqesignRelationFixingObjects removeObject:relation];
        return YES;
    } @catch (__unused NSException *e) {
        [qqesignRelationFixingObjects removeObject:relation];
        return NO;
    }
}

static const void *kQQESignRelationOrigLayoutImpKey = &kQQESignRelationOrigLayoutImpKey;

static void qqesignRelationLayoutThunk(id selfObj, SEL _cmd) {
    IMP orig = NULL;
    Class cls = [selfObj class];
    while (cls) {
        NSValue *v = objc_getAssociatedObject(cls, kQQESignRelationOrigLayoutImpKey);
        if (v) {
            orig = [v pointerValue];
            break;
        }
        cls = class_getSuperclass(cls);
    }
    if (orig) ((void (*)(id, SEL))orig)(selfObj, _cmd);
    if (pref_hideContactSearch && [selfObj isKindOfClass:[UIView class]]) {
        qqesignFixRelationView((UIView *)selfObj, "relation-layout");
    }
}

static void qqesignInstallRelationLayoutHookForView(UIView *relation) {
    // Disabled in safe build.
    // The scheduled relation fixes are enough for the validated layout,
    // and avoiding extra layoutSubviews swizzling reduces crash risk.
    (void)relation;
    return;
}

static void qqesignScheduleRelationFix(UIView *relation, const char *source) {
    if (!pref_hideContactSearch || !relation) return;
    qqesignInstallRelationLayoutHookForView(relation);

    NSArray<NSNumber *> *delays = @[@0, @60, @180, @420, @900];
    for (NSNumber *ms in delays) {
        __weak UIView *weakRelation = relation;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms.doubleValue / 1000.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *r = weakRelation;
            if (r) qqesignFixRelationView(r, source);
        });
    }
}

static BOOL qqesignHandleRelationSearchBar(UIView *bar, const char *source) {
    if (!pref_hideContactSearch || !qqesignIsRelationSearchContext(bar)) return NO;
    UIView *relation = qqesignRelationContainerFromBar(bar);
    if (![relation isKindOfClass:[UIView class]]) return NO;
    if (!qqesignObjClassContains(relation, @"QQRelationTabScrollView")) return NO;

    qqesignFixRelationView(relation, source);
    qqesignScheduleRelationFix(relation, source);
    return YES;
}

// ───── 统一 QUISearchBar 入口 ─────

static void qqesignHandleTopSearchBar(UIView *bar, const char *source) {
    if (![bar isKindOfClass:[UIView class]]) return;
    if (!qqesignIsQUISearchBar(bar)) return;

    if (pref_hideDynamicSearch) {
        id dynamicTable = qqesignFindAncestor(bar, @"QQDynamicPluginTableView", 8);
        if ([dynamicTable isKindOfClass:[UITableView class]]) {
            qqesignRemoveDynamicHeaderIfNeeded(dynamicTable, source);
            return;
        }
    }

    if (pref_hideHomeSearch && qqesignHandleHomeSearchBar(bar, source)) return;
    if (pref_hideContactSearch) qqesignHandleRelationSearchBar(bar, source);
}

static void qqesignQUISearchDidMoveToSuperviewReplacement(id selfObj, SEL _cmd) {
    if (qqesignOrigQUISearchDidMoveToSuperview) {
        ((void (*)(id, SEL))qqesignOrigQUISearchDidMoveToSuperview)(selfObj, _cmd);
    }
    if (pref_hideHomeSearch || pref_hideContactSearch || pref_hideDynamicSearch) {
        qqesignHandleTopSearchBar(selfObj, "searchbar-didMoveToSuperview");
    }
}

static void qqesignQUISearchDidMoveToWindowReplacement(id selfObj, SEL _cmd) {
    if (qqesignOrigQUISearchDidMoveToWindow) {
        ((void (*)(id, SEL))qqesignOrigQUISearchDidMoveToWindow)(selfObj, _cmd);
    }
    if (pref_hideHomeSearch || pref_hideContactSearch || pref_hideDynamicSearch) {
        qqesignHandleTopSearchBar(selfObj, "searchbar-didMoveToWindow");
    }
}

static BOOL gQQESignTopSearchHooksInstalled = NO;

static void qqesignInstallTopSearchHooks(const char *reason) {
    if (!qqesignAnyTopSearchEnabled()) return;
    qqesignSearchEnsureState();

    BOOL installedAny = NO;

    Class searchBarCls = objc_getClass("QUISearchBar");
    if (searchBarCls && (pref_hideHomeSearch || pref_hideContactSearch || pref_hideDynamicSearch)) {
        if (!qqesignOrigQUISearchDidMoveToSuperview) {
            installedAny |= qqesignHookInstanceMethod(searchBarCls, @selector(didMoveToSuperview), (IMP)qqesignQUISearchDidMoveToSuperviewReplacement, &qqesignOrigQUISearchDidMoveToSuperview);
        }
        if (!qqesignOrigQUISearchDidMoveToWindow) {
            installedAny |= qqesignHookInstanceMethod(searchBarCls, @selector(didMoveToWindow), (IMP)qqesignQUISearchDidMoveToWindowReplacement, &qqesignOrigQUISearchDidMoveToWindow);
        }
    }

    if (pref_hideDynamicSearch) {
        Class tableCls = [UITableView class];
        if (tableCls && !qqesignOrigTableSetHeader) {
            installedAny |= qqesignHookInstanceMethod(tableCls, @selector(setTableHeaderView:), (IMP)qqesignTableSetHeaderReplacement, &qqesignOrigTableSetHeader);
        }
    }

    if (pref_hideHomeSearch) {
        Class homeWrapperCls = objc_getClass("NTListViewModule.NTListViewHeaderWrapper");
        if (homeWrapperCls) {
            if (!qqesignOrigHomeWrapperDidMoveToSuperview) {
                installedAny |= qqesignHookInstanceMethod(homeWrapperCls, @selector(didMoveToSuperview), (IMP)qqesignHomeWrapperDidMoveReplacement, &qqesignOrigHomeWrapperDidMoveToSuperview);
            }
            if (!qqesignOrigHomeWrapperLayoutSubviews) {
                installedAny |= qqesignHookInstanceMethod(homeWrapperCls, @selector(layoutSubviews), (IMP)qqesignHomeWrapperLayoutReplacement, &qqesignOrigHomeWrapperLayoutSubviews);
            }
        }

        Class homeListCls = objc_getClass("NTMsgListViewDeprecated");
        if (homeListCls && !qqesignOrigHomeHeaderHeight) {
            installedAny |= qqesignHookInstanceMethod(homeListCls, @selector(collectionView:heightForHeaderAt:), (IMP)qqesignHomeHeaderHeightReplacement, &qqesignOrigHomeHeaderHeight);
        }
    }

    if (installedAny) {
        gQQESignTopSearchHooksInstalled = YES;
        QQELog(@"[QQESign] top-search hooks installed reason=%s home=%d contact=%d dynamic=%d",
                reason ?: "unknown",
                pref_hideHomeSearch,
                pref_hideContactSearch,
                pref_hideDynamicSearch);
    }
}


#pragma mark - 4.6 对方文本消息本地编辑 (移植自 AllCrash 研究脚本)
// ─────────────────────────────────────────────
//
// 长按「对方发来的文本消息」→ 菜单出现「编辑」→ 仅修改本机 AIOTextView 的内容
// 缓存 (_treeContent._intermediatedata._atrributedString)，不发网络、不动 OCMsgRecord。
// 限制：
//   1. 只对方消息——气泡为标准 BubbleView (NTAIOVASBubbleView)；自己消息
//      (NTAIOBubbleDrawLayerView / 无标准气泡) 不注入编辑项。
//   2. 只文本消息——能取到可编辑 attributedString 才注入。
//   3. 只能缩减——新文本字符数必须 ≤ 原文且非空。
// 安全口径沿用研究结论：不清 intermediatedata / truncate 字段（清了菜单复用 force-unwrap 崩），
// 只清 drawInfo；菜单新项用 row=0 模板克隆，绝不让 Swift 用越界 row 索引 items 数组。

static const NSInteger kQQEEditSection = 1;        // 菜单里编辑项所在 section
static NSInteger gQQEMenuEditRow = -1;             // 动态编辑项 row(=原生项数)；-1=本次不注入
static __weak UIView *gQQEEditTextView = nil;      // 本次长按命中的 AIOTextView
static NSString *gQQEEditOriginal = nil;           // 命中文本原文
static NSTimeInterval gQQEEditCaptureTs = 0;
static BOOL gQQEEditCaptureOK = NO;
static NSTimeInterval gQQEEditTriggerTs = 0;       // tap / didSelect 去抖
static NSMutableDictionary<NSString *, NSString *> *gQQEEditsByOriginal = nil; // 原文 -> 新文本(供 cell 重绑补回)
static char kQQEEditTapKey;
static IMP gQQEOrigAIOBindViewModel = NULL;
static BOOL gQQEEditMenuHooked = NO;

static void qqeEditEnsureState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gQQEEditsByOriginal = [NSMutableDictionary dictionary]; });
}

static void qqeMsgSendObj(id target, SEL sel, id arg) {
    if (!target || !sel || ![target respondsToSelector:sel]) return;
    @try { ((void (*)(id, SEL, id))objc_msgSend)(target, sel, arg); } @catch (__unused NSException *e) {}
}
static void qqeMsgSendInt(id target, SEL sel, NSInteger arg) {
    if (!target || !sel || ![target respondsToSelector:sel]) return;
    @try { ((void (*)(id, SEL, NSInteger))objc_msgSend)(target, sel, arg); } @catch (__unused NSException *e) {}
}

static BOOL qqeClassContains(id o, NSString *needle) {
    if (!o) return NO;
    NSString *n = NSStringFromClass([o class]);
    return n.length > 0 && [n rangeOfString:needle].location != NSNotFound;
}

static NSString *qqeAttrPlain(id attr) {
    if (!attr) return @"";
    if ([attr isKindOfClass:[NSString class]]) return (NSString *)attr;
    if ([attr isKindOfClass:[NSAttributedString class]]) {
        NSString *s = [(NSAttributedString *)attr string];
        return s ?: @"";
    }
    return @"";
}

static BOOL qqeIsEditableText(NSString *t) {
    if (t.length == 0 || t.length > 800) return NO;
    static NSSet *menuWords; static dispatch_once_t once;
    dispatch_once(&once, ^{
        menuWords = [NSSet setWithArray:@[@"复制", @"转发", @"收藏", @"删除", @"多选", @"引用", @"翻译", @"截图", @"装扮", @"编辑"]];
    });
    if ([menuWords containsObject:t]) return NO;
    return YES;
}

static id qqeReadAttr(id inter) {
    if (!inter) return nil;
    id attr = qqeObjectIvar(inter, "_atrributedString");
    if (!attr && [inter respondsToSelector:@selector(atrributedString)]) {
        @try { attr = ((id (*)(id, SEL))objc_msgSend)(inter, @selector(atrributedString)); }
        @catch (__unused NSException *e) {}
    }
    return attr;
}

static UIView *qqeFindAncestorCell(UIView *v) {
    for (UIView *cur = v; cur; cur = cur.superview) {
        if ([cur isKindOfClass:[UICollectionViewCell class]] || [cur isKindOfClass:[UITableViewCell class]]) return cur;
    }
    return nil;
}

static UIView *qqeFindSubviewContains(UIView *root, NSString *needle, int depth) {
    if (!root || depth < 0) return nil;
    if (qqeClassContains(root, needle)) return root;
    for (UIView *sub in [root.subviews copy]) {
        UIView *f = qqeFindSubviewContains(sub, needle, depth - 1);
        if (f) return f;
    }
    return nil;
}

static UIView *qqeFindAncestorContains(UIView *v, NSString *needle, int maxDepth) {
    int i = 0;
    for (UIView *cur = v; cur && i < maxDepth; cur = cur.superview, i++) {
        if (qqeClassContains(cur, needle)) return cur;
    }
    return nil;
}

static UIView *qqeFindFirstSubviewOfClass(UIView *root, Class cls) {
    if (!root) return nil;
    if ([root isKindOfClass:cls]) return root;
    for (UIView *sub in [root.subviews copy]) {
        UIView *f = qqeFindFirstSubviewOfClass(sub, cls);
        if (f) return f;
    }
    return nil;
}

static UIView *qqeFindAIOTextView(UIView *pressed, UIView *cell) {
    UIView *cur = pressed;
    for (int i = 0; cur && i < 7; i++) {
        if (qqeClassContains(cur, @"AIOTextView")) return cur;
        if (cell && cur == cell) break;
        cur = cur.superview;
    }
    if (cell) {
        UIView *f = qqeFindSubviewContains(cell, @"AIOTextView", 8);
        if (f) return f;
    }
    return nil;
}

// 对方气泡：rich 祖先里含「标准 BubbleView」(NTAIOVASBubbleView)；自己消息是
// NTAIOBubbleDrawLayerView(不含 "BubbleView" 子串) / 无标准气泡 → 返回 NO。
static BOOL qqeIsIncomingBubble(UIView *tv) {
    UIView *rich = qqeFindAncestorContains(tv, @"NTAIORichTextContentView", 6);
    if (!rich) return NO;
    return qqeFindSubviewContains(rich, @"BubbleView", 3) != nil;
}

static NSString *qqeTextViewExtract(UIView *tv, id *outTree, id *outInter, id *outAttr) {
    if (outTree) *outTree = nil;
    if (outInter) *outInter = nil;
    if (outAttr) *outAttr = nil;
    if (!tv || !qqeClassContains(tv, @"AIOTextView")) return nil;
    id tree = qqeObjectIvar(tv, "_treeContent");
    id inter = tree ? qqeObjectIvar(tree, "_intermediatedata") : nil;
    if (!tree || !inter) return nil;
    id attr = qqeReadAttr(inter);
    NSString *text = qqeAttrPlain(attr);
    if (!qqeIsEditableText(text)) return nil;
    if (outTree) *outTree = tree;
    if (outInter) *outInter = inter;
    if (outAttr) *outAttr = attr;
    return text;
}

static CGSize qqeMeasureAttr(NSAttributedString *attr, NSString *oldText, NSString *newText, CGFloat oldWidth, CGFloat maxWidth) {
    maxWidth = MAX(40, maxWidth > 0 ? maxWidth : (oldWidth > 0 ? oldWidth : 220));
    CGFloat baseW = oldWidth > 0 ? oldWidth : 80;
    CGFloat fallbackChar = MAX(7, MIN(18, baseW / MAX(1.0, (CGFloat)oldText.length)));
    CGFloat fallbackW = MAX(18, MIN(maxWidth, ceil((CGFloat)newText.length * fallbackChar + 4)));
    CGSize result = CGSizeMake(fallbackW, 24);
    if ([attr isKindOfClass:[NSAttributedString class]]) {
        @try {
            CGRect r = [attr boundingRectWithSize:CGSizeMake(maxWidth, 10000)
                                          options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading)
                                          context:nil];
            if (r.size.width > 0 && r.size.height > 0) {
                result.width = MIN(maxWidth, ceil(r.size.width + 4));
                result.height = ceil(r.size.height + 4);
            }
        } @catch (__unused NSException *e) {}
    }
    return result;
}

static void qqeSetViewSizeKeepLeft(UIView *v, CGFloat w, CGFloat h) {
    if (!v) return;
    CGRect f = v.frame;
    f.size.width = MAX(1, w);
    f.size.height = MAX(1, h > 0 ? h : f.size.height);
    @try { v.frame = f; } @catch (__unused NSException *e) {}
}

// 改完 attr 后手动缩气泡（对方气泡左对齐，保左边）。自带幂等守卫：已够小就不动 frame，
// 避免 cell 重绑反复触发越缩越小。
static void qqeAdjustBubble(UIView *tv, NSAttributedString *newAttr, NSString *oldText, NSString *newText) {
    if (!tv) return;
    CGRect tvFrame = tv.frame;
    if (tvFrame.size.width <= 0) return;
    UIView *rich = qqeFindAncestorContains(tv, @"NTAIORichTextContentView", 6);
    UIView *bubble = rich ? qqeFindSubviewContains(rich, @"BubbleView", 3) : nil;
    if (!bubble) return;   // 自己消息(DrawLayer)：不碰 frame
    UIView *cellView = qqeFindAncestorContains(tv, @"NTAIOChatCellView", 6);
    CGFloat maxWidth;
    if (cellView && cellView.bounds.size.width > 0)
        maxWidth = MAX(80, MIN(420, cellView.bounds.size.width * 0.68));
    else
        maxWidth = MAX(120, MIN(420, tvFrame.size.width * 2.2));

    CGSize measured = qqeMeasureAttr(newAttr, oldText, newText, tvFrame.size.width, maxWidth);
    CGFloat newTvW = MAX(18, measured.width);
    CGFloat newTvH = MAX(tvFrame.size.height, measured.height);
    if (tvFrame.size.width <= newTvW + 12) return;   // 幂等守卫

    CGFloat oldTvW = MAX(1, tvFrame.size.width);
    CGFloat oldTvH = MAX(1, tvFrame.size.height);

    qqeSetViewSizeKeepLeft(tv, newTvW, newTvH);

    CGRect rf = rich.frame;
    if (rf.size.width > 0) {
        CGFloat padW = MAX(0, rf.size.width - oldTvW);
        CGFloat padH = MAX(0, rf.size.height - oldTvH);
        qqeSetViewSizeKeepLeft(rich, newTvW + padW, MAX(rf.size.height, newTvH + padH));
    }
    CGRect bf = bubble.frame;
    if (bf.size.width > 0) {
        CGFloat padW = MAX(16, bf.size.width - oldTvW);
        CGFloat padH = MAX(8, bf.size.height - oldTvH);
        qqeSetViewSizeKeepLeft(bubble, newTvW + padW, MAX(bf.size.height, newTvH + padH));
        for (UIView *sub in [bubble.subviews copy]) {
            if (qqeClassContains(sub, @"ImageView") || qqeClassContains(sub, @"Bubble")) {
                qqeSetViewSizeKeepLeft(sub, bubble.bounds.size.width, bubble.bounds.size.height);
            }
        }
    }
}

static void qqeClearDrawInfo(id d) {
    if (!d) return;
    qqeMsgSendObj(d, @selector(setResult:), nil);
    qqeMsgSendObj(d, @selector(setTextImage:), nil);
    qqeMsgSendObj(d, @selector(setTextFrame:), nil);
    qqeMsgSendObj(d, @selector(setFirstLine:), nil);
    qqeMsgSendInt(d, @selector(setLineCount:), 0);
}

static NSAttributedString *qqeMakeReplacementAttr(id baseAttr, NSString *newText) {
    NSString *ns = newText ?: @"";
    NSDictionary *attrs = nil;
    if ([baseAttr isKindOfClass:[NSAttributedString class]] && [(NSAttributedString *)baseAttr length] > 0) {
        @try { attrs = [(NSAttributedString *)baseAttr attributesAtIndex:0 effectiveRange:NULL]; }
        @catch (__unused NSException *e) {}
    }
    @try {
        if (attrs) return [[NSMutableAttributedString alloc] initWithString:ns attributes:attrs];
        return [[NSMutableAttributedString alloc] initWithString:ns];
    } @catch (__unused NSException *e) { return nil; }
}

static void qqeForceRedraw(UIView *view) {
    UIView *cur = view;
    for (int i = 0; cur && i < 6; i++) {
        @try {
            [cur setNeedsDisplay];
            [cur setNeedsLayout];
            [cur layoutIfNeeded];
            [cur.layer setNeedsDisplay];
            [cur.layer displayIfNeeded];
        } @catch (__unused NSException *e) {}
        cur = cur.superview;
    }
}

static BOOL qqeSetContentCacheText(UIView *tv, NSString *newText) {
    if (!tv) return NO;
    id tree = qqeObjectIvar(tv, "_treeContent");
    id inter = tree ? qqeObjectIvar(tree, "_intermediatedata") : nil;
    if (!tree || !inter) return NO;
    id attr = qqeReadAttr(inter);
    NSString *oldText = qqeAttrPlain(attr);
    NSAttributedString *newAttr = qqeMakeReplacementAttr(attr, newText);
    if (!newAttr) return NO;
    SEL setSel = @selector(setAtrributedString:);
    if (![inter respondsToSelector:setSel]) return NO;
    @try { ((void (*)(id, SEL, id))objc_msgSend)(inter, setSel, newAttr); }
    @catch (__unused NSException *e) { return NO; }
    @try {
        qqeClearDrawInfo(qqeObjectIvar(tree, "_normalDrawInfo"));
        qqeClearDrawInfo(qqeObjectIvar(tree, "_editDrawInfo"));
    } @catch (__unused NSException *e) {}
    qqeForceRedraw(tv);
    @try { qqeAdjustBubble(tv, newAttr, oldText, newText); } @catch (__unused NSException *e) {}
    if (oldText.length && newText.length && ![oldText isEqualToString:newText]) {
        qqeEditEnsureState();
        BOOL chained = NO;
        for (NSString *k in [gQQEEditsByOriginal allKeys]) {
            if ([gQQEEditsByOriginal[k] isEqualToString:oldText]) { gQQEEditsByOriginal[k] = newText; chained = YES; break; }
        }
        if (!chained) gQQEEditsByOriginal[oldText] = newText;
    }
    return YES;
}

static void qqeApplyEdit(UIView *tv, NSString *original, NSString *newText) {
    if (!tv || newText.length == 0) return;
    if (newText.length > original.length) return;   // 只能缩减：字符数 ≤ 原文
    @try { qqeSetContentCacheText(tv, newText); } @catch (__unused NSException *e) {}
}

static void qqeDismissMenuWindow(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (qqeClassContains(w, @"AIOPopMenuWindow")) {
                    @try { w.hidden = YES; [w resignKeyWindow]; } @catch (__unused NSException *e) {}
                }
            }
        }
    }
}

static void qqeShowEditAlert(UIView *tv, NSString *original) {
    if (!tv) return;
    UIWindow *win = activeForegroundWindow();
    if (!win) return;
    UIViewController *top = win.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if (!top) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"本地编辑（仅本机显示）"
                                                               message:@"只能删减字数，不能加长"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = original;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    __weak UIView *wtv = tv;
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *txt = ac.textFields.firstObject.text ?: @"";
        qqeApplyEdit(wtv, original, txt);
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:ac animated:YES completion:nil];
}

static void qqeTriggerEdit(void) {
    if (!pref_editText) return;
    if (!gQQEEditCaptureOK || gQQEEditOriginal.length == 0) return;
    UIView *tv = gQQEEditTextView;
    if (!tv) return;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - gQQEEditTriggerTs < 0.6) return;   // 去抖：tap 和 didSelect 只触发一次
    gQQEEditTriggerTs = now;
    NSString *original = [gQQEEditOriginal copy];
    qqeDismissMenuWindow();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        qqeShowEditAlert(tv, original);
    });
}

@interface QQEEditMenuHandler : NSObject
+ (instancetype)shared;
- (void)qqeEditTapped:(id)sender;
@end

@implementation QQEEditMenuHandler
+ (instancetype)shared {
    static QQEEditMenuHandler *s = nil; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [[QQEEditMenuHandler alloc] init]; });
    return s;
}
- (void)qqeEditTapped:(id)sender { qqeTriggerEdit(); }
@end

static BOOL qqeEditMenuShouldInject(void) {
    return gQQEEditCaptureOK && ([NSDate timeIntervalSinceReferenceDate] - gQQEEditCaptureTs < 5.0);
}

static void qqeDecorateEditCell(UIView *cell) {
    if (!cell) return;
    UILabel *label = (UILabel *)qqeFindFirstSubviewOfClass(cell, [UILabel class]);
    if (label) label.text = @"编辑";
    UIImageView *iv = (UIImageView *)qqeFindFirstSubviewOfClass(cell, [UIImageView class]);
    if (iv) {
        UIImage *img = nil;
        if (@available(iOS 13.0, *)) { @try { img = [UIImage systemImageNamed:@"square.and.pencil"]; } @catch (__unused NSException *e) {} }
        if (img) iv.image = img;
    }
    cell.userInteractionEnabled = YES;
    UITapGestureRecognizer *old = objc_getAssociatedObject(cell, &kQQEEditTapKey);
    if (old) { @try { [cell removeGestureRecognizer:old]; } @catch (__unused NSException *e) {} }
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[QQEEditMenuHandler shared] action:@selector(qqeEditTapped:)];
    tap.cancelsTouchesInView = YES;
    [cell addGestureRecognizer:tap];
    objc_setAssociatedObject(cell, &kQQEEditTapKey, tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// cell 滑出再滑回 / 复用重绑后，把编辑补回去。
static void qqeReapplyEditsForCell(UIView *cell) {
    if (!pref_editText) return;
    qqeEditEnsureState();
    if (gQQEEditsByOriginal.count == 0) return;
    if (!qqeClassContains(cell, @"AIOContentCell")) return;
    UIView *tv = qqeFindSubviewContains(cell, @"AIOTextView", 8);
    if (!tv) return;
    id tree = qqeObjectIvar(tv, "_treeContent");
    id inter = tree ? qqeObjectIvar(tree, "_intermediatedata") : nil;
    if (!tree || !inter) return;
    id attr = qqeReadAttr(inter);
    NSString *cur = qqeAttrPlain(attr);
    if (cur.length == 0) return;

    // ① 当前是某条原文 → 重新改成新文本
    NSString *newForOriginal = gQQEEditsByOriginal[cur];
    if (newForOriginal && ![newForOriginal isEqualToString:cur]) {
        @try { qqeSetContentCacheText(tv, newForOriginal); } @catch (__unused NSException *e) {}
        return;
    }
    // ② 当前已是某条新文本(文本对、frame 可能被还原) → 仅重缩气泡(qqeAdjustBubble 自带幂等守卫)
    for (NSString *k in gQQEEditsByOriginal) {
        NSString *nv = gQQEEditsByOriginal[k];
        if ([nv isEqualToString:cur] && ![nv isEqualToString:k]) {
            @try { qqeAdjustBubble(tv, (NSAttributedString *)attr, k, cur); } @catch (__unused NSException *e) {}
            return;
        }
    }
}

static void qqe_AIOContentCell_bindViewModel(id cellSelf, SEL cmd, id vm) {
    if (gQQEOrigAIOBindViewModel) ((void (*)(id, SEL, id))gQQEOrigAIOBindViewModel)(cellSelf, cmd, vm);
    if (!pref_editText) return;
    qqeEditEnsureState();
    if (gQQEEditsByOriginal.count == 0) return;
    UIView *cell = (UIView *)cellSelf;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { qqeReapplyEditsForCell(cell); } @catch (__unused NSException *e) {}
    });
}

static void qqeInstallEditReapplyHook(void) {
    if (gQQEOrigAIOBindViewModel) return;
    Class cls = objc_getClass("AIOLib.AIOContentCell");
    if (!cls) return;
    SEL sel = sel_registerName("bindViewModel:");
    if (!class_getInstanceMethod(cls, sel)) return;
    qqesignHookInstanceMethod(cls, sel, (IMP)qqe_AIOContentCell_bindViewModel, &gQQEOrigAIOBindViewModel);
}

%group QQEEditMenu

%hook AIOMessageMenuController

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    NSInteger n = %orig;
    if (!pref_editText) return n;
    if (section != kQQEEditSection) return n;
    if (!qqeEditMenuShouldInject()) { gQQEMenuEditRow = -1; return n; }
    gQQEMenuEditRow = n;        // 新项插在末尾(row = 原生项数)
    return n + 1;
}

- (id)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (pref_editText && gQQEMenuEditRow >= 0 &&
        indexPath.section == kQQEEditSection && indexPath.row == gQQEMenuEditRow) {
        // 用 row=0 模板克隆，避免 Swift 用越界 row 索引 items 数组
        NSIndexPath *tmpl = [NSIndexPath indexPathForRow:0 inSection:kQQEEditSection];
        id cell = %orig(cv, tmpl);
        @try { qqeDecorateEditCell((UIView *)cell); } @catch (__unused NSException *e) {}
        return cell;
    }
    return %orig;
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    if (pref_editText && gQQEMenuEditRow >= 0 &&
        indexPath.section == kQQEEditSection && indexPath.row == gQQEMenuEditRow) {
        qqeTriggerEdit();
        return;   // 不调 %orig：避免 Swift 用越界 row 索引 items 数组
    }
    %orig;
}

%end

%end // %group QQEEditMenu

static void qqeEditEnsureMenuHooks(void) {
    if (gQQEEditMenuHooked) return;
    if (!objc_getClass("AIOMessageMenuController")) return;   // AIO 未加载，下次再试
    gQQEEditMenuHooked = YES;
    %init(QQEEditMenu);
}

static void qqeCaptureLongPress(UILongPressGestureRecognizer *gr) {
    qqeEditEnsureMenuHooks();      // 进了 AIO 才装菜单 hook
    qqeInstallEditReapplyHook();   // 进了 AIO 才装重绑持久化 hook
    gQQEEditCaptureOK = NO;
    UIView *gv = gr.view;
    if (!gv) return;
    CGPoint p = [gr locationInView:gv];
    UIView *pressed = [gv hitTest:p withEvent:nil];
    if (!pressed) pressed = gv;
    UIView *cell = qqeFindAncestorCell(pressed);
    UIView *tv = qqeFindAIOTextView(pressed, cell);
    if (!tv) return;
    if (!qqeIsIncomingBubble(tv)) return;   // 自己消息 → 不出编辑项
    NSString *original = qqeTextViewExtract(tv, NULL, NULL, NULL);
    if (original.length == 0) return;
    gQQEEditTextView = tv;
    gQQEEditOriginal = [original copy];
    gQQEEditCaptureTs = [NSDate timeIntervalSinceReferenceDate];
    gQQEEditCaptureOK = YES;
}

%hook UILongPressGestureRecognizer

- (void)setState:(UIGestureRecognizerState)state {
    %orig;
    if (state != UIGestureRecognizerStateBegan) return;
    if (!pref_editText) return;
    @try { qqeCaptureLongPress(self); } @catch (__unused NSException *e) {}
}

%end


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
#pragma mark - 7. 启动公告 (远程弹窗，系统样式)
// ─────────────────────────────────────────────
//
// QQ 启动后拉取下面的 URL，按返回的 id 去重（同一条只弹一次），
// 用系统 UIAlertController 弹一次。服务器端随时改内容 / 换 id 即可。
//
// 服务器返回 JSON（建议 HTTPS）：
//   {
//     "id": "2026-06-02-1",          // 去重键；改了它才会重新弹。缺省则用 标题+正文 的哈希
//     "title": "标题",
//     "message": "正文",
//     "buttons": [                    // 可选；缺省给一个「确定」
//       { "text": "知道了", "style": "cancel" },
//       { "text": "查看",   "style": "default", "url": "https://..." }
//     ]
//   }
//   标题和正文都为空 => 不弹（可用于「关掉」公告）。
//
// ★★★ 改成你自己的网址 ★★★
#define QQE_ANNOUNCE_URL @"https://qqnotify.my78.cyou"

static void qqesignPresentAnnouncement(NSString *announceId, NSString *title, NSString *message, NSArray *buttons) {
    UIWindow *win = activeForegroundWindow();
    UIViewController *top = win.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if (!top) return; // 窗口还没就绪：本次放弃，不记 id，下次启动再试

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:(title.length ? title : nil)
                                                                  message:(message.length ? message : nil)
                                                           preferredStyle:UIAlertControllerStyleAlert];
    if (buttons.count == 0) {
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    } else {
        for (id b in buttons) {
            if (![b isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *bd = (NSDictionary *)b;
            NSString *text = [bd[@"text"] isKindOfClass:[NSString class]] ? bd[@"text"] : @"确定";
            if (text.length == 0) text = @"确定";
            NSString *styleStr = [bd[@"style"] isKindOfClass:[NSString class]] ? bd[@"style"] : nil;
            UIAlertActionStyle style = UIAlertActionStyleDefault;
            if ([styleStr isEqualToString:@"cancel"])           style = UIAlertActionStyleCancel;
            else if ([styleStr isEqualToString:@"destructive"]) style = UIAlertActionStyleDestructive;
            NSString *urlStr = [bd[@"url"] isKindOfClass:[NSString class]] ? bd[@"url"] : nil;
            [alert addAction:[UIAlertAction actionWithTitle:text style:style handler:^(UIAlertAction *a) {
                if (urlStr.length) {
                    NSURL *u = [NSURL URLWithString:urlStr];
                    if (u) [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
                }
            }]];
        }
    }

    [top presentViewController:alert animated:YES completion:^{
        // 成功弹出后才记 id，避免「标记已读但其实没看到」
        [tweakDefaults() setObject:announceId forKey:@"lastAnnounceId"];
        [tweakDefaults() synchronize];
    }];
}

static void qqesignFetchLaunchAnnouncement(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURL *url = [NSURL URLWithString:QQE_ANNOUNCE_URL];
        if (!url) return;
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                      timeoutInterval:8.0];
        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                if (err || data.length == 0) return;
                id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (![obj isKindOfClass:[NSDictionary class]]) return;
                NSDictionary *json = (NSDictionary *)obj;

                NSString *title   = [json[@"title"]   isKindOfClass:[NSString class]] ? json[@"title"]   : @"";
                NSString *message = [json[@"message"] isKindOfClass:[NSString class]] ? json[@"message"] : @"";
                if (title.length == 0 && message.length == 0) return; // 空内容 => 不弹

                NSString *announceId = [json[@"id"] isKindOfClass:[NSString class]] ? json[@"id"] : nil;
                if (announceId.length == 0) {
                    announceId = [NSString stringWithFormat:@"h%lu",
                                  (unsigned long)[[title stringByAppendingString:message] hash]];
                }
                NSString *last = [tweakDefaults() stringForKey:@"lastAnnounceId"];
                if ([announceId isEqualToString:last]) return; // 同一条已弹过，跳过

                NSArray *buttons = [json[@"buttons"] isKindOfClass:[NSArray class]] ? json[@"buttons"] : nil;
                dispatch_async(dispatch_get_main_queue(), ^{
                    qqesignPresentAnnouncement(announceId, title, message, buttons);
                });
            }];
        [task resume];
    });
}

// ─────────────────────────────────────────────
#pragma mark - Constructor
// ─────────────────────────────────────────────

%ctor {
    @autoreleasepool {
        loadPrefs();
        %init;
        %init(QZoneAdBlockLazyEntry);
        qqesignInstallQZoneAdHooks("ctor");
        if (qqesignAnyTopSearchEnabled()) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                qqesignInstallTopSearchHooks("post-launch-safe");
            });
        }
        qqesignInstallRecallHooksWithRetry();
        qqesign_installNetworkHooks(); // ★ 网络层SSLRead拦截
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            qqesignFetchLaunchAnnouncement(); // ★ 启动公告（远程弹窗）
        });
    }
}
