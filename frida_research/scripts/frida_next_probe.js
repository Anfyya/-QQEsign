/*
 * QQESign - NTQQ 防撤回下一步探针
 *
 * 目的：
 * 1. 不再依赖 ObjC recall selector、SSLRead 或 C++ 导出符号。
 * 2. 晚绑定 Network.framework 的 nw_connection_receive*，包装 completion block，
 *    观察回调里的 dispatch_data_t 是否已经是应用层明文。
 * 3. Hook sqlite3 prepare/exec/step/open，观察撤回最终是否落到本地消息库
 *    update/delete/insert 灰条。
 *
 * 运行：
 *   frida -U -n QQ -l frida_next_probe.js
 *   或
 *   frida -U -f com.tencent.mqq -l frida_next_probe.js --no-pause
 */

'use strict';

const TAG = '[QQESign-next]';
const state = {
    hooks: {},
    blocks: [],
    wrappedBlocks: {},
    stmtSql: {},
    sqlHits: 0,
    sqlMutationHits: 0,
    netCalls: 0,
    netDataHits: 0,
    binaryDumps: 0,
    openHits: 0,
};

const CAPTURE = {
    // 撤回触发时常常没有可读字符串；宽抓前 400 个非 HTTP payload。
    maxBinaryDumps: 400,
    maxSqlMutations: 500,
};

function log(msg) {
    console.log(`${TAG} ${msg}`);
}

function findExport(name, moduleNeedles) {
    let addr = null;
    try {
        addr = Module.findExportByName(null, name);
        if (addr) return addr;
    } catch (e) {}

    const needles = moduleNeedles || [];
    const modules = Process.enumerateModules();
    for (const m of modules) {
        if (needles.length > 0) {
            const path = (m.path || '').toLowerCase();
            const modName = (m.name || '').toLowerCase();
            let matched = false;
            for (const n of needles) {
                const lower = n.toLowerCase();
                if (path.indexOf(lower) !== -1 || modName.indexOf(lower) !== -1) {
                    matched = true;
                    break;
                }
            }
            if (!matched) continue;
        }

        try {
            addr = m.getExportByName(name);
            if (addr) return addr;
        } catch (e) {}
    }
    return null;
}

function hookOnce(name, addr, callbacks) {
    if (!addr || state.hooks[name]) return false;
    try {
        Interceptor.attach(addr, callbacks);
        state.hooks[name] = addr.toString();
        log(`已 Hook ${name} @ ${addr}`);
        return true;
    } catch (e) {
        log(`Hook ${name} 失败: ${e.message}`);
        return false;
    }
}

function ptrToString(p) {
    if (!p || p.isNull()) return '';
    try {
        return p.readUtf8String();
    } catch (e) {
        return '';
    }
}

function readSizeT(p) {
    try {
        if (Process.pointerSize === 8) return parseInt(p.readU64().toString(), 10);
        return p.readU32();
    } catch (e) {
        try {
            return parseInt(p.readU64().toString(), 10);
        } catch (_) {
            return 0;
        }
    }
}

function bytesFromPtr(buf, size, maxLen) {
    if (!buf || buf.isNull() || size <= 0) return null;
    const len = Math.min(size, maxLen || 4096);
    try {
        const raw = buf.readByteArray(len);
        if (!raw) return null;
        return new Uint8Array(raw);
    } catch (e) {
        return null;
    }
}

function asciiOf(bytes, maxLen) {
    if (!bytes) return '';
    const limit = Math.min(bytes.length, maxLen || 256);
    let out = '';
    for (let i = 0; i < limit; i++) {
        const b = bytes[i];
        out += (b >= 0x20 && b < 0x7f) ? String.fromCharCode(b) : '.';
    }
    return out;
}

function hexOf(bytes, maxLen) {
    if (!bytes) return '';
    const limit = Math.min(bytes.length, maxLen || 128);
    let out = '';
    for (let i = 0; i < limit; i++) {
        if (i > 0 && i % 16 === 0) out += '\n    ';
        out += ('0' + bytes[i].toString(16)).slice(-2) + ' ';
    }
    return out;
}

