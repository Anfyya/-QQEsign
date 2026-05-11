/*
 * QQESign - full runtime anti-revoke injector.
 *
 * Goals:
 * - keep original messages across chat reloads by blocking recall application
 * - keep a visible in-chat marker by rewriting recall gray-tip wording
 * - sanitize recent-list preview text that says a message was recalled
 *
 * Run:
 *   frida -U -f com.tencent.mqq -l .\frida_research\scripts\frida_runtime_antirevoke_full.js
 */

'use strict';

const TAG = '[QQESign-antirevoke-full]';
const start = Date.now();

const MARK_OTHER = '[防撤回] 对方尝试撤回消息，已阻止';
const MARK_SELF = '[防撤回] 你尝试撤回消息，已阻止';
const MARK_PREVIEW = '[防撤回] 有人尝试撤回消息，已阻止';

const SEL = {
    revokeInit: '- initWithOperatorTinyId:operatorRole:operatorUid:operatorNick:operatorRemark:operatorMemRemark:origMsgSenderUid:origMsgSenderNick:origMsgSenderRemark:origMsgSenderMemRemark:isSelfOperate:wording:',
    grayInit: '- initWithSubElementType:revokeElement:proclamationElement:emojiReplyElement:groupElement:buddyElement:feedMsgElement:essenceElement:xmlElement:fileReceiptElement:localGrayTipElement:blockGrayTipElement:aioOpGrayTipElement:jsonGrayTipElement:walletGrayTipElement:',
};

const counts = Object.create(null);
let installed = 0;

function log(message) {
    console.log(`${TAG} ${message}`);
}

function elapsed() {
    return ((Date.now() - start) / 1000).toFixed(1);
}

function inc(key) {
    counts[key] = (counts[key] || 0) + 1;
    return counts[key];
}

function shouldLog(n) {
    return n <= 8 || (n % 50) === 0;
}

function isNull(value) {
    return !value || value.isNull();
}

function safeObj(value) {
    if (isNull(value)) return null;
    try {
        return new ObjC.Object(value);
    } catch (e) {
        return null;
    }
}

function safeText(value) {
    const obj = safeObj(value);
    if (!obj) return '';
    try {
        return obj.toString();
    } catch (e) {
        try {
            return obj.$className || '';
        } catch (_) {
            return '';
        }
    }
}

function nsString(text) {
    return ObjC.classes.NSString.stringWithUTF8String_(Memory.allocUtf8String(text)).handle;
}

function isRecallText(text) {
    if (!text) return false;
    const lower = String(text).toLowerCase();
    return lower.indexOf('撤回') !== -1 ||
           lower.indexOf('recall') !== -1 ||
           lower.indexOf('revoke') !== -1;
}

function sanitizedTextPtr(value, fallback) {
    const text = safeText(value);
    if (isRecallText(text)) return nsString(fallback || MARK_PREVIEW);
    return value;
}

function method(clsName, selName) {
    const cls = ObjC.classes[clsName];
    if (!cls || !cls[selName] || !cls[selName].implementation) return null;
    return cls[selName];
}

function replace(clsName, selName, retType, argTypes, makeCb, label) {
    try {
        const m = method(clsName, selName);
        if (!m) {
            log(`未找到 ${label}: ${clsName} ${selName}`);
            return false;
        }
        const orig = m.implementation;
        const origFn = new NativeFunction(orig, retType, argTypes);
        const cb = new NativeCallback(makeCb(origFn), retType, argTypes);
        m.implementation = cb;
        installed++;
        log(`已安装 ${label}: ${clsName} ${selName}`);
        return true;
    } catch (e) {
        log(`安装失败 ${label}: ${e.message}`);
        return false;
    }
}

function installRevokeMarker() {
    return replace('OCRevokeElement', SEL.revokeInit, 'pointer',
        ['pointer', 'pointer', 'int64', 'int', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'bool', 'pointer'],
        function(orig) {
            return function(self, sel, operatorTinyId, operatorRole,
                            operatorUid, operatorNick, operatorRemark, operatorMemRemark,
                            origMsgSenderUid, origMsgSenderNick, origMsgSenderRemark, origMsgSenderMemRemark,
                            isSelfOperate, wording) {
                const n = inc('revokeInit');
                const marker = nsString(isSelfOperate ? MARK_SELF : MARK_OTHER);
                if (shouldLog(n)) {
                    log(`[${elapsed()}s] 撤回元素改写为标识 #${n} operator="${safeText(operatorNick)}" original="${safeText(origMsgSenderNick)}"`);
                }
                return orig(self, sel, operatorTinyId, operatorRole,
                            operatorUid, operatorNick, operatorRemark, operatorMemRemark,
                            origMsgSenderUid, origMsgSenderNick, origMsgSenderRemark, origMsgSenderMemRemark,
                            isSelfOperate, marker);
            };
        },
        '撤回元素标识');
}

