/*
 * QQESign — Frida 防撤回探索脚本
 * 目标：在 QQ NT (Swift) 中定位撤回的真正处理路径
 *
 * 策略：
 * 1. 枚举所有含 "recall"/"revoke" 的 Swift/ObjC 类和方法
 * 2. Hook 关键的 ObjC 桥接方法，打印调用栈
 * 3. 拦截 NSNotification 分发，追溯发送源头
 * 4. 探索 Swift 类的实际调用链
 * 5. 监控网络数据包中撤回相关的 protobuf
 *
 * 用法：
 *   frida -U com.tencent.mqq -l frida_explore_antirevoke.js
 *   或
 *   frida -U -f com.tencent.mqq -l frida_explore_antirevoke.js --no-pause
 */

// ─────────────────────────────────────────────
// 配置
// ─────────────────────────────────────────────
const CONFIG = {
    // 打印所有枚举到的 recall 相关类
    verboseEnum: true,
    // 打印调用栈 (backtrace)
    showStack: true,
    // 栈帧深度
    stackDepth: 30,
    // 自动附加到已运行的进程
    autoAttach: true,
};

// ─────────────────────────────────────────────
// 工具函数
// ─────────────────────────────────────────────
function log(msg) {
    console.log(`[QQESign-探索] ${msg}`);
}

function logSep(title) {
    const line = '═'.repeat(60);
    console.log(`\n${line}`);
    console.log(`  ${title}`);
    console.log(`${line}\n`);
}

function getStack(depth) {
    try {
        return Thread.backtrace(this.context, Backtracer.ACCURATE)
            .map(DebugSymbol.fromAddress)
            .slice(0, depth || CONFIG.stackDepth)
            .join('\n    ');
    } catch (e) {
        return `(stack unavailable: ${e})`;
    }
}

function formatArg(obj) {
    if (obj === null) return 'null';
    if (obj === undefined) return 'undefined';
    try {
        if (obj.$className) return `[${obj.$className}]`;
        if (obj.$kind === 'instance') return `[instance of ${Object.keys(obj).length} props]`;
        return String(obj);
    } catch (e) {
        return `(obj at ${ptr(obj)})`;
    }
}

function getClassName(obj) {
    try {
        if (obj.$className) return obj.$className;
        return '(unknown)';
    } catch (e) {
        return '(error)';
    }
}

// ─────────────────────────────────────────────
// 1. 枚举所有含 recall/revoke 的类和方法
// ─────────────────────────────────────────────
function enumerateRecallClasses() {
    logSep('1. 枚举 recall/revoke 相关类和方法');

    const recallClasses = [];
    const totalClasses = ObjC.classes;

    for (const name in totalClasses) {
        const lower = name.toLowerCase();
        if (lower.includes('recall') || lower.includes('revoke') || lower.includes('撤回')) {
            const cls = totalClasses[name];
            const methods = {
                own: [],
                protocols: [],
            };

            try {
                methods.own = cls.$ownMethods.filter(m =>
                    m.toLowerCase().includes('recall') ||
                    m.toLowerCase().includes('revoke')
                );
            } catch (e) {}

            if (methods.own.length > 0 || CONFIG.verboseEnum) {
                recallClasses.push({ name, methods });
            }
        }
    }

    // 按名称排序
    recallClasses.sort((a, b) => a.name.localeCompare(b.name));

    log(`找到 ${recallClasses.length} 个 recall/revoke 相关类:`);
    for (const cls of recallClasses) {
        console.log(`  📦 ${cls.name}`);
        if (cls.methods.own.length > 0) {
            for (const m of cls.methods.own) {
                console.log(`     └─ ${m}`);
            }
        }
    }

    return recallClasses;
}

