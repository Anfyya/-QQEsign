/*
 * QQESign — Frida 防撤回拦截验证 v6
 * 
 * 使用 ObjC 底层 API (ObjC.api) 绕过 JS 绑定的问题
 * 所有方法都通过 class_getInstanceMethod / class_getClassMethod 获取
 */

const I = ObjC.api;
let hookCount = 0;

function log(msg) { console.log(`[✅测试] ${msg}`); }

function getStack(depth) {
    try {
        return Thread.backtrace(this.context, Backtracer.ACCURATE)
            .map(DebugSymbol.fromAddress)
            .slice(0, depth || 25)
            .join('\n    ');
    } catch (e) { return ''; }
}

// ─────────────────────────────────────────────
// Hook 实例方法 (使用 ObjC 底层 API)
// ─────────────────────────────────────────────
function hookInstance(className, selector, label) {
    label = label || `${className} -[${selector}]`;
    try {
        const clsPtr = I.objc_getClass(className);
        if (clsPtr.isNull()) { log(`❌ [${label}] 类不存在`); return false; }

        const sel = ObjC.selector(selector);
        const method = I.class_getInstanceMethod(clsPtr, sel);
        if (method.isNull()) {
            log(`❌ [${label}] 实例方法不存在`);
            return false;
        }

        const origIMP = I.method_getImplementation(method);
        const typeEncoding = I.method_getTypeEncoding(method).readCString();
        const returnType = typeEncoding ? typeEncoding[0] : 'v';

        log(`🔧 [${label}] type=${typeEncoding} ret=${returnType}`);

        // 创建替换实现 — 根据返回类型决定 callback 签名
        let replacement;
        let retTypeStr;
        let callbackFn;

        if (returnType === 'v') {
            // void 方法
            retTypeStr = 'void';
            callbackFn = function (self, _cmd) {
                log(`🚫 拦截 [${label}] ✓`);
                log(`    栈:\n    ${getStack()}`);
                // 不调原方法 = 阻止撤回
            };
            replacement = new NativeCallback(callbackFn, retTypeStr, ['pointer', 'pointer']);
        } else if (returnType === 'B' || returnType === 'c') {
            // BOOL 方法
            retTypeStr = 'bool';
            callbackFn = function (self, _cmd) {
                log(`🚫 拦截 [${label}] → 返回 NO`);
                log(`    栈:\n    ${getStack()}`);
                return 0; // 返回 NO 阻止撤回
            };
            replacement = new NativeCallback(callbackFn, retTypeStr, ['pointer', 'pointer']);
        } else if (returnType === '@') {
            // id 方法
            retTypeStr = 'pointer';
            callbackFn = function (self, _cmd) {
                log(`🚫 拦截 [${label}] → 返回 nil`);
                log(`    栈:\n    ${getStack()}`);
                return null; // 返回 nil 阻止撤回
            };
            replacement = new NativeCallback(callbackFn, retTypeStr, ['pointer', 'pointer']);
        } else if (returnType === 'I' || returnType === 'i') {
            retTypeStr = 'int';
            callbackFn = function (self, _cmd) {
                log(`🚫 拦截 [${label}] → 返回 0`);
                log(`    栈:\n    ${getStack()}`);
                return 0;
            };
            replacement = new NativeCallback(callbackFn, retTypeStr, ['pointer', 'pointer']);
        } else if (returnType === 'Q' || returnType === 'q') {
            retTypeStr = 'uint64';
            callbackFn = function (self, _cmd) {
                log(`🚫 拦截 [${label}] → 返回 0`);
                log(`    栈:\n    ${getStack()}`);
                return 0;
            };
            replacement = new NativeCallback(callbackFn, retTypeStr, ['pointer', 'pointer']);
        } else if (returnType === 'f') {
            retTypeStr = 'float';
            callbackFn = function (self, _cmd) {
                log(`🚫 拦截 [${label}]`);
                return 0;
            };
            replacement = new NativeCallback(callbackFn, retTypeStr, ['pointer', 'pointer']);
        } else {
            // 未知类型，默认用 void
            retTypeStr = 'void';
            callbackFn = function () {
                log(`🚫 拦截 [${label}] (类型=${returnType})`);
                log(`    栈:\n    ${getStack()}`);
            };
            replacement = new NativeCallback(callbackFn, retTypeStr, ['pointer', 'pointer']);
        }

        I.method_setImplementation(method, replacement);
        hookCount++;
        log(`✅ [${label}] 拦截已安装 ✓`);
        return true;
    } catch (e) {
        log(`❌ [${label}] 异常: ${e.message}`);
        return false;
    }
}

