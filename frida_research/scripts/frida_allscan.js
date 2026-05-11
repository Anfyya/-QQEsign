// 扫描所有已加载模块找recall/revoke字符串和符号
setTimeout(function(){
var log=function(m){console.log('[ALL] '+m);};
var mods=Process.enumerateModules();
log('已加载模块: '+mods.length);
var found=[];
for(var i=0;i<mods.length;i++){
    var m=mods[i];
    // 只扫描QQ相关的模块
    if(m.path.indexOf('QQ')===-1 && m.path.indexOf('NT')===-1 && m.path.indexOf('Kernel')===-1 && m.path.indexOf('Guild')===-1 && m.path.indexOf('AIO')===-1) continue;
    
    // 尝试获取recall/revoke相关导出符号
    try{
        var testSym=m.getExportByName('recallMsgFromC2CAndGroup');
        if(testSym){ log('✅ '+m.name+' 有 recallMsgFromC2CAndGroup @ '+testSym); found.push({mod:m.name,sym:'recallMsgFromC2CAndGroup',addr:testSym}); }
    }catch(e){}
    try{
        var testSym2=m.getExportByName('getRecallMsgsByMsgId');
        if(testSym2){ log('✅ '+m.name+' 有 getRecallMsgsByMsgId @ '+testSym2); found.push({mod:m.name,sym:'getRecallMsgsByMsgId',addr:testSym2}); }
    }catch(e){}
    
    // 尝试扫描cstring段
    try{
        var ranges=m.enumerateRanges('');
        for(var j=0;j<ranges.length;j++){
            var r=ranges[j];
            // r--段(最后一个)
            if(j===ranges.length-1 && r.size>1024*1024){
                try{
                    var buf=r.base.readByteArray(Math.min(r.size,10*1024*1024));
                    if(buf){
                        var arr=new Uint8Array(buf);
                        var start=-1;
                        var foundStr=0;
                        for(var k=0;k<arr.length;k++){
                            if(arr[k]>=0x20&&arr[k]<0x7f){if(start===-1)start=k;}
                            else{if(start!==-1&&k-start>=5){
                                var parts=[];var lim=Math.min(k-start,500);
                                for(var x=start;x<start+lim;x++)parts.push(String.fromCharCode(arr[x]));
                                var s=parts.join('');var ls=s.toLowerCase();
                                if(ls.indexOf('recall')!==-1||ls.indexOf('revoke')!==-1){
                                    if(ls.indexOf('msg')!==-1||ls.indexOf('message')!==-1||ls.indexOf('kernel')!==-1||ls.indexOf('notif')!==-1){
                                        log('  🔤 '+m.name+': "'+s.substring(0,80)+'"');
                                        foundStr++;
                                        if(foundStr>=5) break;
                                    }
                                }
                                start=-1;
                            }else start=-1;}
                        }
                        if(foundStr>0) log('  📦 '+m.name+' 有 '+foundStr+' 个recall字符串');
                    }
                }catch(e){}
                break;
            }
        }
    }catch(e){}
}

// 尝试 Hook 找到的符号
for(var i=0;i<found.length;i++){
    try{
        Interceptor.attach(found[i].addr,{
            onEnter:function(args){
                log('🚫 命中: '+this.info.mod+' '+this.info.sym);
                try{var bt=Thread.backtrace(this.context,Backtracer.ACCURATE).map(DebugSymbol.fromAddress).slice(0,15).join('\n    ');log('  栈:\n    '+bt);}catch(e){}
                this.context.x0=ptr(0);
            }.bind({info:found[i]})
        });
        log('✅ Hook: '+found[i].mod+' '+found[i].sym);
    }catch(e){log('❌ Hook失败: '+e.message);}
}

if(found.length===0) log('未找到任何recall符号. 撤回完全在Swift闭包/虚函数表中.');
log('扫描完成。撤回测试。');
},10000);
