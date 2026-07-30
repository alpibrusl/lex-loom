import { useState, useEffect } from 'react'
import { useParams, Link } from 'react-router-dom'
import { getSprintTrail, getSprintDigest, getSprintGraph, getArtifact, getAgents, getAgent } from '../api'
import type { TrailEvent, DigestData, Agent } from '../types'
import DiffViewer from '../components/DiffViewer'
import PhaseGraph, { type GraphData, graphStatusFromTrail } from '../components/PhaseGraph'

// ── Helpers ───────────────────────────────────────────────────────────────────

function safeJson(s: string): Record<string, unknown> {
  try { return JSON.parse(s) || {} } catch { return {} }
}

function nodeRole(nodeId: string): string {
  if (nodeId.startsWith('arch')) return 'architect'
  if (nodeId.startsWith('build')) return 'build'
  if (nodeId.startsWith('qa')) return 'qa'
  if (nodeId.startsWith('demo')) return 'demo'
  if (nodeId.startsWith('scribe') || nodeId.startsWith('docs')) return 'scribe'
  if (nodeId === 'intake') return 'intake'
  return nodeId
}

const ROLE_COLOR: Record<string, { bg: string; text: string; border: string; icon: string }> = {
  intake:    { bg: 'bg-slate-800',    text: 'text-slate-300',  border: 'border-slate-600', icon: '📋' },
  architect: { bg: 'bg-indigo-950',   text: 'text-indigo-300', border: 'border-indigo-700', icon: '🏗' },
  build:     { bg: 'bg-blue-950',     text: 'text-blue-300',   border: 'border-blue-700',   icon: '⚙️' },
  qa:        { bg: 'bg-amber-950',    text: 'text-amber-300',  border: 'border-amber-700',  icon: '🔬' },
  demo:      { bg: 'bg-violet-950',   text: 'text-violet-300', border: 'border-violet-700', icon: '🎯' },
  scribe:    { bg: 'bg-teal-950',     text: 'text-teal-300',   border: 'border-teal-700',   icon: '📝' },
}
// GraphData type re-used from PhaseGraph import (type GraphData)


// ── Node step card ────────────────────────────────────────────────────────────

interface NodeStep {
  nodeId: string
  role: string
  artifactHash: string
  content: string | null
  verdict?: string    // for QA: PASS / FAIL
  reason?: string
  testOutput?: string
  accepted: boolean
}

function codePreview(text: string): { isCode: boolean; preview: string } {
  const trimmed = text.trim()
  const isCode = trimmed.startsWith('def ') || trimmed.startsWith('class ') ||
                 trimmed.startsWith('import ') || trimmed.startsWith('#') ||
                 trimmed.includes('\ndef ') || trimmed.includes('\nclass ')
  return { isCode, preview: trimmed.slice(0, 800) }
}

