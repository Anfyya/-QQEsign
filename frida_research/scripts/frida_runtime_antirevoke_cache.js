/*
 * QQESign - runtime anti-revoke with in-session record cache.
 *
 * Purpose:
 * - Keep the only verified current-chat blocker:
 *   OCGrayTipElement(... revokeElement ...) -> NULL
 * - Cache original OCMsgRecord.elements while messages are still normal.
 * - If NTQQ later marks the same bridge record recalled, keep returning the
 *   cached original elements so leaving and re-entering the chat can still show
 *   the original content during this Frida session.
 *
 * This is still a runtime bridge patch. It does not pretend NTQQ recall is an
 * ObjC business method; it uses ObjC only at the decoded UI model boundary.
 */

'use strict';

const TAG = '[QQESign-antirevoke-cache]';
const start = Date.now();
const counts = Object.create(null);

const REVOKE_SEL = '- initWithOperatorTinyId:operatorRole:operatorUid:operatorNick:operatorRemark:operatorMemRemark:origMsgSenderUid:origMsgSenderNick:origMsgSenderRemark:origMsgSenderMemRemark:isSelfOperate:wording:';
const GRAY_SEL = '- initWithSubElementType:revokeElement:proclamationElement:emojiReplyElement:groupElement:buddyElement:feedMsgElement:essenceElement:xmlElement:fileReceiptElement:localGrayTipElement:blockGrayTipElement:aioOpGrayTipElement:jsonGrayTipElement:walletGrayTipElement:';
const MARK_INLINE = '\n[防撤回] 对方尝试撤回这条消息，已阻止';
const MARK_PREVIEW = '[防撤回] 撤回已阻止';

const CACHE_LIMIT = 1200;
const originalElementsByKey = new Map();
const recalledKeys = new Set();
const markedKeys = new Set();

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

function text(p) {
    return objString(obj(p));
}

function ns(s) {
    return ObjC.classes.NSString.stringWithUTF8String_(Memory.allocUtf8String(s)).handle;
}

function isNSString(p) {
    const o = obj(p);
    if (!o) return false;
    try { return o.isKindOfClass_(ObjC.classes.NSString); } catch (_) { return false; }
}

function hasRecallText(s) {
    const t = String(s || '').toLowerCase();
    return t.indexOf('撤回') !== -1 || t.indexOf('recall') !== -1 || t.indexOf('revoke') !== -1;
}

