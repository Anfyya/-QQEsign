"""QQESign 防撤回 Python Frida 脚本——直接调用 ObjC runtime C API 做 Hook"""
import frida
import sys

JS_CODE = r"""
const log = (m) => send(`[${m}]`);

// 等待 ObjC 就绪 (Python spawn 环境下需要)
function waitForObjC(cb) {
    if (typeof ObjC !== 'undefined' && ObjC.available) {
        log('ObjC 已就绪');
        cb();
        return;
    }
    log('等待 ObjC...');
    setTimeout(() => waitForObjC(cb), 1000);
}

waitForObjC(() => {
let callLog = [];

// 获取 QQ 模块的符号表
setTimeout(() => {
    const mods = Process.enumerateModules();
    const qqMod = mods.find(m => m.path.includes('QQ.app') && m.path.endsWith('QQ'));
    
    if (!qqMod) { log('❌ 找不到QQ模块'); return; }
    log(`QQ模块: ${qqMod.name} 基址=${qqMod.base} 大小=${(qqMod.size/1024/1024).toFixed(1)}MB`);
    
    // 尝试用已知的 C++ mangled names 查找符号
    const cppSyms = [
        '__ZN2nt7wrapper16KernelMsgService24recallMsgFromC2CAndGroupEPNS_13MsgRecallItemEiiPS2_',
        '_ZN2nt7wrapper16KernelMsgService24recallMsgFromC2CAndGroupEPNS_13MsgRecallItemEiiPS2_',
        '_ZN2nt7wrapper16KernelMsgService20getRecallMsgsByMsgIdESt6vectorINS0_10MsgKeyTypeESaIS4_EENSt3__18functionIFvNS_13MsgRecallItemEiEEE',
        '__ZN12MsgRecallMgr8RecallMsgERKSt10shared_ptrIN2nt7wrapper15MsgRecallItemEE',
        '_ZN12MsgRecallMgr8RecallMsgERKNSt3__110shared_ptrIN2nt7wrapper15MsgRecallItemEEE',
        'recallMsgFromC2CAndGroup',
        'getRecallMsgsByMsgId',
        'MsgRecallMgr',
        '_ZN2nt7wrapper16KernelMsgService',
        '_ZN12MsgRecallMgr',
        '_ZN9MsgRecall',
        '_ZN9RecallMsg',
    ];
    
    let foundCpp = 0;
    for (const sym of cppSyms) {
        try {
            const addr = qqMod.getExportByName(sym);
            if (addr) {
                log(`✅ C++符号: ${sym} @ ${addr}`);
                Interceptor.attach(addr, {
                    onEnter(args) {
                        log(`🚫 [C++] ${sym} 被调用!`);
                        try {
                            const bt = Thread.backtrace(this.context, Backtracer.ACCURATE)
                                .map(DebugSymbol.fromAddress).slice(0, 20).join('\n    ');
                            log(`  栈:\n    ${bt}`);
                        } catch(e) {}
                        // 返回 0 尝试阻止
                        this.context.x0 = ptr(0);
                    }
                });
                foundCpp++;
            }
        } catch(e) {}
    }
    
    if (foundCpp === 0) {
        log('⚠️ 未找到C++符号。尝试用DebugSymbol扫描...');
        
        // 扫描QQ二进制中所有recall/revoke相关导出
        try {
            // 方法：读取 __TEXT 段扫描字符串引用
            const ranges = qqMod.enumerateRanges('r--');
            let cstringRange = null;
            for (const r of ranges) {
                if (r.name && r.name.includes('__cstring')) {
                    cstringRange = r;
                    break;
                }
            }
            
            if (cstringRange) {
                log(`找到 __cstring 段: ${cstringRange.base} 大小=${(cstringRange.size/1024).toFixed(0)}KB`);
                // 扫描前64KB的cstring找recall关键词
                const buf = cstringRange.base.readByteArray(Math.min(cstringRange.size, 65536));
                if (buf) {
                    const arr = new Uint8Array(buf);
                    let strs = [];
                    let start = -1;
                    for (let i = 0; i < arr.length; i++) {
                        if (arr[i] >= 0x20 && arr[i] < 0x7f) {
                            if (start === -1) start = i;
                        } else {
                            if (start !== -1 && i - start >= 4) {
                                const s = String.fromCharCode.apply(null, arr.slice(start, i));
                                const ls = s.toLowerCase();
                                if (ls.includes('recall') || ls.includes('revoke')) {
                                    strs.push({str: s, offset: start});
                                }
                            }
                            start = -1;
                        }
                    }
                    
                    log(`找到 ${strs.length} 个recall/revoke字符串引用`);
                    strs.forEach(s => {
                        log(`  "${s.str}" @ offset ${s.offset}`);
                    });
                    
                    // 在text段中找引用这些字符串的代码
                    if (strs.length > 0 && qqMod.base) {
                        const textRanges = qqMod.enumerateRanges('r-x');
                        log(`可执行段: ${textRanges.length}个`);
                    }
                }
            }
        } catch(e) {
            log(`扫描异常: ${e.message}`);
        }
    }
    
    // Hook ObjC 类构造方法
    try {
        // Hook OCRevokeElement 构造器 (已知存在)
        const ocRevokeCls = ObjC.classes.OCRevokeElement;
        if (ocRevokeCls) {
            const sel = '+ RevokeElementWithOperatorTinyId:operatorRole:operatorUid:operatorNick:operatorRemark:operatorMemRemark:origMsgSenderUid:origMsgSenderNick:origMsgSenderRemark:origMsgSenderMemRemark:isSelfOperate:wording:';
            const m = ocRevokeCls[sel];
            if (m && m.implementation) {
                const cb = new NativeCallback(function() {
                    log('🚫 OCRevokeElement 完整构造器被调用!');
                    // 阻止构造
                    return null;
                }, 'pointer', ['pointer', 'pointer']);
                m.implementation = cb;
                log('✅ OCRevokeElement 完整构造器已拦截');
            }
        }
    } catch(e) { log(`OCRevokeElement err: ${e.message}`); }
    
    // 监控所有 OCMsgRecallInfo 的方法调用
    try {
        const ocRecallCls = ObjC.classes.OCMsgRecallInfo;
        if (ocRecallCls) {
            const methods = ocRecallCls.$methods;
            log(`OCMsgRecallInfo 共 ${methods.length} 个方法`);
            
            // Hook 所有 setter
            let hooked = 0;
            for (const m of methods) {
                if (m.startsWith('- set') && m.toLowerCase().includes('recall')) {
                    try {
                        const method = ocRecallCls[m];
                        if (method && method.implementation) {
                            const orig = method.implementation;
                            const cb = new NativeCallback(function() {
                                log(`🚫 OCMsgRecallInfo.${m} 被调用! 已阻止`);
                                // 不调 orig，直接返回
                            }, 'void', ['pointer', 'pointer']);
                            method.implementation = cb;
                            hooked++;
                        }
                    } catch(e) {}
                }
            }
            log(`OCMsgRecallInfo 已Hook ${hooked} 个setter`);
        }
    } catch(e) { log(`OCMsgRecallInfo err: ${e.message}`); }
    
    // 更重要的：hook NSNotification 用于观察
    try {
        const ncCls = ObjC.classes.NSNotificationCenter;
        const sel = '- postNotificationName:object:userInfo:';
        const m = ncCls[sel];
        if (m && m.implementation) {
            const orig = m.implementation;
            const cb = new NativeCallback(function(self, cmd, name, obj, info) {
                try {
                    const nameObj = new ObjC.Object(name);
                    const nameStr = nameObj.toString();
                    const lower = nameStr.toLowerCase();
                    if (lower.includes('recall') || lower.includes('revoke') || 
                        lower.includes('delete') || lower.includes('remove') ||
                        lower.includes('update') || lower.includes('change') ||
                        lower.includes('refresh') || lower.includes('reload') ||
                        lower.includes('modified') || lower.includes('msg')) {
                        // 记录所有可能相关的通知
                        log(`📨 通知: ${nameStr}`);
                        callLog.push({time: Date.now(), type: 'notif', name: nameStr});
                    }
                } catch(e) {}
                const origFn = new NativeFunction(orig, 'void', ['pointer', 'pointer', 'pointer', 'pointer', 'pointer']);
                origFn(self, cmd, name, obj, info);
            }, 'void', ['pointer', 'pointer', 'pointer', 'pointer', 'pointer']);
            m.implementation = cb;
            log('✅ NSNotificationCenter 监控已安装');
        }
    } catch(e) { log(`NSNotification err: ${e.message}`); }
    
    log('========================================');
    log('所有Hook已安装。请撤回消息测试。');
    log('========================================');
    
    // 每15秒报告状态
    setInterval(() => {
        const recallHits = callLog.filter(c => 
            c.name && (c.name.toLowerCase().includes('recall') || c.name.toLowerCase().includes('revoke'))
        );
        if (callLog.length > 0) {
            log(`[心跳] 累计捕获 ${callLog.length} 个通知, 其中 ${recallHits.length} 个recall相关`);
            // 打印最近的callLog
            const recent = callLog.slice(-5);
            recent.forEach(c => log(`  ${c.name}`));
        }
    }, 15000);
    
}, 8000);
"""

def on_message(message, data):
    print(message['payload'] if 'payload' in message else str(message))

def main():
    device = frida.get_usb_device()
    pid = device.spawn(["com.tencent.mqq"])
    session = device.attach(pid)
    script = session.create_script(JS_CODE)
    script.on('message', on_message)
    script.load()
    device.resume(pid)
    
    print("防撤回脚本已注入。按 Ctrl+C 停止...")
    try:
        sys.stdin.read()
    except KeyboardInterrupt:
        print("\n停止监控")
        session.detach()

if __name__ == "__main__":
    main()
