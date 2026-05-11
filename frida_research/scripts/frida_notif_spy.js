// 监控 NSNotificationCenter + 关键消息处理类的所有方法调用
var log = function(m) { console.log('[SPY] ' + m); };
var hits = [];
var startTime = Date.now();

// 1. Hook NSNotificationCenter postNotificationName:object:userInfo:
try {
    var nc = ObjC.classes.NSNotificationCenter;
    var sel = '- postNotificationName:object:userInfo:';
    var method = nc[sel];
    if (method && method.implementation) {
        var orig = method.implementation;
        var cb = new NativeCallback(function(self, cmd, name, obj, info) {
            try {
                var s = new ObjC.Object(name).toString();
                var lower = s.toLowerCase();
                // 监控所有包含msg/chat/message/update/change/recall/revoke的通知
                if (lower.indexOf('msg') !== -1 || lower.indexOf('chat') !== -1 ||
                    lower.indexOf('message') !== -1 || lower.indexOf('update') !== -1 ||
                    lower.indexOf('recall') !== -1 || lower.indexOf('revoke') !== -1 ||
                    lower.indexOf('delete') !== -1 || lower.indexOf('change') !== -1 ||
                    lower.indexOf('modif') !== -1 || lower.indexOf('notif') !== -1 ||
                    lower.indexOf('refresh') !== -1 || lower.indexOf('reload') !== -1) {
                    var elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
                    log('📨 [' + elapsed + 's] ' + s);
                }
            } catch(e) {}
            var origFn = new NativeFunction(orig, 'void', ['pointer', 'pointer', 'pointer', 'pointer', 'pointer']);
            origFn(self, cmd, name, obj, info);
        }, 'void', ['pointer', 'pointer', 'pointer', 'pointer', 'pointer']);
        method.implementation = cb;
        log('✅ NSNotificationCenter 监控就绪');
    } else {
        log('❌ NSNotificationCenter 不可用');
    }
} catch(e) { log('❌ 通知Hook: ' + e.message); }

// 2. Hook OCMsgRecord 的消息更新方法 (QQ NT 的消息模型)
try {
    // OCMsgRecord 是NT的消息存储模型，撤回时会被更新
    var msgRecordCls = ObjC.classes.OCMsgRecord;
    if (msgRecordCls) {
        var methods = msgRecordCls.$methods;
        // 监控所有 set 方法
        var hooked = 0;
        for (var i = 0; i < methods.length; i++) {
            var m = methods[i];
            if (m.indexOf('- set') === 0 || m.indexOf('- update') === 0 || m.indexOf('- mark') === 0) {
                try {
                    var meth = msgRecordCls[m];
                    if (meth && meth.implementation) {
                        var origM = meth.implementation;
                        (function(name) {
                            meth.implementation = new NativeCallback(function() {
                                log('📝 OCMsgRecord.' + name);
                            }.bind({name: name}), 'void', ['pointer', 'pointer']);
                        })(m);
                        hooked++;
                    }
                } catch(e) {}
            }
        }
        log('OCMsgRecord: hooked ' + hooked + ' setters');
    } else {
        log('OCMsgRecord 类不存在');
    }
} catch(e) { log('OCMsgRecord err: ' + e.message); }

// 3. 监控 NSFetchedResultsChange / CoreData 变更 (如果QQ用CoreData)
try {
    var c = ObjC.classes.NSFetchedResultsController;
    if (c) log('NSFetchedResultsController 存在 (QQ可能用CoreData)');
} catch(e) {}

log('监控就绪。撤回消息后观察终端输出。');
