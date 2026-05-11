// 所有方式尝试 Hook SSLRead
var log = function(m) { console.log('[SSL] ' + m); };

// 方法1: 各模块 getExportByName
var sslRead = null;
var mods = Process.enumerateModules();
for (var i = 0; i < mods.length; i++) {
    try {
        var a = mods[i].getExportByName('SSLRead');
        if (a) { sslRead = a; log('找到 SSLRead: ' + mods[i].name + ' @ ' + a); break; }
    } catch(e) {}
}

// 方法2: DebugSymbol
if (!sslRead) {
    try {
        sslRead = DebugSymbol.fromName('SSLRead');
        if (sslRead) log('DebugSymbol: ' + sslRead);
    } catch(e) {}
}
// 方法3: 直接 dlsym
if (!sslRead) {
    try {
        var dlsym = null;
        for (var i = 0; i < mods.length; i++) {
            dlsym = mods[i].getExportByName('dlsym');
            if (dlsym) break;
        }
        if (dlsym) {
            var dlopen = null;
            for (var i = 0; i < mods.length; i++) {
                dlopen = mods[i].getExportByName('dlopen');
                if (dlopen) break;
            }
            if (dlopen) {
                var dlopenFn = new NativeFunction(dlopen, 'pointer', ['pointer', 'int']);
                var dlsymFn = new NativeFunction(dlsym, 'pointer', ['pointer', 'pointer']);
                var path = Memory.allocUtf8String('/System/Library/Frameworks/Security.framework/Security');
                var h = dlopenFn(path, 10); // RTLD_NOW|RTLD_GLOBAL
                if (!h.isNull()) {
                    var name = Memory.allocUtf8String('SSLRead');
                    sslRead = dlsymFn(h, name);
                    if (!sslRead.isNull()) log('dlsym SSLRead: ' + sslRead);
                    else sslRead = null;
                }
            }
        }
    } catch(e) { log('dlsym err: ' + e.message); }
}

if (!sslRead) { log('❌ 所有方法都无法找到SSLRead'); } else {
    log('SSLRead @ ' + sslRead);
    
    // Hook SSLRead - 监控所有TLS解密后数据
    Interceptor.attach(sslRead, {
        onEnter: function(args) {
            this.ctx = args[0];
            this.dataPtr = args[1];
            this.dataLen = args[2].toInt32();
            this.processedPtr = args[3];
        },
        onLeave: function(retval) {
            try {
                if (retval.toInt32() !== 0) return;
                var processed = this.processedPtr.readPointer().toUInt32();
                if (processed === 0 || processed > 524288) return;
                
                var buf = this.dataPtr.readByteArray(Math.min(processed, 512));
                if (!buf) return;
                var arr = new Uint8Array(buf);
                
                for (var i = 0; i + 2 < arr.length; i++) {
                    if (arr[i] === 0x08) {
                        var cmd = 0, shift = 0, j = i + 1;
                        while (j < arr.length && (arr[j] & 0x80) && shift < 28) {
                            cmd |= (arr[j] & 0x7F) << shift; shift += 7; j++;
                        }
                        if (j < arr.length) cmd |= (arr[j] & 0x7F) << shift;
                        
                        if (cmd === 0x210 || cmd === 0x211) {
                            log('🚫 撤回包! cmd=0x' + cmd.toString(16) + ' sz=' + processed);
                            // 清空缓冲区
                            var p = this.dataPtr;
                            for (var k = 0; k < processed; k++) { try { p.add(k).writeU8(0); } catch(e) {} }
                            // processed 置 0
                            try { this.processedPtr.writePointer(ptr(0)); } catch(e) {}
                            return;
                        }
                    }
                }
                
                if ((this.count = (this.count || 0) + 1) % 500 === 0) {
                    log('监控 ' + this.count + ' 次SSLRead, 无撤回');
                }
            } catch(e) { /* silently ignore per-packet errors */ }
        }
    });
    
    log('✅ SSLRead 监控就绪。撤回消息测试！');
}