function isLikelyHttp(bytes) {
    if (!bytes || bytes.length < 4) return false;
    const s = asciiOf(bytes, 16);
    return s.indexOf('HTTP/') === 0 ||
        s.indexOf('GET ') === 0 ||
        s.indexOf('POST ') === 0 ||
        s.indexOf('CONNECT ') === 0;
}

function shouldWideDumpNetwork(bytes, size) {
    if (!bytes || size <= 0) return false;
    if (state.binaryDumps >= CAPTURE.maxBinaryDumps) return false;
    if (isLikelyHttp(bytes)) return false;
    if (size < 8) return false;
    return true;
}

function readVarint(bytes, pos) {
    let value = 0;
    let shift = 0;
    let i = pos;
    while (i < bytes.length && shift < 35) {
        const b = bytes[i++];
        value |= (b & 0x7f) << shift;
        if ((b & 0x80) === 0) return { value, next: i };
        shift += 7;
    }
    return null;
}

function looksLikeRecallBytes(bytes) {
    if (!bytes || bytes.length === 0) return false;

    const text = asciiOf(bytes, Math.min(bytes.length, 4096)).toLowerCase();
    if (text.indexOf('recall') !== -1 ||
        text.indexOf('revoke') !== -1 ||
        text.indexOf('msgrecall') !== -1 ||
        text.indexOf('recallmsg') !== -1) {
        return true;
    }

    for (let i = 0; i + 2 < bytes.length; i++) {
        if (bytes[i] !== 0x08) continue;
        const r = readVarint(bytes, i + 1);
        if (!r) continue;
        if (r.value === 0x210 || r.value === 0x211 || r.value === 0x3f6) {
            return true;
        }
    }
    return false;
}

let dispatchDataCreateMapFn = null;
function getDispatchDataCreateMap() {
    if (dispatchDataCreateMapFn) return dispatchDataCreateMapFn;
    const addr = findExport('dispatch_data_create_map', ['libdispatch']);
    if (!addr) return null;
    dispatchDataCreateMapFn = new NativeFunction(addr, 'pointer', ['pointer', 'pointer', 'pointer']);
    return dispatchDataCreateMapFn;
}

function inspectDispatchData(content, label) {
    if (!content || content.isNull()) return;

    const mapper = getDispatchDataCreateMap();
    if (!mapper) {
        if (state.netCalls <= 5) log(`${label}: 找不到 dispatch_data_create_map，无法读取 dispatch_data_t`);
        return;
    }

    const outBuf = Memory.alloc(Process.pointerSize);
    const outSize = Memory.alloc(Process.pointerSize);
    let mapped = NULL;
    try {
        mapped = mapper(content, outBuf, outSize);
    } catch (e) {
        if (state.netCalls <= 5) log(`${label}: dispatch_data_create_map 失败 ${e.message}`);
        return;
    }

    const dataPtr = outBuf.readPointer();
    const size = readSizeT(outSize);
    const bytes = bytesFromPtr(dataPtr, size, 4096);
    if (!bytes) return;

    const suspicious = looksLikeRecallBytes(bytes);
    const wideDump = shouldWideDumpNetwork(bytes, size);
    if (wideDump) state.binaryDumps++;
    if (suspicious || wideDump || state.netCalls <= 8 || state.netCalls % 200 === 0) {
        if (suspicious) state.netDataHits++;
        log(`${label}: size=${size} suspicious=${suspicious} wide=${wideDump} netCalls=${state.netCalls} hits=${state.netDataHits} dump=${state.binaryDumps}`);
        log(`  txt: ${asciiOf(bytes, 256)}`);
        log(`  hex:\n    ${hexOf(bytes, 128)}`);
    }

    // mapped 是 dispatch object；这里不 release，避免在 Frida 侧误释放造成崩溃。
    void mapped;
}

