/*
 * QQESign - anti-revoke with content cache.
 *
 * Keeps the verified current-window blocker:
 *   OCGrayTipElement(... revokeElement ...) -> NULL
 *
 * Adds a low-risk content cache at OCMsgRecord string getters. This does not
 * replace elements arrays and does not hook arbitrary native offsets.
 */

'use strict';

const TAG = '[QQESign-content-cache]';
const start = Date.now();
const counts = Object.create(null);

const REVOKE_SEL = '- initWithOperatorTinyId:operatorRole:operatorUid:operatorNick:operatorRemark:operatorMemRemark:origMsgSenderUid:origMsgSenderNick:origMsgSenderRemark:origMsgSenderMemRemark:isSelfOperate:wording:';
const GRAY_SEL = '- initWithSubElementType:revokeElement:proclamationElement:emojiReplyElement:groupElement:buddyElement:feedMsgElement:essenceElement:xmlElement:fileReceiptElement:localGrayTipElement:blockGrayTipElement:aioOpGrayTipElement:jsonGrayTipElement:walletGrayTipElement:';

const MARK_INLINE = '\n[防撤回] 对方尝试撤回这条消息，已阻止';
const MARK_PREVIEW = '[防撤回] 撤回已阻止';
const CACHE_LIMIT = 2000;

const contentByKey = new Map();
const recalledKeys = new Set();

let installed = 0;

function log(s) { console.log(`${TAG} ${s}`); }
function elapsed() { return ((Date.now() - start) / 1000).toFixed(1); }
function inc(k) { counts[k] = (counts[k] || 0) + 1; return counts[k]; }
function shouldLog(n) { return n <= 8 || (n % 50) === 0; }
function isNull(p) { return !p || p.isNull(); }

function obj(p) {
    if (isNull(p)) return null;
    try { return new ObjC.Object(p); } catch (_) { return null; }
}

function objString(o) {
    if (!o) return '';
    try { return o.toString(); } catch (_) { return ''; }
}

function text(p) { return objString(obj(p)); }

function ns(s) {
    return ObjC.classes.NSString.stringWithUTF8String_(Memory.allocUtf8String(s)).handle;
}

function numericValue(v) {
    if (v === null || v === undefined) return 0;
    if (typeof v === 'number') return v;
    try {
        const value = v.valueOf();
        if (typeof value === 'number') return value;
    } catch (_) {}
    try {
        const s = v.toString();
        if (s.indexOf('0x') === 0) return parseInt(s, 16);
        return parseInt(s, 10);
    } catch (_) {
        return 0;
    }
}

function isNonZero(v) {
    const n = numericValue(v);
    return Number.isFinite(n) && n !== 0;
}

function hasRecallText(s) {
    const t = String(s || '').toLowerCase();
    return t.indexOf('撤回') !== -1 || t.indexOf('recall') !== -1 || t.indexOf('revoke') !== -1;
}

function isNSString(p) {
    const o = obj(p);
    if (!o) return false;
    try { return o.isKindOfClass_(ObjC.classes.NSString); } catch (_) { return false; }
}

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
        installed++;
        log(`已安装 ${label}`);
        return true;
    } catch (e) {
        log(`安装失败 ${label}: ${e.message}`);
        return false;
    }
}

function stack(context) {
    try {
        return Thread.backtrace(context, Backtracer.ACCURATE)
            .map(DebugSymbol.fromAddress)
            .slice(0, 8)
            .join('\n    ');
    } catch (_) {
        return '';
    }
}

function recordKey(recordPtr) {
    const record = obj(recordPtr);
    if (!record) return '';
    let peer = '';
    let seq = 0;
    let random = 0;
    let msgId = 0;
    try { if (record.peerUid) peer = objString(record.peerUid()); } catch (_) {}
    try { if (record.msgSeq) seq = numericValue(record.msgSeq()); } catch (_) {}
    try { if (record.msgRandom) random = numericValue(record.msgRandom()); } catch (_) {}
    try { if (record.msgId) msgId = numericValue(record.msgId()); } catch (_) {}
    if (!peer && !seq && !random && !msgId) return '';
    return `${peer}|${seq}|${random}|${msgId}`;
}

function trimCache() {
    while (contentByKey.size > CACHE_LIMIT) {
        const first = contentByKey.keys().next().value;
        contentByKey.delete(first);
        recalledKeys.delete(first);
    }
}

function cacheContent(self, s, source) {
    if (!s || hasRecallText(s) || s.indexOf('[防撤回]') !== -1) return;
    const key = recordKey(self);
    if (!key || contentByKey.has(key)) return;
    contentByKey.set(key, s);
    trimCache();
    const n = inc('cacheContent');
    if (shouldLog(n)) log(`[${elapsed()}s] 缓存消息文本 #${n} source=${source} key=${key} text="${s.slice(0, 80)}"`);
}