function cleanPreviewPtr(p) {
    if (!isNSString(p)) return p;
    const t = text(p);
    return hasRecallText(t) ? ns(MARK_PREVIEW) : p;
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

function recordKeyFromObj(record) {
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

function elementCount(elements) {
    if (!elements || !elements.count) return 0;
    return numericValue(elements.count());
}

function hasRecallGrayTip(elements) {
    try {
        const count = Math.min(elementCount(elements), 10);
        for (let i = 0; i < count; i++) {
            const element = elements.objectAtIndex_(i);
            if (!element || !element.grayTipElement) continue;
            const gray = element.grayTipElement();
            if (!gray || (gray.isNull && gray.isNull())) continue;
            if (gray.revokeElement) {
                const revoke = gray.revokeElement();
                if (revoke && !(revoke.isNull && revoke.isNull())) return true;
            }
        }
    } catch (_) {}
    return false;
}

function hasUsefulContent(elements) {
    try {
        const count = Math.min(elementCount(elements), 10);
        if (count <= 0) return false;
        if (hasRecallGrayTip(elements)) return false;
        for (let i = 0; i < count; i++) {
            const element = elements.objectAtIndex_(i);
            if (!element) continue;
            if (element.textElement) {
                const t = element.textElement();
                if (t && !(t.isNull && t.isNull())) return true;
            }
            if (element.picElement || element.pttElement || element.videoElement || element.fileElement || element.replyElement) {
                return true;
            }
        }
    } catch (_) {}
    return false;
}

function retainObj(o) {
    try {
        if (o && o.retain) o.retain();
    } catch (_) {}
}

function trimCacheIfNeeded() {
    while (originalElementsByKey.size > CACHE_LIMIT) {
        const first = originalElementsByKey.keys().next().value;
        originalElementsByKey.delete(first);
        recalledKeys.delete(first);
        markedKeys.delete(first);
    }
}

function markCachedTextElements(key, elementsHandle) {
    if (!key || markedKeys.has(key)) return;
    try {
        const elements = obj(elementsHandle);
        const count = Math.min(elementCount(elements), 10);
        for (let i = 0; i < count; i++) {
            const element = elements.objectAtIndex_(i);
            if (!element || !element.textElement) continue;
            const textElement = element.textElement();
            if (!textElement || (textElement.isNull && textElement.isNull())) continue;
            if (!textElement.content || !textElement.setContent_) continue;

            const current = objString(textElement.content());
            if (!current || current.indexOf('[防撤回]') !== -1) {
                markedKeys.add(key);
                return;
            }

            const updated = current + MARK_INLINE;
            textElement.setContent_(ns(updated));
            markedKeys.add(key);
            const n = inc('inlineMark');
            if (shouldLog(n)) log(`[${elapsed()}s] 已给缓存原文本追加防撤回标识 #${n} key=${key}`);
            return;
        }
    } catch (e) {
        const n = inc('inlineMarkError');
        if (shouldLog(n)) log(`[${elapsed()}s] 追加防撤回标识失败 #${n}: ${e.message}`);
    }
}

function cacheRecord(recordPtr, elementsPtr) {
    const record = obj(recordPtr);
    const elements = obj(elementsPtr);
    if (!record || !elements || !hasUsefulContent(elements)) return;
    const key = recordKeyFromObj(record);
    if (!key || originalElementsByKey.has(key)) return;
    retainObj(elements);
    originalElementsByKey.set(key, elements.handle);
    trimCacheIfNeeded();
    const n = inc('cache');
    if (shouldLog(n)) log(`[${elapsed()}s] 缓存原始消息 elements #${n} key=${key} count=${elementCount(elements)}`);
}

function cachedElementsForRecord(recordPtr) {
    const record = obj(recordPtr);
    const key = recordKeyFromObj(record);
    if (!key) return null;
    const cached = originalElementsByKey.get(key);
    if (!cached) return null;
    return { key, handle: cached };
}

function markRecalled(recordPtr, reason) {
    const record = obj(recordPtr);
    const key = recordKeyFromObj(record);
    if (!key) return;
    recalledKeys.add(key);
    const cached = originalElementsByKey.get(key);
    if (cached) markCachedTextElements(key, cached);
    const n = inc('recalledKey');
    if (shouldLog(n)) log(`[${elapsed()}s] 标记撤回记录 ${reason} #${n} key=${key} cached=${originalElementsByKey.has(key)}`);
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

function installRecordCache() {
    replace('OCMsgRecord', '- elements', 'pointer', ['pointer', 'pointer'], 'OCMsgRecord.elements 缓存替换', function(orig) {
        return function(self, sel) {
            const ret = orig(self, sel);
            const elements = obj(ret);
            if (elements && hasRecallGrayTip(elements)) markRecalled(self, 'elements=recallGrayTip');
            cacheRecord(self, ret);

            const cached = cachedElementsForRecord(self);
            if (cached && (recalledKeys.has(cached.key) || hasRecallGrayTip(elements))) {
                const n = inc('restoreElements');
                if (shouldLog(n)) log(`[${elapsed()}s] 恢复缓存原始 elements #${n} key=${cached.key}`);
                return cached.handle;
            }
            return ret;
        };
    });

    replace('OCMsgRecord', '- setElements:', 'void', ['pointer', 'pointer', 'pointer'], 'OCMsgRecord.setElements 缓存替换', function(orig) {
        return function(self, sel, value) {
            const incoming = obj(value);
            const cached = cachedElementsForRecord(self);
            if (incoming && hasRecallGrayTip(incoming)) {
                markRecalled(self, 'setElements=recallGrayTip');
                if (cached) {
                    const n = inc('setElementsRestore');
                    if (shouldLog(n)) log(`[${elapsed()}s] 阻止撤回 elements 覆盖并恢复缓存 #${n} key=${cached.key}`);
                    return orig(self, sel, cached.handle);
                }
            } else {
                cacheRecord(self, value);
            }
            return orig(self, sel, value);
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

    replace('OCMsgRecord', '- setIsTailHidden:', 'void', ['pointer', 'pointer', 'bool'], 'OCMsgRecord.setIsTailHidden no-op', function(_orig) {
        return function(_self, _sel, value) {
            const n = inc('tailHiddenSet');
            if (shouldLog(n)) log(`[${elapsed()}s] 阻止 setIsTailHidden=${value} #${n}`);
        };
    });
}

function installPreviewCleaner() {
    replace('OCRecentContactInfo', '- abstractContent', 'pointer', ['pointer', 'pointer'], '左侧预览读取清洗', function(orig) {
        return function(self, sel) {
            const ret = orig(self, sel);
            const clean = cleanPreviewPtr(ret);
            if (!clean.equals(ret)) {
                const n = inc('previewGet');
                if (shouldLog(n)) log(`[${elapsed()}s] 左侧预览读取清洗 #${n}: "${text(ret)}"`);
            }
            return clean;
        };
    });

    replace('OCRecentContactInfo', '- setAbstractContent:', 'void', ['pointer', 'pointer', 'pointer'], '左侧预览写入清洗', function(orig) {
        return function(self, sel, value) {
            const clean = cleanPreviewPtr(value);
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
    installRecordCache();
    installPreviewCleaner();
    log(`安装完成 installed=${installed} cacheLimit=${CACHE_LIMIT}`);
}

if (ObjC.available) ObjC.schedule(ObjC.mainQueue, install);
else log('ObjC runtime 不可用');