// ─────────────────────────────────────────────
// 2. 枚举含 recall 的 Swift 类 (通过 @objc 暴露的)
//    + 尝试通过模块名过滤出 NTKernelAdapter 等关键模块
// ─────────────────────────────────────────────
function enumerateSwiftRecallClasses() {
    logSep('2. 枚举 Swift recall 相关模块');

    // 通过已知的 Swift 模块前缀来识别
    const swiftPrefixes = ['_TtC', 'NT', 'QQ'];
    const swiftRecallClasses = [];

    for (const name in ObjC.classes) {
        // Swift 类通常有 _TtC 前缀或者是 NT/QQ 开头的 Swift 桥接类
        const lower = name.toLowerCase();
        if (!(lower.includes('recall') || lower.includes('revoke'))) continue;

        const cls = ObjC.classes[name];
        try {
            const methods = cls.$ownMethods.filter(m =>
                m.toLowerCase().includes('recall') ||
                m.toLowerCase().includes('revoke')
            );
            if (methods.length > 0 || CONFIG.verboseEnum) {
                swiftRecallClasses.push({ name, methods });
            }
        } catch (e) {}
    }

    swiftRecallClasses.sort((a, b) => a.name.localeCompare(b.name));
    log(`找到 ${swiftRecallClasses.length} 个 Swift recall 桥接类:`);
    for (const cls of swiftRecallClasses) {
        console.log(`  🦅 ${cls.name}`);
        for (const m of cls.methods) {
            console.log(`     └─ ${m}`);
        }
    }

    return swiftRecallClasses;
}

