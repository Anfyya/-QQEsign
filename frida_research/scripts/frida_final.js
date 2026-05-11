/*
 * QQESign Frida 防撤回验证 - 最终版
 * 关键修复: $methods 返回带 -/+ 前缀的方法名，访问时也必须带前缀！
 */
const log = (msg) => console.log(`[QQESign] ${msg}`);
let total = 0;

function stack(d) {
    try { return Thread.backtrace(this.context, Backtracer.ACCURATE).map(DebugSymbol.fromAddress).slice(0, d||20).join('\n    '); } catch(e) { return ''; }
}

// Hook 实例方法: 使用 '- methodName:' 格式
function hookI(clsName, selWithPrefix, label) {
    label = label || selWithPrefix;
    try {
        const cls = ObjC.classes[clsName];
        if (!cls) { log(`❌ [${label}] 类不存在`); return; }
        
        const m = cls[selWithPrefix];
        if (!m) { log(`❌ [${label}] 方法不可用 (cls[sel] 为空)`); return; }
        
        // 尝试多种方式获取 IMP
        let origImp;
        try { origImp = m.implementation; } catch(e) {}
        
        if (!origImp) {
            log(`❌ [${label}] IMP 获取失败`);
            return;
        }
        
        // ★ 用 NativeCallback 赋值 .implementation
        const cb = new NativeCallback(function() {
            log(`🚫 命中! [${label}]`);
            try { log(`    📍栈:\n    ${stack()}`); } catch(e) {}
        }, 'void', ['pointer', 'pointer']);
        
        try {
            m.implementation = cb;
            total++;
            log(`✅ [${label}] 拦截就绪`);
        } catch(e2) {
            log(`❌ [${label}] 赋值失败: ${e2.message}`);
        }
    } catch(e) { log(`❌ [${label}] ${e.message}`); }
}

// Hook 类方法
function hookC(clsName, selWithPrefix, label) {
    label = label || selWithPrefix;
    try {
        const cls = ObjC.classes[clsName];
        if (!cls) { log(`❌ [${label}] 类不存在`); return; }
        
        const m = cls[selWithPrefix];
        if (!m) { log(`❌ [${label}] 方法不可用`); return; }
        
        let origImp;
        try { origImp = m.implementation; } catch(e) {}
        
        if (!origImp) { log(`❌ [${label}] IMP 获取失败`); return; }
        
        const cb = new NativeCallback(function() {
            log(`🚫 命中! [${label}]`);
            try { log(`    📍栈:\n    ${stack()}`); } catch(e) {}
        }, 'void', ['pointer', 'pointer']);
        
        try {
            m.implementation = cb;
            total++;
            log(`✅ [${label}] 拦截就绪`);
        } catch(e2) {
            log(`❌ [${label}] 赋值失败: ${e2.message}`);
        }
    } catch(e) { log(`❌ [${label}] ${e.message}`); }
}

// 先诊断几个关键方法，确认前缀访问方式正确
function diag(clsName, selWithPrefix) {
    try {
        const cls = ObjC.classes[clsName];
        if (!cls) { log(`  诊断: ${clsName} 不存在`); return false; }
        const m = cls[selWithPrefix];
        const ok = !!(m && m.implementation);
        log(`  诊断: ${selWithPrefix} → ${ok ? '✅ 可访问' : '❌ 不可访问'}`);
        return ok;
    } catch(e) { log(`  诊断: ${selWithPrefix} → ❌ ${e.message}`); return false; }
}

// ───── 主流程 ─────
log('══════════════════════════════════════');
log('QQESign 防撤回验证 (最终版)');
log(`PID: ${Process.id}`);
log('══════════════════════════════════════');

