# Harness 工程接入文档

本文面向 Olivia Soul 桌面端、本机服务及后续独立后端。目标是把“读取记忆—关系定调—生成—检查—必要时重写”作为一个可观测、可恢复的生成管线接入工程，而不是把一次模型调用直接当作回信。

v18 的精简接入契约、文件清单和验收项见 `V18_ENGINEERING.md`；本文保留更完整的设计与运维说明。

## 1. 当前接入状态

本机服务已经接入基础 Harness：

1. `server.js` 收到来信后写入 SQLite 队列。
2. 全局 worker 串行取出待处理信件。
3. `deepSeekGenerator` 启动 `harness-live.ps1`。
4. `harness-live.ps1` 将本封来信临时追加到档案末尾，计算本封往来编号。
5. `harness-4step.ps1` 执行完整生成管线。
6. 最终正文写入临时输出文件，由 Node 读取后写回 SQLite。
7. 成功回信进入 SQLite 记忆序列，随后原子重建 Markdown 投影并触发结构化摘要整理。

入口位置：

- Node 调用：`local-service/server.js` 中的 `deepSeekGenerator`
- 实时适配层：`.cursor/skills/fit-letters/scripts/harness-live.ps1`
- 管线编排：`.cursor/skills/fit-letters/scripts/harness-4step.ps1`
- 记忆构建：`.cursor/skills/fit-letters/scripts/memory-lib.ps1`
- 模型调用：`.cursor/skills/fit-letters/scripts/ds-call.ps1`
- Prompt：`harness/*.md`

当前正式服务默认使用根目录 `harness/`，版本由 `harness/VERSION` 标记，当前为 v18。正式目录保留栏目、预检、生成、检查、重写、写法与开信文件。按需翻信是已撤回的实验步骤，不进入正式生成。

## 2. 为什么叫四步 Harness

主流程通常称“四步 Harness”，因为核心职责是：

1. 预检
2. 生成
3. 检查
4. 必要时重写

按需翻信是预检与正文之间的证据层，不改变“预检、生成、检查、重写”四种核心职责。落到文件产物时：

```text
STEP0 组装记忆
STEP1 暂定账本
STEP2 历史检索与证据校正
STEP3 草稿
STEP4 检查
STEP5 最终稿：草稿直出，或反馈重写后复检
```

STEP5 不是每次都调用模型。检查没有违规时，草稿会直接复制为最终稿。

## 3. 端到端时序

```text
来信入队
  → 创建临时来信文件
  → harness-live 生成临时档案
  → SQL 冻结本轮 olivia-history.snapshot/v1
  → Build-Memory 构造导航上下文与事实上下文
  → STEP1 暂定预检账本
      ├─ 拦截：输出 [BLOCKED]，整封失败
      └─ 通过
  → STEP2 模型按需请求 search/read/neighbors
  → 本地只读检索器返回带 ID 与哈希的原文
  → 原文证据校正账本
  → STEP3 草稿
  → STEP4 逐栏检查
      ├─ 0 个违规：草稿成为最终稿
      └─ 有违规：STEP5 反馈重写并复检
  → Node 读取最终正文
  → SQLite 标记已回信
  → 写入 SQLite 记忆序列
  → 原子全量重建 Markdown 投影
  → 结构化刷新记忆摘要并回写 SQLite
```

工程上必须把“生成成功”和“归档成功”视为两个状态。现有服务已经用 `reply_text`、`archived_at`、`memory_error` 区分它们。

## 4. STEP0：记忆组装

`memory-lib.ps1` 负责生成当前模型可见的上下文，不直接写回信。

同时生成两份上下文：

1. 导航上下文：固定开信、十封以前五段式回忆、再前 5 封逐封摘要、最近 5 封全文、本次来信。
2. 事实上下文：固定开信、最近 5 封全文、本次来信。

重要约束：

- 当前来信必须存在于临时档案，但不能包含对应的林离回信。
- 越近的历史越完整。
- 摘要只负责帮助 STEP2 定位候选，不能建立关系、称呼、亲密动作或共同事实。
- SQLite 是唯一事实源；正式档案是带 MD5 校验、可随时全量重建的 Harness 投影。
- `_probe/mem_cache` 只保留给拟合测试兼容使用，本地服务不会从中恢复正式摘要。

