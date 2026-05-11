/*
 * QQESign — Frida 防撤回探索 v3 (精准版)
 *
 * 基于 v1/v2 枚举成果，仅 Hook 真实存在且最关键的方法
 *
 * 发现的真实 recall 路径候选:
 *   核心: NTKernelAdapter.MessageService.recallMsgWithPeer:msgIds:cb:
 *   ObjC: QQMessageRecallPackageHandler, QQMessageRecallNetEngine, QQMessageRecallModule
 *
 * 用法:
 *   先关闭 QQ 再运行:
 *   frida -U -f com.tencent.mqq -l frida_explore_v3.js
 */

function log(msg) { console.log(`[QQESign-v3] ${msg}`); }
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

function getClassName(obj) {
    try { return obj.$className; } catch (e) { return '?'; }
}

function describeArg(arg, maxLen) {
    maxLen = maxLen || 120;
    if (arg === null) return 'null';
    if (arg === undefined) return 'undefined';
    try {
        if (arg.$className) {
            let desc = '';
            try { desc = arg.toString(); } catch (e) {}
            if (desc && desc.length > maxLen) desc = desc.substring(0, maxLen) + '...';
            return `[${arg.$className}] ${desc}`;
        }
        if (typeof arg === 'object') return `[Object ${Object.keys(arg).length} keys]`;
        return String(arg).substring(0, maxLen);
    } catch (e) {
        return `(error: ${e})`;
    }
}

// ─────────────────────────────────────────────
// 核心 Hook 函数
// ─────────────────────────────────────────────
let hookCount = 0;

function hookSelector(clsName, selName, desc) {
    try {
        const cls = ObjC.classes[clsName];
        if (!cls) { log(`[✗] 类不存在: ${clsName}`); return false; }

        // 检查方法是否存在（支持 + 和 - 前缀）
        const isClassMethod = selName.startsWith('+ ');
        const cleanSel = selName.replace(/^[+-] /, '');
        const methods = cls.$methods;
        const fullSel = (isClassMethod ? '+ ' : '- ') + cleanSel;

        if (!methods.includes(cleanSel) && !methods.includes(fullSel)) {
            log(`[✗] 方法不存在: ${clsName} ${fullSel}`);
            return false;
        }

        // 获取方法实现
        const methodImpl = isClassMethod ? cls.$class[cleanSel] : cls[cleanSel];
        if (!methodImpl) {
            log(`[✗] 无法获取方法: ${clsName} ${fullSel}`);
            return false;
        }

        const orig = methodImpl.implementation;
        const tag = desc || fullSel;

        methodImpl.implementation = function () {
            const args = Array.from(arguments);
            log(`🔧 ${tag}`);
            for (let i = 0; i < args.length; i++) {
                log(`   a[${i}]: ${describeArg(args[i])}`);
            }
            log(`   🥞 栈:\n    ${getStack()}`);
            return orig.apply(this, args);
        };

        hookCount++;
        log(`[✓] ${tag}`);
        return true;
    } catch (e) {
        log(`[✗] Hook 异常: ${clsName} ${selName}: ${e.message}`);
        return false;
    }
}

function hookSwiftSelector(clsName, selName, desc) {
    // Swift 类可能需要通过完整 mangled name 查找
    // 先尝试直接找，再尝试通过模块名查找
    return hookSelector(clsName, selName, desc);
}

// ─────────────────────────────────────────────
// Hook NSNotificationCenter 的 post 方法
// ─────────────────────────────────────────────
function hookNotifications() {
    log('正在 Hook NSNotificationCenter...');
    try {
        const nc = ObjC.classes.NSNotificationCenter;
        // 使用更底层的方式: 直接 hook 实例方法
        const sel = ObjC.selector('postNotificationName:object:userInfo:');
        const method = class_getInstanceMethod(nc, sel);
        if (method) {
            const orig = method_getImplementation(method);
            method_setImplementation(method, new NativeCallback(function (self, _cmd, name, obj, userInfo) {
                const n = new ObjC.Object(name);
                const str = n.toString();
                if (str.toLowerCase().includes('recall') || str.toLowerCase().includes('revoke')) {
                    log(`📨 通知: ${str}`);
                    log(`   🥞 栈:\n    ${getStack()}`);
                }
                const origFn = new NativeFunction(orig, 'void', ['pointer', 'pointer', 'pointer', 'pointer', 'pointer']);
                origFn(self, _cmd, name, obj, userInfo);
            }, 'void', ['pointer', 'pointer', 'pointer', 'pointer', 'pointer']));
            log('[✓] NSNotificationCenter postNotificationName:object:userInfo:');
        } else {
            log('[✗] NSNotificationCenter 方法不可用');
        }
    } catch (e) {
        log(`[✗] 通知 Hook 失败: ${e.message}`);
    }
}

