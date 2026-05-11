// QQESign — 网络层防撤回 (DobbyHook SSLRead)
// 集成: 复制到 Tweak.x 中，在 %ctor 添加 qqesign_installNetworkHooks();

// ─────────────────────────────────────────────
// 1. SSLRead Hook — TLS解密后的明文
//    用 DobbyHook (与现有 inline hook 一致)
// ─────────────────────────────────────────────

typedef OSStatus (*SSLReadFunc)(void *context, void *data, size_t dataLength, size_t *processed);
static SSLReadFunc orig_SSLRead = NULL;

static OSStatus hooked_SSLRead(void *context, void *data, size_t dataLength, size_t *processed) {
    OSStatus ret = orig_SSLRead(context, data, dataLength, processed);
    
    if (ret == noErr && processed && *processed > 0 && pref_antiRevoke) {
        uint8_t *buf = (uint8_t *)data;
        size_t n = *processed;
        
        // 扫描 QQ 撤回协议 Protobuf 特征
        for (size_t i = 0; i + 3 < n; i++) {
            // Protobuf field 1 varint → cmd
            if (buf[i] == 0x08) {
                uint32_t cmd = 0;
                int shift = 0;
                size_t j = i + 1;
                while (j < n && (buf[j] & 0x80) && shift < 28) {
                    cmd |= (uint32_t)(buf[j] & 0x7F) << shift;
                    shift += 7; j++;
                }
                if (j < n) cmd |= (uint32_t)(buf[j] & 0x7F) << shift;
                
                // 撤回 cmd: 0x210(528) C2C, 0x211(529) 群
                if (cmd == 0x210 || cmd == 0x211) {
                    QQELog(@"🔒 SSLRead拦截撤回 cmd=0x%X sz=%zu", cmd, n);
                    memset(buf, 0, n);
                    *processed = 0;
                    return errSSLClosedNoNotify; // -9805
                }
            }
            // 字符串特征
            if (n - i >= 6 && (memcmp(buf + i, "recall", 6) == 0 ||
                               memcmp(buf + i, "revoke", 6) == 0 ||
                               memcmp(buf + i, "Recall", 6) == 0)) {
                QQELog(@"🔒 SSLRead拦截撤回文本 sz=%zu", n);
                memset(buf, 0, n);
                *processed = 0;
                return errSSLClosedNoNotify;
            }
        }
    }
    return ret;
}

static void qqesign_installNetworkHooks(void) {
    // 复用 Tweak.x 已有 Dobby 基础设施
    if (!qqesignResolveInlineHookBackend()) {
        QQELog(@"⚠️ 网络层Hook未安装: Dobby 不可用");
        return;
    }
    
    void *handle = dlopen(
        "/System/Library/Frameworks/Security.framework/Security",
        RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        QQELog(@"⚠️ Security.framework 加载失败");
        return;
    }
    
    void *sslRead = dlsym(handle, "SSLRead");
    if (!sslRead) {
        QQELog(@"⚠️ SSLRead 符号未找到");
        dlclose(handle);
        return;
    }
    
    // ★ 用项目已有的 DobbyHook 函数
    int rc = gQQEDobbyHook(sslRead, (void *)hooked_SSLRead, (void **)&orig_SSLRead);
    if (rc == 0) {
        QQELog(@"✅ SSLRead Hook 已安装 (Dobby) %p", sslRead);
    } else {
        QQELog(@"❌ SSLRead Hook 失败 rc=%d", rc);
    }
    // 不关闭 handle，SSLRead 需要保持可用
}
