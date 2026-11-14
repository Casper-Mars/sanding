#!/usr/bin/env node
/**
 * 三鼎单 host 验收脚本：断言三个角色包的资产真正按 preset 隔离。
 *
 * 为什么需要它：单测只能证明「插件注册了什么」，证明不了「会话里到底看得见什么」。
 * 技能落在 preset 的 scope 层，宿主层读不到；必须起一个真实 profile、按 preset
 * 建会话、再按 scope 读取目录，才能确认三个角色没有互相串味。
 *
 * 用法：
 *   DSH_HOME=<profile 所在目录> DSH_PROFILE=<profile 名> node scripts/verify-presets.mjs
 *   node scripts/verify-presets.mjs --home /tmp/dsh-all --profile v3
 *
 * 前置：该 profile 已安装 dsh-agent-base + dsh-agent-cto + dsh-agent-pm + dsh-agent-dev，
 *      且 profile 的 cordis.patch.yml 把 agent-preset-registry.default 覆盖为 cto。
 *
 * 退出码：全 PASS 为 0，任一 FAIL 为 1。
 */
import { execSync } from 'node:child_process'
import { existsSync, readdirSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'

/** 期望的 preset → 技能清单（与三个包的 assets 清单一一对应）。 */
export const EXPECTED = {
  cto: [
    'architect-tech-spec', 'cto-adr', 'cto-arch-review', 'cto-code-review', 'cto-harness-audit',
    'cto-incident-review', 'cto-security-review', 'cto-standards', 'cto-tech-debt', 'dev-task-plan',
  ],
  pm: [
    'pm-competitive', 'pm-discovery', 'pm-handoff', 'pm-launch', 'pm-metrics',
    'pm-prd', 'pm-prioritize', 'pm-repo-ops', 'pm-retro', 'pm-stakeholder',
  ],
  'dev-leader': [
    'dev-dispatch-contract', 'dev-environment', 'dev-quality-gate', 'dev-release', 'dev-retro', 'dev-worktree-git',
  ],
  'dev-developer': [
    'dev-code-review', 'dev-environment', 'dev-implementation-plan', 'dev-observability',
    'dev-role-developer', 'dev-systematic-debugging', 'dev-test-strategy',
  ],
  'dev-tester': [
    'dev-environment', 'dev-quality-gate', 'dev-role-tester', 'dev-test-strategy',
  ],
}

/** 主会话默认 preset。 */
export const EXPECTED_DEFAULT = 'cto'

/** 所有角色都该看到的共享技能。 */
export const SHARED = ['dev-environment']

/** 每个 preset 的人设标记（用于确认人设没有串味）。 */
export const PERSONA_MARKERS = {
  cto: 'CTO',
  pm: '产品经理',
  'dev-leader': 'Leader',
}

/** 解析参数。 */
export function parseArgs(argv) {
  const options = {
    home: process.env.DSH_HOME,
    profile: process.env.DSH_PROFILE ?? 'v3',
  }
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--home') options.home = argv[++index]
    else if (argv[index] === '--profile') options.profile = argv[++index]
  }
  return options
}

/**
 * 定位 dsh 安装目录：优先 `--dsh-root`，其次从 PATH 里的 dsh 反推。
 * @returns {string} 包含 lib/profile-boot.js 的包根目录。
 */
export function resolveDshRoot(explicit) {
  if (explicit !== undefined && explicit !== '') return resolve(explicit)
  const bin = execSync('command -v dsh', { encoding: 'utf8' }).trim()
  const real = resolve(predecessor(bin))
  // <root>/lib/bin.js → <root>
  const root = resolve(dirname(real), '..')
  if (!existsSync(join(root, 'lib', 'profile-boot.js'))) {
    throw new Error(`无法从 dsh 可执行文件反推安装目录：${real}`)
  }
  return root
}

/** 解析符号链接（不依赖 realpath，逐级 readlink）。 */
function predecessor(path) {
  let current = resolve(path)
  for (let depth = 0; depth < 10; depth += 1) {
    try {
      const target = execSync(`readlink ${JSON.stringify(current)}`, { encoding: 'utf8' }).trim()
      if (target === '') return current
      current = resolve(dirname(current), target)
    } catch {
      return current
    }
  }
  return current
}

