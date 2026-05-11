/*
 * QQESign — Frida 防撤回拦截验证 v7
 * 
 * 使用 NativeFunction 直接调用 ObjC 运行时 C 函数
 * 完全绕过 Frida JS 绑定的限制
 */

const log = (msg) => console.log(`[v7] ${msg}`);

// 直接从共享库导出 ObjC 运行时函数
const libobjc = Process.enumerateModules().find(m => m.name === 'libobjc.A.dylib' || m.path.includes('libobjc'));
if (!libobjc) { log('❌ libobjc 未找到！'); }

function getFn(name, retType, argTypes) {
    const addr = Module.findExportByName(null, name);
    if (!addr) {
        // 有时需要用完整路径
        const addr2 = Module.findExportByName('libobjc.A.dylib', name);
        if (!addr2) return null;
        return new NativeFunction(addr2, retType, argTypes);
    }
    return new NativeFunction(addr, retType, argTypes);
}

// 获取 ObjC 运行时函数
const objc_getClass = getFn('objc_getClass', 'pointer', ['pointer']);
const objc_getMetaClass = getFn('objc_getMetaClass', 'pointer', ['pointer']);
const sel_registerName = getFn('sel_registerName', 'pointer', ['pointer']);
const class_getInstanceMethod = getFn('class_getInstanceMethod', 'pointer', ['pointer', 'pointer']);
const method_getImplementation = getFn('method_getImplementation', 'pointer', ['pointer']);
const method_getTypeEncoding = getFn('method_getTypeEncoding', 'pointer', ['pointer']);
const method_setImplementation = getFn('method_setImplementation', 'pointer', ['pointer', 'pointer']);

if (!objc_getClass) { log('❌ objc_getClass 不可用！'); }
if (!class_getInstanceMethod) { log('❌ class_getInstanceMethod 不可用！'); }

let hookCount = 0;

function getStack(depth) {
    try {
        return Thread.backtrace(this.context, Backtracer.ACCURATE)
            .map(DebugSymbol.fromAddress)
            .slice(0, depth || 25)
            .join('\n    ');
    } catch (e) { return ''; }
}

