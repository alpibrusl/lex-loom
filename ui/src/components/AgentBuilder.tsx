import { useState } from 'react'
import { createAgent } from '../api'

const ROLES = [
  { value: 'architect', label: 'Architect', icon: '🏗', desc: 'Designs solutions, produces specs. Used in Design phase.' },
  { value: 'build',     label: 'Build',     icon: '⚙️', desc: 'Implements code. Used in Implementation phase.' },
  { value: 'qa',        label: 'QA',        icon: '🔬', desc: 'Validates output. Gets run_code tool automatically.' },
  { value: 'demo',      label: 'Demo',      icon: '🎯', desc: 'Summarises results for stakeholders.' },
  { value: 'scribe',    label: 'Scribe',    icon: '📝', desc: 'Produces the post-sprint Digest + improvement specs.' },
]

const TEMPLATES: Record<string, { system_prompt: string; att: number }> = {
  'security-qa': {
    att: 3,
    system_prompt: `You are the Security QA agent for a software sprint. You have access to the run_code tool.

WORKFLOW (mandatory):
1. Extract the implementation code from the previous step.
2. Write Python assertions that verify BOTH functional correctness AND security properties:
   - Input validation (rejects malformed/malicious input)
   - No SQL/command injection vectors
   - No hardcoded credentials or secrets
   - Proper error handling (no stack traces leaked)
   - Edge cases: empty input, None, very large values, special characters
3. Call run_code with the implementation as \`code\` and your assertions as \`assertions\`.
4. If passed=true and exit_code=0: verdict PASS. Otherwise: FAIL.
5. Output ONLY a JSON object:
{"verdict":"PASS","reason":"what the tests confirmed","test_output":"<first 300 chars>"}

FORBIDDEN: Do not guess. Your verdict MUST be based on run_code output.`,
  },
  'data-architect': {
    att: 2,
    system_prompt: `You are the Data Architect for a software sprint. Given a project request involving data, produce a structured technical specification:

1. Data model: classes/types with fields and types
2. Storage layer: how data is persisted (in-memory, file, DB)
3. Query/access patterns: key operations and their complexity
4. Validation rules: what the data layer must enforce
5. Interface contracts: public API surface (function signatures)

Do NOT output JSON sprint graphs. Write 3-5 paragraphs of concrete technical spec. Be specific about types and contracts.`,
  },
  'strict-build': {
    att: 2,
    system_prompt: `You are the Build agent for a software sprint. Given the Architect's design, implement it with the following requirements:

IMPLEMENTATION STANDARDS:
- Type annotations on all public functions
- Docstrings on all classes and public methods
- Input validation at the top of every function (raise ValueError with descriptive message)
- Handle None/empty inputs explicitly
- No global mutable state
- Pure functions where possible

OUTPUT: Only the implementation code. No explanations, no markdown fences.`,
  },
}

interface Props {
  onCreated: () => void
}

type ExecutorType = 'llm' | 'proc' | 'a2a'

const EXECUTOR_INFO: Record<ExecutorType, { label: string; desc: string; placeholder: string }> = {
  llm:  { label: 'LLM',         desc: 'Standard model call — provider selected by server env vars.',       placeholder: 'gemini-2.5-flash' },
  proc: { label: 'Process',     desc: 'Spawn a shell command. Input piped via stdin, stdout = artifact.',   placeholder: 'opencode chat -q' },
  a2a:  { label: 'A2A Agent',   desc: 'Delegate to a remote agent via JSON-RPC tasks/send protocol.',      placeholder: 'http://localhost:8881' },
}

