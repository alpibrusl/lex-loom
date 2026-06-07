import { useState, useEffect, useCallback } from 'react'
import { getAgents, getAgent } from '../api'
import type { Agent, AgentDetail } from '../types'
import DiffViewer from '../components/DiffViewer'
import AgentBuilder from '../components/AgentBuilder'

function AttestationBar({ count, max }: { count: number; max: number }) {
  const pct = max > 0 ? Math.round((count / max) * 100) : 0
  return (
    <div className="flex items-center gap-2">
      <div className="flex-1 h-1.5 bg-slate-800 rounded-full overflow-hidden">
        <div className="h-full bg-emerald-500 rounded-full transition-all duration-500" style={{ width: `${pct}%` }} />
      </div>
      <span className="text-muted text-xs font-mono w-4 text-right">{count}</span>
    </div>
  )
}

function AgentCard({
  agent, maxAtt, isChampion, selected, onClick,
}: {
  agent: Agent; maxAtt: number; isChampion: boolean; selected: boolean; onClick: () => void
}) {
  const improved = agent.id.includes('-improved-')
  const custom = !agent.id.includes('-improved-') && !agent.id.endsWith('-v1') && !agent.id.includes('sprint-')
  return (
    <div
      onClick={onClick}
      className={`p-3 rounded-xl border cursor-pointer transition-all ${
        selected ? 'border-emerald-500 bg-emerald-950/30' : 'border-border bg-surface hover:border-slate-500'
      }`}
    >
      <div className="flex items-start gap-2 mb-2">
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-1.5 mb-1 flex-wrap">
            {isChampion && <span className="text-[10px] px-1.5 py-0.5 rounded bg-amber-900/50 text-amber-400 font-bold">Champion</span>}
            {improved && <span className="text-[10px] px-1.5 py-0.5 rounded bg-indigo-900/50 text-indigo-400 font-semibold">AI-improved</span>}
            {custom && <span className="text-[10px] px-1.5 py-0.5 rounded bg-emerald-900/50 text-emerald-400 font-semibold">Custom</span>}
          </div>
          <p className="font-mono text-xs text-slate-300 truncate" title={agent.id}>{agent.id}</p>
        </div>
      </div>
      <AttestationBar count={agent.attestation_count} max={maxAtt} />
    </div>
  )
}

interface RoleGroup { role: string; agents: Agent[] }

