/*
 * QQESign — Frida 防撤回探索脚本 v2
 * 
 * 基于 v1 枚举结果，定位到真实存在的方法并进行深度追踪
 * 
 * 用法：
 *   先关闭 QQ，然后：
 *   frida -U -f com.tencent.mqq -l frida_explore_v2.js
 */

function log(msg) { console.log(`[QQESign-v2] ${msg}`); }
function sep(title) {
    console.log(`\n${'='.repeat(60)}`);
    console.log(`  ${title}`);
    console.log(`${'='.repeat(60)}`);
}

function getStack(depth) {
    try {
        return Thread.backtrace(this.context, Backtracer.ACCURATE)
            .map(DebugSymbol.fromAddress)
            .slice(0, depth || 25)
            .join('\n    ');
    } catch (e) { return '(no stack)'; }
}

// ═══════════════════════════════════════════════
// 1. 枚举所有含 recall/revoke 的 ObjC 方法
//    (使用 $methods 包含继承方法)
// ═══════════════════════════════════════════════
function enumerateAllRecallMethods() {
    sep('1. 枚举真实 recall 方法 (ObjC)');

    const results = [];

    for (const name in ObjC.classes) {
        const lower = name.toLowerCase();
        if (!(lower.includes('recall') || lower.includes('revoke') || lower.includes('撤回'))) continue;

        const cls = ObjC.classes[name];
        try {
            // 使用 $methods 获取所有方法（包括继承的）
            const allMethods = cls.$methods;
            const recallMethods = allMethods.filter(m =>
                m.toLowerCase().includes('recall') ||
                m.toLowerCase().includes('revoke')
            );
            if (recallMethods.length > 0) {
                results.push({ name, methods: recallMethods });
                console.log(`\n  📦 ${name} (${recallMethods.length} 方法):`);
                for (const m of recallMethods) {
                    console.log(`     └─ ${m}`);
                }
            }
        } catch (e) {}
    }

    log(`共找到 ${results.length} 个 recall 相关类`);
    return results;
}

// ═══════════════════════════════════════════════
// 2. 深度探索关键 Swift 模块的 recall 方法
// ═══════════════════════════════════════════════
function exploreSwiftRecall() {
    sep('2. 深度探索 Swift recall 模块');

    const targets = [
        'NTKernelAdapter',
        'NTAIOChat',
        'NTBaseAIO',
        'MessageService',
        'Recall',
        'Revoke',
        'GuildNTKernel',
        'AIOPhotoBrowser',
    ];

    const found = [];
    for (const name in ObjC.classes) {
        for (const t of targets) {
            if (name.includes(t)) {
                try {
                    const cls = ObjC.classes[name];
                    const methods = cls.$methods.filter(m =>
                        m.toLowerCase().includes('recall') ||
                        m.toLowerCase().includes('revoke')
                    );
                    if (methods.length > 0) {
                        found.push({ name, methods });
                        console.log(`\n  🎯 ${name}:`);
                        for (const m of methods) {
                            console.log(`     └─ ${m}`);
                        }
                        break;
                    }
                } catch (e) {}
            }
        }
    }

    log(`Swift 模块中找到 ${found.length} 个 recall 相关类`);
    return found;
}