ObjC.schedule(ObjC.mainQueue, function() {
    log('\n── 诊断: 验证 -/+ 前缀访问方式 ──');
    
    diag('QQMessageRecallPackageHandler', '+ parseC2CRecallNotify:bufferLen:subcmd:model:');
    diag('QQMessageRecallPackageHandler', '+ parseC2CRecallInOut:');
    diag('OCMsgRecallInfo', '+ MsgRecallInfo');
    diag('OCMsgRecallInfo', '- isRecallNotify');
    diag('OCMsgRecallInfo', '- setIsRecallNotify:');
    diag('OCMsgRecallInfo', '- isTracelessRecall');
    diag('OCMsgRecallInfo', '- setIsTracelessRecall:');
    diag('OCMsgRecallInfo', '- recallMsgPeerUid');
    diag('OCMsgRecallInfo', '- recallMsgSeq');
    diag('RecallPair', '- recallModel');
    diag('RecallPair', '- setRecallModel:');
    diag('RecallPairForOffline', '- setRecallModel:');
    diag('QQMessageRecallModule', '- handleSideAccountRecallNotify:bufferLen:subcmd:bindUin:tracelessFlag:');
    diag('QQMessageRecallModule', '- convertRecallItemToMsg:recallModel:msgType:bindUin:');
    diag('QQMessageRecallNetEngine', '- parseC2CRecallNotify:bufferLen:subcmd:model:');
    diag('QQRecallMenuFilter', '+ isGroupMessageNeedShowMenuRecall:');
    diag('QQRecallMenuFilter', '+ needShowRecallBaseImpl:');
    diag('OCRevokeElement', '+ RevokeElement');
    diag('NTAIOChatRecallService', '+ getNTUnlimitedRecallAbilityInfo');
    diag('NTAIOChat.NTAIOMenuRecallService', '+ recallCompleteWithCell:observer:code:msg:');
    diag('FARecallMgr', '- recallFAModel:');
    diag('FARecallMgr', '- onRecvMsgRecallResult:');
    diag('NTKernelAdapter.MessageService', '- recallMsgWithPeer:msgIds:cb:');
    diag('NTAIOChat.NTStreamMsgAIOHandler', '- receiveRecallNotification:');
    diag('NTAIOChat.NTAIOFloatEarManager', '- onRecvRecallMsg:');
    diag('NTAIOChat.NTAIOFloatEarPart', '- recallMessageWithNotification:');
    diag('ZTPSquareAIOMessageService', '- onMsgRecall:peerUid:seq:');
    
    // 延迟安装 Hook，给 QQ 时间加载所有模块
    setTimeout(function() {
        log('\n══════════════════════════════════════');
        log('开始安装防撤回拦截...');
        log('══════════════════════════════════════');
        
        // ★ 等级1: 撤回包解析 (类方法 + 实例方法)
        hookC('QQMessageRecallPackageHandler', '+ parseC2CRecallNotify:bufferLen:subcmd:model:', '解析入口1');
        hookC('QQMessageRecallPackageHandler', '+ parseC2CRecallInOut:', '解析入口2');
        hookI('QQMessageRecallNetEngine', '- parseC2CRecallNotify:bufferLen:subcmd:model:', '解析引擎');
        
        // ★ 等级2: 撤回模型标志位 (最关键)
        hookI('OCMsgRecallInfo', '- isRecallNotify', '读取撤回标记');
        hookI('OCMsgRecallInfo', '- setIsRecallNotify:', '写入撤回标记 ⭐');
        hookI('OCMsgRecallInfo', '- isTracelessRecall', '无痕撤回标记');
        hookI('OCMsgRecallInfo', '- setIsTracelessRecall:', '写入无痕标记');
        
        // ★ 等级2b: 撤回信息字段 (观察)
        hookI('OCMsgRecallInfo', '- recallMsgPeerUid', 'peerUid');
        hookI('OCMsgRecallInfo', '- recallMsgSeq', 'msgSeq');
        hookI('OCMsgRecallInfo', '- recallMsgRandom', 'msgRandom');
        hookI('OCMsgRecallInfo', '- recallMsgSenderUid', 'senderUid');
        hookI('OCMsgRecallInfo', '- recallMsgTime', 'msgTime');
        hookI('OCMsgRecallInfo', '- recallMsgChatType', 'chatType');
        hookI('OCMsgRecallInfo', '- setRecallMsgPeerUid:', 'setPeerUid');
        hookI('OCMsgRecallInfo', '- setRecallMsgSeq:', 'setSeq');
        
        // ★ 等级3: 撤回模型构造
        hookC('OCMsgRecallInfo', '+ MsgRecallInfo', '构造撤回模型 ⭐');
        hookC('OCRevokeElement', '+ RevokeElement', '构造灰条元素');
        
        // ★ 等级4: 撤回绑定
        hookI('RecallPair', '- setRecallModel:', '绑定撤回模型 ⭐');
        hookI('RecallPairForOffline', '- setRecallModel:', '离线绑定');
        hookI('RecallPair', '- recallModel', '读取绑定');
        
        // ★ 等级5: 传统 ObjC 桥接
        hookI('QQMessageRecallModule', '- handleSideAccountRecallNotify:bufferLen:subcmd:bindUin:tracelessFlag:', '副线入口');
        hookI('QQMessageRecallModule', '- convertRecallItemToMsg:recallModel:msgType:bindUin:', '模型转换');
        
        // ★ 等级6: 通知分发
        hookI('NTAIOChat.NTStreamMsgAIOHandler', '- receiveRecallNotification:', 'AIO接收通知');
        hookI('NTAIOChat.NTAIOFloatEarManager', '- onRecvRecallMsg:', '浮窗接收');
        hookI('NTAIOChat.NTAIOFloatEarPart', '- recallMessageWithNotification:', '浮窗处理');
        hookI('ZTPSquareAIOMessageService', '- onMsgRecall:peerUid:seq:', '空间撤回');
        
        // ★ 等级7: 灰条/菜单
        hookC('QQRecallMenuFilter', '+ isGroupMessageNeedShowMenuRecall:', '群聊菜单过滤');
        hookC('QQRecallMenuFilter', '+ needShowRecallBaseImpl:', '基础菜单过滤');
        hookC('NTAIOChat.NTAIOMenuRecallService', '+ recallCompleteWithCell:observer:code:msg:', '完成撤回');
        hookC('NTAIOChat.NTAIOMenuRecallService', '+ recallGrayTipsMsgWithCellView:observer:', '灰条展示');
        
        // ★ 等级8: FA 撤回
        hookI('FARecallMgr', '- recallFAModel:', 'FA绑定');
        hookI('FARecallMgr', '- onRecvMsgRecallResult:', 'FA接收');
        
        // ★ 等级9: NT Kernel (Swift)
        hookI('NTKernelAdapter.MessageService', '- recallMsgWithPeer:msgIds:cb:', '⭐内核撤回');
        hookI('NTKernelAdapter.MessageService', '- reeditRecallMsgWithPeer:msgId:cb:', '编辑撤回');
        hookI('NTKernelAdapter.MessageService', '- getRecallMsgsWithPeer:msgIds:cb:', '获取撤回');
        
        log('\n══════════════════════════════════════');
        log(`✅ 安装了 ${total} 个拦截点`);
        log('══════════════════════════════════════');
        log('📢 请让朋友给你发一条消息然后撤回！');
        log('   如果有拦截命中会显示 🚫');
        log('══════════════════════════════════════');
    }, 8000);  // 等8秒让 QQ 完全初始化
});