export default function Agents() {
  const [agents, setAgents] = useState<Agent[]>([])
  const [loading, setLoading] = useState(true)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [selectedAgent, setSelectedAgent] = useState<AgentDetail | null>(null)
  const [parentAgent, setParentAgent] = useState<AgentDetail | null>(null)
  const [showDiff, setShowDiff] = useState(false)
  const [showBuilder, setShowBuilder] = useState(false)

  const load = useCallback(async () => {
    setLoading(true)
    try { const d = await getAgents(); setAgents(d.agents) }
    finally { setLoading(false) }
  }, [])

  useEffect(() => { load() }, [load])

  async function selectAgent(agent: Agent, pool: Agent[]) {
    setSelectedId(agent.id)
    setShowDiff(false)
    setParentAgent(null)
    const detail = await getAgent(agent.id)
    setSelectedAgent(detail)
    const parent = pool
      .filter(a => a.role === agent.role && a.id !== agent.id && a.attestation_count < agent.attestation_count)
      .sort((a, b) => b.attestation_count - a.attestation_count)[0]
    if (parent) {
      const pd = await getAgent(parent.id)
      setParentAgent(pd)
    }
  }

  // Group by role
  const seen = new Set<string>()
  const groups: RoleGroup[] = []
  for (const a of agents) {
    if (!seen.has(a.role)) { seen.add(a.role); groups.push({ role: a.role, agents: agents.filter(x => x.role === a.role) }) }
  }

  const maxAtt = agents.reduce((m, a) => Math.max(m, a.attestation_count), 0)

  return (
    <div className="max-w-7xl mx-auto px-6 py-8">
      <div className="flex items-start justify-between mb-6">
        <div>
          <h1 className="text-2xl font-bold text-slate-100">Agent Pool</h1>
          <p className="text-muted mt-1 text-sm max-w-xl">
            Each role has a pool of agents ranked by attestation. Cast always picks the champion.
            You can add specialized agents — they'll compete immediately.
          </p>
        </div>
        <button
          onClick={() => setShowBuilder(!showBuilder)}
          className={`px-4 py-2 rounded-lg text-sm font-semibold transition-all flex-shrink-0 ${
            showBuilder
              ? 'bg-slate-700 text-slate-200'
              : 'bg-emerald-600 hover:bg-emerald-500 text-white'
          }`}
        >
          {showBuilder ? '× Close builder' : '+ New Agent'}
        </button>
      </div>

      <div className="grid grid-cols-3 gap-6">
        {/* Left: pool */}
        <div className="col-span-1 space-y-5">

          {/* Agent Builder panel */}
          {showBuilder && (
            <div className="bg-surface border border-emerald-700/40 rounded-xl p-5 slide-in">
              <h3 className="text-slate-100 font-semibold mb-4 flex items-center gap-2">
                <span>⚗</span> Build a Specialized Agent
              </h3>
              <AgentBuilder onCreated={() => { setShowBuilder(false); load() }} />
            </div>
          )}

          {/* Role groups */}
          {loading ? (
            <div className="text-muted text-sm pulse-soft py-8 text-center">Loading pool…</div>
          ) : (
            groups.map(g => {
              const champion = g.agents[0]
              return (
                <div key={g.role}>
                  <div className="flex items-center gap-2 mb-2">
                    <span className="text-xs font-bold text-muted uppercase tracking-widest">{g.role}</span>
                    <span className="text-xs text-muted">· {g.agents.length}</span>
                  </div>
                  <div className="space-y-2">
                    {g.agents.map(a => (
                      <AgentCard
                        key={a.id} agent={a} maxAtt={maxAtt}
                        isChampion={a.id === champion.id}
                        selected={selectedId === a.id}
                        onClick={() => selectAgent(a, agents)}
                      />
                    ))}
                  </div>
                </div>
              )
            })
          )}
        </div>

        {/* Right: detail */}
        <div className="col-span-2">
          {!selectedAgent ? (
            <div className="bg-surface border border-border rounded-xl p-12 flex flex-col items-center justify-center text-center h-64">
              <p className="text-muted text-sm mb-2">Select an agent to inspect its system prompt</p>
              <p className="text-muted text-xs">Champion agents were rewritten by AI — no human wrote their prompts</p>
            </div>
          ) : (
            <div className="space-y-4 fade-in">
              {/* Header */}
              <div className="bg-surface border border-border rounded-xl p-5">
                <div className="flex items-start justify-between mb-4">
                  <div>
                    <div className="flex items-center gap-2 mb-1 flex-wrap">
                      <span className="text-xs font-bold text-muted uppercase tracking-widest">{selectedAgent.role}</span>
                      {selectedAgent.id.includes('-improved-') && (
                        <span className="text-xs px-1.5 py-0.5 rounded bg-indigo-900/50 text-indigo-400 font-semibold">AI-improved</span>
                      )}
                    </div>
                    <p className="font-mono text-base text-slate-200">{selectedAgent.id}</p>
                    <p className="text-muted text-xs mt-1">{new Date(selectedAgent.created_at).toLocaleString()}</p>
                  </div>
                  <div className="text-right">
                    <p className="text-3xl font-bold text-emerald-400">{selectedAgent.attestation_count}</p>
                    <p className="text-muted text-xs">attestations</p>
                  </div>
                </div>

                {/* Attestation context */}
                <div className="bg-bg rounded-lg p-3 border border-border mb-3">
                  <AttestationBar count={selectedAgent.attestation_count} max={maxAtt} />
                  <p className="text-muted text-xs mt-1.5">
                    {selectedAgent.attestation_count === maxAtt
                      ? '🏆 Current champion — will be selected next sprint'
                      : `Needs ${maxAtt - selectedAgent.attestation_count} more attestations to become champion`}
                  </p>
                </div>

                {parentAgent && (
                  <button
                    onClick={() => setShowDiff(!showDiff)}
                    className={`text-sm px-3 py-1.5 rounded-lg border transition-all ${
                      showDiff ? 'border-emerald-500 bg-emerald-950/40 text-emerald-400' : 'border-border text-muted hover:border-slate-500 hover:text-slate-300'
                    }`}
                  >
                    {showDiff ? '× Hide prompt diff' : `⟳ Show diff vs ${parentAgent.id}`}
                  </button>
                )}
              </div>

              {/* Diff */}
              {showDiff && parentAgent && (
                <div className="bg-surface border border-border rounded-xl p-5 space-y-3 slide-in">
                  <div>
                    <h3 className="text-slate-100 font-semibold mb-1">Prompt Evolution</h3>
                    <p className="text-muted text-sm">The system rewrote this prompt based on sprint retrospective analysis.</p>
                  </div>
                  <DiffViewer
                    before={parentAgent.system_prompt}
                    after={selectedAgent.system_prompt}
                    beforeLabel={`${parentAgent.id}  att=${parentAgent.attestation_count}`}
                    afterLabel={`${selectedAgent.id}  att=${selectedAgent.attestation_count}`}
                  />
                </div>
              )}

              {/* Prompt */}
              {!showDiff && (
                <div className="bg-surface border border-border rounded-xl overflow-hidden slide-in">
                  <div className="px-5 py-3 border-b border-border flex items-center gap-2">
                    <span className="w-2 h-2 rounded-full bg-emerald-500" />
                    <span className="text-xs text-muted font-medium">System Prompt</span>
                    <span className="text-muted text-xs ml-auto">{selectedAgent.system_prompt.length} chars</span>
                  </div>
                  <pre className="p-5 text-sm font-mono text-slate-300 leading-relaxed whitespace-pre-wrap overflow-auto max-h-[500px]">
                    {selectedAgent.system_prompt}
                  </pre>
                </div>
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
