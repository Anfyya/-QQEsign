/*
 * QQESign - runtime anti-revoke injector.
 *
 * This is not an observer. It replaces the confirmed NTQQ recall gray-tip
 * constructor and blocks it when revokeElement is present.
 *
 * Run:
 *   frida -U -f com.tencent.mqq -l .\frida_research\scripts\frida_runtime_antirevoke.js
 */

'use strict';

const TAG = '[QQESign-runtime-antirevoke]';
const start = Date.now();

let grayTipBlocked = 0;
let grayTipPassed = 0;
let revokeSeen = 0;

const LOG_FIRST_BLOCKS = 8;
const LOG_EVERY_BLOCKS = 50;

const GRAY_SEL = '- initWithSubElementType:revokeElement:proclamationElement:emojiReplyElement:groupElement:buddyElement:feedMsgElement:essenceElement:xmlElement:fileReceiptElement:localGrayTipElement:blockGrayTipElement:aioOpGrayTipElement:jsonGrayTipElement:walletGrayTipElement:';
const REVOKE_SEL = '- initWithOperatorTinyId:operatorRole:operatorUid:operatorNick:operatorRemark:operatorMemRemark:origMsgSenderUid:origMsgSenderNick:origMsgSenderRemark:origMsgSenderMemRemark:isSelfOperate:wording:';

function log(message) {
    console.log(`${TAG} ${message}`);
}

function elapsed() {
    return ((Date.now() - start) / 1000).toFixed(1);
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
        return obj.$className || '';
    }
}

function stack(context) {
    try {
        return Thread.backtrace(context, Backtracer.ACCURATE)
            .map(DebugSymbol.fromAddress)
            .slice(0, 8)
            .join('\n    ');
    } catch (e) {
        return '';
    }
}

function shouldLogBlock(count) {
    return count <= LOG_FIRST_BLOCKS || (count % LOG_EVERY_BLOCKS) === 0;
}

function installRevokeObserver() {
    const cls = ObjC.classes.OCRevokeElement;
    if (!cls || !cls[REVOKE_SEL] || !cls[REVOKE_SEL].implementation) {
        log(`未找到 OCRevokeElement ${REVOKE_SEL}`);
        return false;
    }

    Interceptor.attach(cls[REVOKE_SEL].implementation, {
        onEnter(args) {
            revokeSeen++;
            if (revokeSeen <= 8) {
                log(`[${elapsed()}s] 看到撤回元素 #${revokeSeen} wording="${safeText(args[13])}" operator="${safeText(args[5])}" original="${safeText(args[9])}"`);
                const trace = stack(this.context);
                if (trace) log(`  栈:\n    ${trace}`);
            }
        },
    });
    log('已观察 OCRevokeElement，用于证明撤回事件到达运行时');
    return true;
}

function installGrayTipBlocker() {
    const cls = ObjC.classes.OCGrayTipElement;
    if (!cls || !cls[GRAY_SEL] || !cls[GRAY_SEL].implementation) {
        log(`未找到 OCGrayTipElement ${GRAY_SEL}`);
        return false;
    }

    const method = cls[GRAY_SEL];
    const original = method.implementation;
    const originalFn = new NativeFunction(original, 'pointer', [
        'pointer', 'pointer', 'long',
        'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer',
        'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer',
    ]);

    const replacement = new NativeCallback(function(self, sel, subElementType,
                                                    revokeElement,
                                                    proclamationElement,
                                                    emojiReplyElement,
                                                    groupElement,
                                                    buddyElement,
                                                    feedMsgElement,
                                                    essenceElement,
                                                    xmlElement,
                                                    fileReceiptElement,
                                                    localGrayTipElement,
                                                    blockGrayTipElement,
                                                    aioOpGrayTipElement,
                                                    jsonGrayTipElement,
                                                    walletGrayTipElement) {
        if (!isNull(revokeElement)) {
            grayTipBlocked++;
            if (shouldLogBlock(grayTipBlocked)) {
                log(`[${elapsed()}s] 已阻断撤回灰条 #${grayTipBlocked} subType=${subElementType} revokeClass=${safeText(revokeElement)}`);
            }
            if (grayTipBlocked <= 4) {
                const trace = stack(this.context);
                if (trace) log(`  栈:\n    ${trace}`);
            }
            return ptr('0');
        }

        grayTipPassed++;
        if (grayTipPassed <= 6) {
            log(`[${elapsed()}s] 放行非撤回灰条 #${grayTipPassed} subType=${subElementType}`);
        }

        return originalFn(self, sel, subElementType,
                          revokeElement,
                          proclamationElement,
                          emojiReplyElement,
                          groupElement,
                          buddyElement,
                          feedMsgElement,
                          essenceElement,
                          xmlElement,
                          fileReceiptElement,
                          localGrayTipElement,
                          blockGrayTipElement,
                          aioOpGrayTipElement,
                          jsonGrayTipElement,
                          walletGrayTipElement);
    }, 'pointer', [
        'pointer', 'pointer', 'long',
        'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer',
        'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer', 'pointer',
    ]);

    method.implementation = replacement;
    log('已替换 OCGrayTipElement 构造器：revokeElement 非空时返回 NULL');
    return true;
}

function install() {
    const observerOk = installRevokeObserver();
    const blockerOk = installGrayTipBlocker();
    log(`安装完成 observer=${observerOk} blocker=${blockerOk}。现在触发撤回，必须看到“已阻断撤回灰条”。`);
}

log(`启动 PID=${Process.id} arch=${Process.arch}`);
if (!ObjC.available) {
    log('ObjC runtime 不可用');
} else {
    ObjC.schedule(ObjC.mainQueue, install);
}
