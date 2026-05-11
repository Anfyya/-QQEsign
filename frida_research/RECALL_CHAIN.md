# NTQQ 撤回链路记录

## 当前结论

实机 Frida 日志已经确认，当前 NTQQ 撤回不需要继续从 `SSLRead`、明文 SQL 或全局 `objc_msgSend` 宽扫下手。撤回进入 UI/消息摘要层时，会稳定构造下面三类对象：

1. `OCRevokeElement`
   - selector: `initWithOperatorTinyId:operatorRole:operatorUid:operatorNick:operatorRemark:operatorMemRemark:origMsgSenderUid:origMsgSenderNick:origMsgSenderRemark:origMsgSenderMemRemark:isSelfOperate:wording:`
   - 高频内部偏移：`QQ!0x11a2205c`、`QQ!0x11a19b48`、`QQ!0x11a19878`

2. `OCGrayTipElement`
   - selector: `initWithSubElementType:revokeElement:proclamationElement:emojiReplyElement:groupElement:buddyElement:feedMsgElement:essenceElement:xmlElement:fileReceiptElement:localGrayTipElement:blockGrayTipElement:aioOpGrayTipElement:jsonGrayTipElement:walletGrayTipElement:`
   - 关键参数：`revokeElement`
   - 高频内部偏移：`QQ!0x11a199f0`

3. `OCMsgAbstractElement`
   - selector: `initWithElementType:elementSubType:content:customContent:index:isSetProclamation:isSetEssence:operatorRole:operatorTinyId:fileName:tinyId:msgSeq:msgId:emojiId:emojiType:localGrayTipType:grayTiPElement:textGiftElement:calendarElement:channelStateElement:onlineFileMsgCnt:mdSummary:`
   - 关键参数：`grayTiPElement`
   - 高频内部偏移：`QQ!0x11a20938`

共同上游高频偏移：

- `QQ!0x5aa3e08`
- `QQ!0x57f3240`
- `QQ!0x5aed0b4`
- `QQ!0x573d884`
- `QQ!0x1463f94c`
- `QQ!0x1461becc`
- `QQ!0x1462d9f0`

## 2026-05-10 23:09 低影响复测

使用 `frida_research/scripts/frida_event_probe.js` 冷启动 QQ，脚本只观察 `OCRevokeElement` 和带 `revokeElement` 的 `OCGrayTipElement`，没有启用通知、全局 `objc_msgSend` 或 `OCMsgAbstractElement` 宽探针。

日志：`frida_research/logs/frida_event_probe_lite_20260510_230944.log`

复测仍命中同一条链：

- `OCRevokeElement` 栈顶：`QQ!0x11a2205c -> QQ!0x11a19b48 -> QQ!0x11a19878`
- `OCGrayTipElement(revokeElement)` 栈顶：`QQ!0x11a199f0`
- 共同上游：`QQ!0x5aa3e08 -> QQ!0x5aa3938 -> QQ!0x570dc18 -> QQ!0x5aa9a04 -> QQ!0x57053a8`
- 后续还出现：`QQ!0x5994370`、`QQ!0x13d707b8`

这次复测说明撤回灰条链路不是旧重探针误报，低影响构造器探针也能稳定命中。

## 已落地拦截点

`Tweak.x` 当前新增了 `OCGrayTipElement initWithSubElementType:revokeElement:...` 兜底拦截：

- 防撤回开关开启
- `revokeElement != nil`
- 直接返回 `nil`，阻止撤回灰条继续包装成 `OCMsgAbstractElement`

这个点比继续拦截 Network/SQLite 更贴近已确认链路，并且比全局 `objc_msgSend` 低风险。

## 2026-05-10 23:13 运行时防撤回复测

使用 `frida_research/scripts/frida_runtime_antirevoke.js` 冷启动注入 QQ。该脚本不是观察脚本，而是直接替换 `OCGrayTipElement initWithSubElementType:revokeElement:...`：

- `revokeElement != NULL` 时返回 `NULL`
- `revokeElement == NULL` 时调用原始实现

日志：`frida_research/logs/frida_runtime_antirevoke_20260510_231356.log`

结果：

- 注入成功：`已替换 OCGrayTipElement 构造器`
- 撤回事件到达运行时：`看到撤回元素`
- 实际拦截成功：`已阻断撤回灰条`
- 截至 23:14 左右，阻断计数已超过 160 次，QQ 进程仍存活。

关键样例：

```text
已阻断撤回灰条 #1 subType=1 revokeClass=<OCRevokeElement ... operatorNick:Ginka ... origMsgSenderNick:Ginka ...>
```

这证明 Frida 注入后的运行时防撤回已经实际执行，不再只是链路观察。

## Frida 文件布局

- 脚本：`frida_research/scripts`
- 日志：`frida_research/logs`

推荐继续验证的脚本：

- `frida_research/scripts/frida_event_probe.js`
- `frida_research/scripts/frida_runtime_antirevoke.js`
- `frida_research/scripts/frida_recall_chain_offsets.js`
- `frida_research/scripts/frida_next_probe.js`

推荐命令：

```powershell
frida -U -f com.tencent.mqq -l .\frida_research\scripts\frida_event_probe.js
```

偏移探针只用于继续定位 QQ 内部上游，不建议常驻：

```powershell
frida -U -f com.tencent.mqq -l .\frida_research\scripts\frida_recall_chain_offsets.js
```

## 下一步判断

如果 `OCGrayTipElement` 返回 `nil` 后出现崩溃或空白灰条，再改为更早拦截 `OCRevokeElement` 构造并返回 `nil`，让后续灰条构造拿不到撤回元素。当前先不加第二个产品拦截点，避免扩大行为面。