实时入口不会直接修改正式档案。Node 在启动 Harness 前校验 SQL 源 MD5 与投影文件 MD5；任一不符即先全量重建。`harness-live.ps1` 再创建 `_probe/live_input_*.md`，Harness 完成后删除。

## 5. STEP1：预检

预检承担三类职责：

- 安全筛查
- 关系和亲密上限定调
- 对来信中强加事实的识别

正式增量 Prompt 为 `harness/01-预检.md`。首次导入已有档案或实时账本缺失时，改用 `harness/01-初始化账本.md` 完整读取五段式关系摘要与最近原文；之后再由增量 Prompt 逐封继承。

预检输出是下游命令，不是给用户看的分析。草稿、检查和重写都会读取它。

### 5.1 拦截语义

只有明确安全项应阻断整封。关系越界、求抱、求吻或单方面升级，不应直接阻断，而应交给正文按边界处理。

预检若输出“拦截”，Harness 会写出：

```text
[BLOCKED]
<预检正文>
```

`harness-live.ps1` 将其转换为失败，不把内容交给用户。

### 5.2 严格格式

格式校验已经内置在 `harness-4step.ps1`：v18 正式预检必须为十四行。每行必须使用全角分隔符，最后一行必须是“结论”。格式不合格只修复一次，第二次仍失败则整封失败。

## 6. 跨封情感账本

跨封情感账本用于解决每封都重新猜关系而产生的跳档，也避免把“亲密上限”误当成本封应该主动给出的动作：

```text
暧昧 → 密友 → 一般朋友 → 暧昧
```

正式账本持久字段为：

- 关系与关系依据
- 已承认情感
- 已承认称呼
- 既有亲密
- 既有边界
- 亲密上限

每封还会计算两个非持久字段：

- 本封亲密请求
- 本封亲密判定

没有明确身体请求时，判定固定为“未请求，不主动给”。有请求也只表示按关系、边界和林离意愿处理，不要求给满亲密上限。

### 6.1 顺序依赖

第 N 封读取同一 tag 下第 N-1 封的 `1safe` 产物，默认继承持久字段；只有新增的上一封林离回信出现明确升级、撤回、亲密或边界变化时才更新。因此同一 person 必须串行生成。

`harness-live.ps1` 正式传入：

```powershell
-PreviousStateTag "live"
-AllowStateBootstrap
```

升级后若缺少上一封账本，`-AllowStateBootstrap` 会切换到专用初始化 Prompt，依据全部可见历史建立当前账本；之后恢复逐封继承。普通回归不应启用该开关，缺号时直接失败，避免把断链误当成连续状态。一次性导入测试可显式传入 `-InitializeState`。

当前账本保存在 `_probe/h4_{person}_{NN}_live_1safe.txt`。后续可把标准化持久字段写入 SQLite，文件产物继续保留用于审计。

## 7. STEP2：可审计按需翻信

Node 把本轮开始前的 SQL 历史冻结为 `olivia-history.snapshot/v1`，通过 `-HistoryFile` 传入。独立回归则从归档生成同一快照。模型只输出结构化 `finish` 或 `lookup`；控制层只执行 `search`、`read`、`neighbors`。

摘要与搜索片段只负责导航。旧事实进入账本或正文前，必须读取完整往来，并携带 `letterId`、`contentMd5`、`exactSha256`。检索最多两轮、四个查询、五个候选、三封完整往来、12,000 字符和 45 秒。所有意图、拒绝、命中原文与终止原因写入 `2history_audit`。

## 8. STEP3：草稿生成

草稿同时接收：

- 栏目约束
- 经原文校正的最终账本
- 完整写法
- 人设
- 事实上下文
- 按需检索原文证据

输出必须只有回信正文。不得带角色名前缀、分析、Markdown 标题或内部字段。

若使用 `-DraftFile`，Harness 会跳过模型草稿调用，读取指定文件后继续检查。这适合复现检查器问题，不适合正式实时回信。

## 9. STEP4：尾端检查

检查器不是重新写信，而是逐栏判断“过／违规”并给短证据。

主要检查：

- 关系与亲密是否越界或回撤
- 是否认领强加事实
- 点名问题是否遗漏
- 是否泄漏预检、栏目或规则原句
- 口气、节奏、句长和形状
- 是否出现咨询腔、审批腔或元话语

