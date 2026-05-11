/*
 * QQESign - NTQQ anti-revoke bridge.
 *
 * Keep the already verified current-chat blocker:
 *   OCGrayTipElement(... revokeElement ...) -> NULL
 *
 * Also clear recall state when NT kernel data is bridged into OCMsgRecord.
 * NTQQ core is not an ObjC message path, but this bridge object is still the
 * model boundary used by the chat/history UI.
 */

'use strict';

const TAG = '[QQESign-antirevoke-bridge]';
const start = Date.now();
const counts = Object.create(null);

const ALLOW_MARKER_GRAYTIP = true;
const MARK_GRAYTIP = '[防撤回] 对方尝试撤回消息，已阻止';
const MARK_PREVIEW = '[防撤回] 撤回已阻止';
const MARK_INLINE = '\n[防撤回] 对方尝试撤回这条消息，已阻止';

const REVOKE_SEL = '- initWithOperatorTinyId:operatorRole:operatorUid:operatorNick:operatorRemark:operatorMemRemark:origMsgSenderUid:origMsgSenderNick:origMsgSenderRemark:origMsgSenderMemRemark:isSelfOperate:wording:';
const GRAY_SEL = '- initWithSubElementType:revokeElement:proclamationElement:emojiReplyElement:groupElement:buddyElement:feedMsgElement:essenceElement:xmlElement:fileReceiptElement:localGrayTipElement:blockGrayTipElement:aioOpGrayTipElement:jsonGrayTipElement:walletGrayTipElement:';
const MSG_RECORD_SEL = '- initWithMsgId:msgRandom:msgSeq:cntSeq:chatType:msgType:subMsgType:sendType:senderUid:peerUid:channelId:guildId:guildCode:fromUid:fromAppid:msgTime:msgMeta:sendStatus:sendRemarkName:sendMemberName:sendNickName:guildName:channelName:elements:records:emojiLikesList:commentCnt:directMsgFlag:directMsgMembers:peerName:freqLimitInfo:editable:avatarMeta:avatarPendant:feedId:roleId:timeStamp:clientIdentityInfo:isImportMsg:atType:roleType:fromChannelRoleInfo:fromGuildRoleInfo:levelRoleInfo:recallTime:isOnlineMsg:generalFlags:clientSeq:fileGroupSize:foldingInfo:multiTransInfo:senderUin:peerUin:msgAttrs:anonymousExtInfo:nameType:avatarFlag:extInfoForUI:personalMedal:categoryManage:msgEventInfo:';
const MSG_RECORD_FACTORY_SEL = '+ MsgRecordWithMsgId:msgRandom:msgSeq:cntSeq:chatType:msgType:subMsgType:sendType:senderUid:peerUid:channelId:guildId:guildCode:fromUid:fromAppid:msgTime:msgMeta:sendStatus:sendRemarkName:sendMemberName:sendNickName:guildName:channelName:elements:records:emojiLikesList:commentCnt:directMsgFlag:directMsgMembers:peerName:freqLimitInfo:editable:avatarMeta:avatarPendant:feedId:roleId:timeStamp:clientIdentityInfo:isImportMsg:atType:roleType:fromChannelRoleInfo:fromGuildRoleInfo:levelRoleInfo:recallTime:isOnlineMsg:generalFlags:clientSeq:fileGroupSize:foldingInfo:multiTransInfo:senderUin:peerUin:msgAttrs:anonymousExtInfo:nameType:avatarFlag:extInfoForUI:personalMedal:categoryManage:msgEventInfo:';

// ObjC hidden self/cmd occupy args[0] and args[1]. recallTime is business
// parameter #45, so it is args[46] in Frida's onEnter args array.
const MSG_RECORD_RECALL_TIME_ARG = 46;

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
    try { return o.toString(); } catch (_) { return o.$className || ''; }
}

