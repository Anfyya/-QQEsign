/*
 * QQESign — Frida 防撤回拦截验证脚本
 * 
 * 精简可靠版 — 使用 ObjC.schedule 确保运行时就绪
 * 
 * 用法:
 *   frida -U -f com.tencent.mqq -l frida_antirevoke_test.js
 *   或附加到已有进程:
 *   frida -U -n QQ -l frida_antirevoke_test.js
 */

function log(msg) { console.log(`[防撤回测试] ${msg}`); }

function getStack(depth) {
    try {
        return Thread.backtrace(this.context, Backtracer.ACCURATE)
            .map(DebugSymbol.fromAddress)
            .slice(0, depth || 30)
            .join('\n    ');
    } catch (e) { return '(no stack)'; }
}

// ─────────────────────────────────────────────
// Hook 实例方法 (使用正确的 Frida ObjC API)
// ─────────────────────────────────────────────
function hookInstance(className, selector, label) {
    label = label || `${className} -[${selector}]`;
    try {
        const cls = ObjC.classes[className];
        if (!cls) { log(`❌ [${label}] 类不存在`); return false; }

        const method = cls[selector];
        if (!method) {
            log(`❌ [${label}] 方法对象不可访问`);
            return false;
        }

        const origImpl = method.implementation;
        if (!origImpl) {
            log(`❌ [${label}] 无法获取原始实现`);
            return false;
        }

        method.implementation = function () {
            const args = [];
            for (let i = 0; i < arguments.length; i++) args.push(arguments[i]);
            
            log(`🚫 拦截 [${label}]`);
            
            // 打印调用栈
            log(`    调用栈:\n    ${getStack()}`);
            
            // 打印参数
            for (let i = 0; i < args.length; i++) {
                try {
                    const a = args[i];
                    if (a === null) log(`    arg[${i}] = null`);
                    else if (a === undefined) log(`    arg[${i}] = undefined`);
                    else if (a.$className) {
                        let desc = '';
                        try { desc = a.toString().substring(0, 200); } catch(e) {}
                        log(`    arg[${i}] = [${a.$className}] ${desc}`);
                    } else log(`    arg[${i}] = ${a}`);
                } catch(e) { log(`    arg[${i}] = (error: ${e})`); }
            }
            
            // ★ 关键：直接返回，不调用原始方法 = 阻止撤回！
            return undefined;
        };

        log(`✅ 成功拦截 [${label}] — 准备就绪`);
        return true;
    } catch (e) {
        log(`❌ [${label}] Hook 异常: ${e.message}`);
        return false;
    }
}

// ─────────────────────────────────────────────
// Hook 类方法 (元类)
// ─────────────────────────────────────────────
function hookClass(className, selector, label) {
    label = label || `${className} +[${selector}]`;
    try {
        const cls = ObjC.classes[className];
        if (!cls) { log(`❌ [${label}] 类不存在`); return false; }

        const metaCls = cls.$class;
        const method = metaCls[selector];
        if (!method) {
            log(`❌ [${label}] 类方法对象不可访问`);
            return false;
        }

        const origImpl = method.implementation;
        if (!origImpl) {
            log(`❌ [${label}] 无法获取原始实现`);
            return false;
        }

        method.implementation = function () {
            log(`🚫 拦截 [${label}]`);
            log(`    调用栈:\n    ${getStack()}`);
            
            for (let i = 0; i < arguments.length; i++) {
                try {
                    const a = arguments[i];
                    if (a === null) log(`    arg[${i}] = null`);
                    else if (a === undefined) log(`    arg[${i}] = undefined`);
                    else if (a.$className) {
                        let desc = '';
                        try { desc = a.toString().substring(0, 200); } catch(e) {}
                        log(`    arg[${i}] = [${a.$className}] ${desc}`);
                    } else log(`    arg[${i}] = ${a}`);
                } catch(e) {}
            }
            
            return undefined; // 阻止撤回
        };

        log(`✅ 成功拦截 [${label}]`);
        return true;
    } catch (e) {
        log(`❌ [${label}] Hook 异常: ${e.message}`);
        return false;
    }
}