function wrapNWReceiveBlock(blockPtr, label) {
    if (!blockPtr || blockPtr.isNull()) return;
    const key = blockPtr.toString();
    if (state.wrappedBlocks[key]) return;
    if (!ObjC.available || !ObjC.Block) {
        log(`${label}: ObjC.Block 不可用，无法包装 completion`);
        return;
    }

    try {
        const block = new ObjC.Block(blockPtr);
        try {
            block.declare({
                retType: 'void',
                argTypes: ['pointer', 'pointer', 'bool', 'pointer'],
            });
        } catch (e) {}
        const original = block.implementation;
        block.implementation = function(content, context, isComplete, error) {
            state.netCalls++;
            try {
                inspectDispatchData(ptr(content), `${label} completion`);
            } catch (e) {
                if (state.netCalls <= 5) log(`${label} completion 读取失败: ${e.message}`);
            }
            return original(content, context, isComplete, error);
        };
        state.blocks.push(block);
        state.wrappedBlocks[key] = true;
        log(`已包装 ${label} completion block ${key}`);
    } catch (e) {
        log(`包装 ${label} completion 失败: ${e.message}`);
    }
}

function installNetworkReceiveHooks() {
    const receive = findExport('nw_connection_receive', ['Network', 'libnetwork']);
    hookOnce('nw_connection_receive', receive, {
        onEnter(args) {
            wrapNWReceiveBlock(args[3], 'nw_connection_receive');
        }
    });

    const receiveMessage = findExport('nw_connection_receive_message', ['Network', 'libnetwork']);
    hookOnce('nw_connection_receive_message', receiveMessage, {
        onEnter(args) {
            wrapNWReceiveBlock(args[1], 'nw_connection_receive_message');
        }
    });
}

function sqlIsInteresting(sql) {
    if (!sql) return false;
    const compact = compactSql(sql).toLowerCase();
    const recall = compact.indexOf('recall') !== -1 ||
        compact.indexOf('revoke') !== -1 ||
        compact.indexOf('撤回') !== -1;
    return recall || sqlMutationKind(compact) !== '';
}

function sqlMutationKind(compactLowerSql) {
    const s = compactLowerSql || '';
    if (s.indexOf('update ') === 0) return 'update';
    if (s.indexOf('delete ') === 0) return 'delete';
    if (s.indexOf('insert ') === 0) return 'insert';
    if (s.indexOf('replace ') === 0) return 'replace';
    if (s.indexOf('with ') === 0 &&
        (s.indexOf(' update ') !== -1 ||
         s.indexOf(' delete ') !== -1 ||
         s.indexOf(' insert ') !== -1 ||
         s.indexOf(' replace ') !== -1)) {
        return 'cte-mutation';
    }
    return '';
}

function compactSql(sql) {
    return (sql || '').replace(/\s+/g, ' ').trim().slice(0, 800);
}

function logSql(kind, sql) {
    if (!sqlIsInteresting(sql)) return;
    const compact = compactSql(sql);
    const mutKind = sqlMutationKind(compact.toLowerCase());
    if (mutKind) {
        state.sqlMutationHits++;
        if (state.sqlMutationHits > CAPTURE.maxSqlMutations) return;
    }
    state.sqlHits++;
    log(`[SQL:${kind}] #${state.sqlHits} mutation=${mutKind || 'no'} ${compact}`);
}