脚本只把第二列严格等于“违规”的行计入问题。不要用字符串包含“违规”判断，否则“未见违规”也会误触发重写。

## 10. STEP5：最终稿与反馈重写

检查无违规：

```text
5final = 3draft
```

检查有违规：

1. 只提取违规行。
2. 将违规、草稿、上下文、规则和人设交给重写 Prompt。
3. 重写结果成为 `5final`。

重写不是第二次自由创作。Prompt 要求只修违规处和受影响句子，不新增专名、不扩写。

重写后固定复用 STEP4 再检查一次。复检仍有违规则整封失败，不进入第二次重写，避免无限循环。

## 11. 输入契约

### 11.1 Person

- 非空
- 首尾不能有空白
- 不能为 `.` 或 `..`
- 不能包含 Windows 文件名非法字符或控制字符

Person 用于：

- 正式档案名
- Harness 产物名
- 本机唯一身份的档案投影

### 11.2 正式档案

路径：

```text
信件往来/{person}.md
```

最小结构：

```markdown
# 往来 · {person}

## 2026-08-24

### 往来 01

#### 我（信件）

来信正文

#### 林离（回信）

回信正文
```

往来编号必须连续。实时生成时，本封临时来信编号为历史最大编号加一。

### 11.3 规则、人设与密钥

- 规则：`.cursor/rules/linli-letters.mdc`
- 人设：`林离人设.md`
- 密钥：`.cursor/secrets/deepseek.env`

密钥文件至少包含：

```text
DEEPSEEK_API_KEY=...
```

可选自定义项：

```text
DEEPSEEK_CUSTOM=true
DEEPSEEK_MODEL=...
DEEPSEEK_BASE=https://...
```

密钥不得进入日志、Harness 产物、档案或发布包。

## 12. 输出契约

单次运行会在 `_probe/` 下产生：

```text
h4_{person}_{NN}_{tag}_1safe.txt
h4_{person}_{NN}_{tag}_3draft.txt
h4_{person}_{NN}_{tag}_4check.txt
h4_{person}_{NN}_{tag}_5final.txt
```

调用方只把 `5final` 当用户回信。其他文件是审计产物。

成功标志：

```text
HARNESS5 DONE
```

仅跑预检时：

```text
HARNESS1 DONE
```

不能只凭进程退出码判断正文可用，还要校验：

- 输出文件存在
- 正文非空
- 不以 `[BLOCKED]` 开头

## 13. Node 接入方式

现有服务采用参数数组调用 PowerShell，不经过命令行字符串拼接：

```js
await runProcess("powershell.exe", [
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", harnessLivePath,
  "-Person", person,
  "-Letter", letterFile,
  "-OutFile", replyFile,
  "-Root", workspaceRoot,
], workspaceRoot);
```

必须保留：

- `windowsHide: true`
- 独立 stdout/stderr 收集
- 超时
- 非零退出码转失败
- 参数数组，不使用 shell 拼接

Windows PowerShell 5 对中文参数和脚本编码敏感。工程代码应优先直接传参数数组；需要组合复杂命令时使用 UTF-16LE `EncodedCommand`，不要通过 `.cmd` 中转中文路径。

## 14. 队列、并发与事务边界

### 14.1 串行要求

同一 person 必须串行，原因包括：

- 下一封记忆依赖上一封已归档回复
- 关系状态传递依赖上一编号
- 同 tag 产物会覆盖
- 记忆刷新和档案追加需要稳定顺序

不同 person 可以并行，但要分别加锁，并控制模型接口总并发。

### 14.2 成功事务

推荐顺序：

1. 将信件状态改为 `LLM_PROCESSING`
2. 生成最终正文
3. 在事务中写入 `reply_text`、连续 `memory_order`、日期、标签与 `content_md5`
4. 标记 `archived_at`
5. 从 SQL 原子全量重建 Markdown 投影并保存源 MD5、文件 MD5
6. 把结构化摘要任务交给 PowerShell，校验返回的 `letterId/contentMd5/有序哈希` 后事务写回 SQL

回复已生成但尚未进入记忆序列时，不应重新生成正文；现有服务启动时会扫描已回信且 `memory_order` 为空的记录补写，并由 SQL 重建投影。

