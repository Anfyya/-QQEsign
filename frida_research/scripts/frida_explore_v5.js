/*
 * QQESign — Frida 防撤回探索 v5 (动态全量 Hook)
 *
 * 动态枚举所有含 recall/revoke 的 ObjC 方法，逐个 Hook
 * 使用 this.original 模式 (Frida 标准 API)
 */

function log(msg) { console.log(`[QQESign-v5] ${msg}`); }
function sep(title) {
    console.log(`\n${'='.repeat(60)}`);
    console.log(`  ${title}`);
    console.log(`${'='.repeat(60)}`);
}

function getStack(depth) {
    try {
        return Thread.backtrace(this.context, Backtracer.ACCURATE)
            .map(DebugSymbol.fromAddress)
            .slice(0, depth || 20)
            .join('\n    ');
    } catch (e) { return '(no stack)'; }
}

function describeArg(arg, maxLen) {
    maxLen = maxLen || 150;
    if (arg === null) return 'null';
    if (arg === undefined) return 'undefined';
    try {
        if (arg.$className) {
            let desc = '';
            try { desc = arg.toString(); } catch (e) {}
            if (desc && desc.length > maxLen) desc = desc.substring(0, maxLen) + '...';
            // 如果是 NSString，显示内容
            if (arg.$className === '__NSCFString' || arg.$className === 'NSTaggedPointerString' || arg.$className === 'NSString' || arg.$className === '__NSCFConstantString') {
                return `"${desc}"`;
            }
            return `[${arg.$className}] ${desc}`;
        }
        return String(arg).substring(0, maxLen);
    } catch (e) { return `(err)`; }
}

// ─────────────────────────────────────────────
// 动态 Hook 一个类上的所有 recall 方法
// ─────────────────────────────────────────────
let hookCount = 0;

function hookAllRecallMethodsOnClass(className) {
    try {
        const cls = ObjC.classes[className];
        if (!cls) {
            // 可能类名没有正确映射，尝试直接使用 objc_getClass
            const clsPtr = ObjC.api.objc_getClass(className);
            if (clsPtr.isNull()) {
                return; // 类不存在，跳过
            }
            log(`[i] 类 ${className} 存在但无法通过 ObjC.classes 访问`);
            return;
        }

        const recallMethods = [];
        try {
            const methods = cls.$methods;
            for (const m of methods) {
                if (m.toLowerCase().includes('recall') || m.toLowerCase().includes('revoke')) {
                    recallMethods.push(m);
                }
            }
            // 也检查 class methods
            try {
                const classMethods = cls.$class.$methods;
                for (const m of classMethods) {
                    if ((m.toLowerCase().includes('recall') || m.toLowerCase().includes('revoke')) && !recallMethods.includes(m)) {
                        recallMethods.push('+ ' + m);
                    }
                }
            } catch (e) {}
        } catch (e) {
            return;
        }

        if (recallMethods.length === 0) return;

        console.log(`\n  📦 ${className} (${recallMethods.length} 方法):`);

        for (const fullSel of recallMethods) {
            const isClassMethod = fullSel.startsWith('+ ');
            const selName = isClassMethod ? fullSel.slice(2) : fullSel;
            const target = isClassMethod ? cls.$class : cls;
            const typeLabel = isClassMethod ? '+' : '-';
            const tag = `${className} ${typeLabel}[${selName}]`;

            try {
                const method = target[selName];
                if (!method || !method.implementation) {
                    console.log(`     ⚠️  ${tag} — 无法访问`);
                    continue;
                }

                const orig = method.implementation;

                method.implementation = function () {
                    const args = Array.from(arguments);
                    log(`🔧 ${tag}`);
                    for (let i = 0; i < args.length; i++) {
                        log(`   a[${i}]: ${describeArg(args[i])}`);
                    }
                    log(`   🥞 栈:\n    ${getStack()}`);
                    return orig.apply(this, args);
                };

                console.log(`     ✓ ${tag}`);
                hookCount++;
            } catch (e) {
                console.log(`     ✗ ${tag}: ${e.message}`);
            }
        }
    } catch (e) {
        // 忽略无法处理的类
    }
}

// ─────────────────────────────────────────────
// 主扫描循环
// ─────────────────────────────────────────────
function scanAndHook() {
    sep('扫描并 Hook 所有 recall 相关类');

    // 先扫描所有 ObjC 类
    let foundClasses = [];
    for (const name in ObjC.classes) {
        const lower = name.toLowerCase();
        if (lower.includes('recall') || lower.includes('revoke') || lower.includes('撤回')) {
            foundClasses.push(name);
        }
    }

    // 按名称长度排序，短的先处理
    foundClasses.sort((a, b) => a.length - b.length);

    log(`发现 ${foundClasses.length} 个 recall 相关类`);

    for (const name of foundClasses) {
        hookAllRecallMethodsOnClass(name);
    }

    // 额外扫描特定模块中的类 (即使类名不含 recall)
    const extraModules = ['NTAIOChat', 'NTKernelAdapter', 'NTBaseAIO', 'AIOPhotoBrowser', 'GuildNTKernel'];
    for (const name in ObjC.classes) {
        for (const mod of extraModules) {
            if (name.includes(mod)) {
                // 只处理还未处理过的类
                if (!foundClasses.includes(name)) {
                    hookAllRecallMethodsOnClass(name);
                }
                break;
            }
        }
    }

    log(`\n📊 共 Hook ${hookCount} 个 recall 相关方法`);
}

