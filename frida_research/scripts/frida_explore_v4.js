/*
 * QQESign — Frida 防撤回探索 v4 (底层 ObjC API)
 *
 * 使用 ObjC.api 直接操作运行时，更可靠
 */

function log(msg) { console.log(`[QQESign-v4] ${msg}`); }
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

// ─────────────────────────────────────────────
// 通用 Hook 函数 (使用底层 ObjC API)
// ─────────────────────────────────────────────
let hookCount = 0;

function hookInstanceMethod(className, selectorName, tag) {
    tag = tag || `${className} -[${selectorName}]`;
    try {
        // 通过 ObjC API 获取类和选择器
        const clsPtr = ObjC.api.objc_getClass(className);
        if (clsPtr.isNull()) {
            log(`[✗] 类不存在: ${className}`);
            return false;
        }

        const sel = ObjC.selector(selectorName);
        const method = ObjC.api.class_getInstanceMethod(clsPtr, sel);
        if (method.isNull()) {
            log(`[✗] 实例方法不存在: ${tag}`);
            return false;
        }

        const orig = ObjC.api.method_getImplementation(method);
        const types = ObjC.api.method_getTypeEncoding(method);

        log(`[✓] 找到: ${tag}  types=${types.readCString()}`);

        // 创建替换实现
        const replacement = new NativeCallback(function (self, _cmd) {
            const args = Array.from(arguments);
            log(`🔧 ${tag}`);

            // 打印参数 (跳过 self, _cmd)
            for (let i = 2; i < args.length; i++) {
                try {
                    const val = args[i];
                    if (val === null) log(`   a${i}: null`);
                    else if (val === undefined) log(`   a${i}: undefined`);
                    else {
                        // 尝试转换为 ObjC 对象来获取类名
                        try {
                            const obj = new ObjC.Object(val);
                            const desc = obj.toString ? obj.toString().substring(0, 150) : '';
                            log(`   a${i}: [${obj.$className}] ${desc}`);
                        } catch {
                            log(`   a${i}: ${val}`);
                        }
                    }
                } catch (e) { log(`   a${i}: (err: ${e})`); }
            }

            log(`   🥞 栈:\n    ${getStack()}`);

            const origFn = new NativeFunction(orig, 'void', ['pointer', 'pointer', ...]);
            // 直接调用原实现
            return origFn.apply(null, arguments);
        }, 'void', ['pointer', 'pointer']);

        ObjC.api.method_setImplementation(method, replacement);
        hookCount++;
        log(`[✓] Hook 成功: ${tag}`);
        return true;
    } catch (e) {
        log(`[✗] Hook 失败: ${tag}: ${e.message}`);
        return false;
    }
}

function hookClassMethod(className, selectorName, tag) {
    tag = tag || `${className} +[${selectorName}]`;
    try {
        const clsPtr = ObjC.api.objc_getClass(className);
        if (clsPtr.isNull()) {
            log(`[✗] 类不存在: ${className}`);
            return false;
        }

        // 类方法存在元类上
        const metaCls = ObjC.api.objc_getMetaClass(className);
        const sel = ObjC.selector(selectorName);
        const method = ObjC.api.class_getInstanceMethod(metaCls, sel);
        if (method.isNull()) {
            log(`[✗] 类方法不存在: ${tag}`);
            return false;
        }

        const orig = ObjC.api.method_getImplementation(method);
        const types = ObjC.api.method_getTypeEncoding(method);

        log(`[✓] 找到: ${tag}  types=${types.readCString()}`);

        const replacement = new NativeCallback(function (self, _cmd) {
            const args = Array.from(arguments);
            log(`🔧 ${tag}`);
            for (let i = 2; i < args.length; i++) {
                try {
                    const val = args[i];
                    if (val === null) log(`   a${i}: null`);
                    else if (val === undefined) log(`   a${i}: undefined`);
                    else {
                        try {
                            const obj = new ObjC.Object(val);
                            const desc = obj.toString ? obj.toString().substring(0, 150) : '';
                            log(`   a${i}: [${obj.$className}] ${desc}`);
                        } catch {
                            log(`   a${i}: ${val}`);
                        }
                    }
                } catch (e) { log(`   a${i}: (err: ${e})`); }
            }
            log(`   🥞 栈:\n    ${getStack()}`);

            const origFn = new NativeFunction(orig, 'void', ['pointer', 'pointer', ...]);
            return origFn.apply(null, arguments);
        }, 'void', ['pointer', 'pointer']);

        ObjC.api.method_setImplementation(method, replacement);
        hookCount++;
        log(`[✓] Hook 成功: ${tag}`);
        return true;
    } catch (e) {
        log(`[✗] Hook 失败: ${tag}: ${e.message}`);
        return false;
    }
}