/** 入口。 */
async function main() {
  const argv = process.argv.slice(2)
  const options = parseArgs(argv)
  const dshRootArg = argv.includes('--dsh-root') ? argv[argv.indexOf('--dsh-root') + 1] : undefined
  if (options.home === undefined || options.home === '') {
    console.error('FAIL 缺少 DSH_HOME（或 --home）')
    process.exit(1)
  }

  process.env.DSH_HOME = options.home
  process.env.DSH_PROFILE = options.profile

  const dshRoot = resolveDshRoot(dshRootArg)
  const { runProfile } = await import(`${dshRoot}/lib/profile-boot.js`)
  const scopeModule = join(dshRoot, 'node_modules', '@deepseek-ai', 'dsh-scope', 'lib', 'index.js')
  const { scopeOf } = await import(scopeModule)

  const failures = []
  const pass = (message) => console.log(`PASS ${message}`)
  const fail = (message) => {
    failures.push(message)
    console.log(`FAIL ${message}`)
  }
  const warn = (message) => console.log(`WARN ${message}`)

  const environment = new Map(Object.entries(process.env).map(([key, value]) => [key, { value }]))
  const { ctx, shutdown } = await runProfile({ environment, profile: options.profile, patchFiles: [], args: [] })

  try {
    const presets = ctx.get('agentPresets')
    if (presets === undefined) {
      fail('ctx.agentPresets 缺失：preset 服务未装载')
      return
    }

    const roster = await presets.list()
    const ids = roster.map((item) => item.id ?? item.config?.id)
    const missingPresets = Object.keys(EXPECTED).filter((id) => !ids.includes(id))
    if (missingPresets.length === 0) pass(`${Object.keys(EXPECTED).length} 个 preset 全部注册：${ids.join(',')}`)
    else fail(`缺少 preset：${missingPresets.join('、')}`)

    if (presets.defaultId === EXPECTED_DEFAULT) pass(`主会话默认 preset = ${EXPECTED_DEFAULT}`)
    else fail(`主会话默认 preset 是 "${String(presets.defaultId)}"，期望 "${EXPECTED_DEFAULT}"（检查 profile 的 cordis.patch.yml 覆盖）`)

    const skills = ctx.get('skills')
    const globalList = await skills.list()
    if (globalList.length === 0) pass('宿主层没有领域技能（全部在 preset 层，无泄漏）')
    else fail(`宿主层出现 ${globalList.length} 个技能：${globalList.map((item) => item.name).join('、')}`)

    const agents = ctx.get('agents')

    for (const [presetId, expectedSkills] of Object.entries(EXPECTED)) {
      const handle = await agents.create({
        sessionId: `verify-${presetId}-${Date.now()}`,
        meta: { agentPreset: presetId, cwd: '/tmp' },
        setup: async (agentCtx) => {
          await presets.mount(agentCtx, presetId)
        },
      })

      const actual = (await skills.list({ scope: scopeOf(handle.agent.ctx) }))
        .map((item) => item.name)
        .sort()
      const want = [...expectedSkills].sort()

      const extra = actual.filter((name) => !want.includes(name))
      const lack = want.filter((name) => !actual.includes(name))
      if (extra.length === 0 && lack.length === 0) {
        pass(`${presetId}: ${actual.length} 个技能与预期完全一致`)
      } else {
        fail(`${presetId}: 技能清单不符（多出：${extra.join('、') || '无'}；缺少：${lack.join('、') || '无'}）`)
      }

      const marker = PERSONA_MARKERS[presetId]
      if (marker !== undefined) {
        const assembly = await ctx.get('systemPrompt').assemble({ scope: scopeOf(handle.agent.ctx) })
        const persona = assembly.sections.filter((section) => section.name === 'deployment:persona-prefix')
        if (persona.length === 0) {
          warn(`${presetId}: 装配结果里没有 deployment:persona-prefix（跳过该断言）`)
        } else if (persona.some((section) => String(section.text ?? '').includes(marker))) {
          pass(`${presetId}: persona 是本角色（含「${marker}」）`)
        } else {
          const names = assembly.sections.map((section) => section.name).join('、')
          fail(`${presetId}: persona 文本里没有「${marker}」，可能被别的角色覆盖（sections: ${names}）`)
        }
      }
    }

    for (const skill of SHARED) {
      const viewers = Object.entries(EXPECTED)
        .filter(([, list]) => list.includes(skill))
        .map(([id]) => id)
      if (viewers.length > 1) pass(`共享技能 ${skill} 覆盖 ${viewers.length} 个 preset（${viewers.join('、')}）`)
    }
  } catch (error) {
    fail(`验收过程异常：${error instanceof Error ? (error.stack ?? error.message) : String(error)}`)
  } finally {
    try {
      if (typeof shutdown === 'function') await shutdown()
    } catch {
      // 关闭失败不影响结论
    }
  }

  if (failures.length > 0) {
    console.log(`\n# 结果：${failures.length} 项失败`)
    process.exit(1)
  }
  console.log(`\n# 结果：全部通过（${Object.keys(EXPECTED).length} 个 preset）`)
  process.exit(0)
}

const invokedDirectly = process.argv[1] !== undefined
  && resolve(process.argv[1]).endsWith('verify-presets.mjs')
if (invokedDirectly) await main()