// ═══════════════════════════════════════════════
// 3. Hook 所有真实存在的 recall 方法
// ═══════════════════════════════════════════════
function hookExistingRecallMethods() {
    sep('3. Hook 真实存在的 recall 方法');

    const hooked = [];
    const hookClass = (clsName, selName) => {
        try {
            const cls = ObjC.classes[clsName];
            if (!cls) { log(`❌ 类不存在: ${clsName}`); return false; }

            const methods = cls.$methods;
            if (!methods.includes(selName)) {
                log(`⚠️  方法不可用: ${clsName} -[${selName}]`);
                return false;
            }

            const methodImpl = cls[selName];
            if (!methodImpl) { log(`⚠️  方法不可 hook: ${clsName} -[${selName}]`); return false; }

            // 检查是否已经 hook 过
            if (methodImpl.implementation !== methodImpl) {
                // 不是我们 hook 过的就是原始的
            }

            const original = methodImpl.implementation;
            methodImpl.implementation = function () {
                const args = Array.from(arguments);
                log(`🔧 ${clsName} -[${selName}]`);

                for (let i = 0; i < args.length; i++) {
                    try {
                        const arg = args[i];
                        if (arg === null) log(`   arg[${i}]: null`);
                        else if (arg === undefined) log(`   arg[${i}]: undefined`);
                        else if (arg.$className) {
                            const desc = arg.toString ? arg.toString().substring(0, 150) : '';
                            log(`   arg[${i}]: [${arg.$className}] ${desc}`);
                            // 如果是 NSString，打印内容
                            if (arg.$className === '__NSCFString' || arg.$className === 'NSTaggedPointerString' || arg.$className === 'NSString') {
                                log(`   -> 内容: "${arg}"`);
                            }
                        } else if (typeof arg === 'number' || typeof arg === 'boolean') {
                            log(`   arg[${i}]: ${arg} (${typeof arg})`);
                        } else {
                            log(`   arg[${i}]: ${arg}`);
                        }
                    } catch (e) {
                        log(`   arg[${i}]: (error: ${e})`);
                    }
                }

                log(`   🥞 调用栈:\n    ${getStack()}`);
                return original.apply(this, args);
            };

            hooked.push(`${clsName} -[${selName}]`);
            log(`✅ Hook 成功`);
            return true;
        } catch (e) {
            log(`❌ Hook 异常: ${clsName} -[${selName}]: ${e}`);
            return false;
        }
    };

    // 基于枚举结果的精准 hook 列表
    const hookTargets = [
        // --- 消息撤回核心路径 ---
        ['QQMessageRecallPackageHandler', '+ parseC2CRecallInOut:'],
        ['QQMessageRecallPackageHandler', '+ parseC2CRecallNotify:bufferLen:subcmd:model:'],
        ['QQMessageRecallModule', '- convertRecallItemToMsg:recallModel:msgType:bindUin:'],
        ['QQMessageRecallModule', '- handleSideAccountRecallNotify:bufferLen:subcmd:bindUin:tracelessFlag:'],
        ['QQMessageRecallModule', '- getRecallMessageContent:bindUin:'],
        ['QQMessageRecallNetEngine', '- parseC2CRecallNotify:bufferLen:subcmd:model:'],

        // --- Recall 信息模型 ---
        ['OCMsgRecallInfo', '- isRecallNotify'],
        ['OCMsgRecallInfo', '- setIsRecallNotify:'],
        ['OCMsgRecallInfo', '- isTracelessRecall'],
        ['OCMsgRecallInfo', '- setIsTracelessRecall:'],

        // --- 新版 Swift recall 服务 (NT) ---
        ['NTAIOMenuRecallService', '+ recallCompleteWithCell:observer:code:msg:'],
        ['NTAIOMenuRecallService', '+ recallCompleteWithCellViewModel:observer:code:msg:'],
        ['NTAIOMenuRecallService', '+ recallGrayTipsMsgWithCellView:observer:'],
        ['NTAIOChatRecallService', '+ getNTUnlimitedRecallAbilityInfo'],
        ['NTAIOChatRecallService', '+ isSettedRecallCustomWording'],
        ['NTAIOChatRecallService', '+ getRecallCustomGuideTipsShowCount'],

        // --- 灰条处理 ---
        ['NTAIOGrayTipsOtherLinkRecallHandle', '- grayTipsEventWithModel:curVC:contact:busiId:'],

        // --- Recall Pair 模型 ---
        ['RecallPair', '- recallModel'],
        ['RecallPair', '- setRecallModel:'],
        ['RecallPairForOffline', '- recallModel'],
        ['RecallPairForOffline', '- setRecallModel:'],

        // --- Recall 通知 AIO 模型 ---
        ['RecallNotiAIOModel', '- recallModel'],
        ['RecallNotiAIOMsg', '- recallModel'],
        ['RecallNotiAIONickModel', '- recallModel'],

        // --- FA (文件助手) recall ---
        ['FARecallMgr', '- recallFAModel:'],
        ['FARecallMgr', '- onFARecallResult:error:'],
        ['FARecallMgr', '- onRecvMsgRecallResult:'],

        // --- 撤回菜单 ---
        ['QQRecallMenuFilter', '+ isGroupMessageNeedShowMenuRecall:'],
        ['QQRecallMenuFilter', '+ needShowRecallBaseImpl:'],

        // --- 黑名单撤回面板 ---
        ['QQGProBlackListRevokePanelView', '- isRevokeMsgAllowed'],
        ['QQGProBlackListRevokePanelView', '- setIsRevokeMsgAllowed:'],

        // --- 撤回元素 ---
        ['OCRevokeElement', '+ RevokeElement'],

        // --- Recall 自定义文案 ---
        ['MsgRecallCustomWordingRequestItem', '- recallModel'],

        // --- NT recall 视图模型 ---
        ['NTAIOCellViewModelRecaller', '- recallModel'],
        ['NTAIOMenuRecallViewModel', '- recallModel'],
        ['RecallMenuItem', '- recallModel'],
        ['AdminRecallMenuItem', '- recallModel'],

        // --- 撤回灰条模型 ---
        ['NTAIOChatRevokeGrayTipsModel', '- recallModel'],
        ['NTAIORevokeGrayTipsModel', '- recallModel'],

        // --- Rich revoke tips ---
        ['NTAIORichRevokeTipsElement', '- recallModel'],

        // --- Topic/Guild recall ---
        ['OCTopicRecallReq', '- recallId'],
        ['OCTopicRecallReq', '- setRecallId:'],
        ['OCTopicRecallResult', '- recallId'],
        ['OCTopicRecallResult', '- setRecallId:'],
        ['OCTopicRecallRsp', '- recallId'],
        ['OCTopicRecallRsp', '- setRecallId:'],

        // --- 其他可能相关的 Swift 桥接类 (通过 mangled name) ---
        ['_TtCC9NTBaseAIO24NTAIOMenuRecallViewModel19RecallAlertDelegate', '- recallModel'],
    ];

    // 同时 hook 所有含 recall/revoke 的协议方法
    for (const name in ObjC.protocols) {
        const lower = name.toLowerCase();
        if (!(lower.includes('recall') || lower.includes('revoke'))) continue;
        try {
            const proto = ObjC.protocols[name];
            console.log(`\n  📜 Protocol: ${name}`);
            const methodList = proto.$methods;
            for (const m of methodList) {
                if (m.toLowerCase().includes('recall') || m.toLowerCase().includes('revoke')) {
                    console.log(`     └─ ${m}`);
                }
            }
        } catch (e) {}
    }

    log(`\n尝试 Hook ${hookTargets.length} 个目标...`);
    for (const [clsName, selName] of hookTargets) {
        hookClass(clsName, selName);
    }

    log(`\n📊 Hook 完成`);
}

