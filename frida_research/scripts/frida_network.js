// Hook recv 监控 QQ 网络数据流
var log = function(m) { console.log('[NET] ' + m); };
var recvCount = 0, recallHits = 0;

// 找到 recv 和 recvfrom
var mods = Process.enumerateModules();
var recvPtr = null;
for (var i = 0; i < mods.length; i++) {
    if (!recvPtr) recvPtr = mods[i].getExportByName('recv');
    if (recvPtr) break;
}

if (!recvPtr) { log('recv not found'); } else {
    log('recv @ ' + recvPtr);
    
    // 记录 QQ 的线程ID用于快速过滤
    var qqPid = Process.id;
    
    // Hook recv - 监控所有数据
    Interceptor.attach(recvPtr, {
        onEnter: function(args) {
            this.fd = args[0].toInt32();
            this.buf = args[1];
            this.len = args[2].toInt32();
        },
        onLeave: function(retval) {
            var nread = retval.toInt32();
            if (nread <= 0 || nread > 524288) return; // 忽略错误和超大包
            
            recvCount++;
            
            // 每1000次打印一次统计
            if (recvCount % 1000 === 0) {
                log('已监控 ' + recvCount + ' 次recv, ' + recallHits + ' 次recall命中');
            }
            
            // 读取数据检查是否有recall相关Protobuf tag
            try {
                var data = this.buf.readByteArray(Math.min(nread, 2048));
                if (!data) return;
                var arr = new Uint8Array(data);
                
                // Protobuf recall标志:
                // QQ协议中撤回通知通过特定cmd/subcmd标识
                // 常见模式: 0x08 (varint field 1) + cmd值, 0x10 (varint field 2) + subcmd值
                // 撤回cmd通常为 0x210 (528) 或 0x3f6 (1014)
                
                var hex = '';
                var ascii = '';
                var limit = Math.min(arr.length, 256);
                for (var j = 0; j < limit; j++) {
                    var b = arr[j];
                    // 查找recall/revoke ASCII字符串
                    if (b >= 0x20 && b < 0x7f) hex += String.fromCharCode(b);
                    else hex += '.';
                }
                
                // 检查是否包含recall相关的unicode/ASCII
                var check = '';
                for (var j = 0; j < arr.length; j++) {
                    if (arr[j] >= 0x20 && arr[j] < 0x7f) check += String.fromCharCode(arr[j]);
                    else check += ' ';
                }
                
                var lower = check.toLowerCase();
                if (lower.indexOf('recall') !== -1 || lower.indexOf('revoke') !== -1 ||
                    lower.indexOf('msgrecall') !== -1 || lower.indexOf('recallmsg') !== -1 ||
                    lower.indexOf('recall_notify') !== -1 || lower.indexOf('recallnotify') !== -1) {
                    recallHits++;
                    log('🚫 RECALL PACKET DETECTED! nread=' + nread);
                    log('   fd=' + this.fd);
                    
                    // 打印hex dump
                    var hexdump = '';
                    for (var j = 0; j < Math.min(arr.length, 128); j++) {
                        if (j % 16 === 0) hexdump += '\n    ' + ('0000' + j.toString(16)).slice(-4) + ': ';
                        hexdump += ('0' + arr[j].toString(16)).slice(-2) + ' ';
                    }
                    log('   hex:' + hexdump);
                    
                    // 打印ASCII
                    var partial = check.substring(0, 200);
                    log('   txt: ' + partial);
                    
                    // ★ 尝试阻止：清空缓冲区
                    try {
                        this.buf.writeByteArray(new ArrayBuffer(nread)); // zero out
                        retval.replace(ptr(0)); // 返回0字节
                        log('   ⚡ 已清空数据包！');
                    } catch(e) {
                        log('   ❌ 清空失败: ' + e.message);
                    }
                }
            } catch(e) {}
        }
    });
    
    log('recv监控就绪。撤回消息测试。');
}

// 额外：Hook CFReadStreamRead (NSStream层)
var cfReadStreamRead = null;
for (var i = 0; i < mods.length; i++) {
    if (!cfReadStreamRead) cfReadStreamRead = mods[i].getExportByName('CFReadStreamRead');
    if (cfReadStreamRead) break;
}
if (cfReadStreamRead) {
    log('CFReadStreamRead @ ' + cfReadStreamRead);
    Interceptor.attach(cfReadStreamRead, {
        onEnter: function(args) {
            this.stream = args[0];
            this.buf = args[1];
            this.len = args[2].toInt32();
        },
        onLeave: function(retval) {
            var nread = retval.toInt32();
            if (nread <= 0 || nread > 524288) return;
            try {
                var data = this.buf.readByteArray(Math.min(nread, 2048));
                if (!data) return;
                var arr = new Uint8Array(data);
                var check = '';
                for (var j = 0; j < Math.min(arr.length, 500); j++) {
                    if (arr[j] >= 0x20 && arr[j] < 0x7f) check += String.fromCharCode(arr[j]);
                    else check += ' ';
                }
                var lower = check.toLowerCase();
                if (lower.indexOf('recall') !== -1 || lower.indexOf('revoke') !== -1) {
                    log('🚫 CFReadStream RECALL! nread=' + nread);
                }
            } catch(e) {}
        }
    });
}

// 额外：枚举 QQ 使用的 socket fd
setTimeout(function() {
    log('尝试枚举QQ socket连接...');
    // 遍历可能的fd范围
    for (var fd = 3; fd < 256; fd++) {
        try {
            var buf = Memory.alloc(256);
            var getpeername = null;
            for (var i = 0; i < mods.length; i++) {
                getpeername = mods[i].getExportByName('getpeername');
                if (getpeername) break;
            }
            if (!getpeername) continue;
            
            var addr = Memory.alloc(128);
            var addrlen = Memory.alloc(4);
            addrlen.writeInt(128);
            var getpeernameFn = new NativeFunction(getpeername, 'int', ['int', 'pointer', 'pointer']);
            var ret = getpeernameFn(fd, addr, addrlen);
            if (ret === 0) {
                // 解析IP地址
                var family = addr.readU16();
                if (family === 2) { // AF_INET
                    var port = addr.add(2).readU16();
                    port = ((port & 0xFF) << 8) | ((port >> 8) & 0xFF); // ntohs
                    var ip = addr.add(4).readByteArray(4);
                    if (ip) {
                        var ipBytes = new Uint8Array(ip);
                        log('  QQ socket fd=' + fd + ' → ' + ipBytes[0] + '.' + ipBytes[1] + '.' + ipBytes[2] + '.' + ipBytes[3] + ':' + port);
                    }
                }
            }
        } catch(e) {}
    }
}, 8000);