function installSQLiteHooks() {
    const sqliteNeedles = ['sqlite', 'wcdb'];

    const openV2 = findExport('sqlite3_open_v2', sqliteNeedles);
    hookOnce('sqlite3_open_v2', openV2, {
        onEnter(args) {
            this.path = ptrToString(args[0]);
        },
        onLeave(retval) {
            if (!this.path) return;
            const lower = this.path.toLowerCase();
            if (state.openHits < 20 ||
                lower.indexOf('msg') !== -1 ||
                lower.indexOf('message') !== -1 ||
                lower.indexOf('chat') !== -1 ||
                lower.indexOf('qq') !== -1) {
                state.openHits++;
                log(`[SQL:open] rc=${retval.toInt32()} ${this.path}`);
            }
        }
    });

    const exec = findExport('sqlite3_exec', sqliteNeedles);
    hookOnce('sqlite3_exec', exec, {
        onEnter(args) {
            logSql('exec', ptrToString(args[1]));
        }
    });

    const prepareV2 = findExport('sqlite3_prepare_v2', sqliteNeedles);
    hookOnce('sqlite3_prepare_v2', prepareV2, {
        onEnter(args) {
            this.sql = ptrToString(args[1]);
            this.ppStmt = args[3];
            logSql('prepare_v2', this.sql);
        },
        onLeave(retval) {
            if (retval.toInt32() !== 0 || !this.ppStmt || this.ppStmt.isNull()) return;
            try {
                const stmt = this.ppStmt.readPointer();
                if (!stmt.isNull() && sqlIsInteresting(this.sql)) {
                    state.stmtSql[stmt.toString()] = this.sql;
                }
            } catch (e) {}
        }
    });

    const prepareV3 = findExport('sqlite3_prepare_v3', sqliteNeedles);
    hookOnce('sqlite3_prepare_v3', prepareV3, {
        onEnter(args) {
            this.sql = ptrToString(args[1]);
            this.ppStmt = args[4];
            logSql('prepare_v3', this.sql);
        },
        onLeave(retval) {
            if (retval.toInt32() !== 0 || !this.ppStmt || this.ppStmt.isNull()) return;
            try {
                const stmt = this.ppStmt.readPointer();
                if (!stmt.isNull() && sqlIsInteresting(this.sql)) {
                    state.stmtSql[stmt.toString()] = this.sql;
                }
            } catch (e) {}
        }
    });

    const step = findExport('sqlite3_step', sqliteNeedles);
    hookOnce('sqlite3_step', step, {
        onEnter(args) {
            const key = args[0].toString();
            this.sql = state.stmtSql[key];
        },
        onLeave(retval) {
            if (!this.sql) return;
            const rc = retval.toInt32();
            if (rc === 101 || rc === 100 || rc === 0) {
                log(`[SQL:step] rc=${rc} ${compactSql(this.sql)}`);
            }
        }
    });

    const finalize = findExport('sqlite3_finalize', sqliteNeedles);
    hookOnce('sqlite3_finalize', finalize, {
        onEnter(args) {
            delete state.stmtSql[args[0].toString()];
        }
    });

    const bindText = findExport('sqlite3_bind_text', sqliteNeedles);
    hookOnce('sqlite3_bind_text', bindText, {
        onEnter(args) {
            const text = ptrToString(args[2]);
            if (!text) return;
            const lower = text.toLowerCase();
            if (lower.indexOf('recall') !== -1 ||
                lower.indexOf('revoke') !== -1 ||
                lower.indexOf('撤回') !== -1) {
                log(`[SQL:bind_text] idx=${args[1].toInt32()} ${text.slice(0, 500)}`);
            }
        }
    });
}

function installDlopenHook() {
    const dlopen = findExport('dlopen', ['libdyld', 'dyld']);
    hookOnce('dlopen', dlopen, {
        onEnter(args) {
            this.path = ptrToString(args[0]);
        },
        onLeave() {
            if (!this.path) return;
            const lower = this.path.toLowerCase();
            if (lower.indexOf('network') !== -1 || lower.indexOf('sqlite') !== -1 || lower.indexOf('wcdb') !== -1) {
                log(`[dyld] ${this.path} 已加载，重试安装探针`);
                setTimeout(installAll, 50);
            }
        }
    });
}

function installAll() {
    installNetworkReceiveHooks();
    installSQLiteHooks();
}

log(`启动 PID=${Process.id} arch=${Process.arch}`);
installDlopenHook();
installAll();

let retryCount = 0;
const timer = setInterval(function() {
    retryCount++;
    installAll();
    if (retryCount % 10 === 0) {
        log(`探针状态: networkHooks=${!!state.hooks.nw_connection_receive}/${!!state.hooks.nw_connection_receive_message} sqliteHits=${state.sqlHits} netCalls=${state.netCalls} netHits=${state.netDataHits}`);
    }
    if (retryCount >= 90) clearInterval(timer);
}, 1000);

log('探针已启动。现在让对方发消息并撤回，观察 Network completion 和 SQL update/delete 日志。');