// ─────────────────────────────────────────────
// Hook 类方法
// ─────────────────────────────────────────────
function hookClass(className, selector, label) {
    label = label || `${className} +[${selector}]`;
    try {
        const metaCls = I.objc_getMetaClass(className);
        if (metaCls.isNull()) { log(`❌ [${label}] 元类不存在`); return false; }

        const sel = ObjC.selector(selector);
        const method = I.class_getInstanceMethod(metaCls, sel);
        if (method.isNull()) {
            log(`❌ [${label}] 类方法不存在`);
            return false;
        }

        const origIMP = I.method_getImplementation(method);
        const typeEncoding = I.method_getTypeEncoding(method).readCString();
        const returnType = typeEncoding ? typeEncoding[0] : 'v';

        log(`🔧 [${label}] type=${typeEncoding}`);

        let replacement, retTypeStr;

        if (returnType === 'v') {
            retTypeStr = 'void';
            replacement = new NativeCallback(function () {
                log(`🚫 拦截 [${label}] ✓`);
                log(`    栈:\n    ${getStack()}`);
            }, retTypeStr, ['pointer', 'pointer']);
        } else if (returnType === 'B' || returnType === 'c') {
            retTypeStr = 'bool';
            replacement = new NativeCallback(function () {
                log(`🚫 拦截 [${label}] → 返回 NO`);
                log(`    栈:\n    ${getStack()}`);
                return 0;
            }, retTypeStr, ['pointer', 'pointer']);
        } else if (returnType === '@') {
            retTypeStr = 'pointer';
            replacement = new NativeCallback(function () {
                log(`🚫 拦截 [${label}] → 返回 nil`);
                log(`    栈:\n    ${getStack()}`);
                return null;
            }, retTypeStr, ['pointer', 'pointer']);
        } else {
            retTypeStr = 'void';
            replacement = new NativeCallback(function () {
                log(`🚫 拦截 [${label}] (type=${returnType})`);
            }, retTypeStr, ['pointer', 'pointer']);
        }

        I.method_setImplementation(method, replacement);
        hookCount++;
        log(`✅ [${label}] 拦截已安装 ✓`);
        return true;
    } catch (e) {
        log(`❌ [${label}] 异常: ${e.message}`);
        return false;
    }
}

// ─────────────────────────────────────────────
// Hook NSNotificationCenter
// ─────────────────────────────────────────────
function hookNotifications() {
    try {
        const nc = I.objc_getClass('NSNotificationCenter');
        const sel = ObjC.selector('postNotificationName:object:userInfo:');
        const method = I.class_getInstanceMethod(nc, sel);
        if (method.isNull()) { log('❌ 通知方法不存在'); return false; }

        const orig = I.method_getImplementation(method);
        const replacement = new NativeCallback(function (self, _cmd, name, obj, info) {
            try {
                const nameObj = new ObjC.Object(name);
                const str = nameObj.toString();
                if (str.toLowerCase().includes('recall') || str.toLowerCase().includes('revoke')) {
                    log(`📨 撤回通知: ${str}`);
                    log(`    栈:\n    ${getStack()}`);
                }
            } catch (e) {}
            // 调用原始实现
            const origFn = new NativeFunction(orig, 'void', ['pointer', 'pointer', 'pointer', 'pointer', 'pointer']);
            origFn(self, _cmd, name, obj, info);
        }, 'void', ['pointer', 'pointer', 'pointer', 'pointer', 'pointer']);

        I.method_setImplementation(method, replacement);
        log('✅ 通知监控已安装 ✓');
        return true;
    } catch (e) {
        log(`❌ 通知 Hook 失败: ${e.message}`);
        return false;
    }
}

// ─────────────────────────────────────────────
// 尝试通过符号查找 C++ 函数
// ─────────────────────────────────────────────
function hookCpp() {
    const symbols = [
        '__ZN2nt7wrapper16KernelMsgService24recallMsgFromC2CAndGroupEPNS_13MsgRecallItemEiiPS2_',
        '_ZN2nt7wrapper16KernelMsgService24recallMsgFromC2CAndGroupEPNS_13MsgRecallItemEiiPS2_',
    ];
    for (const sym of symbols) {
        try {
            const addr = Module.findExportByName(null, sym);
            if (addr) {
                log(`🔧 C++ ${sym} @ ${addr}`);
                Interceptor.attach(addr, {
                    onEnter() {
                        log(`🚫 C++ KernelMsgService::recallMsgFromC2CAndGroup 被调用`);
                        log(`    栈:\n    ${getStack()}`);
                    }
                });
                log('✅ C++ hook 已安装 ✓');
            }
        } catch (e) {}
    }
}