function elementCount(elements) {
    if (!elements || !elements.count) return 0;
    return numericValue(elements.count());
}

function textFromElements(elements) {
    try {
        const count = Math.min(elementCount(elements), 10);
        for (let i = 0; i < count; i++) {
            const element = elements.objectAtIndex_(i);
            if (!element || !element.textElement) continue;
            const textElement = element.textElement();
            if (!textElement || (textElement.isNull && textElement.isNull())) continue;
            if (!textElement.content) continue;
            const s = objString(textElement.content());
            if (s && !hasRecallText(s) && s.indexOf('[防撤回]') === -1) return s;
        }
    } catch (_) {}
    return '';
}

function cacheContentFromElements(self, elementsPtr, source) {
    const elements = obj(elementsPtr);
    if (!elements) return;
    const s = textFromElements(elements);
    if (s) cacheContent(self, s, source);
}

function markRecalled(self, reason) {
    const key = recordKey(self);
    if (!key) return;
    recalledKeys.add(key);
    const n = inc('recalled');
    if (shouldLog(n)) log(`[${elapsed()}s] 标记撤回 #${n} ${reason} key=${key} cached=${contentByKey.has(key)}`);
}

function contentForGetter(self, ret, source) {
    const s = text(ret);
    cacheContent(self, s, source);
    const key = recordKey(self);
    if (!key || !recalledKeys.has(key)) return ret;

    const cached = contentByKey.get(key);
    if (!cached) return ret;

    const out = cached.indexOf('[防撤回]') === -1 ? `${cached}${MARK_INLINE}` : cached;
    const n = inc('restoreContent');
    if (shouldLog(n)) log(`[${elapsed()}s] 恢复撤回消息文本 #${n} source=${source} key=${key}`);
    return ns(out);
}

function cleanPreview(value) {
    if (!isNSString(value)) return value;
    const s = text(value);
    return hasRecallText(s) ? ns(MARK_PREVIEW) : value;
}

function installGrayTipNullBlocker() {
    const cls = ObjC.classes.OCRevokeElement;
    if (cls && cls[REVOKE_SEL] && cls[REVOKE_SEL].implementation) {
        Interceptor.attach(cls[REVOKE_SEL].implementation, {
            onEnter(args) {
                const n = inc('revoke');
                if (shouldLog(n)) log(`[${elapsed()}s] 看到撤回元素 #${n} operator="${text(args[5])}" original="${text(args[9])}"`);
            },
        });
        installed++;
        log('已观察撤回元素');
    }

    const m = method('OCGrayTipElement', GRAY_SEL);
    if (!m) {
        log('未找到当前聊天灰条短路点');
        return;
    }

    const orig = new NativeFunction(m.implementation, 'pointer', [
        'pointer', 'pointer', 'long',
        'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer',
        'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer',
    ]);

    m.implementation = new NativeCallback(function(self, sel, subType, revokeElement,
                                                    proclamationElement, emojiReplyElement,
                                                    groupElement, buddyElement, feedMsgElement,
                                                    essenceElement, xmlElement, fileReceiptElement,
                                                    localGrayTipElement, blockGrayTipElement,
                                                    aioOpGrayTipElement, jsonGrayTipElement,
                                                    walletGrayTipElement) {
        if (!isNull(revokeElement)) {
            const n = inc('grayBlock');
            if (shouldLog(n)) {
                log(`[${elapsed()}s] 当前聊天阻断撤回灰条 #${n} subType=${subType}`);
                if (n <= 3) {
                    const trace = stack(this.context);
                    if (trace) log(`  栈:\n    ${trace}`);
                }
            }
            return ptr('0');
        }

        return orig(self, sel, subType, revokeElement, proclamationElement,
                    emojiReplyElement, groupElement, buddyElement, feedMsgElement,
                    essenceElement, xmlElement, fileReceiptElement, localGrayTipElement,
                    blockGrayTipElement, aioOpGrayTipElement, jsonGrayTipElement,
                    walletGrayTipElement);
    }, 'pointer', [
        'pointer', 'pointer', 'long',
        'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer',
        'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer',
    ]);
    installed++;
    log('已安装当前聊天灰条短路：revokeElement 非空时返回 NULL');
}