function objText(o) {
    if (!o) return '';
    try { return o.toString(); } catch (_) { return ''; }
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

function isNonZeroScalar(v) {
    const n = numericValue(v);
    return Number.isFinite(n) && n !== 0;
}

function ns(s) {
    return ObjC.classes.NSString.stringWithUTF8String_(Memory.allocUtf8String(s)).handle;
}

function method(c, s) {
    const cls = ObjC.classes[c];
    if (!cls || !cls[s] || !cls[s].implementation) return null;
    return cls[s];
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

function attach(c, s, label, callbacks) {
    try {
        const m = method(c, s);
        if (!m) {
            log(`未找到 ${label}`);
            return false;
        }
        Interceptor.attach(m.implementation, callbacks);
        installed++;
        log(`已观察 ${label}`);
        return true;
    } catch (e) {
        log(`观察失败 ${label}: ${e.message}`);
        return false;
    }
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

function cleanStringPtr(p) {
    if (!isNSString(p)) return p;
    const t = text(p);
    return hasRecallText(t) ? ns(MARK_PREVIEW) : p;
}

function markTextRecord(recordPtr) {
    try {
        const record = obj(recordPtr);
        if (!record || !record.elements) {
            const n = inc('inlineMarkMiss');
            if (shouldLog(n)) log(`[${elapsed()}s] 未找到可标识文本：record/elements 不存在 #${n}`);
            return false;
        }
        const elements = record.elements();
        if (!elements || !elements.count || !elements.objectAtIndex_) {
            const n = inc('inlineMarkMiss');
            if (shouldLog(n)) log(`[${elapsed()}s] 未找到可标识文本：elements 不是数组 #${n}`);
            return false;
        }

        const count = numericValue(elements.count());
        if (!Number.isFinite(count) || count <= 0) {
            const n = inc('inlineMarkMiss');
            if (shouldLog(n)) log(`[${elapsed()}s] 未找到可标识文本：elements 为空 #${n}`);
            return false;
        }
        const max = Math.min(count, 20);
        let firstClass = '';
        for (let i = 0; i < max; i++) {
            const element = elements.objectAtIndex_(i);
            if (i === 0 && element) {
                try { firstClass = element.$className || element.toString(); } catch (_) {}
            }
            if (!element || !element.textElement) continue;
            const textElement = element.textElement();
            if (!textElement || textElement.isNull && textElement.isNull()) continue;
            if (!textElement.content || !textElement.setContent_) continue;

            const current = objText(textElement.content());
            if (!current || current.indexOf('[防撤回]') !== -1) return false;

            const updated = current + MARK_INLINE;
            textElement.setContent_(ns(updated));
            if (textElement.setDisplayText_) textElement.setDisplayText_(ns(updated));

            const n = inc('inlineMark');
            if (shouldLog(n)) log(`[${elapsed()}s] 已给原文本消息追加聊天内防撤回标识 #${n}`);
            return true;
        }
        const n = inc('inlineMarkMiss');
        if (shouldLog(n)) log(`[${elapsed()}s] 未找到可标识文本：elements=${count} first=${firstClass} #${n}`);
    } catch (e) {
        const n = inc('inlineMarkError');
        if (shouldLog(n)) log(`[${elapsed()}s] 追加聊天内标识失败: ${e.message}`);
    }
    return false;
}

function clearRecallTimeArg(args, key, label) {
    const value = args[MSG_RECORD_RECALL_TIME_ARG];
    if (!value || value.isNull()) return;

    const n = inc(key);
    if (shouldLog(n)) {
        log(`[${elapsed()}s] 清零 ${label} recallTime=${value} #${n}`);
    }
    args[MSG_RECORD_RECALL_TIME_ARG] = ptr('0');
}

function installCurrentChatBlocker() {
    if (ALLOW_MARKER_GRAYTIP) {
        replace('OCRevokeElement', REVOKE_SEL, 'pointer',
            ['pointer', 'pointer', 'int64', 'int', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'bool', 'pointer'],
            '撤回元素 wording 改写为防撤回标识',
            function(orig) {
                return function(self, sel, tiny, role, opUid, opNick, opRemark, opMemRemark,
                                origUid, origNick, origRemark, origMemRemark, isSelf, wording) {
                    const n = inc('revoke');
                    if (shouldLog(n)) log(`[${elapsed()}s] 改写撤回元素 #${n} operator="${text(opNick)}" original="${text(origNick)}"`);
                    return orig(self, sel, tiny, role, opUid, opNick, opRemark, opMemRemark,
                                origUid, origNick, origRemark, origMemRemark, isSelf, ns(MARK_GRAYTIP));
                };
            });
    } else {
        attach('OCRevokeElement', REVOKE_SEL, '撤回元素观察', {
            onEnter(args) {
                const n = inc('revoke');
                if (shouldLog(n)) log(`[${elapsed()}s] 看到撤回元素 #${n} operator="${text(args[5])}" original="${text(args[9])}"`);
            },
        });
    }

    const m = method('OCGrayTipElement', GRAY_SEL);
    if (!m) {
        log('未找到 当前聊天灰条短路点');
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
                log(`[${elapsed()}s] ${ALLOW_MARKER_GRAYTIP ? '放行防撤回标识灰条' : '当前聊天阻断撤回灰条'} #${n} subType=${subType}`);
                if (n <= 3) {
                    const trace = stack(this.context);
                    if (trace) log(`  栈:\n    ${trace}`);
                }
            }
            if (!ALLOW_MARKER_GRAYTIP) return ptr('0');
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
    log(`已安装 当前聊天灰条处理：${ALLOW_MARKER_GRAYTIP ? '放行标识灰条并依赖 recallTime 阻断保留原消息' : 'revokeElement 非空时返回 NULL'}`);
}

function installMsgRecordRecallTimeClear() {
    attach('OCMsgRecord', MSG_RECORD_SEL, 'OCMsgRecord.init recallTime 清零', {
        onEnter(args) { clearRecallTimeArg(args, 'recordInitRecallTime', 'OCMsgRecord.init'); },
    });

    attach('OCMsgRecord', MSG_RECORD_FACTORY_SEL, 'OCMsgRecord.factory recallTime 清零', {
        onEnter(args) { clearRecallTimeArg(args, 'recordFactoryRecallTime', 'OCMsgRecord.factory'); },
    });

    replace('OCMsgRecord', '- recallTime', 'int64', ['pointer', 'pointer'], 'OCMsgRecord.recallTime=0', function() {
        return function() {
            const n = inc('recordRecallTimeGet');
            if (shouldLog(n)) log(`[${elapsed()}s] recallTime getter -> 0 #${n}`);
            return 0;
        };
    });

    replace('OCMsgRecord', '- setRecallTime:', 'void', ['pointer', 'pointer', 'int64'], 'OCMsgRecord.setRecallTime no-op', function() {
        return function(self, _sel, value) {
            const n = inc('recordRecallTimeSet');
            if (shouldLog(n)) log(`[${elapsed()}s] 阻止 setRecallTime=${value} #${n}`);
            if (isNonZeroScalar(value)) markTextRecord(self);
        };
    });

    replace('OCMsgRecord', '- setKt_recallTimeFromCodec:', 'void', ['pointer', 'pointer', 'int64'], 'OCMsgRecord.setKt_recallTimeFromCodec no-op', function() {
        return function(self, _sel, value) {
            const n = inc('recordRecallTimeCodec');
            if (shouldLog(n)) log(`[${elapsed()}s] 阻止 codec recallTime=${value} #${n}`);
            if (isNonZeroScalar(value)) markTextRecord(self);
        };
    });

    replace('OCMsgRecord', '- isTailHidden', 'bool', ['pointer', 'pointer'], 'OCMsgRecord.isTailHidden=false', function() {
        return function() { return false; };
    });

    replace('OCMsgRecord', '- setIsTailHidden:', 'void', ['pointer', 'pointer', 'bool'], 'OCMsgRecord.setIsTailHidden no-op', function() {
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
}

function install() {
    log(`启动 PID=${Process.id} arch=${Process.arch}`);
    installCurrentChatBlocker();
    installMsgRecordRecallTimeClear();
    installPreviewCleaner();
    log(`安装完成 installed=${installed}`);
}

if (ObjC.available) ObjC.schedule(ObjC.mainQueue, install);
else log('ObjC runtime 不可用');
