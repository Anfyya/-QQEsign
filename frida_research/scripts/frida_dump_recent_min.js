/*
 * Minimal method dump for current NTQQ recall classes.
 */
'use strict';

function log(s) { console.log('[QQESign-dump-min] ' + s); }

function dump(name) {
    const cls = ObjC.classes[name];
    if (!cls) {
        log('missing ' + name);
        return;
    }
    log('class ' + name + ' methods=' + cls.$ownMethods.length);
    cls.$ownMethods.slice().sort().forEach(function(m) {
        log(name + ' ' + m);
    });
}

log('loaded pid=' + Process.id + ' objc=' + ObjC.available);
if (ObjC.available) {
    dump('OCRecentContactInfo');
    dump('OCMsgAbstractElement');
    dump('OCMsgRecallInfo');
    dump('RecallPair');
    dump('RecallPairForOffline');
}
