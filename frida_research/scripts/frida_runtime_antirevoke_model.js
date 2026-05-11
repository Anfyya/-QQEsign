/*
 * QQESign - NTQQ runtime anti-revoke at decoded model boundary.
 *
 * Verified stable blocker is kept:
 *   OCGrayTipElement(... revokeElement ...) -> NULL
 *
 * This version also caches normal OCMsgRecord elements and maps recall targets
 * from OCMsgRecallInfo / RecallPair so leaving and re-entering a chat can reuse
 * the original model when NTQQ rebuilds the conversation.
 */

'use strict';

const TAG = '[QQESign-antirevoke-model]';
const start = Date.now();
const counts = Object.create(null);

const REVOKE_SEL = '- initWithOperatorTinyId:operatorRole:operatorUid:operatorNick:operatorRemark:operatorMemRemark:origMsgSenderUid:origMsgSenderNick:origMsgSenderRemark:origMsgSenderMemRemark:isSelfOperate:wording:';
const GRAY_SEL = '- initWithSubElementType:revokeElement:proclamationElement:emojiReplyElement:groupElement:buddyElement:feedMsgElement:essenceElement:xmlElement:fileReceiptElement:localGrayTipElement:blockGrayTipElement:aioOpGrayTipElement:jsonGrayTipElement:walletGrayTipElement:';
const MSG_RECORD_SEL = '- initWithMsgId:msgRandom:msgSeq:cntSeq:chatType:msgType:subMsgType:sendType:senderUid:peerUid:channelId:guildId:guildCode:fromUid:fromAppid:msgTime:msgMeta:sendStatus:sendRemarkName:sendMemberName:sendNickName:guildName:channelName:elements:records:emojiLikesList:commentCnt:directMsgFlag:directMsgMembers:peerName:freqLimitInfo:editable:avatarMeta:avatarPendant:feedId:roleId:timeStamp:clientIdentityInfo:isImportMsg:atType:roleType:fromChannelRoleInfo:fromGuildRoleInfo:levelRoleInfo:recallTime:isOnlineMsg:generalFlags:clientSeq:fileGroupSize:foldingInfo:multiTransInfo:senderUin:peerUin:msgAttrs:anonymousExtInfo:nameType:avatarFlag:extInfoForUI:personalMedal:categoryManage:msgEventInfo:';
const MSG_RECORD_FACTORY_SEL = '+ MsgRecordWithMsgId:msgRandom:msgSeq:cntSeq:chatType:msgType:subMsgType:sendType:senderUid:peerUid:channelId:guildId:guildCode:fromUid:fromAppid:msgTime:msgMeta:sendStatus:sendRemarkName:sendMemberName:sendNickName:guildName:channelName:elements:records:emojiLikesList:commentCnt:directMsgFlag:directMsgMembers:peerName:freqLimitInfo:editable:avatarMeta:avatarPendant:feedId:roleId:timeStamp:clientIdentityInfo:isImportMsg:atType:roleType:fromChannelRoleInfo:fromGuildRoleInfo:levelRoleInfo:recallTime:isOnlineMsg:generalFlags:clientSeq:fileGroupSize:foldingInfo:multiTransInfo:senderUin:peerUin:msgAttrs:anonymousExtInfo:nameType:avatarFlag:extInfoForUI:personalMedal:categoryManage:msgEventInfo:';
const RECENT_SEL = '- initWithId:contactId:sortField:chatType:senderUid:senderUin:peerUid:peerUin:msgSeq:c2cClientMsgSeq:msgUid:msgRandom:msgTime:sendRemarkName:sendMemberName:sendNickName:peerName:remark:memberName:avatarUrl:avatarPath:abstractContent:sendStatus:topFlag:topFlagTime:draftFlag:draftTime:specialCareFlag:sessionType:shieldFlag:atType:draft:hiddenFlag:keepHiddenFlag:isMsgDisturb:nestedSortedContactList:nestedChangedList:unreadCnt:unreadChatCnt:unreadFlag:isBeat:isOnlineMsg:msgId:notifiedType:isBlock:listOfSpecificEventTypeInfosInMsgBox:guildContactInfo:vasPersonalInfo:vasMsgInfo:anonymousFlag:extBuffer:extAttrs:liteBusiness:';
const RECENT_FACTORY_SEL = '+ RecentContactInfoWithId:contactId:sortField:chatType:senderUid:senderUin:peerUid:peerUin:msgSeq:c2cClientMsgSeq:msgUid:msgRandom:msgTime:sendRemarkName:sendMemberName:sendNickName:peerName:remark:memberName:avatarUrl:avatarPath:abstractContent:sendStatus:topFlag:topFlagTime:draftFlag:draftTime:specialCareFlag:sessionType:shieldFlag:atType:draft:hiddenFlag:keepHiddenFlag:isMsgDisturb:nestedSortedContactList:nestedChangedList:unreadCnt:unreadChatCnt:unreadFlag:isBeat:isOnlineMsg:msgId:notifiedType:isBlock:listOfSpecificEventTypeInfosInMsgBox:guildContactInfo:vasPersonalInfo:vasMsgInfo:anonymousFlag:extBuffer:extAttrs:liteBusiness:';

const ARG_MSG_ID = 2;
const ARG_MSG_RANDOM = 3;
const ARG_MSG_SEQ = 4;
const ARG_MSG_TYPE = 7;
const ARG_SUB_MSG_TYPE = 8;
const ARG_SENDER_UID = 10;
const ARG_PEER_UID = 11;
const ARG_ELEMENTS = 25;
const ARG_RECALL_TIME = 46;
const ARG_RECENT_ABSTRACT = 23;

const MARK_INLINE = '\n[防撤回] 对方尝试撤回这条消息，已阻止';
const CACHE_LIMIT = 3000;

const elementsByKey = new Map();
const textByKey = new Map();
const recordByKey = new Map();
const msgTypeByKey = new Map();
const subMsgTypeByKey = new Map();
const syntheticElementsByKey = new Map();
const syntheticAtomDataByKey = new Map();
const recalledKeys = new Set();
const markedKeys = new Set();
const textElementKeyByPtr = new Map();
const hookedTextElementClasses = new Set();
const recentBySender = new Map();
const recallInfoByPtr = new Map();
const pairByPtr = new Map();

let installed = 0;

function log(s) { console.log(`${TAG} ${s}`); }
function elapsed() { return ((Date.now() - start) / 1000).toFixed(1); }
function inc(k) { counts[k] = (counts[k] || 0) + 1; return counts[k]; }
function shouldLog(n) { return n <= 10 || (n % 50) === 0; }
function shouldLogHot(n) { return n <= 5 || (n % 500) === 0; }
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
    return ObjC.classes.NSString.stringWithUTF8String_(Memory.allocUtf8String(String(s))).handle;
}

