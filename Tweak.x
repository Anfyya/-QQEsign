// ═══════════════════════════════════════════════════════════════════════════
//  QQESignSettingsUI.x  —  液态玻璃风格设置页（原生实现）
//  目标系统：iOS 16.5+（不使用 iOS 26 专属 API）
//
//  玻璃质感用 UIVisualEffectView + UIBlurEffect 复刻；明/暗自动跟随系统
//  （全部使用 dynamic / semantic 颜色，无需手动监听）。强调色为 QQ 蓝。
//  无功能图标的简洁列表；顶部标题为「QQESign / @Yjln」两行。
//
//  ── 集成方式 ──────────────────────────────────────────────────────────────
//  用本文件中的 QQESignSettingsController 与 showQQESignSettings()
//  替换主 tweak 文件里原来的同名实现即可。以下既有符号需保持可见：
//      tweakDefaults()  loadPrefs()
//      qqesignClearModelAntiRecallRuntimeCache()
//      qqesignDrawerClearAllBlockedModels()
//  （它们在主文件中已定义，这里仅声明引用。）
// ═══════════════════════════════════════════════════════════════════════════

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// 主文件已有的符号（前置声明，避免顺序问题）
extern NSUserDefaults *tweakDefaults(void);
extern void loadPrefs(void);
extern void qqesignClearModelAntiRecallRuntimeCache(void);
extern void qqesignDrawerClearAllBlockedModels(void);

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
    UIView       *_titleView;        // 导航栏内联两行标题（滚动后淡入）
    QQEBatterySlider *_batterySlider;
    UILabel *_batteryRowValue;
    UILabel *_batteryHeadValue;
    UILabel *_batteryHeadLabel;
    UIView  *_batterySliderRow;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // 不用系统单行大标题；标题改为自绘两行（大标题块 + 滚动后淡入的内联标题）
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    self.navigationItem.titleView = [self buildNavTitleView];
    _titleView.alpha = 0;   // 顶部隐藏，滚动后淡入

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(dismissSelf)];
    self.navigationItem.rightBarButtonItem.tintColor = QQEBlue();

    // 导航栏：顶部透明、滚动后毛玻璃
    if (@available(iOS 13.0, *)) {
        UINavigationBar *bar = self.navigationController.navigationBar;
        bar.tintColor = QQEBlue();
        UINavigationBarAppearance *edge = [[UINavigationBarAppearance alloc] init];
        [edge configureWithTransparentBackground];
        bar.scrollEdgeAppearance = edge;
        UINavigationBarAppearance *std = [[UINavigationBarAppearance alloc] init];
        [std configureWithDefaultBackground];
        bar.standardAppearance = std;
        bar.compactAppearance = std;
    }

    // 背景壁纸
    QQEWallpaperView *wall = [[QQEWallpaperView alloc] init];
    wall.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:wall];

    // 滚动容器
    _scroll = [[UIScrollView alloc] init];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.backgroundColor = [UIColor clearColor];
    _scroll.alwaysBounceVertical = YES;
    _scroll.showsVerticalScrollIndicator = NO;
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

        [_content.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor constant:8],
        [_content.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-28],
        [_content.leadingAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.leadingAnchor],
        [_content.trailingAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.trailingAnchor],
    ]];

    [self buildContent];
    [self refreshBatteryEnabledState];
}

// 滚动后让内联标题淡入（模拟大标题折叠）
- (void)scrollViewDidScroll:(UIScrollView *)sv {
    CGFloat top = sv.contentOffset.y + sv.adjustedContentInset.top;
    _titleView.alpha = top > 24 ? 1.0 : 0.0;
}

// 导航栏内联两行标题：QQESign / @Yjln
- (UIView *)buildNavTitleView {
    UILabel *main = [[UILabel alloc] init];
    main.text = @"QQESign";
    main.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    main.textColor = QQETextPrimary();
    main.textAlignment = NSTextAlignmentCenter;

    UILabel *sub = [[UILabel alloc] init];
    sub.text = @"@Yjln";
    sub.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
    sub.textColor = QQETextSecondary();
    sub.textAlignment = NSTextAlignmentCenter;

    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[main, sub]];
    st.axis = UILayoutConstraintAxisVertical;
    st.alignment = UIStackViewAlignmentCenter;
    st.spacing = 1;
    _titleView = st;
    return st;
}

// ── 构建全部内容 ─────────────────────────────────────────────
- (void)buildContent {
    // 大标题块（两行）：QQESign / @Yjln
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
    main.font = [UIFont systemFontOfSize:32 weight:UIFontWeightBold];
    main.textColor = QQETextPrimary();

    UILabel *sub = [[UILabel alloc] init];
    sub.text = @"@Yjln";
    sub.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    sub.textColor = QQETextSecondary();

    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[main, sub]];
    st.axis = UILayoutConstraintAxisVertical;
    st.spacing = 3;
    st.layoutMarginsRelativeArrangement = YES;
    st.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(2, 20, 6, 20);
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
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [root presentViewController:nav animated:YES completion:nil];
    });
}