### 14.3 失败事务

以下任一情况进入失败：

- Harness 非零退出
- 超时
- 输出缺失或为空
- 安全预检拦截
- 服务重启导致正在生成的子进程丢失

失败信不进入正式档案，也不应推进关系状态。

## 15. 超时与重试

当前 Node 侧生成超时为一小时。单次 DeepSeek 调用仍可能发生：

- HTTP 错误
- 连接被远端关闭
- `ReadToEnd` 超时
- 空内容
- 预检格式不合格

工程建议：

- 仅对网络错误、空内容和格式错误重试
- 安全拦截不重试
- 每一步最多重试 2—3 次
- 使用指数退避和抖动
- 重试时复用已成功且输入未变化的前序步骤
- 记录 step、attempt、person、exchange、耗时和错误类型

不要把整个 Harness 无条件重跑多次，否则会增加成本并放大生成漂移。

## 16. 可观测性

至少记录：

- `letterId`
- person
- 往来编号
- tag
- 当前 step
- 每步耗时
- 模型与接口地址
- 是否复用 safe/draft
- 是否触发重写
- 检查违规数量
- 最终状态
- 错误类别

不得记录：

- API Key
- 完整 Authorization Header
- 未经授权的全量用户私信

开发环境可保留 `_probe` 全产物；正式环境应配置保留周期和访问权限。

## 17. 发布包接入

`local-service/packaging/build-release.ps1` 负责把脚本和 Prompt 复制到安装包工作区模板。

新增或修改 Harness 文件时，要同时检查：

1. `.cursor/skills/fit-letters/scripts` 的复制白名单
2. `harness` Prompt 的复制白名单
3. `packaging/linli-letters.mdc`
4. `packaging/林离人设.md`
5. 安装后的 `%APPDATA%\OliviaSoul\workspace\`

不要直接修改：

- `local-service/dist/`
- `local-service/dist-native/stage/`

它们是构建产物，会在下次打包时被覆盖。

v18 情感账本已经并入正式 `01-预检.md`；发布白名单同步该文件和 `VERSION` 即可。

## 18. 测试要求

### 18.1 单元测试

- Person 路径校验
- 临时档案编号计算
- `[BLOCKED]` 转失败
- 空输出转失败
- 已生成未归档的恢复
- 同 person 串行
- 不同 person 隔离

### 18.2 Harness 契约测试

- STEP1 行数与字段顺序
- 检查“未见违规”不会触发重写
- 有违规时一定生成新 `5final`
- 无违规时 `5final` 与 `3draft` 相同
- 不存在 `2feel` 产物且完整管线仍可完成
- `StopAfterSafe` 不生成正文
- 普通回归找不到上一编号时明确失败；实时升级只有显式启用 `AllowStateBootstrap` 才允许初始化

### 18.3 回归样本

至少保留：

- 黑塔：低关系与边界
- 应如是：关系升温、求抱与既有亲密
- 莫离：长历史、媒体事实和关系持续性
- 明确安全拦截样本
- API 超时、空内容和格式错误样本

固定排除黑塔往来 24，不用它评价当前项目的关系与离开行为。

## 19. 上线检查清单

- [ ] 服务只监听预期地址
- [ ] API Key 已配置且不进日志
- [ ] 正式规则、人设、Prompt 与开发版本一致
- [ ] PowerShell 脚本语法校验通过
- [ ] Node 测试通过
- [ ] 实际 DeepSeek 连通性通过
- [ ] 单封完整 Harness 冒烟通过
- [ ] 队列串行与失败重试通过
- [ ] 回信成功后正式档案可恢复
- [ ] 记忆刷新失败不导致重复生成
- [ ] 安装包包含全部新增脚本和 Prompt
- [ ] 跨封情感账本已通过黑塔、应如是、莫离顺序回归

## 20. 推荐接入顺序

1. 用应如是从头完成 v18 情感账本顺序回归。
2. 再用黑塔和莫离验证低关系、长历史与边界稳定性。
3. 在关键转折点对照 v16m 与原版正文。
4. 为十四字段预检、断链初始化、检索预算和摘要毒化增加独立集成测试。
5. 小范围启用，观察关系升级、主动亲密、事实误判和重写率。
6. 稳定后把账本持久字段迁入 SQLite，文件继续用于审计。
