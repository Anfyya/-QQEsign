var log = function(m) { console.log('[MSG] ' + m); };

// 从 libobjc 模块获取 objc_msgSend
var objc_msgSend = null;
var mods = Process.enumerateModules();
for (var i = 0; i < mods.length; i++) {
    if (mods[i].name.indexOf('libobjc') !== -1 || mods[i].path.indexOf('libobjc') !== -1) {
        objc_msgSend = mods[i].getExportByName('objc_msgSend');
        if (objc_msgSend) break;
    }
}
// fallback: try all modules
if (!objc_msgSend) {
    for (var j = 0; j < mods.length; j++) {
        objc_msgSend = mods[j].getExportByName('objc_msgSend');
        if (objc_msgSend) break;
    }
}

if (!objc_msgSend) { log('❌ objc_msgSend not found'); } else {
    log('objc_msgSend @ ' + objc_msgSend);
    
    Interceptor.attach(objc_msgSend, {
        onEnter: function(args) {
            var sel = args[1];
            var name = '';
            try { name = ObjC.selectorAsString(sel); } catch(e) {}
            if (name) {
                var l = name.toLowerCase();
                if (l.indexOf('recall') !== -1 || l.indexOf('revoke') !== -1) {
                    log('🚫 msgSend: ' + name);
                    try {
                        var bt = Thread.backtrace(this.context, Backtracer.ACCURATE)
                            .map(DebugSymbol.fromAddress).slice(0,10).join('\n    ');
                        log('   栈:\n    ' + bt);
                    } catch(e) {}
                }
            }
        }
    });
    
    log('✅ recall msgSend 监控就绪。撤回消息测试。');
}