// ─────────────────────────────────────────────
// Hook 实例方法
// ─────────────────────────────────────────────
function hookInstance(className, selector, label) {
    label = label || `${className} -[${selector}]`;
    try {
        const clsNamePtr = Memory.allocUtf8String(className);
        const clsPtr = objc_getClass(clsNamePtr);
        if (clsPtr.isNull()) { log(`❌ [${label}] 类不存在`); return false; }

        const selPtr = sel_registerName(Memory.allocUtf8String(selector));
        const method = class_getInstanceMethod(clsPtr, selPtr);
        if (method.isNull()) {
            log(`❌ [${label}] 方法不存在`);
            return false;
        }

        const origIMP = method_getImplementation(method);
        const typeEncodingPtr = method_getTypeEncoding(method);
        let typeEncoding = '(unknown)';
        try { if (!typeEncodingPtr.isNull()) typeEncoding = typeEncodingPtr.readUtf8String(); } catch(e) {}
        const returnType = typeEncoding ? typeEncoding[0] : 'v';

        log(`🔧 [${label}] type=${typeEncoding}`);

        let replacement;
        const retTypeStr = returnType === 'B' || returnType === 'c' ? 'bool' :
                          returnType === '@' ? 'pointer' :
                          returnType === 'I' || returnType === 'i' ? 'int' :
                          returnType === 'Q' || returnType === 'q' ? 'uint64' :
                          returnType === 'f' ? 'float' :
                          'void';

        callbackFn = function () {
            log(`🚫 拦截 [${label}] ✓`);
            log(`    栈:\n    ${getStack()}`);
            if (retTypeStr === 'bool') return 0;
            if (retTypeStr === 'pointer') return null;
            if (retTypeStr === 'int' || retTypeStr === 'uint64') return 0;
            if (retTypeStr === 'float') return 0;
            // void: just return undefined
        };

        replacement = new NativeCallback(callbackFn, retTypeStr, ['pointer', 'pointer']);
        method_setImplementation(method, replacement);
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
        const clsNamePtr = Memory.allocUtf8String(className);
        const metaClsPtr = objc_getMetaClass(clsNamePtr);
        if (metaClsPtr.isNull()) { log(`❌ [${label}] 元类不存在`); return false; }

        const selPtr = sel_registerName(Memory.allocUtf8String(selector));
        const method = class_getInstanceMethod(metaClsPtr, selPtr);
        if (method.isNull()) {
            log(`❌ [${label}] 类方法不存在`);
            return false;
        }

        const origIMP = method_getImplementation(method);
        const typeEncodingPtr = method_getTypeEncoding(method);
        let typeEncoding = '';
        try { if (!typeEncodingPtr.isNull()) typeEncoding = typeEncodingPtr.readUtf8String(); } catch(e) {}
        const returnType = typeEncoding ? typeEncoding[0] : 'v';

        log(`🔧 [${label}] type=${typeEncoding}`);

        const retTypeStr = returnType === 'B' || returnType === 'c' ? 'bool' :
                          returnType === '@' ? 'pointer' :
                          returnType === 'I' || returnType === 'i' ? 'int' :
                          'void';

        const replacement = new NativeCallback(function () {
            log(`🚫 拦截 [${label}] ✓`);
            log(`    栈:\n    ${getStack()}`);
            if (retTypeStr === 'bool') return 0;
            if (retTypeStr === 'pointer') return null;
            if (retTypeStr === 'int') return 0;
        }, retTypeStr, ['pointer', 'pointer']);

        method_setImplementation(method, replacement);
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
        const ncName = Memory.allocUtf8String('NSNotificationCenter');
        const ncPtr = objc_getClass(ncName);
        const selPtr = sel_registerName(Memory.allocUtf8String('postNotificationName:object:userInfo:'));
        const method = class_getInstanceMethod(ncPtr, selPtr);
        if (method.isNull()) { log('❌ 通知方法不存在'); return false; }

        const orig = method_getImplementation(method);
        const replacement = new NativeCallback(function (self, _cmd, name, obj, info) {
            try {
                const nameObj = new ObjC.Object(name);
                const str = nameObj.toString();
                if (str.toLowerCase().includes('recall') || str.toLowerCase().includes('revoke')) {
                    log(`📨 撤回通知: ${str}`);
                    log(`    栈:\n    ${getStack()}`);
                }
            } catch (e) {}
            // 调用原始
            const origFn = new NativeFunction(orig, 'void', ['pointer', 'pointer', 'pointer', 'pointer', 'pointer']);
            origFn(self, _cmd, name, obj, info);
        }, 'void', ['pointer', 'pointer', 'pointer', 'pointer', 'pointer']);

        method_setImplementation(method, replacement);
        log('✅ 通知监控已安装 ✓');
        return true;
    } catch (e) {
        log(`❌ 通知 Hook 失败: ${e.message}`);
        return false;
    }
}

// ─────────────────────────────────────────────
// 诊断
// ─────────────────────────────────────────────
function diag(className, selector, isClass) {
    const namePtr = Memory.allocUtf8String(className);
    const clsPtr = isClass ? objc_getMetaClass(namePtr) : objc_getClass(namePtr);
    if (clsPtr.isNull()) { log(`   ❌ ${className} 类不存在`); return false; }

    const selPtr = sel_registerName(Memory.allocUtf8String(selector));
    const method = class_getInstanceMethod(clsPtr, selPtr);
    if (method.isNull()) {
        // 试试另一种获取方式
        log(`   ❌ ${isClass ? '+' : '-'}[${selector}] 不存在`);
        return false;
    }

    const imp = method_getImplementation(method);
    const typePtr = method_getTypeEncoding(method);
    let types = '';
    try { if (!typePtr.isNull()) types = typePtr.readUtf8String(); } catch(e) {}
    log(`   ✅ ${isClass ? '+' : '-'}[${selector}] imp=${imp} type=${types}`);
    return true;
}

