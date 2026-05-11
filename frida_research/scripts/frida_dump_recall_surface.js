/*
 * QQESign - dump narrow recall/delete/update related ObjC surface.
 */

'use strict';

const TAG = '[QQESign-recall-surface]';
function log(s) { console.log(`${TAG} ${s}`); }

const classRe = /(Recall|Revoke|Msg|Message|AIO|Chat|Record|Recent|Delete|Remove)/i;
const methodRe = /(recall|revoke|delete|remove|clear|withdraw|msg|message|record|replace|update|refresh|hidden|hide|element|gray|tip)/i;

if (!ObjC.available) {
    log('ObjC runtime 不可用');
} else {
    const hits = [];
    for (const name in ObjC.classes) {
        if (!classRe.test(name)) continue;
        const cls = ObjC.classes[name];
        const methods = (cls.$ownMethods || []).filter(m => methodRe.test(m));
        if (methods.length === 0) continue;
        hits.push({ name, methods: methods.sort() });
    }
    hits.sort((a, b) => a.name.localeCompare(b.name));
    log(`匹配类数量=${hits.length}`);
    for (const item of hits.slice(0, 260)) {
        log(`class ${item.name}`);
        for (const m of item.methods.slice(0, 80)) log(`  ${m}`);
    }
    log('done');
}