// ═══════════════════════════════════════════════
// 4. 追踪撤回消息的网络层 (Protobuf)
// ═══════════════════════════════════════════════
function hookProtobufRecall() {
    sep('4. 追踪 Protobuf 解析层');

    // 从枚举中找到的 protobuf recall 相关类
    const pbTargets = [
        'Oidb_0xf26RevokeItem',
        'TNF_StGetQQRecallCardReq',
        'TNF_StGetQQRecallCardRsp',
        'TNF_StQQRecallCard',
    ];

    for (const name of pbTargets) {
        const cls = ObjC.classes[name];
        if (!cls) continue;

        console.log(`\n  📦 ${name}:`);
        try {
            const methods = cls.$methods;
            for (const m of methods) {
                console.log(`     └─ ${m}`);
                // 尝试 hook init 和 parse 方法
                if (m.includes('init') || m.includes('data') || m.includes('parse')) {
                    const sel = cls[m];
                    if (sel && sel.implementation) {
                        const orig = sel.implementation;
                        sel.implementation = function () {
                            log(`🔧 [PB] ${name} -[${m}]`);
                            if (m.includes('initWithData')) {
                                const data = arguments[0];
                                if (data && data.bytes) {
                                    try {
                                        const bytes = data.bytes();
                                        const len = data.length();
                                        log(`   📦 数据长度: ${len} 字节`);
                                        if (len > 0 && len <= 64) {
                                            log(`   原始: ${hexdump(bytes, { length: len, ansi: true })}`);
                                        }
                                    } catch (e) {}
                                }
                            }
                            log(`   🥞 调用栈:\n    ${getStack()}`);
                            return orig.apply(this, arguments);
                        };
                        log(`   ✅ Hook 成功`);
                    }
                }
            }
        } catch (e) {
            log(`   ❌ 错误: ${e}`);
        }
    }
}