// ─────────────────────────────────────────────
// 主动探测: 枚举当前所有 OCMsgRecallInfo 实例
// ─────────────────────────────────────────────
function probeRecallInstances() {
    setTimeout(() => {
        try {
            const cls = ObjC.classes.OCMsgRecallInfo;
            if (!cls) return;
            const instances = ObjC.choose(cls);
            if (instances.length > 0) {
                log(`📊 当前 OCMsgRecallInfo 实例数: ${instances.length}`);
                for (let i = 0; i < Math.min(instances.length, 3); i++) {
                    const inst = instances[i];
                    try {
                        log(`   [${i}] isRecallNotify=${inst.isRecallNotify()}`);
                    } catch(e) {
                        log(`   [${i}] (读取失败)`);
                    }
                }
            }
        } catch(e) {}
    }, 10000);
}

// ─────────────────────────────────────────────
// 诊断: 用底层 API 测试方法可访问性
// ─────────────────────────────────────────────
function diagMethod(className, selector, isClassMethod) {
    const clsPtr = isClassMethod ? I.objc_getMetaClass(className) : I.objc_getClass(className);
    const sel = ObjC.selector(selector);
    const method = isClassMethod ? I.class_getInstanceMethod(clsPtr, sel) : I.class_getInstanceMethod(clsPtr, sel);
    const exists = !method.isNull();
    
    let typeStr = '';
    if (exists) {
        try {
            typeStr = I.method_getTypeEncoding(method).readCString();
        } catch(e) {}
    }
    
    log(`   ${exists ? '✅' : '❌'} ${isClassMethod ? '+' : '-'}[${selector}] ${typeStr}`);
    return exists;
}

// ─────────────────────────────────────────────
// 主入口
// ─────────────────────────────────────────────
log('══════════════════════════════════════');
log('QQESign 防撤回拦截验证 v6 (底层API)');
log(`PID: ${Process.id}`);
log('══════════════════════════════════════');