// ─────────────────────────────────────────────
// 额外: Hook NSNotificationCenter
// ─────────────────────────────────────────────
function hookNotificationCenter() {
    try {
        const nc = ObjC.classes.NSNotificationCenter;
        const method = nc['postNotificationName:object:userInfo:'];
        if (method) {
            const orig = method.implementation;
            method.implementation = function () {
                const args = Array.from(arguments);
                try {
                    const nameObj = args[0];
                    if (nameObj && typeof nameObj.toString === 'function') {
                        const str = nameObj.toString();
                        if (str.toLowerCase().includes('recall') || str.toLowerCase().includes('revoke')) {
                            log(`📨 通知: ${str}`);
                            log(`   🥞 栈:\n    ${getStack()}`);
                        }
                    }
                } catch (e) {}
                return orig.apply(this, args);
            };
            log('[✓] NSNotificationCenter Hook 成功');
        } else {
            log('[✗] NSNotificationCenter 方法不可用');
        }
    } catch (e) {
        log(`[✗] 通知 Hook 失败: ${e.message}`);
    }
}

// ─────────────────────────────────────────────
// 额外: Hook OCRevokeElement 的创建
// ─────────────────────────────────────────────
function hookRevokeElement() {
    try {
        const cls = ObjC.classes.OCRevokeElement;
        if (!cls) { log('[✗] OCRevokeElement 不可用'); return; }

        const methods = cls.$methods;
        for (const m of methods) {
            if (m.startsWith('init') || m.startsWith('RevokeElement')) {
                try {
                    const method = cls[m];
                    if (method && method.implementation) {
                        const orig = method.implementation;
                        hookCount++;
                        method.implementation = function () {
                            const ret = orig.apply(this, arguments);
                            log(`🔧 OCRevokeElement +[${m}] 被调用，创建了撤回元素`);
                            log(`   🥞 栈:\n    ${getStack()}`);
                            try {
                                const obj = ret || this;
                                if (obj && obj.$className) {
                                    log(`   对象: [${obj.$className}]`);
                                }
                            } catch (e) {}
                            return ret;
                        };
                        log(`[✓] OCRevokeElement +[${m}]`);
                    }
                } catch (e) {
                    log(`[✗] OCRevokeElement +[${m}]: ${e.message}`);
                }
            }
        }
    } catch (e) {
        log(`[✗] OCRevokeElement Hook 失败: ${e.message}`);
    }
}

// ─────────────────────────────────────────────
// 追踪 C++ 层
// ─────────────────────────────────────────────
function hookCppSymbols() {
    sep('搜索 C++ recall 符号');

    try {
        const modules = Process.enumerateModules();
        const qqModule = modules.find(m => m.path.includes('QQ.app/QQ') && m.path.endsWith('QQ'));
        if (!qqModule) { log('[✗] QQ 模块未找到'); return; }

        const symbols = Module.enumerateSymbols(qqModule.path);
        let found = 0;

        for (const sym of symbols) {
            const name = sym.name;
            if (name.includes('recall') || name.includes('Recall') || name.includes('Revoke') || name.includes('revoke')) {
                if (name.includes('MsgRecall') || name.includes('KernelMsg') ||
                    name.includes('MessageService') || name.includes('RecallMsg')) {
                    console.log(`  🔧 ${name}`);
                    try {
                        Interceptor.attach(sym.address, {
                            onEnter(args) {
                                log(`🔧 [C++] ${name}`);
                                log(`   🥞 栈:\n    ${getStack()}`);
                            }
                        });
                        console.log(`     ✓ Hook 成功`);
                        found++;
                    } catch (e) {
                        console.log(`     ✗ ${e.message}`);
                    }
                }
            }
        }
        log(`共 Hook ${found} 个 C++ 符号`);
    } catch (e) {
        log(`[✗] C++ 搜索失败: ${e.message}`);
    }
}

// ─────────────────────────────────────────────
// 启动 - 分阶段执行
// ─────────────────────────────────────────────
sep('QQESign Frida 防撤回探索 v5');
log(`PID: ${Process.id} | Arch: ${Process.arch}`);

// 阶段 1: 先等待 ObjC 初始化
ObjC.schedule(ObjC.mainQueue, () => {
    // 阶段 2: Hook ObjC 层
    scanAndHook();

    // 阶段 3: 通知中心
    log('\n--- 通知中心 ---');
    hookNotificationCenter();

    // 阶段 4: RevokeElement
    log('\n--- OCRevokeElement ---');
    hookRevokeElement();

    // 阶段 5: C++ 符号
    hookCppSymbols();

    // 阶段 6: 定期报告
    setInterval(() => {
        log(`[心跳] 已 Hook ${hookCount} 个方法，等待撤回事件...`);
    }, 30000);

    sep('探索就绪');
    log(`已 Hook ${hookCount} 个方法`);
    log('现在请让朋友在 QQ 中撤回一条消息！');
});