// ─────────────────────────────────────────────
// 3. 动态 Hook 已知的关键 ObjC 方法，打印调用栈
// ─────────────────────────────────────────────
function hookRecallMethods() {
    logSep('3. Hook 关键 recall 方法 - 追踪调用链');

    const targets = [
        // QQ 传统 ObjC 层
        ['QQMessageRecallNetEngine', 'parseC2CRecallNotify:bufferLen:subcmd:model:'],
        ['QQMessageRecallModule', 'convertRecallItemToMsg:recallModel:msgType:bindUin:'],
        ['QQMessageRecallModule', 'handleSideAccountRecallNotify:bufferLen:subcmd:bindUin:tracelessFlag:'],
        ['QQMessageDecouplingBridge', 'recallMessagePair:'],
        ['QQMessageDecouplingBridge', 'generatePushUniqueIdentifier:isRecallPush:'],
        ['OCMsgRecallInfo', 'isRecallNotify'],
        ['OCMsgRecallInfo', 'isTracelessRecall'],

        // NT Swift 桥接层
        ['OCIKernelMsgService', 'getRecallMsgsByMsgId:msgIds:cb:'],
        ['_TtC15NTKernelAdapter14MessageService', 'getRecallMsgsWithPeer:msgIds:cb:'],

        // AIO / UI 层
        ['QQAIOCell', 'updateCellViewRecall'],
        ['NTAIOGrayTipsOtherLinkRecallHandle', 'grayTipsEventWithModel:curVC:contact:busiId:'],

        // 闪照浏览器中的 recall 处理
        ['_TtC15AIOPhotoBrowser31NTAIOPhotoBrowserViewController', 'receiveRecallNotification:'],
        ['_TtC9NTAIOChat21NTStreamMsgAIOHandler', 'receiveRecallNotification:'],

        // 浮层
        ['_TtC9NTAIOChat20NTAIOFloatEarManager', 'onRecvRecallMsg:'],
        ['_TtC9NTAIOChat17NTAIOFloatEarPart', 'recallMessageWithNotification:'],

        // Kernel / Guild
        ['NTGuildMsgListener', 'onMsgRecall:peerUid:seq:'],
        ['_TtC13GuildNTKernel20SWIKernelMsgListener', 'onMsgRecall:peerUid:seq:'],
        ['KTIKernelMsgListener', 'onMsgRecall:peerUid:seq:'],

        // 通知中心 - 追踪撤回通知的源头
        ['NSNotificationCenter', 'postNotification:'],
        ['NSNotificationCenter', 'postNotificationName:object:'],
        ['NSNotificationCenter', 'postNotificationName:object:userInfo:'],
    ];

    let hookedCount = 0;
    for (const [clsName, selName] of targets) {
        const cls = ObjC.classes[clsName];
        if (!cls) {
            log(`⚠️  类不存在: ${clsName}`);
            continue;
        }

        try {
            // 先检查方法是否存在
            let methods;
            try {
                methods = cls.$ownMethods;
            } catch (e) {
                log(`⚠️  无法获取 ${clsName} 的方法列表`);
                continue;
            }

            if (!methods.includes(selName)) {
                log(`⚠️  方法不存在: ${clsName} -${selName}`);
                continue;
            }

            const hookImpl = function () {
                const args = Array.from(arguments);
                const sel = ObjC.selectorAsString(this._cmd);

                // 过滤掉非 recall 通知
                if (selName === 'postNotification:' || selName === 'postNotificationName:object:' || selName === 'postNotificationName:object:userInfo:') {
                    let notifName = '';
                    try {
                        if (args[0] && args[0].$className === 'NSNotification') {
                            notifName = args[0].name().toString();
                        } else if (args[0] && typeof args[0] === 'string') {
                            notifName = args[0];
                        }
                    } catch (e) {}
                    if (!notifName.toLowerCase().includes('recall') && !notifName.toLowerCase().includes('revoke')) {
                        return this.original.apply(this, args);
                    }
                    log(`📨 通知: ${notifName}`);
                }

                // 检查是否是 recall 相关调用
                log(`🔧 ${clsName} -[${sel}]`);

                // 打印参数详情
                for (let i = 0; i < args.length; i++) {
                    const arg = args[i];
                    if (arg && arg.$className) {
                        try {
                            // 尝试打印对象描述
                            const desc = arg.toString();
                            log(`   arg[${i}]: [${arg.$className}] ${desc.substring(0, 200)}`);
                        } catch (e) {
                            log(`   arg[${i}]: [${arg.$className}]`);
                        }
                    } else if (arg !== null && arg !== undefined) {
                        log(`   arg[${i}]: ${arg}`);
                    } else {
                        log(`   arg[${i}]: ${arg}`);
                    }
                }

                // 打印调用栈
                if (CONFIG.showStack) {
                    log(`   🥞 调用栈:\n    ${getStack()}`);
                }

                // 继续原始调用
                return this.original.apply(this, args);
            };

            // 保存原始实现并 hook
            const className = clsName;
            ObjC.schedule(ObjC.mainQueue, () => {
                try {
                    const hook = ObjC.classes[className][selName];
                    if (hook) {
                        hook.implementation = hookImpl;
                        hookedCount++;
                        log(`✅ Hook 成功: ${className} -[${selName}]`);
                    }
                } catch (e) {
                    log(`❌ Hook 失败: ${className} -[${selName}]: ${e}`);
                }
            });
        } catch (e) {
            log(`❌ 处理 ${clsName} -[${selName}] 时出错: ${e}`);
        }
    }

    // 延迟一下确认 hook 数量
    setTimeout(() => {
        log(`\n📊 共尝试 Hook ${targets.length} 个方法，成功 ${hookedCount} 个`);
    }, 500);
}

// ─────────────────────────────────────────────
// 4. 探索 Swift 运行时 — 通过 Module 名称扫描
// ─────────────────────────────────────────────
function exploreSwiftRuntime() {
    logSep('4. Swift 运行时探索');

    // 枚举所有 ObjC 类，找出属于特定模块的 Swift 类
    const modules = {
        'NTKernelAdapter': [],
        'NTAIOChat': [],
        'AIOPhotoBrowser': [],
        'QQ': [],
    };

    for (const name in ObjC.classes) {
        for (const mod in modules) {
            if (name.includes(mod)) {
                modules[mod].push(name);
                break;
            }
        }
    }

    for (const [mod, classes] of Object.entries(modules)) {
        console.log(`\n  📦 模块: ${mod} (${classes.length} 个类)`);
        // 只显示前 30 个
        const display = classes.slice(0, 30);
        for (const cls of display) {
            console.log(`     └─ ${cls}`);
        }
        if (classes.length > 30) {
            console.log(`     ... 还有 ${classes.length - 30} 个类`);
        }
    }
}

