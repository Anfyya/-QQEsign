/*
 * Dump text/message classes from the currently running QQ process.
 */
'use strict';

function log(s) { console.log('[QQESign-text-dump] ' + s); }

function dump(name) {
    const cls = ObjC.classes[name];
    if (!cls) {
        log('missing ' + name);
        return;
    }
    log('class ' + name + ' methods=' + cls.$ownMethods.length);
    cls.$ownMethods.slice().sort().forEach(function(m) {
        if (/text|content|msg|message|element|summary|sender|seq|uid|id|time|body|attr|plain/i.test(m)) {
            log(name + ' ' + m);
        }
    });
}

const names = [];
for (const name in ObjC.classes) {
    if (/OC.*Text|Text.*Element|Msg.*Text|TextMsg|Message.*Text|OCMsg|MsgInfo|MsgRecord|AIO.*Message|Chat.*Message|NT.*Message/i.test(name)) {
        names.push(name);
    }
}
names.sort();
log('classes=' + names.length + ' ' + names.slice(0, 300).join(', '));

[
    'OCTextElement',
    'OCTextMsgElement',
    'OCMsgTextElement',
    'OCMessageTextElement',
    'OCMsgInfo',
    'OCMsgRecord',
    'OCMsgInfoBody',
    'OCMsgAbstractElement',
    'OCMsgElement',
    'OCVASRecentContactMsgElement',
].forEach(dump);