// ─────────────────────────────────────────────
// Hook C++ 符号 (通过 Module.findExportByName)
// ─────────────────────────────────────────────
function hookCppSymbols() {
    log('正在搜索 C++ recall 符号...');
    const symbols = [
        '_ZN2nt7wrapper16KernelMsgService24recallMsgFromC2CAndGroupEPNS_13MsgRecallItemEiiPS2_',
        '_ZN2nt7wrapper16KernelMsgService20getRecallMsgsByMsgIdESt6vectorINS0_10MsgKeyTypeESaIS4_EENSt3__18functionIFvNS_13MsgRecallItemEiEEE',
        '_ZN12MsgRecallMgr8RecallMsgERKSt10shared_ptrIN2nt7wrapper15MsgRecallItemEE',
        // Alternative mangling
        '__ZN2nt7wrapper16KernelMsgService24recallMsgFromC2CAndGroupEPNS_13MsgRecallItemEiiPS2_',
        '__ZN2nt7wrapper16KernelMsgService20getRecallMsgsByMsgIdERKNSt3__16vectorINS0_10MsgKeyTypeENS1_9allocatorIS4_EEEEPFS6_NS1_8functionIFvNS_13MsgRecallItemEiEEEEE',
        '__ZN12MsgRecallMgr8RecallMsgERKNSt3__110shared_ptrIN2nt7wrapper15MsgRecallItemEEE',
    ];

    let found = 0;
    for (const sym of symbols) {
        try {
            const addr = Module.findExportByName(null, sym);
            if (addr) {
                log(`[✓] C++ 符号: ${sym} @ ${addr}`);
                Interceptor.attach(addr, {
                    onEnter(args) {
                        log(`🔧 [C++] ${sym}`);
                        log(`   🥞 栈:\n    ${getStack()}`);
                        for (let i = 0; i < Math.min(args.length, 8); i++) {
                            log(`   x${i}: ${args[i]}`);
                        }
                    },
                    onRetVal(retval) { log(`   ↩ ${retval}`); }
                });
                found++;
            }
        } catch (e) { /* ignore */ }
    }
    if (found === 0) log('[i] 未找到 C++ 符号 (纯 Swift 实现?)');
    else log(`[i] 共 Hook ${found} 个 C++ 符号`);
}

// ─────────────────────────────────────────────
// 拦截 ObjC 消息发送 (低层, 无侵入全局追踪)
// ─────────────────────────────────────────────
function traceObjCMsgSend() {
    sep('额外: 追踪 recall 相关的 ObjC msgSend');

    // 使用 Stalker 或 ObjC 方法 swizzling 来追踪
    // 这里用更简单的方式: 定期检查
    log('设置 ObjC 消息跟踪器...');

    try {
        // 拦截 objc_msgSend 中带 recall/revoke 的调用
        const msgSend = Module.findExportByName(null, 'objc_msgSend');
        if (msgSend) {
            log(`[i] objc_msgSend @ ${msgSend}`);
            // 注意: 不直接 hook objc_msgSend，那太重量级了
        }
    } catch (e) {
        log(`[✗] msgSend 追踪失败: ${e.message}`);
    }
}

