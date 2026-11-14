# 单 host 角色合并（dsh-agent）

三个角色包（`dsh-agent-cto` / `dsh-agent-pm` / `dsh-agent-dev`）合并进同一个 profile。

## 为什么能共存

- 三个包的**技能**都挂在各自 preset 的 scope 层（`*/assets`），不是宿主层；
- **persona** 按 preset id 门控，一个 agent 只会被注入属于它 preset 的人设；
- 唯一的冲突点是 `agent-preset-registry`：三个包各带一份 insert，加载器按 id 合并，
  最后写入的 `default` 会胜出。

## 必须做的一件事

在 profile 的 `cordis.patch.yml` 里覆盖默认 preset（本目录的 `cordis.patch.yml` 可直接用）：

```yaml
- id: agent-preset-registry
  config:
    default: cto
```

不覆盖的话默认 preset 取决于 bundle 顺序（实测是 `pm`），主会话会落到错误的角色上。

## 验收

```bash
DSH_HOME=<profile 根> DSH_PROFILE=<profile 名> node scripts/verify-presets.mjs
```

断言：5 个 preset 注册、默认 preset 是 cto、宿主层没有领域技能、每个 preset 的技能清单
与预期完全一致、persona 不串味。
