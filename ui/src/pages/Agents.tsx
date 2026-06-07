import { useState, useEffect } from 'react'
import { getAgents, getAgent } from '../api'
import type { Agent, AgentDetail } from '../types'
import DiffViewer from '../components/DiffViewer'

function AttestationBar({ count, max }: { count: number; max: number }) {
  const pct = max > 0 ? (count / max) * 100 : 0
  return (
    <div className="flex items-center gap-2">
      <div className="flex-1 h-1.5 bg-slate-800 rounded-full overflow-hidden">
        <div className="h-full bg-emerald-500 rounded-full transition-all" style={{ width: `${pct}%` }} />
      </div>
      <span className="text-muted text-xs font-mono w-4 text-right">{count}</span>
    </div>
  )
}

function AgentCard({
  agent,
  maxAtt,
  isChampion,
  onClick,
  selected,
}: {
  agent: Agent
  maxAtt: number
  isChampion: boolean
  onClick: () => void
  selected: boolean
}) {
  const improved = agent.id.includes('-improved-')
  return (
    <div
      onClick={onClick}
      className={`p-4 rounded-xl border cursor-pointer transition-all ${
        selected
          ? 'border-emerald-500 bg-emerald-950/30'
          : 'border-border bg-surface hover:border-slate-500'
      }`}
    >
      <div className="flex items-start justify-between mb-2">
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 mb-1">
            {isChampion && (
              <span className="text-xs px-1.5 py-0.5 rounded bg-amber-900/50 text-amber-400 font-semibold">Champion</span>
            )}
            {improved && (
              <span className="text-xs px-1.5 py-0.5 rounded bg-indigo-900/50 text-indigo-400 font-semibold">AI-improved</span>
            )}
          </div>
          <p className="font-mono text-sm text-slate-300 truncate">{agent.id}</p>
        </div>
      </div>
      <div className="mt-3">
        <div className="flex justify-between items-center mb-1">
          <span className="text-muted text-xs">Attestation</span>
        </div>
        <AttestationBar count={agent.attestation_count} max={maxAtt} />
      </div>
      <p className="text-muted text-xs mt-2 font-mono">{new Date(agent.created_at).toLocaleDateString()}</p>
    </div>
  )
}

interface RoleGroup {
  role: string
  agents: Agent[]
}

