// What the channels.sh guard alerts may say about auth (card e65e15e7).
//
// Both boot-path alerts used to claim, unconditionally, that the main agent
// "auths from the rotating shared credential and can 401". Measured 2026-09-25
// on a boot that drew that alert: the tmux global env and the main claude's
// /proc/<pid>/environ carried CLAUDE_CODE_OAUTH_TOKEN, and
// ~/.claude/.credentials.json did not exist. The exported env token outranks the
// /login session (#1805), so the claim was false. #1846 fixed the respawn twin
// (src/web/main-config-decision.ts); this pins the boot path.
//
// Same two kinds of assertion as channels-guard-sender.test.ts: the verdict
// helper is lifted out and RUN, and separately the call sites are pinned, so a
// green helper test cannot hide an alert that stopped using it.

import { describe, it, expect } from 'vitest'
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const __dirname = dirname(fileURLToPath(import.meta.url))
const SCRIPT = join(__dirname, '..', '..', 'scripts', 'channels.sh')
const src = readFileSync(SCRIPT, 'utf-8')

const fnStart = src.indexOf('_guard_auth_verdict() {')
const fnEnd = src.indexOf('\n}\n', fnStart)
const fn = fnStart >= 0 && fnEnd > fnStart ? src.slice(fnStart, fnEnd + 3) : ''

/** Run the lifted helper. The token travels in the ENVIRONMENT only. */
function verdict(mode: 'log' | 'msg', env: Record<string, string>): string {
  return execFileSync('bash', ['-c', `${fn}\n_guard_auth_verdict ${mode}`], {
    encoding: 'utf-8',
    env: { PATH: process.env['PATH'] ?? '', ...env },
    timeout: 10000,
  })
}

describe('_guard_auth_verdict: the 401 claim follows what this launch exports', () => {
  it('is defined in channels.sh', () => {
    expect(fn, '_guard_auth_verdict() not found in scripts/channels.sh').toContain('_guard_auth_verdict() {')
  })

  it('token exported -> no 401 risk, in both languages, and never the old "rotating credential" claim', () => {
    const env = { CLAUDE_CODE_OAUTH_TOKEN: 'sk-ant-oat01-test' }
    const msg = verdict('msg', env)
    const log = verdict('log', env)
    expect(msg).toContain('401-VESZELY: NINCS')
    expect(log).toContain('401 risk: NO')
    for (const t of [msg, log]) {
      expect(t).not.toMatch(/rotalodo|rotating/i)
      // The token value itself never reaches an alert.
      expect(t).not.toContain('sk-ant-oat01-test')
    }
  })

  it('no token -> 401 risk, said out loud', () => {
    expect(verdict('msg', {})).toContain('401-VESZELY: VAN')
    expect(verdict('log', {})).toContain('401 risk: YES')
  })

  it('an EMPTY token is no token', () => {
    expect(verdict('msg', { CLAUDE_CODE_OAUTH_TOKEN: '' })).toContain('401-VESZELY: VAN')
  })
})

describe('the call sites', () => {
  it('no alert text in channels.sh still makes the unconditional rotating-credential claim', () => {
    expect(src).not.toMatch(/rotalodo megosztott credential|rotalodo shared session|rotating shared credential|Auth rides the rotating shared session/)
  })

  it('both triggers carry the measured verdict in the log line AND the message', () => {
    expect(src.match(/\$\(_guard_auth_verdict log\)/g)?.length).toBe(2)
    expect(src.match(/\$\(_guard_auth_verdict msg\)/g)?.length).toBe(2)
  })

  it('trigger 1 is narrowed like its respawn twin: it warns only when the token is NOT exported', () => {
    const warn = src.indexOf('although a fleet setup-token exists')
    expect(warn).toBeGreaterThan(0)
    const cond = src.lastIndexOf('if [ -z "$CFG_ENV" ]', warn)
    const condLine = src.slice(cond, src.indexOf('\n', cond))
    expect(condLine).toContain('[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]')
    // And the healthy shared-root-with-token case leaves a trace instead of silence.
    expect(src).toContain('fleet token exported as CLAUDE_CODE_OAUTH_TOKEN (outranks the /login session per the documented precedence) -- nothing to warn about')
  })

  it('trigger 2 keeps its condition: a lost isolation setting is still reported, token or not', () => {
    const warn = src.indexOf('although isolated dir')
    const cond = src.lastIndexOf('if [ -z "$CFG_ENV" ]', warn)
    const condLine = src.slice(cond, src.indexOf('\n', cond))
    expect(condLine).toBe('if [ -z "$CFG_ENV" ] && [ -d "$INSTALL_DIR/.channels-config" ]; then')
  })
})
