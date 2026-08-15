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

import { execFile } from 'node:child_process'

const BIN = process.env.CLUMSIES_BIN
  || '/Users/weiwang/Applications/Clumsies.app/Contents/Resources/clumsiesd'
const FALLBACK_CWD = process.env.CLUMSIES_HOOK_CWD || process.cwd()

function forward(payload) {
  execFile(BIN, ['_agent', 'issue-run-event', '--host', 'dsh'], {
    input: JSON.stringify(payload),
    timeout: 5000,
    windowsHide: true,
  }, () => { /* fail-open: never block the session */ })
}

export default {
  name: 'clumsies-hook',
  apply(ctx) {
    const emit = (session, event) => {
      const header = session?.header ?? session
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
      if (!header || header.origin === 'subagent' || (header.delegationDepth ?? 0) > 0) {
        return
      }
      forward({
        hook_event_name: 'SessionEnd',
        session_id: header.id ?? 'unknown',
        cwd: header.cwd ?? FALLBACK_CWD,
      })
    })
  },
}