// ═══════════════════════════════════════════════
// 5. 追踪撤回 NSNotification 的替代方案
//    直接枚举并 hook 通知中心的替代方法
// ═══════════════════════════════════════════════
function hookNotificationDelivery() {
    sep('5. 追踪通知投递');

    // NSNotificationCenter 的方法通常是继承的，但我们可以通过类别 hook
    // 枚举 NSNotificationCenter 上的所有方法
    const nc = ObjC.classes.NSNotificationCenter;
    if (nc) {
        console.log('\n  NSNotificationCenter 所有方法:');
        for (const m of nc.$methods) {
            console.log(`     └─ ${m}`);
        }

        // Hook postNotificationName:object:userInfo: (存在于父类)
        // 使用更直接的方式
        const selName = 'postNotificationName:object:userInfo:';
        try {
            const method = nc[selName];
            if (method) {
                const orig = method.implementation;
                method.implementation = function () {
                    const name = arguments[0];
                    const lower = name && name.toString
                        ? name.toString().toLowerCase()
                        : '';
                    if (lower.includes('recall') || lower.includes('revoke')) {
                        log(`📨 NSNotification: ${name}`);
                        log(`   🥞 发送栈:\n    ${getStack()}`);
                    }
                    return orig.apply(this, arguments);
                };
                log('✅ Hook postNotificationName:object:userInfo: 成功');
            } else {
                log('⚠️  postNotificationName:object:userInfo: 不可用');
            }
        } catch (e) {
            log(`❌ 通知 hook 失败: ${e}`);
        }
    }
}

// ═══════════════════════════════════════════════
// 6. 追踪 MsgRecallMgr / KernelMsgService C++ 符号
//    使用更广泛的符号匹配
// ═══════════════════════════════════════════════
function hookCppSymbols() {
    sep('6. 搜索 C++ recall 符号');

    // 枚举所有模块的所有符号
    const modules = Process.enumerateModules();
    const qqModule = modules.find(m =>
        m.path.includes('QQ.app/QQ') || m.path.endsWith('/QQ')
    );

    if (!qqModule) {
        log('❌ 找不到 QQ 主模块');
        return;
    }

    log(`扫描 ${qqModule.path} 中的 C++ 符号...`);
    let foundCount = 0;

    try {
        const symbols = Module.enumerateSymbols(qqModule.path);
        for (const sym of symbols) {
            const name = sym.name.toLowerCase();
            if ((name.includes('recall') || name.includes('revoke')) &&
                (name.includes('msg') || name.includes('kernel') || name.includes('service'))) {
                foundCount++;
                console.log(`  🔧 ${sym.name}`);
                console.log(`     地址: ${sym.address}, 类型: ${sym.type}`);

                // Hook 这个符号
                try {
                    Interceptor.attach(sym.address, {
                        onEnter(args) {
                            log(`🔧 [C++] ${sym.name} 被调用`);
                            log(`   🥞 调用栈:\n    ${getStack()}`);
                        },
                        onRetVal(retval) {
                            log(`   ↩️  返回值: ${retval}`);
                        }
                    });
                    console.log(`     ✅ Hook 成功`);
                } catch (e) {
                    console.log(`     ⚠️  Hook 失败: ${e}`);
                }
            }
        }
    } catch (e) {
        log(`符号枚举失败: ${e}`);
    }

    log(`共找到 ${foundCount} 个相关 C++ 符号`);
}

