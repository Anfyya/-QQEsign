/*
 * QQESign - NTQQ recall chain offset probe.
 *
 * This script is intentionally narrow. It observes the confirmed recall
 * constructors and a small set of QQ internal offsets seen repeatedly in
 * prior logs. Do not keep it running longer than needed.
 */

'use strict';

const TAG = '[QQESign-chain]';
const start = Date.now();
const counts = Object.create(null);

const LIMIT = {
    objc: 12,
    offset: 6,
    stack: 2,
};

const OFFSETS = [
    ['revoke-build-a', '0x11a2205c'],
    ['revoke-build-b', '0x11a19b48'],
    ['revoke-build-c', '0x11a19878'],
    ['graytip-build', '0x11a199f0'],
    ['abstract-build', '0x11a20938'],
    ['common-decode-a', '0x5aa3e08'],
    ['common-decode-b', '0x57f3240'],
    ['common-decode-c', '0x5aed0b4'],
    ['common-decode-d', '0x573d884'],
    ['common-live-a', '0x5aa3938'],
    ['common-live-b', '0x570dc18'],
    ['common-live-c', '0x5aa9a04'],
    ['common-live-d', '0x57053a8'],
    ['common-live-e', '0x5994370'],
    ['upper-a', '0x1463f94c'],
    ['upper-b', '0x1461becc'],
    ['upper-c', '0x1462d9f0'],
    ['upper-live-a', '0x13d707b8'],
];

function log(message) {
    console.log(`${TAG} ${message}`);
}

function elapsed() {
    return ((Date.now() - start) / 1000).toFixed(1);
}

function keyCount(key, max) {
    const value = counts[key] || 0;
    if (value >= max) return -1;
    counts[key] = value + 1;
    return value;
}

function safeObj(ptrValue) {
    if (!ptrValue || ptrValue.isNull()) return null;
    try {
        return new ObjC.Object(ptrValue);
    } catch (e) {
        return null;
    }
}

function safeString(ptrValue) {
    const obj = safeObj(ptrValue);
    if (!obj) return '';
    try {
        return obj.toString();
    } catch (e) {
        return obj.$className || '';
    }
}

function bt(context) {
    try {
        return Thread.backtrace(context, Backtracer.ACCURATE)
            .map(DebugSymbol.fromAddress)
            .slice(0, 8)
            .join('\n    ');
    } catch (e) {
        return '';
    }
}

function hookMethod(clsName, selName, key, label, onHit) {
    try {
        const cls = ObjC.classes[clsName];
        if (!cls || !cls[selName] || !cls[selName].implementation) {
            log(`未找到 ${label}: ${clsName} ${selName}`);
            return false;
        }

        Interceptor.attach(cls[selName].implementation, {
            onEnter(args) {
                if (onHit && onHit(args) === false) return;
                const index = keyCount(key, LIMIT.objc);
                if (index < 0) return;
                log(`[${elapsed()}s] ${label}`);
                if (index < LIMIT.stack) {
                    const trace = bt(this.context);
                    if (trace) log(`  栈:\n    ${trace}`);
                }
            },
        });
        log(`已观察 ${label}`);
        return true;
    } catch (e) {
        log(`观察 ${label} 失败: ${e.message}`);
        return false;
    }
}

function hookOffsets() {
    const qq = Process.findModuleByName('QQ');
    if (!qq) {
        log('未找到 QQ 主模块');
        return;
    }

    log(`QQ base=${qq.base} size=${qq.size}`);
    for (const [name, offset] of OFFSETS) {
        const address = qq.base.add(ptr(offset));
        const range = Process.findRangeByAddress(address);
        if (!range || range.protection.indexOf('x') === -1) {
            log(`跳过不可执行偏移 ${name} ${offset} addr=${address}`);
            continue;
        }

        try {
            Interceptor.attach(address, {
                onEnter() {
                    const index = keyCount(`off:${name}`, LIMIT.offset);
                    if (index < 0) return;
                    log(`[${elapsed()}s] offset ${name} ${offset}`);
                    if (index < LIMIT.stack) {
                        const trace = bt(this.context);
                        if (trace) log(`  栈:\n    ${trace}`);
                    }
                },
            });
            log(`已观察偏移 ${name} ${offset} addr=${address}`);
        } catch (e) {
            log(`观察偏移失败 ${name} ${offset}: ${e.message}`);
        }
    }
}

function install() {
    hookMethod(
        'OCRevokeElement',
        '- initWithOperatorTinyId:operatorRole:operatorUid:operatorNick:operatorRemark:operatorMemRemark:origMsgSenderUid:origMsgSenderNick:origMsgSenderRemark:origMsgSenderMemRemark:isSelfOperate:wording:',
        'objc:revoke',
        'OCRevokeElement',
        function(args) {
            log(`  wording=${safeString(args[13])} operator=${safeString(args[5])} original=${safeString(args[9])}`);
            return true;
        }
    );

    hookMethod(
        'OCGrayTipElement',
        '- initWithSubElementType:revokeElement:proclamationElement:emojiReplyElement:groupElement:buddyElement:feedMsgElement:essenceElement:xmlElement:fileReceiptElement:localGrayTipElement:blockGrayTipElement:aioOpGrayTipElement:jsonGrayTipElement:walletGrayTipElement:',
        'objc:gray',
        'OCGrayTipElement(revokeElement)',
        function(args) {
            return !!args[3] && !args[3].isNull();
        }
    );

    hookMethod(
        'OCMsgAbstractElement',
        '- initWithElementType:elementSubType:content:customContent:index:isSetProclamation:isSetEssence:operatorRole:operatorTinyId:fileName:tinyId:msgSeq:msgId:emojiId:emojiType:localGrayTipType:grayTiPElement:textGiftElement:calendarElement:channelStateElement:onlineFileMsgCnt:mdSummary:',
        'objc:abstract',
        'OCMsgAbstractElement(grayTiPElement)',
        function(args) {
            return !!args[18] && !args[18].isNull();
        }
    );

    hookOffsets();
    log('撤回链路偏移探针已就绪，请触发一次撤回后立即停止。');
}

log(`启动 PID=${Process.id} arch=${Process.arch}`);
if (!ObjC.available) {
    log('ObjC runtime 不可用');
} else {
    ObjC.schedule(ObjC.mainQueue, install);
}