ObjC.schedule(ObjC.mainQueue, () => {
    // 阶段1: 诊断
    log('\n--- 诊断方法可访问性 ---');
    diagMethod('QQMessageRecallModule', 'handleSideAccountRecallNotify:bufferLen:subcmd:bindUin:tracelessFlag:', false);
    diagMethod('QQMessageRecallModule', 'convertRecallItemToMsg:recallModel:msgType:bindUin:', false);
    diagMethod('QQMessageRecallModule', 'getRecallMessageContent:bindUin:', false);
    diagMethod('QQMessageRecallNetEngine', 'parseC2CRecallNotify:bufferLen:subcmd:model:', false);
    diagMethod('QQMessageRecallPackageHandler', 'parseC2CRecallNotify:bufferLen:subcmd:model:', true);
    diagMethod('QQMessageRecallPackageHandler', 'parseC2CRecallInOut:', true);
    diagMethod('OCMsgRecallInfo', 'isRecallNotify', false);
    diagMethod('OCMsgRecallInfo', 'setIsRecallNotify:', false);
    diagMethod('OCMsgRecallInfo', 'isTracelessRecall', false);
    diagMethod('OCMsgRecallInfo', 'setIsTracelessRecall:', false);
    diagMethod('RecallPair', 'recallModel', false);
    diagMethod('RecallPair', 'setRecallModel:', false);
    diagMethod('RecallPairForOffline', 'recallModel', false);
    diagMethod('FARecallMgr', 'recallFAModel:', false);
    diagMethod('FARecallMgr', 'onFARecallResult:error:', false);
    diagMethod('FARecallMgr', 'onRecvMsgRecallResult:', false);
    diagMethod('QQRecallMenuFilter', 'isGroupMessageNeedShowMenuRecall:', true);
    diagMethod('QQRecallMenuFilter', 'needShowRecallBaseImpl:', true);
    diagMethod('NTAIOChat.NTAIMenuRecallService', 'recallCompleteWithCell:observer:code:msg:', true);
    diagMethod('NTAIOChatRecallService', 'getNTUnlimitedRecallAbilityInfo', true);

    // 诊断 Swift 桥接类
    diagMethod('NTKernelAdapter.MessageService', 'recallMsgWithPeer:msgIds:cb:', false);
    diagMethod('NTAIOChat.NTStreamMsgAIOHandler', 'receiveRecallNotification:', false);
    diagMethod('NTAIOChat.NTAIOFloatEarManager', 'onRecvRecallMsg:', false);
    diagMethod('NTAIOChat.NTAIOFloatEarPart', 'recallMessageWithNotification:', false);
    diagMethod('ZTPSquareAIOMessageService', 'onMsgRecall:peerUid:seq:', false);

    // 阶段2: 安装拦截
    log('\n══════════════════════════════════════');
    log('安装拦截...');
    log('══════════════════════════════════════');

    // 先安装确认存在的方法
    log('\n--- ObjC 类方法 ---');
    hookClass('QQMessageRecallPackageHandler', 'parseC2CRecallNotify:bufferLen:subcmd:model:', 'PackageHandler.parseC2C');
    hookClass('QQMessageRecallPackageHandler', 'parseC2CRecallInOut:', 'PackageHandler.parseInOut');
    hookClass('QQRecallMenuFilter', 'isGroupMessageNeedShowMenuRecall:', 'MenuFilter.isGroup');
    hookClass('QQRecallMenuFilter', 'needShowRecallBaseImpl:', 'MenuFilter.baseImpl');

    log('\n--- ObjC 实例方法 (底层 API) ---');
    hookInstance('QQMessageRecallModule', 'handleSideAccountRecallNotify:bufferLen:subcmd:bindUin:tracelessFlag:', 'RecallModule.sideAccount');
    hookInstance('QQMessageRecallModule', 'convertRecallItemToMsg:recallModel:msgType:bindUin:', 'RecallModule.convert');
    hookInstance('QQMessageRecallNetEngine', 'parseC2CRecallNotify:bufferLen:subcmd:model:', 'NetEngine.parseC2C');
    hookInstance('OCMsgRecallInfo', 'isRecallNotify', 'isRecallNotify');
    hookInstance('OCMsgRecallInfo', 'setIsRecallNotify:', 'setIsRecallNotify');
    hookInstance('OCMsgRecallInfo', 'isTracelessRecall', 'isTracelessRecall');
    hookInstance('OCMsgRecallInfo', 'setIsTracelessRecall:', 'setIsTracelessRecall');
    hookInstance('RecallPair', 'recallModel', 'recallModel');
    hookInstance('RecallPair', 'setRecallModel:', 'setRecallModel');
    hookInstance('RecallPairForOffline', 'recallModel', 'recallModel(offline)');
    hookInstance('RecallPairForOffline', 'setRecallModel:', 'setRecallModel(offline)');
    hookInstance('FARecallMgr', 'recallFAModel:', 'FARecallMgr.recallFA');
    hookInstance('FARecallMgr', 'onFARecallResult:error:', 'FARecallMgr.onResult');
    hookInstance('FARecallMgr', 'onRecvMsgRecallResult:', 'FARecallMgr.onRecvResult');

    log('\n--- Swift 桥接类 (底层 API) ---');
    hookInstance('NTKernelAdapter.MessageService', 'recallMsgWithPeer:msgIds:cb:', '⭐ MessageService.recallMsg');
    hookInstance('NTKernelAdapter.MessageService', 'reeditRecallMsgWithPeer:msgId:cb:', 'MessageService.reedit');
    hookInstance('NTKernelAdapter.MessageService', 'getRecallMsgsWithPeer:msgIds:cb:', 'MessageService.getMsgs');
    hookInstance('NTAIOChat.NTStreamMsgAIOHandler', 'receiveRecallNotification:', '⭐ StreamHandler.receive');
    hookInstance('NTAIOChat.NTAIOFloatEarManager', 'onRecvRecallMsg:', 'FloatEar.onRecv');
    hookInstance('NTAIOChat.NTAIOFloatEarPart', 'recallMessageWithNotification:', 'FloatEarPart');
    hookInstance('ZTPSquareAIOMessageService', 'onMsgRecall:peerUid:seq:', 'ZTPSquare.onMsgRecall');

    log('\n--- 通知 ---');
    hookNotifications();

    log('\n--- C++ ---');
    hookCpp();

    // 定期探测
    probeRecallInstances();

    log('\n══════════════════════════════════════');
    log(`✅ 安装了 ${hookCount} 个拦截点`);
    log('📢 请让朋友发消息然后撤回！');
    log('   如果有拦截命中，会显示 🚫 标记');
    log('══════════════════════════════════════');
});