function installContentCache() {
    replace('OCMsgRecord', '- elements', 'pointer', ['pointer', 'pointer'], 'OCMsgRecord.elements 文本缓存', function(orig) {
        return function(self, sel) {
            const ret = orig(self, sel);
            cacheContentFromElements(self, ret, 'elements');
            return ret;
        };
    });

    replace('OCMsgRecord', '- swizzled_elements', 'pointer', ['pointer', 'pointer'], 'OCMsgRecord.swizzled_elements 文本缓存', function(orig) {
        return function(self, sel) {
            const ret = orig(self, sel);
            cacheContentFromElements(self, ret, 'swizzled_elements');
            return ret;
        };
    });

    replace('OCMsgRecord', '- setElements:', 'void', ['pointer', 'pointer', 'pointer'], 'OCMsgRecord.setElements 文本缓存', function(orig) {
        return function(self, sel, value) {
            cacheContentFromElements(self, value, 'setElements');
            return orig(self, sel, value);
        };
    });

    replace('OCMsgRecord', '- getContent', 'pointer', ['pointer', 'pointer'], 'OCMsgRecord.getContent 缓存恢复', function(orig) {
        return function(self, sel) {
            return contentForGetter(self, orig(self, sel), 'getContent');
        };
    });

    replace('OCMsgRecord', '- qsd_retriveContent', 'pointer', ['pointer', 'pointer'], 'OCMsgRecord.qsd_retriveContent 缓存恢复', function(orig) {
        return function(self, sel) {
            return contentForGetter(self, orig(self, sel), 'qsd_retriveContent');
        };
    });

    replace('OCMsgElement', '- qsd_retriveContent', 'pointer', ['pointer', 'pointer'], 'OCMsgElement.qsd_retriveContent 读取清洗', function(orig) {
        return function(self, sel) {
            const ret = orig(self, sel);
            if (isNSString(ret) && hasRecallText(text(ret))) return ns(MARK_PREVIEW);
            return ret;
        };
    });

    replace('OCMsgRecord', '- setRecallTime:', 'void', ['pointer', 'pointer', 'int64'], 'OCMsgRecord.setRecallTime no-op', function(_orig) {
        return function(self, _sel, value) {
            if (isNonZero(value)) markRecalled(self, `setRecallTime=${value}`);
            const n = inc('recallTimeSet');
            if (shouldLog(n)) log(`[${elapsed()}s] 阻止 setRecallTime=${value} #${n}`);
        };
    });

    replace('OCMsgRecord', '- setKt_recallTimeFromCodec:', 'void', ['pointer', 'pointer', 'int64'], 'OCMsgRecord.setKt_recallTimeFromCodec no-op', function(_orig) {
        return function(self, _sel, value) {
            if (isNonZero(value)) markRecalled(self, `codecRecallTime=${value}`);
            const n = inc('recallTimeCodec');
            if (shouldLog(n)) log(`[${elapsed()}s] 阻止 codec recallTime=${value} #${n}`);
        };
    });

    replace('OCMsgRecord', '- recallTime', 'int64', ['pointer', 'pointer'], 'OCMsgRecord.recallTime=0', function(_orig) {
        return function() { return 0; };
    });

    replace('OCMsgRecord', '- isTailHidden', 'bool', ['pointer', 'pointer'], 'OCMsgRecord.isTailHidden=false', function(_orig) {
        return function() { return false; };
    });
}

function installPreviewCleaner() {
    replace('OCRecentContactInfo', '- abstractContent', 'pointer', ['pointer', 'pointer'], '左侧预览读取清洗', function(orig) {
        return function(self, sel) {
            const ret = orig(self, sel);
            const clean = cleanPreview(ret);
            if (!clean.equals(ret)) {
                const n = inc('previewGet');
                if (shouldLog(n)) log(`[${elapsed()}s] 左侧预览读取清洗 #${n}: "${text(ret)}"`);
            }
            return clean;
        };
    });

    replace('OCRecentContactInfo', '- setAbstractContent:', 'void', ['pointer', 'pointer', 'pointer'], '左侧预览写入清洗', function(orig) {
        return function(self, sel, value) {
            const clean = cleanPreview(value);
            if (!clean.equals(value)) {
                const n = inc('previewSet');
                if (shouldLog(n)) log(`[${elapsed()}s] 左侧预览写入清洗 #${n}: "${text(value)}"`);
            }
            return orig(self, sel, clean);
        };
    });
}

function install() {
    log(`启动 PID=${Process.id} arch=${Process.arch}`);
    installGrayTipNullBlocker();
    installContentCache();
    installPreviewCleaner();
    log(`安装完成 installed=${installed} cacheLimit=${CACHE_LIMIT}`);
}

if (ObjC.available) ObjC.schedule(ObjC.mainQueue, install);
else log('ObjC runtime 不可用');
