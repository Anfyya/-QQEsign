from pathlib import Path

p = Path('Tweak.x')
s = p.read_text()

s = s.replace('// 防撤回 / 闪照保存+无限查看 / 自定义设备名+电量', '// 防撤回 / 闪照无限查看 / 自定义电量')

s = s.replace('static BOOL   pref_flashUnlimited = YES;\nstatic BOOL   pref_flashSave      = YES;\nstatic BOOL   pref_fakeDevice     = NO;\nstatic NSString *pref_deviceName  = @"iPhone 16 Pro";\nstatic BOOL   pref_fakeBattery    = NO;', 'static BOOL   pref_flashUnlimited = YES;\nstatic BOOL   pref_fakeBattery    = NO;')

s = s.replace('            @"flashUnlimited": @YES,\n            @"flashSave":      @YES,\n            @"fakeDevice":     @NO,\n            @"deviceName":     @"iPhone 16 Pro",\n            @"fakeBattery":    @NO,', '            @"flashUnlimited": @YES,\n            @"fakeBattery":    @NO,')

s = s.replace('    pref_flashUnlimited = [ud boolForKey:@"flashUnlimited"];\n    pref_flashSave      = [ud boolForKey:@"flashSave"];\n    pref_fakeDevice     = [ud boolForKey:@"fakeDevice"];\n    pref_fakeBattery    = [ud boolForKey:@"fakeBattery"];', '    pref_flashUnlimited = [ud boolForKey:@"flashUnlimited"];\n    pref_fakeBattery    = [ud boolForKey:@"fakeBattery"];')

s = s.replace('    NSString *name = [ud stringForKey:@"deviceName"];\n    if (name.length > 0) pref_deviceName = name;\n', '')

old_sections = '''    _sectionTitles = @[@"消息防撤回", @"闪照设置", @"自定义设备名", @"自定义电量", @"关于"];
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
        @[@{@"title": @"QQESign v2.0\\n适配NT架构 · 防撤回 · 闪照解锁\\n自定义设备名与电量", @"type": @"info"}],
    ];'''
new_sections = '''    _sectionTitles = @[@"消息防撤回", @"闪照设置", @"自定义电量", @"关于"];
    _sections = @[
        @[@{@"title": @"开启防撤回", @"key": @"antiRevoke", @"type": @"switch"}],
        @[@{@"title": @"无限次查看闪照", @"key": @"flashUnlimited", @"type": @"switch"}],
        @[
            @{@"title": @"启用自定义电量", @"key": @"fakeBattery", @"type": @"switch"},
            @{@"title": @"电量 (0~100)", @"key": @"batteryLevel", @"type": @"number"},
            @{@"title": @"模拟充电中", @"key": @"isCharging", @"type": @"switch"},
        ],
        @[@{@"title": @"QQESign v2.1\\n适配NT架构 · 防撤回 · 闪照无限查看\\n自定义电量", @"type": @"info"}],
    ];'''
s = s.replace(old_sections, new_sections)

old_vdl = '''- (void)viewDidLoad {
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
'''
s = s.replace(old_vdl, '''- (void)viewDidLoad {
    %orig;
}
''')

start = s.find('// ─────────────────────────────────────────────\n#pragma mark - 4. 自定义设备名 / 电量')
end = s.find('// ─────────────────────────────────────────────\n#pragma mark - 5. 设置入口', start)
if start != -1 and end != -1:
    s = s[:start] + '''// ─────────────────────────────────────────────
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

''' + s[end:]

s = s.replace('''static void qqesignClearModelAntiRecallRuntimeCache(void) {
    qqeEnsureModelCacheLoaded();
    @synchronized (gQQEModelAntiRecallCache) {
        [gQQEModelAntiRecallCache removeAllObjects];
        [gQQEModelAntiRecallOrder removeAllObjects];
    }
}
''', '''static void qqesignClearModelAntiRecallRuntimeCache(void) {
    qqeEnsureModelCacheLoaded();
    @synchronized (gQQEModelAntiRecallCache) {
        [gQQEModelAntiRecallCache removeAllObjects];
        [gQQEModelAntiRecallOrder removeAllObjects];
        [gQQEModelAntiRecallDisk removeAllObjects];
        [[NSFileManager defaultManager] removeItemAtPath:qqeModelCachePath() error:nil];
    }
}
''')

s = s.replace('防撤回开关关闭：本轮运行缓存已清空，后续撤回放行', '防撤回开关关闭：运行缓存和持久化缓存已清空，后续撤回放行')

s = s.replace('''NSLog(@"[QQESign] v2.0 Loaded (NT架构) antiRevoke=%d flashUnlimited=%d flashSave=%d fakeDevice=%d fakeBatt=%d",
              pref_antiRevoke, pref_flashUnlimited, pref_flashSave,
              pref_fakeDevice, pref_fakeBattery);''', '''NSLog(@"[QQESign] v2.1 Loaded (NT架构) antiRevoke=%d flashUnlimited=%d fakeBatt=%d",
              pref_antiRevoke, pref_flashUnlimited, pref_fakeBattery);''')

for needle in ['pref_flashSave', 'pref_fakeDevice', 'pref_deviceName', '@"flashSave"', '@"fakeDevice"', '@"deviceName"']:
    if needle in s:
        raise SystemExit(f'patch incomplete: {needle}')

p.write_text(s)
print('ci_patch_tweak.py: patched Tweak.x')
