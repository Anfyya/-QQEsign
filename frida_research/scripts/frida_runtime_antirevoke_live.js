/*
 * QQESign - live anti-revoke injector, conservative version.
 *
 * It avoids kernel callback no-ops. Those can destabilize QQ because callers
 * may wait for callbacks. This version only touches the confirmed UI/model
 * layer:
 * - rewrite recall wording into a visible anti-revoke marker
 * - block recallMessagePair: from applying deletion
 * - force recall flags to false
 * - sanitize recent-list preview text
 */

'use strict';

const TAG = '[QQESign-antirevoke-live]';
const start = Date.now();

const MARK_OTHER = '[防撤回] 对方尝试撤回消息，已阻止';
const MARK_SELF = '[防撤回] 你尝试撤回消息，已阻止';
const MARK_PREVIEW = '[防撤回] 有人尝试撤回消息，已阻止';

const counts = Object.create(null);
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

function text(p) {
    const o = obj(p);
    if (!o) return '';
    try { return o.toString(); } catch (_) { return ''; }
}

function ns(s) {
    return ObjC.classes.NSString.stringWithUTF8String_(Memory.allocUtf8String(s)).handle;
}

function hasRecallText(s) {
    const t = String(s || '').toLowerCase();
    return t.indexOf('撤回') !== -1 || t.indexOf('recall') !== -1 || t.indexOf('revoke') !== -1;
}

function method(c, s) {
    const cls = ObjC.classes[c];
    if (!cls || !cls[s] || !cls[s].implementation) return null;
    return cls[s];
}