// ─────────────────────────────────────────────
// 5. 监控撤回通知的完整生命周期
// ─────────────────────────────────────────────
function monitorRecallLifecycle() {
    logSep('5. 监控撤回通知生命周期');

    // Hook NSNotificationCenter 的 post 方法
    const nc = ObjC.classes.NSNotificationCenter;
    const postSel = ObjC.selector('postNotification:');

    try {
        // 使用更精确的 hook
        const orig = nc.$methods.postNotification;
        if (orig) {
            orig.implementation = ObjC.implement(orig.types, function (self, cmd, notification) {
                try {
                    const name = notification.name().toString();
                    const lower = name.toLowerCase();
                    if (lower.includes('recall') || lower.includes('revoke') || lower.includes('撤回')) {
                        log(`🔥 [通知生命周期] 发出撤回通知: ${name}`);
                        log(`   🥞 发送者调用栈:\n    ${getStack(20)}`);

                        // 打印 userInfo
                        try {
                            const ui = notification.userInfo();
                            if (ui) {
                                const dict = ObjC.classes.NSDictionary;
                                const keys = ui.allKeys();
                                for (let i = 0; i < keys.count(); i++) {
                                    const key = keys.objectAtIndex_(i).toString();
                                    const val = ui.objectForKey_(keys.objectAtIndex_(i));
                                    let valStr = '';
                                    try {
                                        valStr = val.toString().substring(0, 100);
                                    } catch (e) {
                                        valStr = `[${val.$className}]`;
                                    }
                                    log(`      userInfo.${key} = ${valStr}`);
                                }
                            }
                        } catch (e) {
                            log(`      (userInfo 不可读: ${e})`);
                        }

                        // 检查是否是 QQ 内部发出的
                        const bt = Thread.backtrace(this.context, Backtracer.ACCURATE);
                        for (const addr of bt) {
                            const sym = DebugSymbol.fromAddress(addr);
                            const symStr = sym.toString();
                            if (symStr.includes('QQ') && !symStr.includes('Foundation') && !symStr.includes('CoreFoundation')) {
                                log(`   🔗 QQ 内部帧: ${symStr}`);
                            }
                        }
                    }
                } catch (e) {
                    // ignore
                }
                return this.original(self, cmd, notification);
            });
            log('✅ 已 Hook NSNotificationCenter postNotification:');
        }
    } catch (e) {
        log(`❌ Hook 通知失败: ${e}`);
    }
}

// ─────────────────────────────────────────────
// 6. 探索关键对象的属性
// ─────────────────────────────────────────────
function exploreKeyObjects() {
    logSep('6. 探索关键对象结构');

    // 尝试获取 OCMsgRecallInfo 的 ivar 列表
    const classesToExplore = [
        'OCMsgRecallInfo',
        'QQMessageRecallNetEngine',
        'QQMessageRecallModule',
        'QQMessageDecouplingBridge',
        'OCIKernelMsgService',
    ];

    for (const clsName of classesToExplore) {
        const cls = ObjC.classes[clsName];
        if (!cls) {
            log(`❌ ${clsName} 不存在`);
            continue;
        }

        console.log(`\n  📋 ${clsName}:`);

        // 列出所有 ivars
        try {
            const ivars = cls.$ivars;
            if (ivars && ivars.length > 0) {
                console.log(`     ivars: ${ivars.join(', ')}`);
            }
        } catch (e) {}

        // 列出所有 protocols
        try {
            const protos = cls.$protocols;
            if (protos && protos.length > 0) {
                console.log(`     protocols: ${protos.join(', ')}`);
            }
        } catch (e) {}
    }
}

