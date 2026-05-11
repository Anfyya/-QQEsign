// 直接扫 QQ 主程序所有导出符号，找 recall/revoke 相关 C++ 函数并 Hook
const log = (m) => console.log(`[CPP] ${m}`);

setTimeout(function() {
    const mod = Process.enumerateModules().find(function(m) {
        return m.path.includes('QQ.app') && m.path.endsWith('QQ');
    });
    if (!mod) { log('找不到 QQ 主模块'); return; }
    
    log('模块: ' + mod.path);
    log('基址: ' + mod.base);
    log('大小: ' + (mod.size / 1024 / 1024).toFixed(1) + ' MB');
    
    // 枚举所有符号
    const syms = Module.enumerateSymbols(mod.path);
    log('总符号数: ' + syms.length);
    
    var found = [];
    for (var i = 0; i < syms.length; i++) {
        var n = syms[i].name.toLowerCase();
        if (n.includes('recall') || n.includes('revoke')) {
            found.push(syms[i]);
        }
    }
    
    log('recall/revoke 相关符号: ' + found.length);
    
    // 打印所有找到的
    for (var i = 0; i < found.length; i++) {
        console.log('  [' + i + '] ' + found[i].name + ' @ ' + found[i].address);
        
        // 尝试 Hook
        try {
            Interceptor.attach(found[i].address, {
                onEnter: function(args) {
                    log('🚫 命中 C++: ' + this.name);
                    log('   地址: ' + this.addr);
                    try {
                        var bt = Thread.backtrace(this.context, Backtracer.ACCURATE)
                            .map(DebugSymbol.fromAddress)
                            .slice(0, 15)
                            .join('\n    ');
                        log('   栈:\n    ' + bt);
                    } catch(e) {}
                }.bind({name: found[i].name, addr: found[i].address})
            });
            console.log('    ✅ Hook 成功');
        } catch(e) {
            console.log('    ❌ Hook 失败: ' + e.message);
        }
    }
    
    log('扫描完成。让朋友撤回消息测试。');
}, 10000);
