// GitHub 事件 → 角色会话（dsh-webhook 规则模块）。
// 当前部署：agentPreset=cto + requiredLabels=[bug]；prompt 只有一句 issue/PR 链接，
//
// 挂载：deployment/agents/webhook → /home/node/.dsh/profiles/web/webhook
// 加载：home patch（deployment/agents/dsh-agent.patch.yml）
//       name: './profiles/web/webhook/repo-ops-rule.mjs'
//
// 只 import node: 内置模块：本文件从 dsh home 加载，Node 解析路径上只有
// /home/node/.dsh/profiles/web/node_modules，运行时依赖不保证可见。
// WebhookRuleId 只是标识（identity 函数），runtime 只校验非空字符串。

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'

export const name = 'github-repo-ops-rule'
export const inject = ['webhookRuntime']

// 第一期只接三类事件（技术方案 §5.1 Phase 1）
const EVENT_ACTIONS = {
  issues: ['opened', 'reopened'],
  issue_comment: ['created'],
  pull_request: ['opened', 'ready_for_review'],
}

// requiredLabels 非空时额外订阅 issues.labeled：
// 「先建 issue，再打 bug 标签」是最常见路径，只订阅 opened 会漏掉这类。
const EVENT_ACTIONS_WITH_LABELS = {
  ...EVENT_ACTIONS,
  issues: [...EVENT_ACTIONS.issues, 'labeled'],
}

// 去重分两层：
// - 进程内：Set 挡同一进程里的重复 dispatch；
// - 跨进程：落盘到 $DSH_HOME/webhook-seen.json，容器重启后仍记得已处理过的 delivery。
// delivery id 是 GitHub 的 X-GitHub-Delivery，redeliver 保持不变，所以按 id 去重。
const SEEN_LIMIT = 1000
const SEEN_TTL_MS = 7 * 24 * 3600 * 1000

function loadSeen(file) {
  try {
    const raw = JSON.parse(readFileSync(file, 'utf8'))
    const now = Date.now()
    const entries = Array.isArray(raw) ? raw : []
    return new Map(
      entries
        .filter(entry => entry && typeof entry.id === 'string' && Number.isFinite(entry.at))
        .filter(entry => now - entry.at < SEEN_TTL_MS)
        .map(entry => [entry.id, entry.at]),
    )
  } catch {
    return new Map()
  }
}

export function apply(ctx, config) {
  const source = config?.source
  const workspacePath = config?.workspacePath
  const agentPreset = config?.agentPreset ?? 'pm'
  const permissionPreset = config?.permissionPreset ?? 'workspace-write'
  const repositories = Array.isArray(config?.repositories) ? config.repositories : []
  // 仓库 → 本地 checkout。未命中时用 workspacePath（会按需建目录）。
  // 单一固定目录无法服务多个仓库，所以映射优先。
  const workspaceByRepo =
    config?.workspaceByRepo && typeof config.workspaceByRepo === 'object'
      ? config.workspaceByRepo
      : {}
  // 空数组 = 不按标签过滤（保持原有行为）。
  // 语义：all-of —— 必须同时带齐这些标签；只关心一个标签时就是「必须带 bug」。
  const requiredLabels = Array.isArray(config?.requiredLabels)
    ? config.requiredLabels.filter(label => typeof label === 'string' && label !== '')
    : []
  const eventActions = requiredLabels.length === 0 ? EVENT_ACTIONS : EVENT_ACTIONS_WITH_LABELS

  if (typeof source !== 'string' || source.trim() === '') {
    throw new Error('repo-ops rule: source 必须是非空字符串')
  }
  if (typeof workspacePath !== 'string' || !workspacePath.startsWith('/')) {
    throw new Error('repo-ops rule: workspacePath 必须是绝对路径')
  }
  for (const [name, path] of Object.entries(workspaceByRepo)) {
    if (typeof path !== 'string' || !path.startsWith('/')) {
      throw new Error(`repo-ops rule: workspaceByRepo.${name} 必须是绝对路径`)
    }
  }

  const seenFile = join(process.env.DSH_HOME ?? '/home/node/.dsh', 'webhook-seen.json')
  const seen = loadSeen(seenFile)

  function remember(deliveryId) {
    seen.set(deliveryId, Date.now())
    while (seen.size > SEEN_LIMIT) seen.delete(seen.keys().next().value)
    try {
      mkdirSync(dirname(seenFile), { recursive: true })
      writeFileSync(
        seenFile,
        JSON.stringify([...seen].map(([id, at]) => ({ id, at }))),
      )
    } catch (error) {
      ctx.logger?.warn?.(`repo-ops rule: 去重文件写入失败：${error?.message ?? error}`)
    }
  }

  ctx.effect(
    () =>
      ctx.webhookRuntime.register({
        id: 'github-repo-ops',
        kind: 'github',

        async run(delivery, signal) {
          if (delivery.source !== source) return null

          const { name: eventName, payload } = delivery.event ?? {}
          const actions = eventActions[eventName]
          if (!actions || !actions.includes(payload?.action)) return null

          const repo = payload.repository?.full_name
          if (typeof repo !== 'string' || repo === '') return null
          if (repositories.length > 0 && !repositories.includes(repo)) return null

          // bot / 自己：GitHub App 与常见 CI 机器人都会带 [bot] 后缀
          const sender = payload.sender ?? {}
          if (sender.type === 'Bot') return null
          if (typeof sender.login === 'string' && sender.login.endsWith('[bot]')) return null

          const subject = payload.issue ?? payload.pull_request ?? {}
          const labels = Array.isArray(subject.labels)
            ? subject.labels
                .map(label => (typeof label === 'string' ? label : label?.name))
                .filter(label => typeof label === 'string' && label !== '')
            : []
          if (requiredLabels.length > 0 && !requiredLabels.every(label => labels.includes(label))) {
            return null
          }

          if (seen.has(delivery.deliveryId)) return null
          remember(delivery.deliveryId)

          // 「创建 issue 时就带标签」会同时产生 issues.opened 与 issues.labeled 两个投递
          // （X-GitHub-Delivery 不同，delivery 级去重挡不住）→ 同一 issue 起两个会话。
          // 这两个事件描述的是同一份 issue 状态（同标签集合），所以按「issue + 标签集合」去重，
          // 与投递顺序无关：先到的处理，后到的直接丢。
          // 只对 issues 生效；pull_request 的 opened / ready_for_review 语义不同，不能合并；
          // issue_comment 仍按 delivery id 去重（评论 id 天然唯一）。
          if (eventName === 'issues') {
            const subjectNumber = subject.number ?? payload.number
            if (subjectNumber !== undefined) {
              const stateKey = `issue:${repo}#${subjectNumber}[${[...labels].sort().join(',')}]`
              if (seen.has(stateKey)) return null
              remember(stateKey)
            }
          }

          signal.throwIfAborted()

          const issue = subject
          const number = issue.number ?? payload.number
          const url = issue.html_url ?? payload.pull_request?.html_url ?? ''
          const target = eventName === 'pull_request' ? 'PR' : 'issue'
          const targetWorkspace = workspaceByRepo[repo] ?? workspacePath
          // WorkspaceRegistry 要求目录存在（realpath）；首次投递按需创建。
          mkdirSync(targetWorkspace, { recursive: true })

          return {
            workspacePath: targetWorkspace,
            agentPreset,
            permissionPreset,
            title: `[repo-ops] ${repo}#${number} ${eventName}.${payload.action}`,
            prompt: `看看这个${target}：${url}`,
          }
        },
      }),
    'repo-ops rule',
  )
}