function NodeCard({ step, index }: { step: NodeStep; index: number }) {
  const [expanded, setExpanded] = useState(false)
  const meta = ROLE_COLOR[step.role] || ROLE_COLOR['intake']
  const roleLabel = step.role.charAt(0).toUpperCase() + step.role.slice(1)

  const isQA = step.role === 'qa'
  const qaPass = step.verdict === 'PASS'

  return (
    <div className={`rounded-xl border overflow-hidden ${step.accepted ? 'border-border' : 'border-rose-800'}`}>
      {/* Header */}
      <div className={`flex items-center gap-3 px-4 py-3 border-b border-border ${meta.bg}/30`}>
        <div className={`flex items-center gap-2 px-2.5 py-1 rounded-md text-xs font-semibold ${meta.bg} ${meta.text} ${meta.border} border`}>
          {meta.icon} {roleLabel}
        </div>
        <span className="text-muted text-xs font-mono">{step.nodeId}</span>
        <div className="ml-auto flex items-center gap-2">
          {isQA && step.verdict && (
            <span className={`px-2.5 py-1 rounded-md text-xs font-bold ${
              qaPass ? 'bg-emerald-900/60 text-emerald-400 border border-emerald-700' : 'bg-rose-900/60 text-rose-400 border border-rose-700'
            }`}>
              {qaPass ? '✓' : '✗'} {step.verdict}
            </span>
          )}
          <span className={`w-5 h-5 rounded-full flex items-center justify-center text-xs ${
            step.accepted ? 'bg-emerald-700 text-white' : 'bg-rose-700 text-white'
          }`}>
            {step.accepted ? '✓' : '✗'}
          </span>
        </div>
      </div>

      {/* Content */}
      {step.content ? (
        <div className="p-4">
          {isQA ? (
            <div className="space-y-3">
              {step.reason && <p className={`text-sm ${qaPass ? 'text-emerald-300' : 'text-rose-300'}`}>{step.reason}</p>}
              {step.testOutput && (
                <div className="bg-black/40 rounded-lg p-3">
                  <p className="text-muted text-xs mb-1 font-mono">Code execution output</p>
                  <pre className="text-slate-400 text-xs font-mono overflow-auto max-h-24 leading-relaxed">{step.testOutput}</pre>
                </div>
              )}
            </div>
          ) : (
            <div>
              {(() => {
                const { isCode, preview } = codePreview(step.content)
                const full = step.content
                const shown = expanded ? full : preview
                return (
                  <>
                    <pre className={`text-sm leading-relaxed overflow-auto ${
                      isCode ? 'font-mono text-emerald-300 bg-black/30 p-3 rounded-lg' : 'text-slate-300 whitespace-pre-wrap'
                    } ${expanded ? 'max-h-none' : 'max-h-48'}`}>
                      {shown}
                    </pre>
                    {full.length > 800 && (
                      <button
                        onClick={() => setExpanded(!expanded)}
                        className="mt-2 text-xs text-muted hover:text-slate-300 transition-colors"
                      >
                        {expanded ? '↑ Collapse' : `↓ Show all (${full.length} chars)`}
                      </button>
                    )}
                  </>
                )
              })()}
            </div>
          )}
        </div>
      ) : (
        <div className="p-4 text-muted text-sm">Loading output…</div>
      )}
    </div>
  )
}

// ── Improvement section ───────────────────────────────────────────────────────

