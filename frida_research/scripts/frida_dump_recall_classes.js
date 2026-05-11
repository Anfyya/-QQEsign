/*
 * QQESign - dump recall-related ObjC classes.
 */

'use strict';

const TAG = '[QQESign-dump]';

function log(s) {
    console.log(`${TAG} ${s}`);
}

log(`loaded pid=${Process.id} objc=${ObjC.available}`);

function dumpClass(name) {
    const cls = ObjC.classes[name];
    if (!cls) {
        log(`missing ${name}`);
        return;
    }
    log(`class ${name}`);
    const methods = cls.$ownMethods.slice().sort();
    for (const m of methods) {
        if (/recall|revoke|msg|message|gray|tip|summary|content|preview|abstract|seq|uid|time|random|text|title|sender|nick|element/i.test(m)) {
            log(`  ${m}`);
        }
    }
}

function dumpMatchingClasses() {
    const names = [];
    for (const name in ObjC.classes) {
        if (/RecentContact|MsgAbstract|RecallInfo|GrayTip|RevokeElement|MsgElement|AIO.*Msg|MessageElement/i.test(name)) {
            names.push(name);
        }
    }
    names.sort();
    log(`matching classes ${names.length}`);
    log(names.slice(0, 250).join(', '));
}

function runDump() {
        dumpMatchingClasses();
        [
            'OCRecentContactInfo',
            'OCMsgAbstractElement',
            'OCRevokeElement',
            'OCGrayTipElement',
            'OCMsgRecallInfo',
            'OCTextElement',
            'OCMsgElement',
            'OCMsgInfo',
            'OCMessage',
        ].forEach(dumpClass);
        log('done');
}

if (ObjC.available) {
    runDump();
} else {
    log('ObjC unavailable');
}
