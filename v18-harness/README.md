# v18 Harness

这是不依赖主工程目录结构的 v18 可审计 Harness：组装记忆后依次预检、生成、检查，必要时重写。更早的信用摘要带路，最近几封保留原文。

快速入口：

```powershell
$env:DEEPSEEK_API_KEY = "你的密钥"
.\run-live.ps1 -Person "示例对象" -Letter ".\incoming.txt" -OutFile ".\reply.txt"
```

完整配置、档案格式、回归运行和连续状态传递见 [`../docs/HARNESS.md`](../docs/HARNESS.md)。

请勿提交 API 密钥、`_probe/` 产物或真实私密往来。