function isNSString(p) {
    const o = obj(p);
    if (!o) return false;
    try { return o.isKindOfClass_(ObjC.classes.NSString); } catch (_) { return false; }
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

function i64(v) {
    try { return new Int64(v); } catch (_) { return new Int64(String(v)); }
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

function ptrId(p) {
    try { return p.toString(); } catch (_) { return ''; }
}

function keyParts(peer, seq, random, msgId) {
    return {
        peer: String(peer || ''),
        seq: numericValue(seq),
        random: numericValue(random),
        msgId: numericValue(msgId),
    };
}

function keyVariants(parts) {
    const out = [];
    if (!parts.peer && !parts.seq && !parts.random && !parts.msgId) return out;
    if (parts.peer && parts.seq && parts.random && parts.msgId) out.push(`${parts.peer}|${parts.seq}|${parts.random}|${parts.msgId}`);
    if (parts.peer && parts.seq && parts.random) out.push(`${parts.peer}|${parts.seq}|${parts.random}`);
    if (parts.peer && parts.seq) out.push(`${parts.peer}|${parts.seq}`);
    if (parts.peer && parts.random) out.push(`${parts.peer}|r:${parts.random}`);
    return Array.from(new Set(out));
}

function recordPartsFromArgs(args) {
    return keyParts(text(args[ARG_PEER_UID]), args[ARG_MSG_SEQ], args[ARG_MSG_RANDOM], args[ARG_MSG_ID]);
}

function recordSenderFromArgs(args) {
    return text(args[ARG_SENDER_UID]);
}

function recordPartsFromObj(recordPtr) {
    const record = obj(recordPtr);
    if (!record) return keyParts('', 0, 0, 0);
    let peer = '';
    let seq = 0;
    let random = 0;
    let msgId = 0;
    try { if (record.peerUid) peer = objString(record.peerUid()); } catch (_) {}
    try { if (record.msgSeq) seq = numericValue(record.msgSeq()); } catch (_) {}
    try { if (record.msgRandom) random = numericValue(record.msgRandom()); } catch (_) {}
    try { if (record.msgId) msgId = numericValue(record.msgId()); } catch (_) {}
    return keyParts(peer, seq, random, msgId);
}

function recordSenderFromObj(recordPtr) {
    const record = obj(recordPtr);
    if (!record) return '';
    try { if (record.senderUid) return objString(record.senderUid()); } catch (_) {}
    return '';
}

function recordTypesFromObj(recordPtr) {
    const record = obj(recordPtr);
    const out = { msgType: null, subMsgType: null };
    if (!record) return out;
    try { if (record.msgType) out.msgType = numericValue(record.msgType()); } catch (_) {}
    try { if (record.subMsgType) out.subMsgType = numericValue(record.subMsgType()); } catch (_) {}
    return out;
}

function cacheRecordTypes(keys, msgType, subMsgType, source) {
    if (!keys || keys.length === 0) return;
    const hasMt = msgType !== null && msgType !== undefined;
    const hasSt = subMsgType !== null && subMsgType !== undefined;
    const mt = hasMt ? numericValue(msgType) : NaN;
    const st = hasSt ? numericValue(subMsgType) : NaN;
    let added = false;
    for (const key of keys) {
        if (Number.isFinite(mt) && !msgTypeByKey.has(key)) {
            msgTypeByKey.set(key, mt);
            added = true;
        }
        if (Number.isFinite(st) && !subMsgTypeByKey.has(key)) {
            subMsgTypeByKey.set(key, st);
            added = true;
        }
    }
    if (added) {
        const n = inc('typeCache');
        if (shouldLog(n)) log(`[${elapsed()}s] 缓存原始类型 #${n} source=${source} msgType=${mt} subMsgType=${st} key=${keys[0]}`);
    }
}

function retainObj(o) {
    try { if (o && o.retain) o.retain(); } catch (_) {}
}

function trimCache() {
    while (elementsByKey.size > CACHE_LIMIT) {
        const first = elementsByKey.keys().next().value;
        elementsByKey.delete(first);
        textByKey.delete(first);
        recalledKeys.delete(first);
        markedKeys.delete(first);
        recordByKey.delete(first);
        msgTypeByKey.delete(first);
        subMsgTypeByKey.delete(first);
        syntheticElementsByKey.delete(first);
        syntheticAtomDataByKey.delete(first);
    }
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

function textFromElements(elements) {
    try {
        const count = Math.min(elementCount(elements), 10);
        for (let i = 0; i < count; i++) {
            const element = elements.objectAtIndex_(i);
            if (!element || !element.textElement) continue;
            const textElement = element.textElement();
            if (!textElement || (textElement.isNull && textElement.isNull())) continue;
            let s = '';
            try { if (textElement.content) s = objString(textElement.content()); } catch (_) {}
            if (!s) {
                try { if (textElement.displayText) s = objString(textElement.displayText()); } catch (_) {}
            }
            if (!s) {
                try { if (textElement.swizzled_content) s = objString(textElement.swizzled_content()); } catch (_) {}
            }
            if (s && !hasRecallText(s) && s.indexOf('[防撤回]') === -1) return s;
        }
    } catch (_) {}
    return '';
}

function classNameOf(o) {
    if (!o) return '';
    try { return o.$className || ''; } catch (_) { return ''; }
}

function markedTextForKey(key, ret) {
    if (!key || !recalledKeys.has(key) || !isNSString(ret)) return ret;
    const s = text(ret);
    if (!s || hasRecallText(s) || s.indexOf('[防撤回]') !== -1) return ret;
    const n = inc('textGetterMark');
    if (shouldLogHot(n)) log(`[${elapsed()}s] 文本 getter 返回防撤回标识 #${n} key=${key}`);
    return ns(s + MARK_INLINE);
}

function installTextElementClassHooks(className) {
    if (!className || hookedTextElementClasses.has(className)) return;
    hookedTextElementClasses.add(className);
    replace(className, '- content', 'pointer', ['pointer', 'pointer'], `${className}.content 标识`, function(orig) {
        return function(self, sel) {
            return markedTextForKey(textElementKeyByPtr.get(ptrId(self)), orig(self, sel));
        };
    });
    replace(className, '- displayText', 'pointer', ['pointer', 'pointer'], `${className}.displayText 标识`, function(orig) {
        return function(self, sel) {
            return markedTextForKey(textElementKeyByPtr.get(ptrId(self)), orig(self, sel));
        };
    });
    replace(className, '- swizzled_content', 'pointer', ['pointer', 'pointer'], `${className}.swizzled_content 标识`, function(orig) {
        return function(self, sel) {
            return markedTextForKey(textElementKeyByPtr.get(ptrId(self)), orig(self, sel));
        };
    });
}

function noteTextElements(elements, keys, source) {
    if (!elements || !keys || keys.length === 0) return;
    try {
        const count = Math.min(elementCount(elements), 10);
        for (let i = 0; i < count; i++) {
            const element = elements.objectAtIndex_(i);
            if (!element || !element.textElement) continue;
            const textElement = element.textElement();
            if (!textElement || (textElement.isNull && textElement.isNull())) continue;
            textElementKeyByPtr.set(ptrId(textElement.handle), keys[0]);
            installTextElementClassHooks(classNameOf(textElement));
            let s = '';
            try { if (textElement.content) s = objString(textElement.content()); } catch (_) {}
            if (!s) {
                try { if (textElement.displayText) s = objString(textElement.displayText()); } catch (_) {}
            }
            if (!s) {
                try { if (textElement.swizzled_content) s = objString(textElement.swizzled_content()); } catch (_) {}
            }
            if (s && !hasRecallText(s) && s.indexOf('[防撤回]') === -1) {
                for (const key of keys) {
                    if (!textByKey.has(key)) textByKey.set(key, s);
                }
            }
            const n = inc('noteTextElement');
            if (shouldLogHot(n)) log(`[${elapsed()}s] 记录文本元素 #${n} source=${source} class=${classNameOf(textElement)} key=${keys[0]}`);
        }
    } catch (_) {}
}

function hasUsefulContent(elements) {
    try {
        const count = Math.min(elementCount(elements), 10);
        if (count <= 0 || hasRecallGrayTip(elements)) return false;
        if (textFromElements(elements)) return true;
        for (let i = 0; i < count; i++) {
            const element = elements.objectAtIndex_(i);
            if (!element) continue;
            if (element.picElement || element.pttElement || element.videoElement || element.fileElement || element.replyElement) return true;
        }
    } catch (_) {}
    return false;
}

function rememberRecent(sender, parts, keys) {
    if (!sender || keys.length === 0) return;
    let arr = recentBySender.get(sender);
    if (!arr) {
        arr = [];
        recentBySender.set(sender, arr);
    }
    arr.push({ parts, keys, time: Date.now() });
    while (arr.length > 80) arr.shift();
}

function cacheElements(elementsPtr, parts, sender, source) {
    const elements = obj(elementsPtr);
    if (!elements || !hasUsefulContent(elements)) return false;
    const keys = keyVariants(parts);
    if (keys.length === 0) return false;
    const s = textFromElements(elements);
    noteTextElements(elements, keys, source);
    retainObj(elements);
    let added = false;
    for (const key of keys) {
        if (!elementsByKey.has(key)) {
            elementsByKey.set(key, elements.handle);
            if (s) textByKey.set(key, s);
            added = true;
        }
    }
    rememberRecent(sender, parts, keys);
    if (added) {
        trimCache();
        const n = inc('cache');
        if (shouldLog(n)) log(`[${elapsed()}s] 缓存原始消息 #${n} source=${source} keys=${keys.join(',')} text="${s.slice(0, 80)}"`);
    }
    return true;
}

function findCached(keys) {
    for (const key of keys) {
        const handle = elementsByKey.get(key);
        if (handle) return { key, handle };
    }
    return null;
}

function peerFromKeys(keys) {
    for (const key of keys || []) {
        const peer = String(key).split('|')[0];
        if (peer) return peer;
    }
    return '';
}

function findCachedForPreview(keys) {
    const exact = findCached(keys || []);
    if (exact && originalTextForCached(exact)) return exact;

    const peer = peerFromKeys(keys);
    if (!peer) return exact;
    const recalled = Array.from(recalledKeys);
    for (let i = recalled.length - 1; i >= 0; i--) {
        const key = recalled[i];
        if (key.indexOf(peer + '|') !== 0) continue;
        const handle = elementsByKey.get(key);
        if (!handle) continue;
        const cached = { key, handle };
        if (originalTextForCached(cached)) return cached;
    }
    return exact;
}

function cacheRecordHandle(recordPtr, parts, source) {
    const record = obj(recordPtr);
    if (!record) return false;
    const keys = keyVariants(parts);
    if (keys.length === 0) return false;
    const types = recordTypesFromObj(recordPtr);
    cacheRecordTypes(keys, types.msgType, types.subMsgType, `${source}.recordType`);
    retainObj(record);
    let added = false;
    for (const key of keys) {
        if (!recordByKey.has(key)) {
            recordByKey.set(key, record.handle);
            added = true;
        }
    }
    if (added) {
        const n = inc('recordCache');
        if (shouldLog(n)) log(`[${elapsed()}s] 缓存原始 record #${n} source=${source} keys=${keys.join(',')}`);
    }
    return added;
}

function findCachedRecord(keys) {
    for (const key of keys) {
        const handle = recordByKey.get(key);
        if (handle) return { key, handle };
    }
    return null;
}

function syntheticElementsForCached(cached, source) {
    if (!cached || !cached.key) return null;
    const existing = syntheticElementsByKey.get(cached.key);
    if (existing) return existing;

    const original = originalTextForCached(cached);
    if (!original) return null;

    try {
        let textObj = null;
        try { textObj = ObjC.classes.OCTextElement.TextElement(); } catch (_) {}
        if (!textObj) textObj = ObjC.classes.OCTextElement.alloc().init();
        if (!textObj) return null;
        const marked = ns(original + MARK_INLINE);
        if (textObj.setContent_) textObj.setContent_(marked);
        if (textObj.setDisplayText_) textObj.setDisplayText_(marked);
        if (textObj.swizzled_setContent_) textObj.swizzled_setContent_(marked);
        if (textObj.setSubElementType_) {
            try { textObj.setSubElementType_(i64(0)); } catch (_) {
                try { textObj.setSubElementType_(0); } catch (_) {}
            }
        }
        retainObj(textObj);
        textElementKeyByPtr.set(ptrId(textObj.handle), cached.key);
        installTextElementClassHooks(classNameOf(textObj));

        const msgObj = ObjC.classes.OCMsgElement.MsgElement();
        if (!msgObj) return null;
        if (msgObj.setElementType_) {
            try { msgObj.setElementType_(i64(1)); } catch (_) {
                try { msgObj.setElementType_(1); } catch (_) {}
            }
        }
        if (msgObj.setElementId_) {
            try { msgObj.setElementId_(i64(0)); } catch (_) {}
        }
        if (msgObj.setTextElement_) msgObj.setTextElement_(textObj);
        retainObj(msgObj);

        const arr = ObjC.classes.NSMutableArray.array();
        arr.addObject_(msgObj);
        retainObj(arr);
        syntheticElementsByKey.set(cached.key, arr.handle);
        markedKeys.add(cached.key);

        const n = inc('syntheticText');
        if (shouldLog(n)) log(`[${elapsed()}s] 重建撤回原文 text elements #${n} source=${source} key=${cached.key} text="${original.slice(0, 80)}"`);
        return arr.handle;
    } catch (e) {
        const n = inc('syntheticTextErr');
        if (shouldLog(n)) log(`[${elapsed()}s] 重建 text elements 失败 #${n} source=${source}: ${e.message}`);
        return null;
    }
}

function textAtomDataForCachedRecord(recordPtr, cached, source) {
    if (!cached || !cached.key || !recordPtr) return null;
    const existing = syntheticAtomDataByKey.get(cached.key);
    if (existing) return existing;
    if (!originalTextForCached(cached)) return null;

    try {
        const cls = ObjC.classes['AIOChatProtocol.TextAtomMsgData'];
        if (!cls) return null;
        const record = obj(recordPtr);
        if (!record) return null;

        let atom = null;
        try { atom = cls.alloc().initWithMsgRecord_(record); } catch (_) {}
        if (!atom) {
            try { atom = cls.alloc().initWithMsg_(record); } catch (_) {}
        }
        if (!atom) return null;

        retainObj(atom);
        syntheticAtomDataByKey.set(cached.key, atom.handle);
        const n = inc('syntheticAtomData');
        if (shouldLog(n)) log(`[${elapsed()}s] 重建 TextAtomMsgData #${n} source=${source} key=${cached.key}`);
        return atom.handle;
    } catch (e) {
        const n = inc('syntheticAtomDataErr');
        if (shouldLog(n)) log(`[${elapsed()}s] 重建 TextAtomMsgData 失败 #${n} source=${source}: ${e.message}`);
        return null;
    }
}

function markElements(cached, reason) {
    if (!cached || !cached.handle || markedKeys.has(cached.key)) return;
    try {
        const elements = obj(cached.handle);
        const count = Math.min(elementCount(elements), 10);
        for (let i = 0; i < count; i++) {
            const element = elements.objectAtIndex_(i);
            if (!element || !element.textElement) continue;
            const textElement = element.textElement();
            if (!textElement || (textElement.isNull && textElement.isNull())) continue;
            textElementKeyByPtr.set(ptrId(textElement.handle), cached.key);
            installTextElementClassHooks(classNameOf(textElement));
            let current = '';
            try { if (textElement.content) current = objString(textElement.content()); } catch (_) {}
            if (!current) {
                try { if (textElement.displayText) current = objString(textElement.displayText()); } catch (_) {}
            }
            if (!current || current.indexOf('[防撤回]') !== -1) {
                markedKeys.add(cached.key);
                return;
            }
            const updated = current + MARK_INLINE;
            if (textElement.setContent_) textElement.setContent_(ns(updated));
            if (textElement.setDisplayText_) textElement.setDisplayText_(ns(updated));
            if (textElement.swizzled_setContent_) textElement.swizzled_setContent_(ns(updated));
            markedKeys.add(cached.key);
            const n = inc('markText');
            if (shouldLog(n)) log(`[${elapsed()}s] 已给原消息加标识 #${n} reason=${reason} key=${cached.key}`);
            return;
        }
    } catch (e) {
        const n = inc('markTextErr');
        if (shouldLog(n)) log(`[${elapsed()}s] 原消息标识失败 #${n}: ${e.message}`);
    }
}

function markRecalledByKeys(keys, reason) {
    if (!keys || keys.length === 0) return null;
    const known = keys.some(k => recalledKeys.has(k));
    for (const key of keys) recalledKeys.add(key);
    const cached = findCached(keys);
    if (cached) markElements(cached, reason);
    if (!known) {
        const n = inc('markRecall');
        if (shouldLog(n)) log(`[${elapsed()}s] 标记撤回 #${n} reason=${reason} keys=${keys.join(',')} cached=${!!cached}`);
    }
    return cached;
}

function refreshRecallInfoState(self, state) {
    const info = obj(self);
    if (!info) return state;
    try { if (!state.peerUid && info.recallMsgPeerUid) state.peerUid = objString(info.recallMsgPeerUid()); } catch (_) {}
    try { if (!state.senderUid && info.recallMsgSenderUid) state.senderUid = objString(info.recallMsgSenderUid()); } catch (_) {}
    try { if (!state.seq && info.recallMsgSeq) state.seq = numericValue(info.recallMsgSeq()); } catch (_) {}
    try { if (!state.seq && info.recallMsgC2cClientSeq) state.seq = numericValue(info.recallMsgC2cClientSeq()); } catch (_) {}
    try { if (!state.random && info.recallMsgRandom) state.random = numericValue(info.recallMsgRandom()); } catch (_) {}
    return state;
}

function recallInfoState(self) {
    const id = ptrId(self);
    let state = recallInfoByPtr.get(id);
    if (!state) {
        state = {};
        recallInfoByPtr.set(id, state);
    }
    return state;
}

function markRecallInfo(self, source) {
    const state = refreshRecallInfoState(self, recallInfoState(self));
    const peer = state.peerUid || state.senderUid || '';
    const parts = keyParts(peer, state.seq || 0, state.random || 0, 0);
    const keys = keyVariants(parts);
    if (keys.length === 0) return null;
    return markRecalledByKeys(keys, `OCMsgRecallInfo.${source}`);
}

function pairState(self) {
    const id = ptrId(self);
    let state = pairByPtr.get(id);
    if (!state) {
        state = {};
        pairByPtr.set(id, state);
    }
    return state;
}

function cacheRecordObject(recordPtr, source) {
    const record = obj(recordPtr);
    if (!record || !record.elements) return false;
    const parts = recordPartsFromObj(recordPtr);
    cacheRecordHandle(recordPtr, parts, source);
    let elements = null;
    try { elements = record.elements(); } catch (_) {}
    if (!elements) return false;
    return cacheElements(elements.handle, parts, recordSenderFromObj(recordPtr), source);
}

function recentPartsFromArgs(args) {
    return keyParts(text(args[8]) || text(args[3]), args[10], args[13], args[2]);
}

function recentPartsFromObj(self) {
    const recent = obj(self);
    if (!recent) return keyParts('', 0, 0, 0);
    let peer = '';
    let seq = 0;
    let random = 0;
    let msgId = 0;
    try { if (recent.peerUid) peer = objString(recent.peerUid()); } catch (_) {}
    try { if (!peer && recent.contactId) peer = objString(recent.contactId()); } catch (_) {}
    try { if (recent.msgSeq) seq = numericValue(recent.msgSeq()); } catch (_) {}
    try { if (recent.msgRandom) random = numericValue(recent.msgRandom()); } catch (_) {}
    try { if (recent.msgId) msgId = numericValue(recent.msgId()); } catch (_) {}
    return keyParts(peer, seq, random, msgId);
}

function cleanPreviewPtr(value, keys, source) {
    if (!isNSString(value)) return value;
    const s = text(value);
    if (!hasRecallText(s)) return value;
    const cached = findCachedForPreview(keys || []);
    const restored = originalTextForCached(cached);
    if (restored) {
        const n = inc('previewRestore');
        if (shouldLog(n)) log(`[${elapsed()}s] 左侧预览恢复原文 #${n} source=${source} key=${cached.key} text="${restored.slice(0, 80)}"`);
        return ns(restored);
    }
    return value;
}

function originalTextForCached(cached) {
    if (!cached) return '';
    let s = textByKey.get(cached.key) || '';
    if (!s) s = textFromElements(obj(cached.handle));
    if (!s) return '';
    return s.replace(/\n?\[防撤回\][\s\S]*$/, '');
}

function cleanRecordSummaryPtr(recordPtr, value, source) {
    const parts = recordPartsFromObj(recordPtr);
    const keys = keyVariants(parts);
    const recalled = keys.some(k => recalledKeys.has(k));
    let cached = null;
    if (recalled) cached = findCached(keys);

    if (cached) {
        const s = originalTextForCached(cached);
        if (s) {
            markElements(cached, source);
            const n = inc('recordSummaryRestore');
            if (shouldLog(n)) log(`[${elapsed()}s] 恢复撤回消息摘要 #${n} source=${source} key=${cached.key} text="${s.slice(0, 80)}"`);
            return ns(s);
        }
    }

    if (isNSString(value) && hasRecallText(text(value))) {
        const n = inc('recordSummaryClean');
        if (shouldLog(n)) log(`[${elapsed()}s] 清洗撤回摘要 #${n} source=${source}: "${text(value)}"`);
        return value;
    }

    return value;
}

function cleanRecallTextPtr(value, source) {
    return value;
}

function restoreRecordObject(recordPtr, source) {
    const record = obj(recordPtr);
    if (!record) return recordPtr;
    const parts = recordPartsFromObj(recordPtr);
    const keys = keyVariants(parts);
    if (keys.length === 0) return recordPtr;

    let elements = null;
    try { if (record.elements) elements = record.elements(); } catch (_) {}
    if (elements && hasUsefulContent(elements)) {
        cacheRecordHandle(recordPtr, parts, `${source}.record`);
        cacheElements(elements.handle, parts, recordSenderFromObj(recordPtr), `${source}.elements`);
    }

    const recalled = keys.some(k => recalledKeys.has(k));
    const recallGray = elements && hasRecallGrayTip(elements);
    if (!recalled && !recallGray) return recordPtr;

    const cachedElements = markRecalledByKeys(keys, `${source}.restore`);
    if (cachedElements && record.setElements_) {
        const restoredElements = syntheticElementsForCached(cachedElements, `${source}.restore`) || cachedElements.handle;
        try { record.setElements_(restoredElements); } catch (_) {}
    }

    const cachedRecord = findCachedRecord(keys);
    if (cachedRecord && !originalTextForCached(cachedElements)) {
        const n = inc('atomRecordRestore');
        if (shouldLog(n)) log(`[${elapsed()}s] Atom 层恢复原始 record #${n} source=${source} key=${cachedRecord.key}`);
        return cachedRecord.handle;
    }
    return recordPtr;
}

function restoreAtomMsgData(dataPtr, source) {
    const data = obj(dataPtr);
    if (!data || !data.msg) return dataPtr;
    let record = null;
    try { record = data.msg(); } catch (_) {}
    if (!record || (record.isNull && record.isNull())) return dataPtr;

    const parts = recordPartsFromObj(record.handle);
    const keys = keyVariants(parts);
    let beforeElements = null;
    try { if (record.elements) beforeElements = record.elements(); } catch (_) {}
    const wasRecall = keys.some(k => recalledKeys.has(k)) || (beforeElements && hasRecallGrayTip(beforeElements));

    const restored = restoreRecordObject(record.handle, source);
    if (restored && !restored.equals(record.handle) && data.setMsg_) {
        try {
            data.setMsg_(restored);
            const n = inc('atomDataSetMsg');
            if (shouldLog(n)) log(`[${elapsed()}s] AtomData 替换 msg 为原始 record #${n} source=${source}`);
        } catch (_) {}
    }

    const isRecall = wasRecall || keys.some(k => recalledKeys.has(k));
    if (isRecall) {
        const cached = findCached(keys);
        if (cached && originalTextForCached(cached)) {
            const atom = textAtomDataForCachedRecord(restored || record.handle, cached, source);
            if (atom) return atom;
        }
    }
    return dataPtr;
}

function installAtomLayerHooks() {
    replace('AIOChatProtocol.BaseAtomMsgData', '- msg', 'pointer', ['pointer', 'pointer'], 'BaseAtomMsgData.msg 恢复', function(orig) {
        return function(self, sel) {
            const ret = orig(self, sel);
            return restoreRecordObject(ret, 'BaseAtomMsgData.msg');
        };
    });
    replace('AIOChatProtocol.BaseAtomMsgData', '- setMsg:', 'void', ['pointer', 'pointer', 'pointer'], 'BaseAtomMsgData.setMsg 恢复', function(orig) {
        return function(self, sel, value) {
            return orig(self, sel, restoreRecordObject(value, 'BaseAtomMsgData.setMsg'));
        };
    });
    replace('AIOChatProtocol.BaseAtomMsgData', '- convertToMsgRecord', 'pointer', ['pointer', 'pointer'], 'BaseAtomMsgData.convertToMsgRecord 恢复', function(orig) {
        return function(self, sel) {
            const ret = orig(self, sel);
            return restoreRecordObject(ret, 'BaseAtomMsgData.convertToMsgRecord');
        };
    });
    attach('AIOChatProtocol.TextAtomMsgData', '- initWithMsgRecord:', 'TextAtomMsgData.initWithMsgRecord 恢复', {
        onEnter(args) {
            args[2] = restoreRecordObject(args[2], 'TextAtomMsgData.initWithMsgRecord');
        },
    });
    attach('AIOChatServiceModule.AtomMsgService', '+ createAtomMsgViewWithAtomMsgData:atomMsgExtraData:', 'AtomMsgService.createAtomMsgView 恢复', {
        onEnter(args) {
            const restored = restoreAtomMsgData(args[2], 'AtomMsgService.createAtomMsgView');
            if (restored && !restored.equals(args[2])) args[2] = restored;
        },
    });
    replace('AIOChatProtocol.AtomMsgView', '- setAtomMsgData:', 'void', ['pointer', 'pointer', 'pointer'], 'AtomMsgView.setAtomMsgData 恢复', function(orig) {
        return function(self, sel, value) {
            return orig(self, sel, restoreAtomMsgData(value, 'AtomMsgView.setAtomMsgData'));
        };
    });
}

function installSummaryCleaners() {
    replace('OCMsgRecord', '- getContent', 'pointer', ['pointer', 'pointer'], 'OCMsgRecord.getContent 摘要恢复', function(orig) {
        return function(self, sel) {
            const ret = orig(self, sel);
            return cleanRecordSummaryPtr(self, ret, 'OCMsgRecord.getContent');
        };
    });
    replace('OCMsgRecord', '- qsd_retriveContent', 'pointer', ['pointer', 'pointer'], 'OCMsgRecord.qsd_retriveContent 摘要恢复', function(orig) {
        return function(self, sel) {
            const ret = orig(self, sel);
            return cleanRecordSummaryPtr(self, ret, 'OCMsgRecord.qsd_retriveContent');
        };
    });
    replace('OCMsgElement', '- qsd_retriveContent', 'pointer', ['pointer', 'pointer'], 'OCMsgElement.qsd_retriveContent 摘要清洗', function(orig) {
        return function(self, sel) {
            const ret = orig(self, sel);
            if (isNSString(ret) && hasRecallText(text(ret))) {
                const n = inc('elementSummaryClean');
                if (shouldLog(n)) log(`[${elapsed()}s] 清洗元素撤回摘要 #${n}: "${text(ret)}"`);
            }
            return ret;
        };
    });
    replace('AIOChatServiceModule.AtomMsgService', '+ getRichMsgSummaryWithMsgRecord:', 'pointer', ['pointer', 'pointer', 'pointer'], 'AtomMsgService.getRichMsgSummaryWithMsgRecord 预览恢复', function(orig) {
        return function(self, sel, record) {
            const ret = orig(self, sel, record);
            return cleanRecordSummaryPtr(record, ret, 'AtomMsgService.getRichMsgSummaryWithMsgRecord');
        };
    });
    replace('OCMsgAbstractElement', '- content', 'pointer', ['pointer', 'pointer'], 'OCMsgAbstractElement.content 摘要清洗', function(orig) {
        return function(self, sel) {
            return cleanRecallTextPtr(orig(self, sel), 'OCMsgAbstractElement.content');
        };
    });
    replace('OCMsgAbstractElement', '- mdSummary', 'pointer', ['pointer', 'pointer'], 'OCMsgAbstractElement.mdSummary 摘要清洗', function(orig) {
        return function(self, sel) {
            return cleanRecallTextPtr(orig(self, sel), 'OCMsgAbstractElement.mdSummary');
        };
    });
    replace('OCMsgAbstractElement', '- setContent:', 'void', ['pointer', 'pointer', 'pointer'], 'OCMsgAbstractElement.setContent 摘要清洗', function(orig) {
        return function(self, sel, value) {
            return orig(self, sel, cleanRecallTextPtr(value, 'OCMsgAbstractElement.setContent'));
        };
    });
    replace('OCMsgAbstractElement', '- setMdSummary:', 'void', ['pointer', 'pointer', 'pointer'], 'OCMsgAbstractElement.setMdSummary 摘要清洗', function(orig) {
        return function(self, sel, value) {
            return orig(self, sel, cleanRecallTextPtr(value, 'OCMsgAbstractElement.setMdSummary'));
        };
    });
    replace('OCMsgAbstractElement', '- setKt_contentFromCodec:', 'void', ['pointer', 'pointer', 'pointer'], 'OCMsgAbstractElement.codec content 摘要清洗', function(orig) {
        return function(self, sel, value) {
            return orig(self, sel, cleanRecallTextPtr(value, 'OCMsgAbstractElement.codecContent'));
        };
    });
    replace('OCMsgAbstractElement', '- setKt_mdSummaryFromCodec:', 'void', ['pointer', 'pointer', 'pointer'], 'OCMsgAbstractElement.codec mdSummary 摘要清洗', function(orig) {
        return function(self, sel, value) {
            return orig(self, sel, cleanRecallTextPtr(value, 'OCMsgAbstractElement.codecMdSummary'));
        };
    });
}

function installGrayTipBlocker() {
    const cls = ObjC.classes.OCRevokeElement;
    if (cls && cls[REVOKE_SEL] && cls[REVOKE_SEL].implementation) {
        Interceptor.attach(cls[REVOKE_SEL].implementation, {
            onEnter(args) {
                const sender = text(args[9]) || text(args[5]);
                const n = inc('revoke');
                if (shouldLog(n)) log(`[${elapsed()}s] 看到撤回元素 #${n} operator="${text(args[5])}" original="${sender}"`);
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

function handleRecordBuildArgs(args, source) {
    const parts = recordPartsFromArgs(args);
    const sender = recordSenderFromArgs(args);
    const keys = keyVariants(parts);
    const incoming = obj(args[ARG_ELEMENTS]);
    if (incoming && hasUsefulContent(incoming)) {
        cacheRecordTypes(keys, args[ARG_MSG_TYPE], args[ARG_SUB_MSG_TYPE], `${source}.argsType`);
        cacheElements(args[ARG_ELEMENTS], parts, sender, source);
    }

    const isRecall = isNonZero(args[ARG_RECALL_TIME]) || (incoming && hasRecallGrayTip(incoming));
    if (!isRecall) return;
    const cached = markRecalledByKeys(keys, `${source}.recall`);
    if (isNonZero(args[ARG_RECALL_TIME])) {
        const n = inc('ctorRecallTime');
        if (shouldLog(n)) log(`[${elapsed()}s] 构造清零 recallTime #${n} source=${source} value=${args[ARG_RECALL_TIME]}`);
        args[ARG_RECALL_TIME] = ptr('0');
    }
    if (cached) {
        const n = inc('ctorRestore');
        if (shouldLog(n)) log(`[${elapsed()}s] 构造替换撤回 elements #${n} source=${source} key=${cached.key}`);
        args[ARG_ELEMENTS] = syntheticElementsForCached(cached, `${source}.ctor`) || cached.handle;
        const mt = msgTypeByKey.get(cached.key);
        const st = subMsgTypeByKey.get(cached.key);
        if (mt !== undefined) args[ARG_MSG_TYPE] = ptr(String(mt));
        if (st !== undefined) args[ARG_SUB_MSG_TYPE] = ptr(String(st));
    }
}

function cachedTypeForRecord(recordPtr, kind) {
    const keys = keyVariants(recordPartsFromObj(recordPtr));
    if (keys.length === 0 || !keys.some(k => recalledKeys.has(k))) return null;
    const cached = findCached(keys);
    if (!cached || !originalTextForCached(cached)) return null;
    const map = kind === 'subMsgType' ? subMsgTypeByKey : msgTypeByKey;
    if (!map.has(cached.key)) return null;
    return map.get(cached.key);
}

function installRecordModelHooks() {
    attach('OCMsgRecord', MSG_RECORD_SEL, 'OCMsgRecord.init 构造修正', {
        onEnter(args) { handleRecordBuildArgs(args, 'init'); },
    });
    attach('OCMsgRecord', MSG_RECORD_FACTORY_SEL, 'OCMsgRecord.factory 构造修正', {
        onEnter(args) { handleRecordBuildArgs(args, 'factory'); },
    });

    replace('OCMsgRecord', '- msgType', 'long', ['pointer', 'pointer'], 'OCMsgRecord.msgType 原类型', function(orig) {
        return function(self, sel) {
            const cached = cachedTypeForRecord(self, 'msgType');
            if (cached !== null) {
                const n = inc('msgTypeRestore');
                if (shouldLogHot(n)) log(`[${elapsed()}s] 恢复 msgType #${n} value=${cached}`);
                return cached;
            }
            return orig(self, sel);
        };
    });
    replace('OCMsgRecord', '- subMsgType', 'long', ['pointer', 'pointer'], 'OCMsgRecord.subMsgType 原类型', function(orig) {
        return function(self, sel) {
            const cached = cachedTypeForRecord(self, 'subMsgType');
            if (cached !== null) {
                const n = inc('subMsgTypeRestore');
                if (shouldLogHot(n)) log(`[${elapsed()}s] 恢复 subMsgType #${n} value=${cached}`);
                return cached;
            }
            return orig(self, sel);
        };
    });
    replace('OCMsgRecord', '- setMsgType:', 'void', ['pointer', 'pointer', 'long'], 'OCMsgRecord.setMsgType 原类型', function(orig) {
        return function(self, sel, value) {
            const cached = cachedTypeForRecord(self, 'msgType');
            return orig(self, sel, cached !== null ? cached : value);
        };
    });
    replace('OCMsgRecord', '- setSubMsgType:', 'void', ['pointer', 'pointer', 'long'], 'OCMsgRecord.setSubMsgType 原类型', function(orig) {
        return function(self, sel, value) {
            const cached = cachedTypeForRecord(self, 'subMsgType');
            return orig(self, sel, cached !== null ? cached : value);
        };
    });

    replace('OCMsgRecord', '- elements', 'pointer', ['pointer', 'pointer'], 'OCMsgRecord.elements 恢复', function(orig) {
        return function(self, sel) {
            const ret = orig(self, sel);
            const parts = recordPartsFromObj(self);
            const keys = keyVariants(parts);
            const sender = recordSenderFromObj(self);
            const elements = obj(ret);
            if (elements && hasUsefulContent(elements)) {
                cacheRecordHandle(self, parts, 'elements');
                cacheElements(ret, parts, sender, 'elements');
            }
            const recalled = keys.some(k => recalledKeys.has(k));
            const recallGray = elements && hasRecallGrayTip(elements);
            if (recalled || recallGray) {
                const cached = markRecalledByKeys(keys, recallGray ? 'elements.grayTip' : 'elements.recalled');
                if (cached) {
                    const n = inc('restoreElements');
                    if (shouldLog(n)) log(`[${elapsed()}s] 返回缓存原始 elements #${n} key=${cached.key}`);
                    return syntheticElementsForCached(cached, 'elements.getter') || cached.handle;
                }
            }
            return ret;
        };
    });

    replace('OCMsgRecord', '- swizzled_elements', 'pointer', ['pointer', 'pointer'], 'OCMsgRecord.swizzled_elements 恢复', function(orig) {
        return function(self, sel) {
            const ret = orig(self, sel);
            const parts = recordPartsFromObj(self);
            const keys = keyVariants(parts);
            const sender = recordSenderFromObj(self);
            const elements = obj(ret);
            if (elements && hasUsefulContent(elements)) {
                cacheRecordHandle(self, parts, 'swizzled_elements');
                cacheElements(ret, parts, sender, 'swizzled_elements');
            }
            if (keys.some(k => recalledKeys.has(k)) || (elements && hasRecallGrayTip(elements))) {
                const cached = markRecalledByKeys(keys, 'swizzled_elements');
                if (cached) return syntheticElementsForCached(cached, 'swizzled_elements') || cached.handle;
            }
            return ret;
        };
    });

    replace('OCMsgRecord', '- setElements:', 'void', ['pointer', 'pointer', 'pointer'], 'OCMsgRecord.setElements 恢复', function(orig) {
        return function(self, sel, value) {
            const parts = recordPartsFromObj(self);
            const keys = keyVariants(parts);
            const sender = recordSenderFromObj(self);
            const incoming = obj(value);
            if (incoming && hasUsefulContent(incoming)) {
                cacheRecordHandle(self, parts, 'setElements');
                cacheElements(value, parts, sender, 'setElements');
            }
            if (incoming && hasRecallGrayTip(incoming)) {
                const cached = markRecalledByKeys(keys, 'setElements.grayTip');
                if (cached) {
                    const n = inc('setElementsRestore');
                    if (shouldLog(n)) log(`[${elapsed()}s] 阻止撤回 elements 覆盖 #${n} key=${cached.key}`);
                    return orig(self, sel, syntheticElementsForCached(cached, 'setElements.grayTip') || cached.handle);
                }
            }
            return orig(self, sel, value);
        };
    });

    replace('OCMsgRecord', '- setRecallTime:', 'void', ['pointer', 'pointer', 'long'], 'OCMsgRecord.setRecallTime no-op', function(_orig) {
        return function(self, _sel, value) {
            if (isNonZero(value)) markRecalledByKeys(keyVariants(recordPartsFromObj(self)), `setRecallTime=${value}`);
            const n = inc('recallTimeSet');
            if (shouldLog(n)) log(`[${elapsed()}s] 阻止 setRecallTime=${value} #${n}`);
        };
    });

    replace('OCMsgRecord', '- setKt_recallTimeFromCodec:', 'void', ['pointer', 'pointer', 'long'], 'OCMsgRecord.setKt_recallTimeFromCodec no-op', function(_orig) {
        return function(self, _sel, value) {
            if (isNonZero(value)) markRecalledByKeys(keyVariants(recordPartsFromObj(self)), `codecRecallTime=${value}`);
            const n = inc('recallTimeCodec');
            if (shouldLog(n)) log(`[${elapsed()}s] 阻止 codec recallTime=${value} #${n}`);
        };
    });

    replace('OCMsgRecord', '- isTailHidden', 'bool', ['pointer', 'pointer'], 'OCMsgRecord.isTailHidden=false', function(_orig) {
        return function() { return 0; };
    });
    replace('OCMsgRecord', '- setIsTailHidden:', 'void', ['pointer', 'pointer', 'bool'], 'OCMsgRecord.setIsTailHidden no-op', function(_orig) {
        return function(_self, _sel, value) {
            const n = inc('tailHiddenSet');
            if (shouldLog(n)) log(`[${elapsed()}s] 阻止 setIsTailHidden=${value} #${n}`);
        };
    });
}

function installRecallInfoHooks() {
    replace('OCMsgRecallInfo', '- setRecallMsgPeerUid:', 'void', ['pointer', 'pointer', 'pointer'], 'OCMsgRecallInfo.setPeerUid 记录', function(orig) {
        return function(self, sel, value) {
            recallInfoState(self).peerUid = text(value);
            const ret = orig(self, sel, value);
            markRecallInfo(self, 'setPeerUid');
            return ret;
        };
    });
    replace('OCMsgRecallInfo', '- setRecallMsgSenderUid:', 'void', ['pointer', 'pointer', 'pointer'], 'OCMsgRecallInfo.setSenderUid 记录', function(orig) {
        return function(self, sel, value) {
            recallInfoState(self).senderUid = text(value);
            const ret = orig(self, sel, value);
            markRecallInfo(self, 'setSenderUid');
            return ret;
        };
    });
    replace('OCMsgRecallInfo', '- setRecallMsgSeq:', 'void', ['pointer', 'pointer', 'long'], 'OCMsgRecallInfo.setSeq 记录', function(orig) {
        return function(self, sel, value) {
            recallInfoState(self).seq = numericValue(value);
            const ret = orig(self, sel, value);
            markRecallInfo(self, 'setSeq');
            return ret;
        };
    });
    replace('OCMsgRecallInfo', '- setRecallMsgRandom:', 'void', ['pointer', 'pointer', 'long'], 'OCMsgRecallInfo.setRandom 记录', function(orig) {
        return function(self, sel, value) {
            recallInfoState(self).random = numericValue(value);
            const ret = orig(self, sel, value);
            markRecallInfo(self, 'setRandom');
            return ret;
        };
    });
    replace('OCMsgRecallInfo', '- setIsRecallNotify:', 'void', ['pointer', 'pointer', 'bool'], 'OCMsgRecallInfo.setIsRecallNotify no-op', function(_orig) {
        return function(self, _sel, value) {
            const n = inc('recallNotifySet');
            if (shouldLog(n)) log(`[${elapsed()}s] 阻止 setIsRecallNotify=${value} #${n}`);
            markRecallInfo(self, 'setIsRecallNotify');
        };
    });
    replace('OCMsgRecallInfo', '- setIsTracelessRecall:', 'void', ['pointer', 'pointer', 'bool'], 'OCMsgRecallInfo.setIsTracelessRecall no-op', function(_orig) {
        return function(self, _sel, value) {
            const n = inc('tracelessSet');
            if (shouldLog(n)) log(`[${elapsed()}s] 阻止 setIsTracelessRecall=${value} #${n}`);
            markRecallInfo(self, 'setIsTracelessRecall');
        };
    });
    replace('OCMsgRecallInfo', '- isRecallNotify', 'bool', ['pointer', 'pointer'], 'OCMsgRecallInfo.isRecallNotify=false', function(_orig) {
        return function(self) {
            markRecallInfo(self, 'isRecallNotify');
            return 0;
        };
    });
    replace('OCMsgRecallInfo', '- isTracelessRecall', 'bool', ['pointer', 'pointer'], 'OCMsgRecallInfo.isTracelessRecall=false', function(_orig) {
        return function(self) {
            markRecallInfo(self, 'isTracelessRecall');
            return 0;
        };
    });
}

function installRecallPairHooks() {
    replace('RecallPair', '- setMsg:', 'void', ['pointer', 'pointer', 'pointer'], 'RecallPair.setMsg 记录', function(orig) {
        return function(self, sel, value) {
            const state = pairState(self);
            state.msg = value;
            cacheRecordObject(value, 'RecallPair.msg');
            if (state.recallModel) markRecallInfo(state.recallModel, 'RecallPair.setMsg');
            return orig(self, sel, value);
        };
    });
    replace('RecallPair', '- setRecallModel:', 'void', ['pointer', 'pointer', 'pointer'], 'RecallPair.setRecallModel no-op', function(_orig) {
        return function(self, _sel, value) {
            const state = pairState(self);
            state.recallModel = value;
            if (state.msg) {
                cacheRecordObject(state.msg, 'RecallPair.recallModel.msg');
                markRecalledByKeys(keyVariants(recordPartsFromObj(state.msg)), 'RecallPair.setRecallModel.msg');
            }
            markRecallInfo(value, 'RecallPair.setRecallModel');
            const n = inc('pairNoop');
            if (shouldLog(n)) log(`[${elapsed()}s] 阻止 RecallPair.setRecallModel #${n}`);
        };
    });
    replace('RecallPairForOffline', '- setRecallModel:', 'void', ['pointer', 'pointer', 'pointer'], 'RecallPairForOffline.setRecallModel no-op', function(_orig) {
        return function(_self, _sel, value) {
            markRecallInfo(value, 'RecallPairForOffline.setRecallModel');
            const n = inc('offlinePairNoop');
            if (shouldLog(n)) log(`[${elapsed()}s] 阻止 RecallPairForOffline.setRecallModel #${n}`);
        };
    });
}

function installBridgeNoops() {
    replace('QQMessageDecouplingBridge', '- recallMessagePair:', 'void', ['pointer', 'pointer', 'pointer'], 'QQMessageDecouplingBridge.recallMessagePair no-op', function(_orig) {
        return function(_self, _sel, pair) {
            const state = pairState(pair);
            if (state.msg) markRecalledByKeys(keyVariants(recordPartsFromObj(state.msg)), 'QQMessageDecouplingBridge.recallMessagePair');
            if (state.recallModel) markRecallInfo(state.recallModel, 'QQMessageDecouplingBridge.recallMessagePair');
            const n = inc('bridgeNoop');
            if (shouldLog(n)) log(`[${elapsed()}s] 阻止 recallMessagePair #${n}`);
        };
    });
    replace('GroupEmotionManager', '- recallMessagePair:', 'void', ['pointer', 'pointer', 'pointer'], 'GroupEmotionManager.recallMessagePair no-op', function(_orig) {
        return function(_self, _sel, pair) {
            const state = pairState(pair);
            if (state.msg) markRecalledByKeys(keyVariants(recordPartsFromObj(state.msg)), 'GroupEmotionManager.recallMessagePair');
            if (state.recallModel) markRecallInfo(state.recallModel, 'GroupEmotionManager.recallMessagePair');
            const n = inc('groupEmotionNoop');
            if (shouldLog(n)) log(`[${elapsed()}s] 阻止 GroupEmotionManager.recallMessagePair #${n}`);
        };
    });
}

function installPreviewCleaner() {
    attach('OCRecentContactInfo', RECENT_SEL, 'OCRecentContactInfo.init 预览清洗', {
        onEnter(args) {
            const clean = cleanPreviewPtr(args[ARG_RECENT_ABSTRACT], keyVariants(recentPartsFromArgs(args)), 'OCRecentContactInfo.init');
            if (!clean.equals(args[ARG_RECENT_ABSTRACT])) {
                const n = inc('recentInitClean');
                if (shouldLog(n)) log(`[${elapsed()}s] 构造清洗左侧预览 #${n}: "${text(args[ARG_RECENT_ABSTRACT])}"`);
                args[ARG_RECENT_ABSTRACT] = clean;
            }
        },
    });
    attach('OCRecentContactInfo', RECENT_FACTORY_SEL, 'OCRecentContactInfo.factory 预览清洗', {
        onEnter(args) {
            const clean = cleanPreviewPtr(args[ARG_RECENT_ABSTRACT], keyVariants(recentPartsFromArgs(args)), 'OCRecentContactInfo.factory');
            if (!clean.equals(args[ARG_RECENT_ABSTRACT])) args[ARG_RECENT_ABSTRACT] = clean;
        },
    });
    replace('OCRecentContactInfo', '- abstractContent', 'pointer', ['pointer', 'pointer'], '左侧预览读取清洗', function(orig) {
        return function(self, sel) {
            const ret = orig(self, sel);
            const clean = cleanPreviewPtr(ret, keyVariants(recentPartsFromObj(self)), 'OCRecentContactInfo.abstractContent');
            if (!clean.equals(ret)) {
                const n = inc('previewGet');
                if (shouldLog(n)) log(`[${elapsed()}s] 左侧预览读取清洗 #${n}: "${text(ret)}"`);
            }
            return clean;
        };
    });
    replace('OCRecentContactInfo', '- setAbstractContent:', 'void', ['pointer', 'pointer', 'pointer'], '左侧预览写入清洗', function(orig) {
        return function(self, sel, value) {
            const clean = cleanPreviewPtr(value, keyVariants(recentPartsFromObj(self)), 'OCRecentContactInfo.setAbstractContent');
            if (!clean.equals(value)) {
                const n = inc('previewSet');
                if (shouldLog(n)) log(`[${elapsed()}s] 左侧预览写入清洗 #${n}: "${text(value)}"`);
            }
            return orig(self, sel, clean);
        };
    });
    replace('OCRecentContactInfo', '- setKt_abstractContentFromCodec:', 'void', ['pointer', 'pointer', 'pointer'], '左侧预览 codec 清洗', function(orig) {
        return function(self, sel, value) {
            return orig(self, sel, cleanPreviewPtr(value, keyVariants(recentPartsFromObj(self)), 'OCRecentContactInfo.codec'));
        };
    });
}

function install() {
    log(`启动 PID=${Process.id} arch=${Process.arch}`);
    installGrayTipBlocker();
    installRecordModelHooks();
    installRecallInfoHooks();
    installRecallPairHooks();
    installBridgeNoops();
    installAtomLayerHooks();
    installSummaryCleaners();
    installPreviewCleaner();
    log(`安装完成 installed=${installed} cacheLimit=${CACHE_LIMIT}`);
}

if (ObjC.available) ObjC.schedule(ObjC.mainQueue, install);
else log('ObjC runtime 不可用');