export default function Agents() {
  const [agents, setAgents] = useState<Agent[]>([])
  const [loading, setLoading] = useState(true)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [selectedAgent, setSelectedAgent] = useState<AgentDetail | null>(null)
  const [parentAgent, setParentAgent] = useState<AgentDetail | null>(null)
  const [showDiff, setShowDiff] = useState(false)

  useEffect(() => {
    getAgents()
      .then(d => setAgents(d.agents))
      .finally(() => setLoading(false))
  }, [])

  async function selectAgent(agent: Agent, allAgents: Agent[]) {
    setSelectedId(agent.id)
    setShowDiff(false)
    setParentAgent(null)

    const detail = await getAgent(agent.id)
    setSelectedAgent(detail)

    // Find parent: same role, next lower attestation_count
    const sameRole = allAgents
      .filter(a => a.role === agent.role && a.id !== agent.id && a.attestation_count < agent.attestation_count)
      .sort((a, b) => b.attestation_count - a.attestation_count)

    if (sameRole.length > 0) {
      const parent = await getAgent(sameRole[0].id)
      setParentAgent(parent)
    }
  }

  // Group by role
  const groups: RoleGroup[] = []
  const seen = new Set<string>()
  for (const a of agents) {
    if (!seen.has(a.role)) {
      seen.add(a.role)
      groups.push({ role: a.role, agents: agents.filter(x => x.role === a.role) })
    }
  }

  const maxAtt = agents.reduce((m, a) => Math.max(m, a.attestation_count), 0)

  return (
    <div className="max-w-7xl mx-auto px-6 py-8">
      <div className="mb-6">
        <h1 className="text-2xl font-bold text-slate-100">Agent Pool</h1>
        <p className="text-muted mt-1 text-sm">
          Agents earn attestation by delivering accepted results. Cast always picks the highest-attested agent per role.
        </p>
      </div>

      {loading ? (
        <div className="text-muted text-sm pulse-soft py-12 text-center">Loading agents…</div>
      ) : (
        <div className="grid grid-cols-3 gap-6">
          {/* Left: grouped agent cards */}
          <div className="col-span-1 space-y-6">
            {groups.map(g => {
              const champion = g.agents[0]
              return (
                <div key={g.role}>
                  <div className="flex items-center gap-2 mb-3">
                    <span className="text-xs font-semibold text-muted uppercase tracking-widest">{g.role}</span>
                    <span className="text-xs text-muted">· {g.agents.length} agents</span>
                  </div>
                  <div className="space-y-2">
                    {g.agents.map(a => (
                      <AgentCard
                        key={a.id}
                        agent={a}
                        maxAtt={maxAtt}
                        isChampion={a.id === champion.id}
                        selected={selectedId === a.id}
                        onClick={() => selectAgent(a, agents)}
                      />
                    ))}
                  </div>
                </div>
              )
            })}
          </div>

          {/* Right: detail panel */}
          <div className="col-span-2">
            {!selectedAgent ? (
              <div className="bg-surface border border-border rounded-xl p-12 flex flex-col items-center justify-center text-center h-64">
                <p className="text-muted text-sm mb-2">Select an agent to view its system prompt</p>
                <p className="text-muted text-xs">Champion agents were AI-improved — no human wrote their prompts</p>
              </div>
            ) : (
              <div className="space-y-4 fade-in">
                {/* Header */}
                <div className="bg-surface border border-border rounded-xl p-5">
                  <div className="flex items-start justify-between mb-3">
                    <div>
                      <div className="flex items-center gap-2 mb-1">
                        <span className="text-xs font-semibold text-muted uppercase tracking-wide">{selectedAgent.role}</span>
                        {selectedAgent.id.includes('-improved-') && (
                          <span className="text-xs px-1.5 py-0.5 rounded bg-indigo-900/50 text-indigo-400 font-semibold">AI-improved</span>
                        )}
                      </div>
                      <p className="font-mono text-base text-slate-200">{selectedAgent.id}</p>
                    </div>
                    <div className="text-right">
                      <p className="text-2xl font-bold text-emerald-400">{selectedAgent.attestation_count}</p>
                      <p className="text-muted text-xs">attestations</p>
                    </div>
                  </div>

                  {parentAgent && (
                    <button
                      onClick={() => setShowDiff(!showDiff)}
                      className={`text-sm px-3 py-1.5 rounded-lg border transition-all ${
                        showDiff
                          ? 'border-emerald-500 bg-emerald-950/40 text-emerald-400'
                          : 'border-border text-muted hover:border-slate-500 hover:text-slate-300'
                      }`}
                    >
                      {showDiff ? '× Hide diff' : `⟳ Show diff vs ${parentAgent.id.split('-improved-')[0] || parentAgent.id}`}
                    </button>
                  )}
                </div>

                {/* Diff viewer */}
                {showDiff && parentAgent && (
                  <div className="bg-surface border border-border rounded-xl p-5 space-y-3 slide-in">
                    <div>
                      <h3 className="text-slate-100 font-semibold mb-1">Prompt Evolution</h3>
                      <p className="text-muted text-sm">
                        The AI rewrote this prompt after analysing sprint failures. No human wrote either version.
                      </p>
                    </div>
                    <DiffViewer
                      before={parentAgent.system_prompt}
                      after={selectedAgent.system_prompt}
                      beforeLabel={`${parentAgent.id} (att=${parentAgent.attestation_count})`}
                      afterLabel={`${selectedAgent.id} (att=${selectedAgent.attestation_count})`}
                    />
                  </div>
                )}

                {/* System prompt */}
                {!showDiff && (
                  <div className="bg-surface border border-border rounded-xl overflow-hidden slide-in">
                    <div className="px-5 py-3 border-b border-border flex items-center gap-2">
                      <span className="w-2 h-2 rounded-full bg-emerald-500" />
                      <span className="text-xs text-muted font-medium">System Prompt</span>
                      <span className="text-muted text-xs ml-auto">{selectedAgent.system_prompt.length} chars</span>
                    </div>
                    <pre className="p-5 text-sm font-mono text-slate-300 leading-relaxed whitespace-pre-wrap overflow-auto max-h-96">
                      {selectedAgent.system_prompt}
                    </pre>
                  </div>
                )}
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  )
}