// ─────────────────────────────────────────────
// Hook NSNotificationCenter
// ─────────────────────────────────────────────
function hookNotificationCenter() {
    try {
        const nc = ObjC.classes.NSNotificationCenter;
        // postNotificationName:object:userInfo: 是 NSNotificationCenter 的方法
        const sel = 'postNotificationName:object:userInfo:';
        const method = nc[sel];
        if (method && method.implementation) {
            const orig = method.implementation;
            method.implementation = function () {
                const args = arguments;
                let name = '';
                try {
                    if (args[0] && args[0].toString) name = args[0].toString();
                } catch(e) {}
                
                const lower = name.toLowerCase();
                if (lower.includes('recall') || lower.includes('revoke') || lower.includes('撤回')) {
                    log(`📨 拦截撤回通知: ${name}`);
                    log(`    调用栈:\n    ${getStack()}`);
                    // ★ 不拦截通知，只观察
                }
                return orig.apply(this, args);
            };
            log(`✅ 通知监控就绪`);
        } else {
            log(`❌ NSNotificationCenter 方法不可用`);
        }
    } catch (e) {
        log(`❌ 通知 Hook 失败: ${e.message}`);
    }
}

// ─────────────────────────────────────────────
// 诊断: 打印类和方法信息
// ─────────────────────────────────────────────
function diagClass(className) {
    try {
        const cls = ObjC.classes[className];
        if (!cls) { log(`📋 [${className}] 类不存在`); return; }
        
        const methods = cls.$methods || [];
        const recallMethods = methods.filter(m => 
            m.toLowerCase().includes('recall') || m.toLowerCase().includes('revoke')
        );
        
        log(`📋 [${className}] 共 ${methods.length} 方法, ${recallMethods.length} 个 recall 相关`);
        
        // 尝试访问第一个 recall 方法看是否可访问
        if (recallMethods.length > 0) {
            const m = recallMethods[0];
            const cleanM = m.replace(/^[+-]\s*/, '');
            try {
                const test = cls[cleanM];
                log(`   方法 "${cleanM}" 可访问: ${test ? '✅' : '❌'}`);
            } catch(e) {
                log(`   方法 "${cleanM}" 访问异常: ${e.message}`);
            }
        }
    } catch (e) {
        log(`📋 [${className}] 诊断异常: ${e.message}`);
    }
}

// ─────────────────────────────────────────────
// 主入口
// ─────────────────────────────────────────────
log('========================================');
log('QQESign Frida 防撤回拦截验证脚本 v1.0');
log(`PID: ${Process.id}`);
log('========================================');

// 先诊断，确认方法可访问
setTimeout(() => {
    log('\n--- 诊断关键类 ---');
    diagClass('QQMessageRecallModule');
    diagClass('QQMessageRecallNetEngine');
    diagClass('OCMsgRecallInfo');
    diagClass('RecallPair');
    diagClass('QQMessageRecallPackageHandler');
    diagClass('OCRevokeElement');
    diagClass('QQRecallMenuFilter');
    diagClass('FARecallMgr');
    
    // 诊断 Swift 桥接类
    diagClass('NTAIOChat.NTStreamMsgAIOHandler');
    diagClass('NTKernelAdapter.MessageService');
    diagClass('NTAIOChat.NTAIOFloatEarManager');
    diagClass('NTAIOChatRecallService');
    diagClass('NTAIOChat.NTAIOMenuRecallService');
    diagClass('ZTPSquareAIOMessageService');
}, 3000);

