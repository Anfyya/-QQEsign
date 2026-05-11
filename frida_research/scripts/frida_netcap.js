// 抓取recv数据包，只记录最近的数据，撤回时打印上下文
var log = function(m) { console.log('[CAP] ' + m); };
var mods = Process.enumerateModules();
var recvPtr = null;
for (var i = 0; i < mods.length; i++) { recvPtr = mods[i].getExportByName('recv'); if (recvPtr) break; }

// 环形缓冲区存最近1000个包
var BUFSIZE = 1000;
var ringBuf = [];
var ringIdx = 0;
var totalPkts = 0;

function hexify(arr, maxLen) {
    var s = '';
    var len = Math.min(arr.length, maxLen || 64);
    for (var i = 0; i < len; i++) {
        if (i % 16 === 0 && i > 0) s += '\n';
        s += ('0' + arr[i].toString(16)).slice(-2) + ' ';
    }
    return s;
}

function toAscii(arr, maxLen) {
    var s = '';
    var len = Math.min(arr.length, maxLen || 256);
    for (var i = 0; i < len; i++) {
        if (arr[i] >= 0x20 && arr[i] < 0x7f) s += String.fromCharCode(arr[i]);
        else s += '.';
        if ((i+1) % 64 === 0) s += '\n';
    }
    return s;
}

if (!recvPtr) { log('recv not found'); } else {
    log('watching recv...');
    Interceptor.attach(recvPtr, {
        onEnter: function(args) {
            this.fd = args[0].toInt32();
            this.buf = args[1];
            this.len = Math.min(args[2].toInt32(), 65536);
        },
        onLeave: function(retval) {
            var n = retval.toInt32();
            if (n <= 32 || n > 65536 || this.fd < 3) return;
            
            totalPkts++;
            try {
                var data = this.buf.readByteArray(Math.min(n, 512));
                if (!data) return;
                var arr = new Uint8Array(data);
                
                // 存储到环形缓冲区
                ringBuf[ringIdx] = {
                    fd: this.fd,
                    size: n,
                    time: Date.now(),
                    hex: hexify(arr, 64),
                    txt: toAscii(arr, 128).substring(0, 100)
                };
                ringIdx = (ringIdx + 1) % BUFSIZE;
                
                // 每100次打印心跳
                if (totalPkts % 100 === 0) {
                    log('[' + totalPkts + '] fd=' + this.fd + ' size=' + n + ' 最新hex: ' + ringBuf[(ringIdx-1+BUFSIZE)%BUFSIZE].hex.substring(0, 80));
                }
            } catch(e) {}
        }
    });
}

// 提供一个RPC接口让Python侧触发dump
rpc.exports = {
    dump: function() {
        log('=== 最近30个包 ===');
        var start = (ringIdx - 30 + BUFSIZE) % BUFSIZE;
        for (var i = 0; i < 30; i++) {
            var idx = (start + i) % BUFSIZE;
            var pkt = ringBuf[idx];
            if (!pkt) continue;
            log('[' + pkt.time + '] fd=' + pkt.fd + ' size=' + pkt.size);
            log('  hex: ' + pkt.hex.substring(0, 200));
            log('  txt: ' + pkt.txt);
        }
        log('=== end dump ===');
    },
    
    stats: function() {
        log('Total packets: ' + totalPkts + ', buffer: ' + (ringBuf.filter(function(x){return !!x;}).length));
    }
};

setTimeout(function() { log('抓包就绪。撤回消息后回来看终端。'); }, 5000);