// ─────────────────────────────────────────────
// 7. 监控 MsgRecallMgr (C++) — 通过 Dobby/Substrate
//    如果 Frida 能访问到 C++ 符号，尝试直接 hook
// ─────────────────────────────────────────────
function tryHookCppRecall() {
    logSep('7. 尝试定位 C++ 符号 (MsgRecallMgr/KernelMsgService)');

    const cppSymbols = [
        '__ZN2nt7wrapper16KernelMsgService24recallMsgFromC2CAndGroupEPNS_13MsgRecallItemEiiPS2_',
        '__ZN2nt7wrapper16KernelMsgService20getRecallMsgsByMsgIdERKNSt3__16vectorINS0_10MsgKeyTypeENS1_9allocatorIS4_EEEEPFS6_NS1_8functionIFvNS_13MsgRecallItemEiEEEEE',
        '__ZN12MsgRecallMgr8RecallMsgERKNSt3__110shared_ptrIN2nt7wrapper15MsgRecallItemEEE',
        // 可能的不同 mangling
        '_ZN2nt7wrapper16KernelMsgService24recallMsgFromC2CAndGroupEPNS_13MsgRecallItemEiiPS2_',
        '_ZN2nt7wrapper16KernelMsgService20getRecallMsgsByMsgIdESt6vectorINS0_10MsgKeyTypeESaIS4_EENSt3__18functionIFvNS_13MsgRecallItemEiEEE',
        '_ZN12MsgRecallMgr8RecallMsgERKSt10shared_ptrIN2nt7wrapper15MsgRecallItemEE',
    ];

    for (const sym of cppSymbols) {
        try {
            const addr = Module.findExportByName(null, sym);
            if (addr) {
                log(`✅ 找到 C++ 符号: ${sym}`);
                log(`   地址: ${addr}`);

                // 尝试 Hook
                Interceptor.attach(addr, {
                    onEnter(args) {
                        log(`🔧 [C++] ${sym} 被调用`);
                        const bt = Thread.backtrace(this.context, Backtracer.ACCURATE);
                        const stackStr = bt.map(DebugSymbol.fromAddress).join('\n    ');
                        log(`   🥞 调用栈:\n    ${stackStr}`);
                    },
                    onRetVal(retval) {
                        log(`   ↩️  返回值: ${retval}`);
                    }
                });
                log(`   ✅ Hook 成功: ${sym}`);
            }
        } catch (e) {
            // 符号可能不存在或无法 hook
        }
    }
}

// ─────────────────────────────────────────────
// 8. 扫描二进制中的 recall 相关字符串
// ─────────────────────────────────────────────
function scanRecallStrings() {
    logSep('8. 扫描 QQ 二进制中的 recall 相关字符串');

    const modules = Process.enumerateModules();
    const qqModule = modules.find(m =>
        m.path.toLowerCase().includes('qq') &&
        m.path.endsWith('QQ')
    );

    if (!qqModule) {
        log('❌ 找不到 QQ 主模块');
        return;
    }

    log(`📄 QQ 模块: ${qqModule.path}`);
    log(`   范围: ${qqModule.base} - ${ptr(qqModule.base).add(qqModule.size)}`);

    // 扫描字符串
    const keywords = ['recall', 'revoke', '撤回', 'Recall', 'Revoke'];
    let foundCount = 0;

    try {
        // 使用 Memory.scan 扫描 __cstring 段
        const cstringRanges = qqModule.enumerateRanges('r--')
            .filter(r => {
                const name = r.name || '';
                return name.includes('__cstring') || name.includes('__const');
            });

        for (const range of cstringRanges) {
            try {
                Memory.scan(range.base, range.size, 'recall|revoke|Recall|Revoke'.replace(/\|/g, '\\x00|'), {
                    onMatch(address, size) {
                        try {
                            const str = address.readUtf8String();
                            if (str && (str.toLowerCase().includes('recall') || str.toLowerCase().includes('revoke'))) {
                                console.log(`  🔤 [${address}] "${str}"`);
                                foundCount++;
                            }
                        } catch (e) {}
                    },
                    onError(reason) {},
                    onComplete() {}
                });
            } catch (e) {}
        }
    } catch (e) {
        log(`扫描字符串时出错: ${e}`);
    }

    log(`共找到 ${foundCount} 个 recall/revoke 相关字符串`);
}

