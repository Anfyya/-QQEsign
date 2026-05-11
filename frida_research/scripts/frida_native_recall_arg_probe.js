/*
 * QQESign - narrow native recall argument probe.
 *
 * This is read-only and intentionally hooks only offsets repeatedly observed in
 * the confirmed recall stack. Use it together with the stable gray-tip NULL
 * script, then trigger one new recall.
 */

'use strict';

const TAG = '[QQESign-native-arg]';
const start = Date.now();
const counts = Object.create(null);

const OFFSETS = [
    ['upper-a', '0x1463f94c'],
    ['upper-b', '0x1461becc'],
    ['upper-c', '0x1462d9f0'],
    ['upper-live-a', '0x13d707b8'],
    ['mid-a', '0x58a0188'],
    ['common-live-d', '0x57053a8'],
    ['common-live-c', '0x5aa9a04'],
    ['common-live-b', '0x570dc18'],
];

const MAX_PER_OFFSET = 8;

function log(s) { console.log(`${TAG} ${s}`); }
function elapsed() { return ((Date.now() - start) / 1000).toFixed(1); }
function inc(k) { counts[k] = (counts[k] || 0) + 1; return counts[k]; }

function readUtf8Near(p) {
    if (!p || p.isNull()) return '';
    try {
        const r = Process.findRangeByAddress(p);
        if (!r || r.protection.indexOf('r') === -1) return '';
        const s = p.readUtf8String(160);
        if (!s) return '';
        if (/[\x00-\x08\x0e-\x1f]/.test(s)) return '';
        return s;
    } catch (_) {
        return '';
    }
}

function dumpPtr(p) {
    if (!p || p.isNull()) return '0';
    const pieces = [p.toString()];
    try {
        const r = Process.findRangeByAddress(p);
        if (r) pieces.push(r.protection);
    } catch (_) {}
    const s = readUtf8Near(p);
    if (s) pieces.push(JSON.stringify(s));
    if (ObjC.available) {
        try {
            const o = new ObjC.Object(p);
            pieces.push(`objc=${o.$className}:${o.toString()}`);
        } catch (_) {}
    }
    return pieces.join(' ');
}

function bt(context) {
    try {
        return Thread.backtrace(context, Backtracer.ACCURATE)
            .map(DebugSymbol.fromAddress)
            .slice(0, 10)
            .join('\n    ');
    } catch (_) {
        return '';
    }
}

function install() {
    const qq = Process.findModuleByName('QQ');
    if (!qq) {
        log('未找到 QQ 主模块');
        return;
    }
    log(`启动 PID=${Process.id} QQ base=${qq.base}`);

    for (const [name, off] of OFFSETS) {
        const addr = qq.base.add(ptr(off));
        const range = Process.findRangeByAddress(addr);
        if (!range || range.protection.indexOf('x') === -1) {
            log(`跳过不可执行 ${name} ${off} addr=${addr}`);
            continue;
        }
        Interceptor.attach(addr, {
            onEnter(args) {
                const n = inc(name);
                if (n > MAX_PER_OFFSET) return;
                log(`[${elapsed()}s] hit ${name} ${off} #${n}`);
                log(`  x0=${dumpPtr(this.context.x0)}`);
                log(`  x1=${dumpPtr(this.context.x1)}`);
                log(`  x2=${dumpPtr(this.context.x2)}`);
                log(`  x3=${dumpPtr(this.context.x3)}`);
                log(`  x4=${dumpPtr(this.context.x4)}`);
                log(`  x5=${dumpPtr(this.context.x5)}`);
                const trace = bt(this.context);
                if (trace) log(`  栈:\n    ${trace}`);
            },
        });
        log(`已观察 ${name} ${off} addr=${addr}`);
    }
    log('安装完成，请触发一次新的撤回。');
}

install();