// ─────────────────────────────────────────────
// 主入口
// ─────────────────────────────────────────────
log('══════════════════════════════════');
log('QQESign 防撤回拦截 v7 (NativeFn)');
log(`PID: ${Process.id}`);
log('══════════════════════════════════');

setTimeout(() => {
    // 诊断
    log('\n--- 诊断 (NativeFunction) ---');
    diag('QQMessageRecallModule', 'handleSideAccountRecallNotify:bufferLen:subcmd:bindUin:tracelessFlag:', false);
    diag('QQMessageRecallModule', 'convertRecallItemToMsg:recallModel:msgType:bindUin:', false);
    diag('QQMessageRecallNetEngine', 'parseC2CRecallNotify:bufferLen:subcmd:model:', false);
    diag('QQMessageRecallPackageHandler', 'parseC2CRecallNotify:bufferLen:subcmd:model:', true);
    diag('QQMessageRecallPackageHandler', 'parseC2CRecallInOut:', true);
    diag('OCMsgRecallInfo', 'isRecallNotify', false);
    diag('OCMsgRecallInfo', 'setIsRecallNotify:', false);
    diag('RecallPair', 'recallModel', false);
    diag('RecallPair', 'setRecallModel:', false);
    diag('QQRecallMenuFilter', 'isGroupMessageNeedShowMenuRecall:', true);
    diag('NTKernelAdapter.MessageService', 'recallMsgWithPeer:msgIds:cb:', false);
    diag('NTAIOChat.NTStreamMsgAIOHandler', 'receiveRecallNotification:', false);
    diag('NTAIOChat.NTAIOFloatEarManager', 'onRecvRecallMsg:', false);
    diag('NTAIOChat.NTAIOFloatEarPart', 'recallMessageWithNotification:', false);
    diag('NTAIOChatRecallService', 'getNTUnlimitedRecallAbilityInfo', true);
    diag('NTAIOChat.NTAIOMenuRecallService', 'recallCompleteWithCell:observer:code:msg:', true);
    diag('FARecallMgr', 'recallFAModel:', false);
    diag('OCRevokeElement', 'RevokeElement', true);

    // 安装拦截
    log('\n══════════════════════════════════');
    log('安装拦截...');
    log('══════════════════════════════════');

    hookClass('QQMessageRecallPackageHandler', 'parseC2CRecallNotify:bufferLen:subcmd:model:', 'PackageHandler.parseC2C');
    hookClass('QQMessageRecallPackageHandler', 'parseC2CRecallInOut:', 'PackageHandler.parseInOut');
    hookClass('QQRecallMenuFilter', 'isGroupMessageNeedShowMenuRecall:', 'MenuFilter.isGroup');
    hookClass('QQRecallMenuFilter', 'needShowRecallBaseImpl:', 'MenuFilter.baseImpl');

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

    hookInstance('NTKernelAdapter.MessageService', 'recallMsgWithPeer:msgIds:cb:', '⭐MessageService.recallMsg');
    hookInstance('NTKernelAdapter.MessageService', 'reeditRecallMsgWithPeer:msgId:cb:', 'MessageService.reedit');
    hookInstance('NTKernelAdapter.MessageService', 'getRecallMsgsWithPeer:msgIds:cb:', 'MessageService.getMsgs');
    hookInstance('NTAIOChat.NTStreamMsgAIOHandler', 'receiveRecallNotification:', '⭐StreamHandler.receive');
    hookInstance('NTAIOChat.NTAIOFloatEarManager', 'onRecvRecallMsg:', 'FloatEar.onRecv');
    hookInstance('NTAIOChat.NTAIOFloatEarPart', 'recallMessageWithNotification:', 'FloatEarPart');
    hookInstance('ZTPSquareAIOMessageService', 'onMsgRecall:peerUid:seq:', 'ZTPSquare.onRecall');

    hookNotifications();

    log(`\n══════════════════════════════════`);
    log(`✅ 安装了 ${hookCount} 个拦截点`);
    log('📢 请让朋友发消息然后撤回！');
    log('══════════════════════════════════');
}, 5000);