function ImprovementSection({ sprintId, specs }: { sprintId: string; specs: DigestData['specs'] }) {
  const [agents, setAgents] = useState<Agent[]>([])
  const [diff, setDiff] = useState<{ before: string; after: string; beforeLabel: string; afterLabel: string } | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    getAgents().then(d => {
      const pool = d.agents
      setAgents(pool)

      // Find newly created agents for this sprint
      const improved = pool.filter(a => a.id.includes(sprintId.replace('sprint-', '')))
      if (improved.length === 0) { setLoading(false); return }

      // For the first improved agent, find its parent
      const newAgent = improved[0]
      const parent = pool
        .filter(a => a.role === newAgent.role && a.id !== newAgent.id && a.attestation_count < newAgent.attestation_count)
        .sort((a, b) => b.attestation_count - a.attestation_count)[0]

      if (!parent) { setLoading(false); return }

      Promise.all([getAgent(newAgent.id), getAgent(parent.id)]).then(([n, p]) => {
        setDiff({
          before: p.system_prompt,
          after: n.system_prompt,
          beforeLabel: `${p.id}  (was: att=${p.attestation_count})`,
          afterLabel: `${n.id}  (new champion: att=${n.attestation_count})`,
        })
        setLoading(false)
      }).catch(() => setLoading(false))
    }).catch(() => setLoading(false))
  }, [sprintId])

  const improvedAgents = agents.filter(a => a.id.includes(sprintId.replace('sprint-', '')))

  return (
    <div className="space-y-4">
      {/* What the system learned */}
      {specs.length > 0 && (
        <div className="bg-amber-950/20 border border-amber-800/40 rounded-xl p-5">
          <h3 className="text-amber-400 font-semibold mb-3 flex items-center gap-2">
            <span>💡</span> What the Scribe identified
          </h3>
          <div className="space-y-2">
            {specs.map((spec, i) => (
              <div key={i} className="bg-black/20 rounded-lg p-3 border border-amber-900/30">
                <div className="flex items-center gap-2 mb-1">
                  <span className="text-xs font-mono bg-amber-900/40 text-amber-300 px-1.5 py-0.5 rounded">{spec.node_role}</span>
                  <span className="text-muted text-xs">must now reliably satisfy:</span>
                </div>
                <p className="text-slate-300 text-sm">{spec.spec_src}</p>
                <p className="text-muted text-xs mt-1">reason: {spec.reason}</p>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* New agents born */}
      {improvedAgents.length > 0 && (
        <div className="bg-emerald-950/20 border border-emerald-800/40 rounded-xl p-5">
          <h3 className="text-emerald-400 font-semibold mb-1 flex items-center gap-2">
            <span>⬆</span> New agents created by the system
          </h3>
          <p className="text-muted text-sm mb-3">These agents will be selected automatically next sprint — no human wrote their prompts.</p>
          <div className="space-y-1">
            {improvedAgents.map(a => (
              <div key={a.id} className="flex items-center gap-3">
                <span className="text-xs text-muted font-mono bg-slate-800 px-2 py-0.5 rounded">{a.role}</span>
                <span className="text-sm font-mono text-emerald-300">{a.id}</span>
                <span className="text-emerald-400 text-xs font-bold ml-auto">att={a.attestation_count} → next champion</span>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* The diff — the "wow" moment */}
      {loading && <div className="text-muted text-sm pulse-soft py-4 text-center">Loading agent diff…</div>}
      {diff && (
        <div className="bg-surface border border-border rounded-xl p-5">
          <h3 className="text-slate-100 font-semibold mb-1 flex items-center gap-2">
            <span>⟳</span> How the agent prompt evolved
          </h3>
          <p className="text-muted text-sm mb-4">
            The AI analysed the sprint and rewrote the prompt. Red = removed, Green = added.
          </p>
          <DiffViewer
            before={diff.before}
            after={diff.after}
            beforeLabel={diff.beforeLabel}
            afterLabel={diff.afterLabel}
          />
        </div>
      )}
    </div>
  )
}

// ── Main page ─────────────────────────────────────────────────────────────────

export default function SprintDetail() {
  const { id } = useParams<{ id: string }>()
  const [events, setEvents] = useState<TrailEvent[]>([])
  const [digest, setDigest] = useState<DigestData | null>(null)
  const [graphJson, setGraphJson] = useState<string>('')
  const [steps, setSteps] = useState<NodeStep[]>([])
  const [request, setRequest] = useState<string>('')
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    if (!id) return

    async function load() {
      const [trailData, digestData] = await Promise.all([
        getSprintTrail(id!),
        getSprintDigest(id!).catch(() => null),
      ])

      const evs = trailData.events
      setEvents(evs)
      if (digestData) setDigest(digestData)

      // Extract request from sprint_started
      const startEv = evs.find(e => e.event_kind === 'sprint_started')
      if (startEv) {
        const d = safeJson(startEv.data_json)
        if (typeof d.request === 'string') setRequest(d.request)
      }

      // Extract graph JSON from graph_validated event or graph endpoint
      const graphEv = evs.find(e => e.event_kind === 'graph_validated')
      if (graphEv) {
        // Try to fetch from graph endpoint
        try {
          const grData = await getSprintGraph(id!)
          if (grData.graph) setGraphJson(JSON.stringify(grData.graph))
        } catch {}
      }

      // Extract node steps from node_accepted events
      const accepted = evs.filter(e => e.event_kind === 'node_accepted')
      const stepList: NodeStep[] = []

      for (const ev of accepted) {
        const d = safeJson(ev.data_json)
        const nodeId = d.node as string
        const hash = d.artifact as string
        if (!nodeId || !hash) continue

        const role = nodeRole(nodeId)
        const step: NodeStep = { nodeId, role, artifactHash: hash, content: null, accepted: true }
        stepList.push(step)
      }

      setSteps(stepList)
      setLoading(false)

      // Load artifact contents
      for (const step of stepList) {
        getArtifact(step.artifactHash).then(r => {
          const raw = r.content
          if (step.role === 'qa') {
            try {
              const qa = JSON.parse(raw)
              step.content = raw
              step.verdict = qa.verdict
              step.reason = qa.reason
              step.testOutput = qa.test_output
            } catch {
              step.content = raw
            }
          } else {
            step.content = raw
          }
          setSteps(prev => prev.map(s => s.artifactHash === step.artifactHash ? { ...step } : s))
        }).catch(() => {})
      }
    }

    load()
  }, [id])

  const success = events.some(e => e.event_kind === 'sprint_complete' && e.data_json.includes('"success":true'))
  const failed = events.some(e => e.event_kind === 'sprint_failed')
  const startedAt = events.find(e => e.event_kind === 'sprint_started')?.ts

  // Deduplicate steps: keep latest per nodeId (re-tries produce duplicates)
  const deduped = steps.reduce<NodeStep[]>((acc, s) => {
    const existing = acc.findIndex(x => x.nodeId === s.nodeId)
    if (existing >= 0) { acc[existing] = s } else { acc.push(s) }
    return acc
  }, [])

  // Order: intake → architect → build → qa → demo → scribe
  const ORDER = ['intake', 'architect', 'build', 'qa', 'demo', 'scribe']
  const sorted = deduped.slice().sort((a, b) => {
    const ai = ORDER.indexOf(a.role)
    const bi = ORDER.indexOf(b.role)
    return (ai === -1 ? 99 : ai) - (bi === -1 ? 99 : bi)
  })

  return (
    <div className="max-w-4xl mx-auto px-6 py-8 space-y-8">

      {/* Back */}
      <Link to="/" className="text-muted text-sm hover:text-slate-300 transition-colors inline-block">← Dashboard</Link>

      {/* ① PROBLEM */}
      <section>
        <div className="flex items-center gap-3 mb-3">
          <span className="text-xs font-bold text-muted uppercase tracking-widest">① Problem</span>
          <div className={`px-3 py-0.5 rounded-full text-xs font-semibold ${
            success ? 'bg-emerald-900/50 text-emerald-400' :
            failed  ? 'bg-rose-900/50 text-rose-400' :
            'bg-amber-900/50 text-amber-400'
          }`}>
            {success ? '✓ Solved' : failed ? '✗ Failed' : 'Running…'}
          </div>
          {startedAt && <span className="text-muted text-xs ml-auto">{new Date(startedAt).toLocaleString()}</span>}
        </div>
        <div className="bg-surface border border-border rounded-xl p-5">
          {request ? (
            <p className="text-slate-200 text-base leading-relaxed">{request}</p>
          ) : (
            <p className="text-muted text-sm font-mono">{id}</p>
          )}
        </div>
      </section>

      {/* ② PLAN */}
      {graphJson && (() => {
        const g = safeJson(graphJson) as unknown as GraphData
        if (!g.nodes?.length) return null
        const { accepted, active } = graphStatusFromTrail(events)
        return (
          <section>
            <div className="flex items-center gap-2 mb-3">
              <span className="text-xs font-bold text-muted uppercase tracking-widest">② Plan</span>
              <span className="text-muted text-xs">· {g.nodes.length} agent{g.nodes.length !== 1 ? 's' : ''} · {g.edges?.length ?? 0} handoffs</span>
            </div>
            <div className="bg-surface border border-border rounded-xl p-5">
              <PhaseGraph graph={g} acceptedNodes={accepted} activeNode={active} />
            </div>
          </section>
        )
      })()}

      {/* ③ EXECUTION */}
      <section>
        <div className="flex items-center gap-2 mb-3">
          <span className="text-xs font-bold text-muted uppercase tracking-widest">③ Execution</span>
          <span className="text-muted text-xs">· {sorted.length} steps</span>
        </div>
        {loading && sorted.length === 0 ? (
          <div className="text-muted text-sm py-8 text-center pulse-soft">Loading steps…</div>
        ) : (
          <div className="space-y-3">
            {sorted.map((step, i) => (
              <NodeCard key={step.artifactHash} step={step} index={i} />
            ))}
          </div>
        )}
      </section>

      {/* ④ IMPROVEMENT */}
      {(success || failed) && digest && (
        <section>
          <div className="flex items-center gap-2 mb-3">
            <span className="text-xs font-bold text-muted uppercase tracking-widest">④ Improvement</span>
            <span className="text-muted text-xs">· system rewrote its own agents</span>
          </div>
          <ImprovementSection sprintId={id!} specs={digest.specs} />
        </section>
      )}

    </div>
  )
}