// ─────────────────────────────────────────────
// 使用 Frida 高级 API (ObjC.classes) 作为备选
// ─────────────────────────────────────────────
function hookViaFridaAPI(className, methodName, isClassMethod, tag) {
    tag = tag || `${className} ${isClassMethod ? '+' : '-'}[${methodName}]`;
    try {
        const cls = ObjC.classes[className];
        if (!cls) {
            log(`[✗] 类不可用: ${className}`);
            return false;
        }

        // 检查方法存在性
        const methods = cls.$methods;
        if (!methods.includes(methodName)) {
            log(`[✗] 方法不在 $methods 中: ${tag}`);
            return false;
        }

        const target = isClassMethod ? cls.$class : cls;
        const hook = target[methodName];
        if (!hook) {
            log(`[✗] 无法通过 API 获取方法: ${tag}`);
            return false;
        }

        const orig = hook.implementation;
        hook.implementation = function () {
            const args = Array.from(arguments);
            log(`🔧 ${tag}`);
            for (let i = 0; i < args.length; i++) {
                log(`   a${i}: ${describeArg(args[i])}`);
            }
            log(`   🥞 栈:\n    ${getStack()}`);
            return orig.apply(this, args);
        };

        hookCount++;
        log(`[✓] Hook 成功: ${tag}`);
        return true;
    } catch (e) {
        log(`[✗] Hook 失败: ${tag}: ${e.message}`);
        return false;
    }
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
        if (typeof arg === 'object') return `[Object]`;
        return String(arg).substring(0, maxLen);
    } catch (e) { return `(error: ${e})`; }
}

// ─────────────────────────────────────────────
// Hook NSNotificationCenter (通过 ObjC API)
// ─────────────────────────────────────────────
function hookNotifications() {
    log('Hook NSNotificationCenter...');
    try {
        const cls = ObjC.api.objc_getClass('NSNotificationCenter');
        const sel = ObjC.selector('postNotificationName:object:userInfo:');
        const method = ObjC.api.class_getInstanceMethod(cls, sel);
        if (!method.isNull()) {
            const orig = ObjC.api.method_getImplementation(method);
            const replacement = new NativeCallback(function (self, _cmd, name, obj, userInfo) {
                try {
                    const nameObj = new ObjC.Object(name);
                    const str = nameObj.toString();
                    if (str.toLowerCase().includes('recall') || str.toLowerCase().includes('revoke') || str.toLowerCase().includes('撤回')) {
                        log(`📨 撤回通知: ${str}`);
                        log(`   🥞 栈:\n    ${getStack()}`);
                    }
                } catch (e) {}
                const origFn = new NativeFunction(orig, 'void', ['pointer', 'pointer', 'pointer', 'pointer', 'pointer']);
                origFn(self, _cmd, name, obj, userInfo);
            }, 'void', ['pointer', 'pointer', 'pointer', 'pointer', 'pointer']);

            ObjC.api.method_setImplementation(method, replacement);
            log('[✓] NSNotificationCenter 通知 Hook 成功');
        } else {
            log('[✗] postNotificationName:object:userInfo: 不存在');
        }
    } catch (e) {
        log(`[✗] 通知 Hook 失败: ${e.message}`);
    }
}

// ─────────────────────────────────────────────
// 追踪 objc_msgSend 中带 recall 的调用 (轻量级)
// ─────────────────────────────────────────────
function traceObjcMsgSendRecall() {
    sep('追踪 objc_msgSend (recall 过滤)');

    try {
        const msgSend = Module.findExportByName(null, 'objc_msgSend');
        if (!msgSend) { log('[✗] objc_msgSend 未找到'); return; }

        const symbols = Module.enumerateSymbols('QQ');
        const recallSelectors = new Set();

        // 从 ObjC 类中收集所有 recall 相关 selector
        for (const name in ObjC.classes) {
            try {
                const cls = ObjC.classes[name];
                const methods = cls.$methods;
                for (const m of methods) {
                    if (m.toLowerCase().includes('recall') || m.toLowerCase().includes('revoke')) {
                        recallSelectors.add(m);
                    }
                }
            } catch (e) {}
        }

        log(`找到 ${recallSelectors.size} 个 recall 相关 selector`);

        // 由于 hook objc_msgSend 性能开销大，这里只打印不实际 hook
        log('[i] 要追踪 objc_msgSend 请取消下面代码的注释(高开销)');

        /* // 取消注释以启用 (会显著降低性能)
        Interceptor.attach(msgSend, {
            onEnter(args) {
                const sel = ObjC.selectorName(args[1]);
                if (sel && (sel.toLowerCase().includes('recall') || sel.toLowerCase().includes('revoke'))) {
                    log(`📞 objc_msgSend: ${ObjC.className(args[0])} ${sel}`);
                }
            }
        });
        log('[✓] objc_msgSend recall 追踪已启用');
        */
    } catch (e) {
        log(`[✗] msgSend 追踪失败: ${e.message}`);
    }
}

