// Hook所有可能的TLS解密入口，定位QQ实际用的API
var log = function(m) { console.log('[SSL] ' + m); };
var mods = Process.enumerateModules();

// 候选TLS API列表
var targets = [
    'SSLRead',           // Security.framework (Secure Transport)
    'SSLWrite',
    'nw_connection_receive',  // Network.framework  
    'nw_connection_receive_message',
    'nw_read_request_data',
    'nw_frame_receive',
    'sec_protocol_metadata_get_early_data_accepted',
    'tls_handshake_process',
    'boringssl_ssl_read',
    'boringssl_ssl_write',
];

var hooked = 0;
for (var ti = 0; ti < targets.length; ti++) {
    var name = targets[ti];
    for (var i = 0; i < mods.length; i++) {
        try {
            var addr = mods[i].getExportByName(name);
            if (addr) {
                try {
                    Interceptor.attach(addr, {
                        onEnter: function(args) {
                            this.name = this.hookName;
                            this.hits = (this.hits || 0) + 1;
                            if (this.hits <= 3 || this.hits % 100 === 0) {
                                log('✅ ' + this.name + ' 被调用! (#' + this.hits + ')');
                            }
                        },
                        onLeave: function(retval) {
                            if (this.hits <= 3) {
                                log('   返回: ' + retval);
                            }
                        }
                    }.bind({hookName: name}));
                    log('✅ ' + mods[i].name + '::' + name + ' @ ' + addr);
                    hooked++;
                } catch(e) {
                    log('❌ ' + name + ': ' + e.message);
                }
                break;
            }
        } catch(e) {}
    }
}

log('共Hook ' + hooked + ' 个TLS API: ' + targets.slice(0, hooked).join(', '));
log('撤回消息后看终端，找到被调用的TLS API。');
