// DSH → Clumsies hook bridge.
//
// Forwards web-session lifecycle events to the local Clumsies daemon so it
// can issue and end `dsh` AgentRuns (kanban.begin_work / request_closure
// require a hook-issued run). Fail-open: a missing daemon or a failed
// forward never blocks the session.
//
// Install: copy to ~/.dsh/profiles/web/clumsies-hook.mjs and add to
// cordis.patch.yml:
//   - insert:
//       - id: clumsy-hook
//         name: /Users/weiwang/.dsh/profiles/web/clumsies-hook.mjs
//
// Root sessions only: subagent/child sessions (origin 'subagent' or
// delegationDepth > 0) are skipped so one user prompt maps to one root run.
// turn_id embeds the session id so a fresh session never collides with an
// older session's run key.
//
// Note: the payload must reach the hook proxy via stdin, so we use spawn()
// and write the JSON ourselves — async execFile() has no input option and
// the child would block on stdin forever.

import { spawn } from 'node:child_process'
import { appendFileSync } from 'node:fs'

const BIN = process.env.CLUMSIES_BIN
  || '/Users/weiwang/Applications/Clumsies.app/Contents/Resources/clumsiesd'
const FALLBACK_CWD = process.env.CLUMSIES_HOOK_CWD || process.cwd()
const LOG = process.env.CLUMSIES_HOOK_LOG || '/tmp/clumsies-hook.log'

function log(line) {
  try { appendFileSync(LOG, `[${new Date().toISOString()}] ${line}\n`) } catch { /* never block */ }
}

function forward(payload) {
  const input = JSON.stringify(payload)
  log('forward ' + input.slice(0, 140))
  const child = spawn(BIN, ['_agent', 'issue-run-event', '--host', 'dsh'], {
    stdio: ['pipe', 'ignore', 'pipe'],
    windowsHide: true,
  })
  let stderr = ''
  child.stderr?.on('data', (chunk) => { stderr += chunk })
  child.on('error', (err) => log('forward error: ' + (err.message || err).slice(0, 200)))
  child.on('close', (code, signal) => {
    log('forward close code=' + code + ' signal=' + signal + (stderr ? ' stderr=' + stderr.slice(0, 120) : ''))
  })
  child.stdin.on('error', () => { /* EPIPE when the child exits early */ })
  child.stdin.end(input)
  // Fail-open watchdog: never let a stuck hook block the session's resources.
  const watchdog = setTimeout(() => { child.kill('SIGKILL') }, 5000)
  child.on('close', () => clearTimeout(watchdog))
}

export default {
  name: 'clumsies-hook',
  apply(ctx) {
    log('plugin loaded, bin=' + BIN)
    const emit = (session, event) => {
      const header = session?.header ?? session
      log('session/event type=' + (event?.type ?? '?') + ' session=' + (header?.id ?? '?'))
      if (!header || header.origin === 'subagent' || (header.delegationDepth ?? 0) > 0) {
        return
      }
      const sessionId = header.id ?? 'unknown'
      const cwd = header.cwd ?? FALLBACK_CWD
      switch (event?.type) {
        case 'turn/start': {
          const turn = event.data?.turn ?? '?'
          forward({
            hook_event_name: 'UserPromptSubmit',
            session_id: sessionId,
            turn_id: sessionId + ':t' + turn,
            cwd,
          })
          break
        }
        case 'turn/end': {
          const turn = event.data?.turn ?? '?'
          const failed = event.data?.reason?.kind === 'error'
          forward({
            hook_event_name: failed ? 'StopFailure' : 'Stop',
            session_id: sessionId,
            turn_id: sessionId + ':t' + turn,
            cwd,
            ...(failed ? { error: 'turn-failed' } : {}),
          })
          break
        }
      }
    }
    ctx.on('session/event', (session, event) => emit(session, event))
    ctx.on('session/disposed', (session) => {
      const header = session?.header ?? session
      log('session/disposed session=' + (header?.id ?? '?'))
      if (!header || header.origin === 'subagent' || (header.delegationDepth ?? 0) > 0) {
        return
      }
      forward({
        hook_event_name: 'SessionEnd',
        session_id: header.id ?? 'unknown',
        cwd: header.cwd ?? FALLBACK_CWD,
      })
    })
    log('plugin handlers attached')
  },
}