// 等待 QQ 完全启动后安装 Hook
setTimeout(() => {
    log('\n========================================');
    log('开始安装防撤回拦截...');
    log('========================================\n');

    // === 等级1: 核心 Swift 撤回入口 ===
    log('--- ★ 1. 核心撤回入口 (最高优先级) ---');
    hookInstance('NTKernelAdapter.MessageService', 'recallMsgWithPeer:msgIds:cb:', 
        'MessageService.recallMsgWithPeer');
    hookInstance('NTKernelAdapter.MessageService', 'reeditRecallMsgWithPeer:msgId:cb:', 
        'MessageService.reeditRecallMsg');
    hookInstance('NTKernelAdapter.MessageService', 'getRecallMsgsWithPeer:msgIds:cb:', 
        'MessageService.getRecallMsgs');

    // === 等级2: AIO 通知接收 ===
    log('\n--- ★ 2. AIO 撤回通知接收 ---');
    hookInstance('NTAIOChat.NTStreamMsgAIOHandler', 'receiveRecallNotification:', 
        'StreamMsgHandler.receiveRecall');
    hookInstance('NTAIOChat.NTAIOFloatEarManager', 'onRecvRecallMsg:', 
        'FloatEarManager.onRecvRecall');
    hookInstance('NTAIOChat.NTAIOFloatEarPart', 'recallMessageWithNotification:', 
        'FloatEarPart.recallMessage');
    hookInstance('NTAIOChat.NTAIOEGPetHandlerBuilder', 'receiveRecallNotification:', 
        'EGPetHandler.receiveRecall');
    hookInstance('NTAIOChat.NTAIOReplyMsgHandlerBuilder', 'receiveRecallNotificationAt:', 
        'ReplyMsgHandler.receiveRecallAt');
    hookInstance('NTAIOChat.NTAIOMultiSelectToHereHandlerBuilder', 'onReceiveRecallMsgNotification:', 
        'MultiSelectHandler.onReceiveRecall');

    // === 等级3: ZTP/Guild ===
    log('\n--- ★ 3. ZTP/Guild 撤回 ---');
    hookInstance('ZTPSquareAIOMessageService', 'onMsgRecall:peerUid:seq:', 
        'ZTPSquare.onMsgRecall');

    // === 等级4: ObjC 传统层 ===
    log('\n--- ★ 4. ObjC 传统召回处理 ---');
    hookInstance('QQMessageRecallModule', 'handleSideAccountRecallNotify:bufferLen:subcmd:bindUin:tracelessFlag:', 
        'RecallModule.sideAccount');
    hookInstance('QQMessageRecallModule', 'convertRecallItemToMsg:recallModel:msgType:bindUin:', 
        'RecallModule.convert');
    hookClass('QQMessageRecallPackageHandler', 'parseC2CRecallNotify:bufferLen:subcmd:model:', 
        'PackageHandler.parseC2C');
    hookClass('QQMessageRecallPackageHandler', 'parseC2CRecallInOut:', 
        'PackageHandler.parseInOut');
    hookInstance('QQMessageRecallNetEngine', 'parseC2CRecallNotify:bufferLen:subcmd:model:', 
        'NetEngine.parseC2C');

    // === 等级5: Recall 标记 ===
    log('\n--- ★ 5. 撤回标记拦截 ---');
    hookInstance('OCMsgRecallInfo', 'isRecallNotify', 'isRecallNotify');
    hookInstance('OCMsgRecallInfo', 'setIsRecallNotify:', 'setIsRecallNotify');
    hookInstance('OCMsgRecallInfo', 'isTracelessRecall', 'isTracelessRecall');
    hookInstance('OCMsgRecallInfo', 'setIsTracelessRecall:', 'setIsTracelessRecall');

    // === 等级6: RecallPair ===
    log('\n--- ★ 6. RecallPair 模型 ---');
    hookInstance('RecallPair', 'recallModel', 'recallModel');
    hookInstance('RecallPair', 'setRecallModel:', 'setRecallModel');
    hookInstance('RecallPairForOffline', 'recallModel', 'recallModel(offline)');
    hookInstance('RecallPairForOffline', 'setRecallModel:', 'setRecallModel(offline)');

    // === 等级7: 菜单/灰条 ===
    log('\n--- ★ 7. 撤回菜单/灰条 ---');
    hookClass('QQRecallMenuFilter', 'isGroupMessageNeedShowMenuRecall:', 'menuFilter.isGroup');
    hookClass('QQRecallMenuFilter', 'needShowRecallBaseImpl:', 'menuFilter.baseImpl');
    hookInstance('NTAIOChat.NTAIOMenuRecallService', 'recallCompleteWithCell:observer:code:msg:', 
        'MenuRecallService.complete');
    hookInstance('NTAIOChat.NTAIOMenuRecallService', 'recallGrayTipsMsgWithCellView:observer:', 
        'MenuRecallService.grayTips');

    // === 等级8: FA (文件助手) ===
    log('\n--- ★ 8. 文件助手撤回 ---');
    hookInstance('FARecallMgr', 'recallFAModel:', 'FARecallMgr.recallFA');
    hookInstance('FARecallMgr', 'onRecvMsgRecallResult:', 'FARecallMgr.onRecvResult');

    // === 通知监控 ===
    log('\n--- ★ 通知监控 ---');
    hookNotificationCenter();

    log('\n========================================');
    log('✅ 所有 Hook 安装完成！');
    log('📢 现在请让朋友给你发消息并撤回！');
    log('========================================');
}, 8000);