export default function AgentBuilder({ onCreated }: Props) {
  const [id, setId] = useState('')
  const [role, setRole] = useState('qa')
  const [prompt, setPrompt] = useState('')
  const [att, setAtt] = useState(1)
  const [saving, setSaving] = useState(false)
  const [saved, setSaved] = useState(false)
  const [error, setError] = useState('')
  const [template, setTemplate] = useState('')
  const [executor, setExecutor] = useState<ExecutorType>('llm')
  const [execTarget, setExecTarget] = useState('')   // cmd for proc, url for a2a

  function applyTemplate(key: string) {
    setTemplate(key)
    const t = TEMPLATES[key]
    if (!t) return
    setPrompt(t.system_prompt)
    setAtt(t.att)
    if (key === 'security-qa') setRole('qa')
    if (key === 'data-architect') setRole('architect')
    if (key === 'strict-build') setRole('build')
    if (!id) setId(key + '-v1')
    setExecutor('llm')
  }

  function effectiveModelName(): string {
    if (executor === 'proc') return execTarget ? `proc:${execTarget}` : 'proc:'
    if (executor === 'a2a')  return execTarget ? `a2a:${execTarget}`  : 'a2a:'
    return ''  // server picks default LLM model
  }

  async function handleSave() {
    if (!id.trim() || !role) {
      setError('ID and role are required')
      return
    }
    if (executor === 'llm' && !prompt.trim()) {
      setError('System prompt is required for LLM executor')
      return
    }
    if ((executor === 'proc' || executor === 'a2a') && !execTarget.trim()) {
      setError(executor === 'proc' ? 'Command is required' : 'Agent URL is required')
      return
    }
    setSaving(true)
    setError('')
    try {
      await createAgent({
        id: id.trim(),
        role,
        system_prompt: prompt.trim(),
        attestation_count: att,
        model_name: effectiveModelName(),
      })
      setSaved(true)
      setTimeout(() => { setSaved(false); onCreated() }, 1500)
    } catch (e: any) {
      setError(e.message || 'Failed to save')
    } finally {
      setSaving(false)
    }
  }

  const selectedRole = ROLES.find(r => r.value === role)

  return (
    <div className="space-y-5">
      {/* Templates */}
      <div>
        <p className="text-xs text-muted font-medium mb-2">Start from a template</p>
        <div className="grid grid-cols-3 gap-2">
          {[
            { key: 'security-qa', label: 'Security QA', icon: '🔐' },
            { key: 'data-architect', label: 'Data Architect', icon: '🗄' },
            { key: 'strict-build', label: 'Strict Builder', icon: '📐' },
          ].map(t => (
            <button
              key={t.key}
              onClick={() => applyTemplate(t.key)}
              className={`p-2.5 rounded-lg border text-left text-xs transition-all ${
                template === t.key
                  ? 'border-emerald-500 bg-emerald-950/30 text-emerald-300'
                  : 'border-border bg-bg text-muted hover:border-slate-500 hover:text-slate-300'
              }`}
            >
              <div className="text-base mb-0.5">{t.icon}</div>
              <div className="font-medium">{t.label}</div>
            </button>
          ))}
        </div>
      </div>

      {/* ID + Role */}
      <div className="grid grid-cols-2 gap-3">
        <div>
          <label className="text-xs text-muted mb-1 block">Agent ID</label>
          <input
            className="w-full bg-bg border border-border rounded-lg px-3 py-2 text-sm font-mono text-slate-200 focus:outline-none focus:border-emerald-500 placeholder-muted"
            placeholder="my-security-qa-v1"
            value={id}
            onChange={e => setId(e.target.value)}
          />
        </div>
        <div>
          <label className="text-xs text-muted mb-1 block">Role</label>
          <select
            className="w-full bg-bg border border-border rounded-lg px-3 py-2 text-sm text-slate-200 focus:outline-none focus:border-emerald-500"
            value={role}
            onChange={e => setRole(e.target.value)}
          >
            {ROLES.map(r => (
              <option key={r.value} value={r.value}>{r.icon} {r.label}</option>
            ))}
          </select>
        </div>
      </div>

      {/* Role info */}
      {selectedRole && (
        <div className="flex items-start gap-2 text-xs bg-bg rounded-lg px-3 py-2 border border-border">
          <span className="text-muted">{selectedRole.desc}</span>
          {role === 'qa' && (
            <span className="ml-auto flex-shrink-0 text-amber-400 bg-amber-950/40 px-1.5 py-0.5 rounded font-semibold">
              + run_code tool
            </span>
          )}
        </div>
      )}

      {/* Executor type */}
      <div>
        <p className="text-xs text-muted font-medium mb-2">Executor</p>
        <div className="grid grid-cols-3 gap-2">
          {(Object.entries(EXECUTOR_INFO) as [ExecutorType, typeof EXECUTOR_INFO[ExecutorType]][]).map(([key, info]) => (
            <button
              key={key}
              onClick={() => setExecutor(key)}
              className={`p-2.5 rounded-lg border text-left text-xs transition-all ${
                executor === key
                  ? 'border-emerald-500 bg-emerald-950/30 text-emerald-300'
                  : 'border-border bg-bg text-muted hover:border-slate-500 hover:text-slate-300'
              }`}
            >
              <div className="font-semibold mb-0.5">{info.label}</div>
              <div className="text-[10px] leading-tight">{info.desc}</div>
            </button>
          ))}
        </div>

        {executor !== 'llm' && (
          <div className="mt-2">
            <label className="text-xs text-muted mb-1 block">
              {executor === 'proc' ? 'Shell command (input via stdin)' : 'Remote agent URL'}
            </label>
            <input
              className="w-full bg-bg border border-border rounded-lg px-3 py-2 text-sm font-mono text-slate-200 focus:outline-none focus:border-emerald-500 placeholder-muted"
              placeholder={EXECUTOR_INFO[executor].placeholder}
              value={execTarget}
              onChange={e => setExecTarget(e.target.value)}
            />
            {executor === 'proc' && (
              <p className="text-[10px] text-muted mt-1">
                model_name will be stored as <span className="font-mono text-slate-400">proc:{execTarget || '<cmd>'}</span>
              </p>
            )}
            {executor === 'a2a' && (
              <p className="text-[10px] text-muted mt-1">
                model_name will be stored as <span className="font-mono text-slate-400">a2a:{execTarget || '<url>'}</span>
              </p>
            )}
          </div>
        )}
      </div>

      {/* Starting attestation */}
      <div>
        <div className="flex items-center justify-between mb-1">
          <label className="text-xs text-muted">Starting attestation</label>
          <span className="text-xs text-emerald-400 font-mono">{att}</span>
        </div>
        <input
          type="range" min={1} max={10} value={att}
          onChange={e => setAtt(Number(e.target.value))}
          className="w-full accent-emerald-500"
        />
        <div className="flex justify-between text-[10px] text-muted mt-0.5">
          <span>1 — low priority</span>
          <span>10 — preferred over all others</span>
        </div>
      </div>

      {/* System prompt — shown for LLM (mandatory) and optional context for proc/a2a */}
      <div>
        <label className="text-xs text-muted mb-1 block">
          System Prompt {executor !== 'llm' && <span className="text-slate-600">(optional — prepended to input)</span>}
        </label>
        <textarea
          className="w-full bg-bg border border-border rounded-lg p-3 text-xs font-mono text-slate-300 resize-none h-48 focus:outline-none focus:border-emerald-500 placeholder-muted leading-relaxed"
          placeholder={executor === 'llm' ? 'You are a specialised agent for...' : 'Optional context prepended to each task input…'}
          value={prompt}
          onChange={e => setPrompt(e.target.value)}
        />
        <p className="text-[10px] text-muted mt-1">{prompt.length} chars</p>
      </div>

      {error && <p className="text-rose-400 text-xs">{error}</p>}

      <button
        onClick={handleSave}
        disabled={saving || saved}
        className={`w-full py-2.5 rounded-lg text-sm font-semibold transition-all ${
          saved
            ? 'bg-emerald-700 text-white'
            : saving
            ? 'bg-slate-700 text-muted'
            : 'bg-emerald-600 hover:bg-emerald-500 text-white'
        }`}
      >
        {saved ? '✓ Agent saved to pool' : saving ? 'Saving…' : 'Add to Agent Pool'}
      </button>
    </div>
  )
}
