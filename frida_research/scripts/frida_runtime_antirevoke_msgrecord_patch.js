/*
 * QQESign - patch OCMsgRecord recall state in a running QQ process.
 *
 * Attach while the main anti-revoke script is still running:
 *   frida -U -p <QQ_PID> -l .\frida_research\scripts\frida_runtime_antirevoke_msgrecord_patch.js
 */

'use strict';

const TAG = '[QQESign-msgrecord-patch]';
const start = Date.now();
const counts = Object.create(null);

function log(s) { console.log(`${TAG} ${s}`); }
function elapsed() { return ((Date.now() - start) / 1000).toFixed(1); }
function inc(k) { counts[k] = (counts[k] || 0) + 1; return counts[k]; }
function shouldLog(n) { return n <= 8 || (n % 50) === 0; }

function method(c, s) {
    const cls = ObjC.classes[c];
    if (!cls || !cls[s] || !cls[s].implementation) return null;
    return cls[s];
}

function replace(c, s, ret, args, label, factory) {
    try {
        const m = method(c, s);
        if (!m) {
            log(`未找到 ${label}`);
            return false;
        }
        const orig = new NativeFunction(m.implementation, ret, args);
        m.implementation = new NativeCallback(factory(orig), ret, args);
        log(`已安装 ${label}`);
        return true;
    } catch (e) {
        log(`安装失败 ${label}: ${e.message}`);
        return false;
    }
}

function install() {
    log(`启动 PID=${Process.id} arch=${Process.arch}`);

    replace('OCMsgRecord', '- recallTime', 'int64', ['pointer', 'pointer'], 'OCMsgRecord.recallTime=0', function() {
        return function() {
            const n = inc('recallTimeGet');
            if (shouldLog(n)) log(`[${elapsed()}s] recallTime getter -> 0 #${n}`);
            return 0;
        };
    });

    replace('OCMsgRecord', '- setRecallTime:', 'void', ['pointer', 'pointer', 'int64'], 'OCMsgRecord.setRecallTime no-op', function() {
        return function(self, sel, value) {
            const n = inc('recallTimeSet');
            if (shouldLog(n)) log(`[${elapsed()}s] 阻止写入 recallTime=${value} #${n}`);
            return;
        };
    });

    replace('OCMsgRecord', '- isTailHidden', 'bool', ['pointer', 'pointer'], 'OCMsgRecord.isTailHidden=false', function() {
        return function() {
            const n = inc('tailHiddenGet');
            if (shouldLog(n)) log(`[${elapsed()}s] isTailHidden getter -> false #${n}`);
            return false;
        };
    });

    replace('OCMsgRecord', '- setIsTailHidden:', 'void', ['pointer', 'pointer', 'bool'], 'OCMsgRecord.setIsTailHidden no-op', function() {
        return function(self, sel, value) {
            const n = inc('tailHiddenSet');
            if (shouldLog(n)) log(`[${elapsed()}s] 阻止写入 isTailHidden=${value} #${n}`);
            return;
        };
    });

    log('安装完成：消息记录撤回态已强制清零。');
}

if (ObjC.available) install();
else log('ObjC runtime 不可用');
