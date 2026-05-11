/*
 * QQESign - NTQQ recall persistence probe.
 *
 * Read-only probe. It does not modify QQ behavior. It opens a short capture
 * window when the confirmed recall UI bridge is reached, then logs native file
 * writes and sqlite steps with stacks. This is for finding the NTQQ persistence
 * point behind current-chat anti-revoke.
 */

'use strict';

const TAG = '[QQESign-persist-probe]';
const start = Date.now();
const counts = Object.create(null);

const CAPTURE_MS = 12000;
const F_GETPATH = 50;
const MAX_LOG = 160;
const DB_PATH_RE = /(nt|qq|msg|message|kernel|chat|recent|sqlite|db|wal|shm|level|rocks|mmkv|store|cache)/i;
const REVOKE_SEL = '- initWithOperatorTinyId:operatorRole:operatorUid:operatorNick:operatorRemark:operatorMemRemark:origMsgSenderUid:origMsgSenderNick:origMsgSenderRemark:origMsgSenderMemRemark:isSelfOperate:wording:';

let captureUntil = 0;
let totalLogs = 0;

function log(s) { console.log(`${TAG} ${s}`); }
function elapsed() { return ((Date.now() - start) / 1000).toFixed(1); }
function inc(k) { counts[k] = (counts[k] || 0) + 1; return counts[k]; }
function inCapture() { return Date.now() <= captureUntil; }
function openCapture(reason) {
    captureUntil = Date.now() + CAPTURE_MS;
    log(`[${elapsed()}s] 打开持久化捕获窗口 ${CAPTURE_MS}ms: ${reason}`);
}

function symbol(name) {
    return Module.findGlobalExportByName(name);
}

function bt(context) {
    try {
        return Thread.backtrace(context, Backtracer.ACCURATE)
            .map(DebugSymbol.fromAddress)
            .slice(0, 8)
            .join('\n    ');
    } catch (_) {
        return '';
    }
}

const fcntlPtr = symbol('fcntl');
const fcntlFn = fcntlPtr ? new NativeFunction(fcntlPtr, 'int', ['int', 'int', 'pointer']) : null;

function fdPath(fd) {
    if (!fcntlFn || fd < 0) return '';
    const buf = Memory.alloc(4096);
    const rc = fcntlFn(fd, F_GETPATH, buf);
    if (rc !== 0) return '';
    try { return buf.readUtf8String() || ''; } catch (_) { return ''; }
}

function shouldLogPath(path) {
    return !path || DB_PATH_RE.test(path);
}

function logWrite(kind, fd, size, context) {
    if (!inCapture() || totalLogs >= MAX_LOG) return;
    const path = fdPath(fd);
    if (!shouldLogPath(path)) return;

    totalLogs++;
    const n = inc(`write:${kind}`);
    log(`[${elapsed()}s] ${kind} fd=${fd} size=${size} path="${path}" #${n}`);
    if (n <= 8) {
        const trace = bt(context);
        if (trace) log(`  栈:\n    ${trace}`);
    }
}

function hookWrite(name, argc) {
    const p = symbol(name);
    if (!p) {
        log(`未找到 ${name}`);
        return;
    }
    Interceptor.attach(p, {
        onEnter(args) {
            if (!inCapture()) return;
            const fd = args[0].toInt32();
            let size = 0;
            try { size = Number(args[argc - 1]); } catch (_) {}
            logWrite(name, fd, size, this.context);
        },
    });
    log(`已观察 ${name}`);
}

function hookSqlite() {
    const step = symbol('sqlite3_step');
    const sql = symbol('sqlite3_sql');
    if (!step || !sql) {
        log('未找到 sqlite3_step/sqlite3_sql');
        return;
    }
    const sqlite3Sql = new NativeFunction(sql, 'pointer', ['pointer']);
    Interceptor.attach(step, {
        onEnter(args) {
            if (!inCapture() || totalLogs >= MAX_LOG) return;
            let q = '';
            try {
                const p = sqlite3Sql(args[0]);
                if (p && !p.isNull()) q = p.readUtf8String() || '';
            } catch (_) {}
            if (!q || !/(recall|revoke|delete|update|msg|message|撤回)/i.test(q)) return;
            totalLogs++;
            const n = inc('sqlite3_step');
            log(`[${elapsed()}s] sqlite3_step #${n}: ${q.slice(0, 400)}`);
            if (n <= 8) {
                const trace = bt(this.context);
                if (trace) log(`  栈:\n    ${trace}`);
            }
        },
    });
    log('已观察 sqlite3_step');
}

function hookRecallBridge() {
    if (!ObjC.available) return;
    const cls = ObjC.classes.OCRevokeElement;
    if (!cls || !cls[REVOKE_SEL] || !cls[REVOKE_SEL].implementation) {
        log('未找到 OCRevokeElement 触发点');
        return;
    }
    Interceptor.attach(cls[REVOKE_SEL].implementation, {
        onEnter() {
            openCapture('OCRevokeElement');
        },
    });
    log('已观察 OCRevokeElement，用于触发捕获窗口');
}

function install() {
    log(`启动 PID=${Process.id} arch=${Process.arch}`);
    hookRecallBridge();
    hookWrite('write', 3);
    hookWrite('pwrite', 4);
    hookWrite('writev', 3);
    hookSqlite();
    log('安装完成：触发一次新的撤回后查看写入路径。');
}

install();