// ─────────────────────────────────────────────
// 9. 主动探索：查找撤回消息的数据流
//    尝试 hook protobuf 解析入口
// ─────────────────────────────────────────────
function hookProtobufLayer() {
    logSep('9. Hook Protobuf 解析层 (拦截网络数据)');

    // 常见的 protobuf 解析类
    const pbTargets = [
        ['QQPBMsgRecallItem', 'initWithData:'],  // 可能是 protobuf 模型
        ['MsgRecallItem', 'initWithPbData:'],
        ['RecallMsgPB', 'initWithData:'],
    ];

    for (const [clsName, selName] of pbTargets) {
        try {
            const cls = ObjC.classes[clsName];
            if (cls && cls[selName]) {
                cls[selName].implementation = function () {
                    const args = Array.from(arguments);
                    log(`🔧 [PB] ${clsName} -[${selName}] 被调用`);
                    if (CONFIG.showStack) {
                        log(`   🥞 调用栈:\n    ${getStack(15)}`);
                    }
                    return this.original.apply(this, args);
                };
                log(`✅ Hook PB: ${clsName} -[${selName}]`);
            }
        } catch (e) {}
    }
}

// ─────────────────────────────────────────────
// 10. 尝试定位撤回涉及的消息存储层
// ─────────────────────────────────────────────
function hookMsgStorage() {
    logSep('10. Hook 消息存储层 (撤回消息落地)');

    // QQ 可能通过 MsgCache / MsgStorage 等类处理撤回
    const storageTargets = [
        'MsgCache',
        'MsgStorage',
        'QQMsgCache',
        'QQMsgStorage',
        'MessageService',
        'KernelMsgService',
        'NTMessageService',
        'QQMessageService',
    ];

    for (const clsName of storageTargets) {
        const cls = ObjC.classes[clsName];
        if (!cls) continue;

        try {
            const methods = cls.$ownMethods;
            const recallMethods = methods.filter(m =>
                m.toLowerCase().includes('recall') ||
                m.toLowerCase().includes('revoke') ||
                m.toLowerCase().includes('delet') ||
                m.toLowerCase().includes('remove')
            );

            if (recallMethods.length > 0) {
                console.log(`\n  📦 ${clsName} — 发现 ${recallMethods.length} 个相关方法:`);
                for (const m of recallMethods) {
                    console.log(`     └─ ${m}`);
                }
            }
        } catch (e) {}
    }
}

// ─────────────────────────────────────────────
// 启动
// ─────────────────────────────────────────────
function main() {
    logSep('QQESign Frida 防撤回探索脚本 v1.0');
    log(`设备: ${Process.arch} | ${Process.platform}`);
    log(`进程: ${Process.name} (PID: ${Process.id})`);

    // 阶段 1: 枚举
    const recallClasses = enumerateRecallClasses();
    const swiftClasses = enumerateSwiftRecallClasses();

    // 阶段 2: 探索
    exploreSwiftRuntime();
    exploreKeyObjects();
    hookMsgStorage();

    // 阶段 3: Hook
    hookRecallMethods();
    monitorRecallLifecycle();
    hookProtobufLayer();

    // 阶段 4: C++ / 底层
    tryHookCppRecall();
    scanRecallStrings();

    logSep('探索脚本已就绪');
    log('现在去 QQ 中让某人撤回一条消息，观察输出！');
    log('按 Ctrl+C 停止\n');
}

try {
    main();
} catch (e) {
    log(`❌ 初始化错误: ${e}`);
    console.error(e.stack);
}