// ═══════════════════════════════════════════════
// 7. 扫描二进制中的 recall 相关字符串 (改进版)
// ═══════════════════════════════════════════════
function scanStrings() {
    sep('7. 扫描 recall 字符串 (改进版)');

    const module = Process.enumerateModules().find(m =>
        m.path.includes('QQ.app/QQ') || m.path.endsWith('/QQ')
    );
    if (!module) { log('❌ 找不到 QQ 模块'); return; }

    try {
        const ranges = module.enumerateRanges('--');
        let total = 0;

        for (const range of ranges) {
            if ((range.protection & 4) === 0) continue; // 跳过不可读
            try {
                const data = range.base.readByteArray(Math.min(range.size, 1024 * 1024 * 50)); // 最多 50MB
                if (!data) continue;

                const buf = Buffer.from(data);
                let offset = 0;
                while (offset < buf.length) {
                    // 查找 ASCII 字符串
                    if (buf[offset] >= 0x20 && buf[offset] < 0x7F) {
                        let start = offset;
                        while (offset < buf.length && buf[offset] >= 0x20 && buf[offset] < 0x7F) offset++;
                        const len = offset - start;
                        if (len >= 5 && len <= 80) {
                            const str = buf.slice(start, offset).toString('ascii');
                            const lower = str.toLowerCase();
                            if ((lower.includes('recall') || lower.includes('revoke')) &&
                                !lower.startsWith('_') && !lower.startsWith('-')) {
                                console.log(`  🔤 [${range.base.add(start)}] "${str}"`);
                                total++;
                            }
                        }
                    } else {
                        offset++;
                    }
                }
            } catch (e) { /* 跳过不可读段 */ }
        }
        log(`共找到 ${total} 个 recall/revoke 字符串`);
    } catch (e) { log(`扫描失败: ${e}`); }
}

// ═══════════════════════════════════════════════
// 8. 探索撤回的实际数据流
//    通过观察消息删除/隐藏操作
// ═══════════════════════════════════════════════
function exploreMsgDeletion() {
    sep('8. 探索消息删除/隐藏操作');

    // 撤回的本质是删除/隐藏消息，所以 hook 消息删除相关方法
    const deleteTargets = [
        'QQMessage',
        'QQMsg',
        'MsgCache',
        'MsgStorage',
        'NTAIOChat',
        'NTMessage',
        'ChatMsg',
        'AIOChat',
    ];

    for (const name in ObjC.classes) {
        for (const t of deleteTargets) {
            if (name.includes(t)) {
                try {
                    const cls = ObjC.classes[name];
                    const methods = cls.$methods.filter(m =>
                        m.toLowerCase().includes('delete') ||
                        m.toLowerCase().includes('remove') ||
                        m.toLowerCase().includes('hide') ||
                        m.toLowerCase().includes('revoke') ||
                        m.toLowerCase().includes('recall') ||
                        m.toLowerCase().includes('erase')
                    );
                    if (methods.length > 0) {
                        console.log(`\n  📦 ${name}:`);
                        for (const m of methods) {
                            console.log(`     └─ ${m}`);
                        }
                        break;
                    }
                } catch (e) {}
            }
        }
    }
}

// ═══════════════════════════════════════════════
// 启动 (延迟执行让 QQ 先初始化)
// ═══════════════════════════════════════════════
setTimeout(() => {
    try {
        sep('QQESign Frida 防撤回探索 v2');
        log(`设备: ${Process.arch} | PID: ${Process.id}`);

        // 先枚举所有 recall 类
        const classes = enumerateAllRecallMethods();
        const swiftClasses = exploreSwiftRecall();
        exploreMsgDeletion();

        // 然后等一会儿再 Hook（让所有 ObjC 类加载完成）
        setTimeout(() => {
            hookExistingRecallMethods();
            hookProtobufRecall();
            hookNotificationDelivery();
            hookCppSymbols();
            scanStrings();

            sep('探索就绪');
            log('现在去 QQ 中发起一次消息撤回，观察输出！');
            log('按 Ctrl+C 停止');
        }, 5000);
    } catch (e) {
        log(`❌ 初始化错误: ${e}`);
        console.error(e.stack);
    }
}, 3000);
