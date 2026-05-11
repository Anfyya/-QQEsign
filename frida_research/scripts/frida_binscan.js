// 扫描QQ二进制: cstring → 交叉引用 → 函数地址 → Hook
var log = function(m) { console.log('[SCAN] ' + m); };

// 等QQ完全初始化后再扫描
setTimeout(function() {
var mod = Process.enumerateModules().find(function(m){ return m.path.indexOf('QQ.app')!==-1 && m.path.endsWith('QQ'); });

if (!mod) { log('QQ模块未找到'); } else {
    log('QQ模块: ' + mod.path);
    log('基址: ' + mod.base + ' 大小: ' + (mod.size/1024/1024).toFixed(1) + 'MB');
    
    // 枚举所有内存区域
    var ranges = mod.enumerateRanges('');
    log('共' + ranges.length + '个内存区域:');
    for (var i = 0; i < Math.min(ranges.length, 20); i++) {
        var r = ranges[i];
        var protStr = (r.protection & 1 ? 'x' : '-') + (r.protection & 2 ? 'w' : '-') + (r.protection & 4 ? 'r' : '-');
        log('  [' + i + '] ' + r.base + ' size=' + (r.size/1024/1024).toFixed(1) + 'MB prot=' + protStr + ' offset=' + (r.file ? r.file.offset : '?'));
    }
    
    var textRange = null, cstringRange = null;
    // prot全为0时: TEXT=第一个(offset=0), cstring=最后一个(r--段)
    for (var i = 0; i < ranges.length; i++) {
        var r = ranges[i];
        if (r.protection === 5 && !textRange) textRange = r;
        if (r.protection === 4) cstringRange = r;
    }
    // 备选: 用offset和位置识别
    if (!textRange) {
        // TEXT是第一个大段(offset=0)
        for (var i = 0; i < ranges.length; i++) {
            if (ranges[i].file && ranges[i].file.offset === 0 && ranges[i].size > 100*1024*1024) {
                textRange = ranges[i];
                break;
            }
        }
        if (!textRange) textRange = ranges[0]; // fallback
    }
    if (!cstringRange) {
        // cstring在最后一个段
        cstringRange = ranges[ranges.length - 1];
    }
    
    if (!cstringRange) { log('r--段未找到'); } 
    else if (!textRange) { log('r-x段未找到'); }
    else {
        log('TEXT(r-x): ' + textRange.base + ' size=' + (textRange.size/1024/1024).toFixed(1) + 'MB');
        log('DATA(r--): ' + cstringRange.base + ' size=' + (cstringRange.size/1024/1024).toFixed(1) + 'MB');
        
        // 扫描 cstring 找 recall/revoke 字符串
        var foundStrs = [];
        var chunkSize = 1024 * 1024; // 每次读1MB
        var totalRead = 0;
        var maxRead = Math.min(cstringRange.size, 100 * 1024 * 1024); // 最多读100MB
        
        while (totalRead < maxRead) {
            var readSize = Math.min(chunkSize, maxRead - totalRead);
            try {
                var buf = cstringRange.base.add(totalRead).readByteArray(readSize);
                if (!buf) break;
                var arr = new Uint8Array(buf);
                var start = -1;
                for (var i = 0; i < arr.length; i++) {
                    if (arr[i] >= 0x20 && arr[i] < 0x7f) {
                        if (start === -1) start = i;
                    } else {
                        if (start !== -1 && i - start >= 5) {
                            var s = '';
                            for (var j = start; j < i; j++) s += String.fromCharCode(arr[j]);
                            var ls = s.toLowerCase();
                            if (ls.indexOf('recall') !== -1 || ls.indexOf('revoke') !== -1) {
                                foundStrs.push({
                                    str: s,
                                    addr: cstringRange.base.add(totalRead + start),
                                    offset: totalRead + start
                                });
                            }
                        }
                        start = -1;
                    }
                }
            } catch(e) { break; }
            totalRead += readSize;
        }
        
        log('cstring扫描完成, 找到 ' + foundStrs.length + ' 个recall/revoke字符串');
        
        // 过滤: 只保留可能与消息撤回相关的
        var filtered = foundStrs.filter(function(s){
            var ls = s.str.toLowerCase();
            return (ls.indexOf('msg') !== -1 || 
                    ls.indexOf('message') !== -1 || 
                    ls.indexOf('recallmsg') !== -1 ||
                    ls.indexOf('kernel') !== -1 ||
                    ls.indexOf('nt::') !== -1 ||
                    ls.indexOf('wrapper') !== -1 ||
                    ls.indexOf('service') !== -1 ||
                    ls.indexOf('mgr') !== -1 ||
                    ls.indexOf('notif') !== -1);
        });
        
        if (filtered.length === 0) filtered = foundStrs; // 如果没有过滤结果，显示全部
        
        log('过滤后: ' + filtered.length + ' 个候选字符串');
        
        // 打印前20个
        for (var i = 0; i < Math.min(filtered.length, 30); i++) {
            console.log('  [' + i + '] @"' + filtered[i].str + '" @ ' + filtered[i].addr);
        }
        
        // 交叉引用: 在text段中搜索引用这些字符串的指令
        log('搜索交叉引用...');
        
        // ARM64: ADRP + ADD 模式引用字符串
        // ADRP: 0x90000000 mask 0x9F000000
        // ADD: 0x91000000 mask 0xFFC00000
        
        var textBase = textRange.base;
        var textSize = Math.min(textRange.size, 200 * 1024 * 1024); // 最多200MB
        var textChunk = 4 * 1024 * 1024; // 每次4MB
        var xrefFound = [];
        
        for (var si = 0; si < Math.min(filtered.length, 10) && xrefFound.length < 20; si++) {
            var targetAddr = filtered[si].addr;
            var t = 0;
            while (t < textSize && xrefFound.length < 20) {
                var chunk = Math.min(textChunk, textSize - t);
                try {
                    var instBuf = textBase.add(t).readByteArray(chunk);
                    if (!instBuf) break;
                    var inst = new Uint32Array(instBuf);
                    for (var ii = 0; ii + 1 < inst.length; ii++) {
                        // 检查 ADRP
                        if ((inst[ii] & 0x9F000000) === 0x90000000) {
                            // 粗略解码 ADRP + ADD 看是否指向目标字符串
                            var pc = textBase.add(t + ii * 4);
                            var adrp = inst[ii];
                            var add = inst[ii + 1];
                            
                            // 简单检查: 下一个指令是ADD
                            if ((add & 0xFFC00000) === 0x91000000) {
                                var immlo = (adrp >>> 29) & 0x3;
                                var immhi = (adrp >>> 5) & 0x7FFFF;
                                var adrpImm = ((immhi << 2) | immlo);
                                // sign extend 21-bit
                                if (adrpImm & (1 << 20)) adrpImm |= ~((1 << 21) - 1);
                                adrpImm = adrpImm * 4096; // << 12
                                var page = pc.and(ptr(0xFFFFFFFFFFFFF000));
                                var base = page.add(adrpImm);
                                
                                var imm12 = (add >>> 10) & 0xFFF;
                                var resolved = base.add(imm12);
                                
                                if (resolved.equals(targetAddr)) {
                                    // 找到交叉引用！
                                    var refAddr = pc;
                                    // 向上查找函数开始 (找 stp x29, x30 模式)
                                    var searchBack = 1024;
                                    var fnStart = pc;
                                    for (var b = 0; b < searchBack / 4; b++) {
                                        var checkAddr = pc.sub(b * 4 + 4);
                                        if (checkAddr.compare(textBase) < 0) break;
                                        var idx = (checkAddr.sub(textBase).toInt32()) / 4;
                                        if (idx >= 0 && idx < inst.length) {
                                            var op = inst[Math.floor(idx)];
                                            if ((op & 0xFFC003FF) === 0xA98003FD) { // stp x29, x30, [sp, ...]
                                                fnStart = checkAddr;
                                                break;
                                            }
                                        }
                                    }
                                    
                                    var symbol = '<unknown>';
                                    try { symbol = DebugSymbol.fromAddress(fnStart).toString(); } catch(e) {}
                                    
                                    xrefFound.push({
                                        str: filtered[si].str,
                                        strAddr: targetAddr,
                                        refAddr: refAddr,
                                        fnAddr: fnStart,
                                        symbol: symbol
                                    });
                                    
                                    console.log('  🔗 "' + filtered[si].str + '" → 函数 @ ' + fnStart + ' (' + symbol + ')');
                                    
                                    // 尝试 Hook
                                    try {
                                        Interceptor.attach(fnStart, {
                                            onEnter: function(args) {
                                                log('🚫 命中函数: ' + this.sym);
                                                try {
                                                    var bt = Thread.backtrace(this.context, Backtracer.ACCURATE)
                                                        .map(DebugSymbol.fromAddress).slice(0, 15).join('\n    ');
                                                    log('  栈:\n    ' + bt);
                                                } catch(e) {}
                                            }.bind({sym: symbol})
                                        });
                                        console.log('    ✅ Hook成功');
                                    } catch(e) {
                                        console.log('    ❌ Hook失败: ' + e.message);
                                    }
                                    
                                    if (xrefFound.length >= 20) break;
                                }
                            }
                        }
                    }
                } catch(e) { break; }
                t += chunk;
            }
        }
        
        log('共找到 ' + xrefFound.length + ' 个交叉引用, Hook了 ' + xrefFound.length + ' 个函数');
    }
    
    log('扫描完成。撤回消息测试。');
}
}, 8000);