function replace(c, s, ret, args, label, factory) {
    try {
        const m = method(c, s);
        if (!m) { log(`未找到 ${label}`); return false; }
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

function installRevokeMarker() {
    replace('OCRevokeElement',
        '- initWithOperatorTinyId:operatorRole:operatorUid:operatorNick:operatorRemark:operatorMemRemark:origMsgSenderUid:origMsgSenderNick:origMsgSenderRemark:origMsgSenderMemRemark:isSelfOperate:wording:',
        'pointer',
        ['pointer', 'pointer', 'int64', 'int', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'bool', 'pointer'],
        '撤回元素改写为聊天内标识',
        function(orig) {
            return function(self, sel, tiny, role, opUid, opNick, opRemark, opMemRemark,
                            origUid, origNick, origRemark, origMemRemark, isSelf, wording) {
                const n = inc('revoke');
                if (shouldLog(n)) log(`[${elapsed()}s] 标识撤回 #${n} operator="${text(opNick)}" original="${text(origNick)}"`);
                return orig(self, sel, tiny, role, opUid, opNick, opRemark, opMemRemark,
                            origUid, origNick, origRemark, origMemRemark,
                            isSelf, ns(isSelf ? MARK_SELF : MARK_OTHER));
            };
        });
}

function installGrayTipObserver() {
    replace('OCGrayTipElement',
        '- initWithSubElementType:revokeElement:proclamationElement:emojiReplyElement:groupElement:buddyElement:feedMsgElement:essenceElement:xmlElement:fileReceiptElement:localGrayTipElement:blockGrayTipElement:aioOpGrayTipElement:jsonGrayTipElement:walletGrayTipElement:',
        'pointer',
        ['pointer', 'pointer', 'long', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer'],
        '防撤回标识灰条放行',
        function(orig) {
            return function(self, sel, subType, revokeElement, proclamationElement, emojiReplyElement,
                            groupElement, buddyElement, feedMsgElement, essenceElement,
                            xmlElement, fileReceiptElement, localGrayTipElement,
                            blockGrayTipElement, aioOpGrayTipElement, jsonGrayTipElement,
                            walletGrayTipElement) {
                if (!isNull(revokeElement)) {
                    const n = inc('gray');
                    if (shouldLog(n)) log(`[${elapsed()}s] 聊天内防撤回标识灰条 #${n}`);
                }
                return orig(self, sel, subType, revokeElement, proclamationElement, emojiReplyElement,
                            groupElement, buddyElement, feedMsgElement, essenceElement,
                            xmlElement, fileReceiptElement, localGrayTipElement,
                            blockGrayTipElement, aioOpGrayTipElement, jsonGrayTipElement,
                            walletGrayTipElement);
            };
        });
}

function installRecallApplyBlockers() {
    replace('QQMessageDecouplingBridge', '- recallMessagePair:',
        'void', ['pointer', 'pointer', 'pointer'],
        '阻断撤回落库/应用 QQMessageDecouplingBridge.recallMessagePair',
        function(_orig) {
            return function() {
                const n = inc('bridge');
                if (shouldLog(n)) log(`[${elapsed()}s] 已阻断撤回落库/应用 #${n}`);
                return;
            };
        });

    replace('GroupEmotionManager', '- recallMessagePair:',
        'void', ['pointer', 'pointer', 'pointer'],
        '阻断群表情撤回应用 GroupEmotionManager.recallMessagePair',
        function(_orig) {
            return function() {
                const n = inc('groupBridge');
                if (shouldLog(n)) log(`[${elapsed()}s] 已阻断群表情撤回应用 #${n}`);
                return;
            };
        });
}

function installRecallFlagBlockers() {
    replace('OCMsgRecallInfo', '- isRecallNotify', 'bool', ['pointer', 'pointer'], '撤回标记读取=false', function() {
        return function() { return false; };
    });
    replace('OCMsgRecallInfo', '- isTracelessRecall', 'bool', ['pointer', 'pointer'], '无痕撤回标记读取=false', function() {
        return function() { return false; };
    });
    replace('OCMsgRecallInfo', '- setIsRecallNotify:', 'void', ['pointer', 'pointer', 'bool'], '阻止写入撤回标记', function() {
        return function() { return; };
    });
    replace('OCMsgRecallInfo', '- setIsTracelessRecall:', 'void', ['pointer', 'pointer', 'bool'], '阻止写入无痕撤回标记', function() {
        return function() { return; };
    });
}

function isNSString(p) {
    const o = obj(p);
    if (!o) return false;
    try { return o.isKindOfClass_(ObjC.classes.NSString); } catch (_) { return false; }
}

function cleanStringPtr(p) {
    if (!isNSString(p)) return p;
    const t = text(p);
    if (hasRecallText(t)) return ns(MARK_PREVIEW);
    return p;
}

function installPreviewSanitizers() {
    replace('OCRecentContactInfo', '- abstractContent', 'pointer', ['pointer', 'pointer'], '左侧预览读取清洗', function(orig) {
        return function(self, sel) {
            const ret = orig(self, sel);
            const clean = cleanStringPtr(ret);
            if (!clean.equals(ret)) {
                const n = inc('previewGet');
                if (shouldLog(n)) log(`[${elapsed()}s] 左侧预览读取清洗 #${n}: "${text(ret)}"`);
            }
            return clean;
        };
    });
    replace('OCRecentContactInfo', '- setAbstractContent:', 'void', ['pointer', 'pointer', 'pointer'], '左侧预览写入清洗', function(orig) {
        return function(self, sel, value) {
            const clean = cleanStringPtr(value);
            if (!clean.equals(value)) {
                const n = inc('previewSet');
                if (shouldLog(n)) log(`[${elapsed()}s] 左侧预览写入清洗 #${n}: "${text(value)}"`);
            }
            return orig(self, sel, clean);
        };
    });

    replace('OCMsgAbstractElement', '- setContent:', 'void', ['pointer', 'pointer', 'pointer'], '消息摘要内容写入清洗', function(orig) {
        return function(self, sel, value) {
            const clean = cleanStringPtr(value);
            if (!clean.equals(value)) {
                const n = inc('abstractSetContent');
                if (shouldLog(n)) log(`[${elapsed()}s] 消息摘要内容写入清洗 #${n}: "${text(value)}"`);
            }
            return orig(self, sel, clean);
        };
    });

    replace('OCMsgAbstractElement', '- content', 'pointer', ['pointer', 'pointer'], '消息摘要内容读取清洗', function(orig) {
        return function(self, sel) {
            const ret = orig(self, sel);
            const clean = cleanStringPtr(ret);
            if (!clean.equals(ret)) {
                const n = inc('abstractGetContent');
                if (shouldLog(n)) log(`[${elapsed()}s] 消息摘要内容读取清洗 #${n}: "${text(ret)}"`);
            }
            return clean;
        };
    });
}

function install() {
    log(`启动 PID=${Process.id} arch=${Process.arch}`);
    installRevokeMarker();
    installGrayTipObserver();
    installRecallApplyBlockers();
    installRecallFlagBlockers();
    installPreviewSanitizers();
    log(`安装完成 installed=${installed}`);
}

if (ObjC.available) install();
else log('ObjC runtime 不可用');
