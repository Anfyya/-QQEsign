/*
 * QQESign - NTQQ recall constructor probe, low impact mode.
 *
 * Run:
 *   frida -U -p <QQ_PID> -l frida_event_probe.js
 *   frida -U -f com.tencent.mqq -l frida_event_probe.js
 */

'use strict';

const TAG = '[QQESign-event-lite]';
const start = Date.now();
const hitCounts = Object.create(null);

const LIMIT = {
    revoke: 20,
    gray: 20,
    stack: 4,
};

function log(message) {
    console.log(`${TAG} ${message}`);
}

function elapsed() {
    return ((Date.now() - start) / 1000).toFixed(1);
}

function isNull(ptr) {
    return !ptr || ptr.isNull();
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

function hookEnter(clsName, selName, key, label, shouldLog) {
    try {
        const cls = ObjC.classes[clsName];
        if (!cls || !cls[selName] || !cls[selName].implementation) {
            log(`未找到 ${label}: ${clsName} ${selName}`);
            return false;
        }

        Interceptor.attach(cls[selName].implementation, {
            onEnter(args) {
                if (shouldLog && !shouldLog(args)) return;

                const count = hitCounts[key] || 0;
                const max = key === 'revoke' ? LIMIT.revoke : LIMIT.gray;
                if (count >= max) return;
                hitCounts[key] = count + 1;

                log(`[命中 ${elapsed()}s] ${label}: ${clsName} ${selName}`);
                if (count < LIMIT.stack) {
                    const trace = bt(this.context);
                    if (trace) log(`  栈:\n    ${trace}`);
                }
            },
        });

        log(`已观察 ${label}: ${clsName} ${selName}`);
        return true;
    } catch (e) {
        log(`观察 ${label} 失败: ${e.message}`);
        return false;
    }
}

function install() {
    hookEnter(
        'OCRevokeElement',
        '- initWithOperatorTinyId:operatorRole:operatorUid:operatorNick:operatorRemark:operatorMemRemark:origMsgSenderUid:origMsgSenderNick:origMsgSenderRemark:origMsgSenderMemRemark:isSelfOperate:wording:',
        'revoke',
        '撤回元素构造',
        null
    );

    hookEnter(
        'OCGrayTipElement',
        '- initWithSubElementType:revokeElement:proclamationElement:emojiReplyElement:groupElement:buddyElement:feedMsgElement:essenceElement:xmlElement:fileReceiptElement:localGrayTipElement:blockGrayTipElement:aioOpGrayTipElement:jsonGrayTipElement:walletGrayTipElement:',
        'gray',
        '撤回灰条构造',
        function(args) {
            return !isNull(args[3]);
        }
    );

    log('低影响探针已就绪：未 Hook 通知、未 Hook objc_msgSend、未 Hook OCMsgAbstractElement。请收一条消息再撤回。');
}

log(`启动 PID=${Process.id} arch=${Process.arch}`);
if (!ObjC.available) {
    log('ObjC runtime 不可用');
} else {
    ObjC.schedule(ObjC.mainQueue, install);
}