// ─────────────────────────────────────────────
// 主动扫描: 使用 ObjC.choose 枚举 recall 对象
// ─────────────────────────────────────────────
function chooseRecallObjects() {
    sep('枚举 OCMsgRecallInfo 实例');

    setTimeout(() => {
        try {
            const instances = ObjC.choose(ObjC.classes.OCMsgRecallInfo);
            log(`当前 OCMsgRecallInfo 实例数: ${instances.length}`);
            for (let i = 0; i < Math.min(instances.length, 5); i++) {
                const inst = instances[i];
                try {
                    log(`  实例[${i}]:`);
                    log(`    isRecallNotify: ${inst.isRecallNotify()}`);
                    log(`    isTracelessRecall: ${inst.isTracelessRecall()}`);
                    log(`    recallMsgPeerUid: ${inst.recallMsgPeerUid()}`);
                    log(`    recallMsgSeq: ${inst.recallMsgSeq()}`);
                } catch (e) {
                    log(`    (读取失败: ${e.message})`);
                }
            }
        } catch (e) {
            log(`OCMsgRecallInfo 枚举失败: ${e.message}`);
        }

        // 也枚举 RecallPair
        try {
            const pairs = ObjC.choose(ObjC.classes.RecallPair);
            log(`当前 RecallPair 实例数: ${pairs.length}`);
        } catch (e) {}

        try {
            const notiModels = ObjC.choose(ObjC.classes.RecallNotiAIOModel);
            log(`当前 RecallNotiAIOModel 实例数: ${notiModels.length}`);
        } catch (e) {}
    }, 3000);
}

// ─────────────────────────────────────────────
// 主函数
// ─────────────────────────────────────────────
function main() {
    sep('QQESign Frida 防撤回探索 v4 (底层 API)');
    log(`PID: ${Process.id} | Arch: ${Process.arch}`);

    // 延迟等待 ObjC 运行时加载
    ObjC.schedule(ObjC.mainQueue, () => {
        sep('开始 Hook...');

        // === A. ObjC 传统层 (使用底层 ObjC API) ===
        log('\n--- ObjC 传统层 (底层 API) ---');
        hookInstanceMethod('QQMessageRecallNetEngine',
            'parseC2CRecallNotify:bufferLen:subcmd:model:', 'NetEngine.parseC2C');

        hookInstanceMethod('QQMessageRecallModule',
            'handleSideAccountRecallNotify:bufferLen:subcmd:bindUin:tracelessFlag:', 'RecallModule.sideAccount');
        hookInstanceMethod('QQMessageRecallModule',
            'convertRecallItemToMsg:recallModel:msgType:bindUin:', 'RecallModule.convert');
        hookInstanceMethod('QQMessageRecallModule',
            'getRecallMessageContent:bindUin:', 'RecallModule.getContent');

        // === B. 类方法 (元类) ===
        log('\n--- 类方法 ---');
        hookClassMethod('QQMessageRecallPackageHandler',
            'parseC2CRecallNotify:bufferLen:subcmd:model:', 'PackageHandler.parseC2C');
        hookClassMethod('QQMessageRecallPackageHandler',
            'parseC2CRecallInOut:', 'PackageHandler.parseInOut');

        // === C. OCMsgRecallInfo ===
        log('\n--- OCMsgRecallInfo ---');
        hookInstanceMethod('OCMsgRecallInfo', 'isRecallNotify', 'isRecallNotify');
        hookInstanceMethod('OCMsgRecallInfo', 'setIsRecallNotify:', 'setIsRecallNotify');
        hookInstanceMethod('OCMsgRecallInfo', 'isTracelessRecall', 'isTracelessRecall');
        hookInstanceMethod('OCMsgRecallInfo', 'setIsTracelessRecall:', 'setIsTracelessRecall');

        // === D. RecallPair ===
        log('\n--- RecallPair ---');
        hookInstanceMethod('RecallPair', 'recallModel', 'recallModel');
        hookInstanceMethod('RecallPair', 'setRecallModel:', 'setRecallModel');

        // === E. FARecallMgr ===
        log('\n--- FARecallMgr ---');
        hookInstanceMethod('FARecallMgr', 'recallFAModel:', 'recallFA');
        hookInstanceMethod('FARecallMgr', 'onFARecallResult:error:', 'onFAResult');
        hookInstanceMethod('FARecallMgr', 'onRecvMsgRecallResult:', 'onRecvResult');

        // === F. QQRecallMenuFilter (类方法) ===
        log('\n--- QQRecallMenuFilter ---');
        hookClassMethod('QQRecallMenuFilter', 'isGroupMessageNeedShowMenuRecall:', 'menuFilter.isGroup');
        hookClassMethod('QQRecallMenuFilter', 'needShowRecallBaseImpl:', 'menuFilter.baseImpl');

        // === G. 通知 ===
        log('\n--- 通知系统 ---');
        hookNotifications();

        // === H. 主动枚举 ===
        chooseRecallObjects();

        sep('探索就绪');
        log(`共 Hook ${hookCount} 个方法`);
        log('现在去 QQ 让朋友撤回一条消息，观察输出！');
    });
}

setTimeout(main, 2000);