// ─────────────────────────────────────────────
// 主函数
// ─────────────────────────────────────────────
function main() {
    sep('QQESign Frida 防撤回探索 v3');
    log(`PID: ${Process.id} | Arch: ${Process.arch}`);

    // 等待 ObjC 运行时完全加载
    ObjC.schedule(ObjC.mainQueue, () => {
        sep('开始 Hook...');

        // === 1. 核心 Swift NT 层 (新发现的) ===
        log('\n--- 核心 NTKernelAdapter.MessageService ---');
        hookSwiftSelector('NTKernelAdapter.MessageService',
            '- recallMsgWithPeer:msgIds:cb:', '📥 MessageService.recallMsgWithPeer');
        hookSwiftSelector('NTKernelAdapter.MessageService',
            '- reeditRecallMsgWithPeer:msgId:cb:', '📥 MessageService.reeditRecallMsg');
        hookSwiftSelector('NTKernelAdapter.MessageService',
            '- getRecallMsgsWithPeer:msgIds:cb:', '📥 MessageService.getRecallMsgs');

        // === 2. Swift AIO 层 (新发现的) ===
        log('\n--- NTAIOChat 层 ---');
        hookSwiftSelector('NTAIOChat.NTStreamMsgAIOHandler',
            '- receiveRecallNotification:', '📥 NTStreamMsgAIOHandler.receiveRecall');
        hookSwiftSelector('NTAIOChat.NTAIOFloatEarPart',
            '- recallMessageWithNotification:', '📥 FloatEarPart.recallMessage');
        hookSwiftSelector('NTAIOChat.NTAIOFloatEarManager',
            '- onRecvRecallMsg:', '📥 FloatEarManager.onRecvRecall');
        hookSwiftSelector('NTAIOChat.NTAIOEGPetHandlerBuilder',
            '- receiveRecallNotification:', '📥 EGPetHandler.receiveRecall');
        hookSwiftSelector('NTAIOChat.NTAIOReplyMsgHandlerBuilder',
            '- receiveRecallNotificationAt:', '📥 ReplyMsgHandler.receiveRecallAt');
        hookSwiftSelector('NTAIOChat.NTAIOMultiSelectToHereHandlerBuilder',
            '- onReceiveRecallMsgNotification:', '📥 MultiSelectHandler.onReceiveRecall');

        // === 3. ZTP 服务 ===
        log('\n--- ZTP / Guild 层 ---');
        hookSwiftSelector('ZTPSquareAIOMessageService',
            '- onMsgRecall:peerUid:seq:', '📥 ZTPSquare.onMsgRecall');

        // === 4. ObjC 传统层 (已验证存在) ===
        log('\n--- ObjC 传统层 ---');
        hookSelector('QQMessageRecallPackageHandler',
            '+ parseC2CRecallNotify:bufferLen:subcmd:model:', '📦 PackageHandler.parseC2C');
        hookSelector('QQMessageRecallPackageHandler',
            '+ parseC2CRecallInOut:', '📦 PackageHandler.parseInOut');
        hookSelector('QQMessageRecallNetEngine',
            '- parseC2CRecallNotify:bufferLen:subcmd:model:', '📦 NetEngine.parseC2C');
        hookSelector('QQMessageRecallModule',
            '- handleSideAccountRecallNotify:bufferLen:subcmd:bindUin:tracelessFlag:', '📦 RecallModule.sideAccount');
        hookSelector('QQMessageRecallModule',
            '- convertRecallItemToMsg:recallModel:msgType:bindUin:', '📦 RecallModule.convert');
        hookSelector('QQMessageRecallModule',
            '- getRecallMessageContent:bindUin:', '📦 RecallModule.getContent');

        // === 5. OCMsgRecallInfo (撤回信息模型) ===
        log('\n--- OCMsgRecallInfo ---');
        hookSelector('OCMsgRecallInfo', '- isRecallNotify', '📋 isRecallNotify');
        hookSelector('OCMsgRecallInfo', '- setIsRecallNotify:', '📋 setIsRecallNotify');
        hookSelector('OCMsgRecallInfo', '- isTracelessRecall', '📋 isTracelessRecall');
        hookSelector('OCMsgRecallInfo', '- setIsTracelessRecall:', '📋 setIsTracelessRecall');

        // === 6. NTAIOMenuRecallService ===
        log('\n--- NTAIOMenuRecallService ---');
        hookSelector('NTAIOChat.NTAIOMenuRecallService',
            '+ recallCompleteWithCell:observer:code:msg:', '📋 MenuRecallService.complete');
        hookSelector('NTAIOChat.NTAIOMenuRecallService',
            '+ recallGrayTipsMsgWithCellView:observer:', '📋 MenuRecallService.grayTips');

        // === 7. NTAIOChatRecallService ===
        log('\n--- NTAIOChatRecallService ---');
        hookSelector('NTAIOChatRecallService',
            '+ getNTUnlimitedRecallAbilityInfo', '📋 RecallService.unlimitedInfo');
        hookSelector('NTAIOChatRecallService',
            '+ isSettedRecallCustomWording', '📋 RecallService.isCustomWording');

        // === 8. RecallPair / RecallNoti 模型 ===
        log('\n--- RecallPair / RecallNoti ---');
        hookSelector('RecallPair', '- setRecallModel:', '📋 RecallPair.setRecallModel');
        hookSelector('RecallPairForOffline', '- setRecallModel:', '📋 RecallPairForOffline.setRecallModel');

        // === 9. 通知 Hook ===
        log('\n--- 通知系统 ---');
        hookNotifications();

        // === 10. C++ 符号 ===
        log('\n--- C++ 符号 ---');
        hookCppSymbols();

        // === 11. FARecallMgr ===
        log('\n--- FARecallMgr ---');
        hookSelector('FARecallMgr', '- recallFAModel:', '📋 FARecallMgr.recallFA');
        hookSelector('FARecallMgr', '- onFARecallResult:error:', '📋 FARecallMgr.onResult');
        hookSelector('FARecallMgr', '- onRecvMsgRecallResult:', '📋 FARecallMgr.onRecvResult');

        sep('探索就绪');
        log(`共 Hook ${hookCount} 个方法`);
        log('现在去 QQ 让朋友撤回一条消息，观察输出！');
    });
}

setTimeout(main, 2000);