function installGrayTipMarkerPassThrough() {
    return replace('OCGrayTipElement', SEL.grayInit, 'pointer',
        ['pointer', 'pointer', 'long',
         'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer',
         'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer'],
        function(orig) {
            return function(self, sel, subElementType,
                            revokeElement, proclamationElement, emojiReplyElement,
                            groupElement, buddyElement, feedMsgElement, essenceElement,
                            xmlElement, fileReceiptElement, localGrayTipElement,
                            blockGrayTipElement, aioOpGrayTipElement, jsonGrayTipElement,
                            walletGrayTipElement) {
                if (!isNull(revokeElement)) {
                    const n = inc('grayInit');
                    if (shouldLog(n)) {
                        log(`[${elapsed()}s] 放行防撤回标识灰条 #${n} subType=${subElementType}`);
                    }
                }
                return orig(self, sel, subElementType,
                            revokeElement, proclamationElement, emojiReplyElement,
                            groupElement, buddyElement, feedMsgElement, essenceElement,
                            xmlElement, fileReceiptElement, localGrayTipElement,
                            blockGrayTipElement, aioOpGrayTipElement, jsonGrayTipElement,
                            walletGrayTipElement);
            };
        },
        '防撤回标识灰条');
}

function installVoidNoop(clsName, selName, argTypes, label) {
    return replace(clsName, selName, 'void', ['pointer', 'pointer'].concat(argTypes || []),
        function(_orig) {
            return function() {
                const n = inc(label);
                if (shouldLog(n)) log(`[${elapsed()}s] 已阻断 ${label} #${n}`);
                return;
            };
        },
        label);
}

function installBoolFalse(clsName, selName, label) {
    return replace(clsName, selName, 'bool', ['pointer', 'pointer'],
        function(_orig) {
            return function() {
                const n = inc(label);
                if (shouldLog(n)) log(`[${elapsed()}s] ${label}=false #${n}`);
                return false;
            };
        },
        label);
}

function installObjectSetterSanitizer(clsName, selName, fallback, label) {
    return replace(clsName, selName, 'void', ['pointer', 'pointer', 'pointer'],
        function(orig) {
            return function(self, sel, value) {
                const clean = sanitizedTextPtr(value, fallback);
                if (!clean.equals(value)) {
                    const n = inc(label);
                    if (shouldLog(n)) log(`[${elapsed()}s] 清洗 ${label} #${n}: "${safeText(value)}"`);
                }
                return orig(self, sel, clean);
            };
        },
        label);
}

function installObjectGetterSanitizer(clsName, selName, fallback, label) {
    return replace(clsName, selName, 'pointer', ['pointer', 'pointer'],
        function(orig) {
            return function(self, sel) {
                const value = orig(self, sel);
                const clean = sanitizedTextPtr(value, fallback);
                if (!clean.equals(value)) {
                    const n = inc(label);
                    if (shouldLog(n)) log(`[${elapsed()}s] 清洗 ${label} getter #${n}: "${safeText(value)}"`);
                }
                return clean;
            };
        },
        label);
}

function installRecallFlagBlockers() {
    installBoolFalse('OCMsgRecallInfo', '- isRecallNotify', 'isRecallNotify');
    installBoolFalse('OCMsgRecallInfo', '- isTracelessRecall', 'isTracelessRecall');
    installVoidNoop('OCMsgRecallInfo', '- setIsRecallNotify:', ['bool'], 'setIsRecallNotify');
    installVoidNoop('OCMsgRecallInfo', '- setIsTracelessRecall:', ['bool'], 'setIsTracelessRecall');
}

function installRecallApplyBlockers() {
    installVoidNoop('QQMessageDecouplingBridge', '- recallMessagePair:', ['pointer'], 'QQMessageDecouplingBridge.recallMessagePair');
    installVoidNoop('GroupEmotionManager', '- recallMessagePair:', ['pointer'], 'GroupEmotionManager.recallMessagePair');
    installVoidNoop('RecallPair', '- setRecallModel:', ['pointer'], 'RecallPair.setRecallModel');
    installVoidNoop('RecallPairForOffline', '- setRecallModel:', ['pointer'], 'RecallPairForOffline.setRecallModel');
    installVoidNoop('_TtC15NTKernelAdapter14MessageService', '- getRecallMsgsWithPeer:msgIds:cb:', ['pointer', 'pointer', 'pointer'], 'MessageService.getRecallMsgsWithPeer');
    installVoidNoop('OCIKernelMsgService', '- getRecallMsgsByMsgId:msgIds:cb:', ['pointer', 'pointer', 'pointer'], 'OCIKernelMsgService.getRecallMsgsByMsgId');
}

function installPreviewSanitizers() {
    installObjectGetterSanitizer('OCRecentContactInfo', '- abstractContent', MARK_PREVIEW, 'Recent.abstractContent');
    installObjectSetterSanitizer('OCRecentContactInfo', '- setAbstractContent:', MARK_PREVIEW, 'Recent.setAbstractContent');
    installObjectGetterSanitizer('OCMsgAbstractElement', '- content', MARK_PREVIEW, 'MsgAbstract.content');
    installObjectSetterSanitizer('OCMsgAbstractElement', '- setContent:', MARK_PREVIEW, 'MsgAbstract.setContent');
    installObjectGetterSanitizer('OCMsgAbstractElement', '- mdSummary', MARK_PREVIEW, 'MsgAbstract.mdSummary');
    installObjectSetterSanitizer('OCMsgAbstractElement', '- setMdSummary:', MARK_PREVIEW, 'MsgAbstract.setMdSummary');
}

function install() {
    log(`启动 PID=${Process.id} arch=${Process.arch}`);
    installRevokeMarker();
    installGrayTipMarkerPassThrough();
    installRecallFlagBlockers();
    installRecallApplyBlockers();
    installPreviewSanitizers();
    log(`安装完成 installed=${installed}。目标：原消息保留，聊天内显示防撤回标识，左侧预览不再显示撤回一条消息。`);
}

if (!ObjC.available) {
    log('ObjC runtime 不可用');
} else {
    install();
}
