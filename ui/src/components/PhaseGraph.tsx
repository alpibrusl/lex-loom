import { Link } from 'react-router-dom'
import type { TrailEvent } from '../types'

export interface GraphNode { id: string; role: string; gate: string; expand?: string }
export interface GraphEdge { from: string; to: string; handoff: string }
export interface GraphData  { id: string; phase: string; nodes: GraphNode[]; edges: GraphEdge[] }

// Map role → phase column. Covers every role in the Architect's actual
// vocabulary (roles.lex's AVAILABLE ROLES), not just the Lex build/qa track --
// found live (#153): a real company sprint (py_build/py_qa/launch/finance/
// legal/docs) had 7 of its 10 non-intake nodes silently vanish from this
// diagram because their roles weren't Lex's literal "build"/"qa" strings and
// PHASE_ORDER didn't include an 'Other' bucket for anything unmapped.
const ROLE_PHASE: Record<string, string> = {
  intake: 'Intake',
  pm: 'Intake',
  architect: 'Design',
  ux_designer: 'Design',
  brand_designer: 'Design',
  content_designer: 'Design',
  build: 'Implementation',
  py_build: 'Implementation',
  fe_build: 'Implementation',
  devops: 'Implementation',
  qa: 'QA',
  py_qa: 'QA',
  security: 'QA',
  deploy: 'Ship',
  launch: 'Ship',
  demo: 'Demo',
  finance: 'Business',
  legal: 'Business',
  monetization_handoff: 'Business',
  brand_strategist: 'Distribution',
  copywriter: 'Distribution',
  content_creator: 'Distribution',
  seo_specialist: 'Distribution',
  docs: 'Scribe',
  scribe: 'Scribe',
}

// 'Other' is a deliberate catch-all, not a dead end: any role not in
// ROLE_PHASE above still renders here instead of vanishing, so a role added
// to the Architect's vocabulary later degrades gracefully instead of
// silently dropping nodes again.
const PHASE_ORDER = ['Intake', 'Design', 'Implementation', 'QA', 'Ship', 'Demo', 'Business', 'Distribution', 'Scribe', 'Other']

const DEFAULT_STYLE = { bg: 'bg-slate-800', border: 'border-slate-600', text: 'text-slate-300', dot: 'bg-slate-400', icon: '●' }

const ROLE_STYLE: Record<string, { bg: string; border: string; text: string; dot: string; icon: string }> = {
  intake:              { bg: 'bg-slate-800',   border: 'border-slate-600',  text: 'text-slate-300',  dot: 'bg-slate-400',   icon: '📋' },
  pm:                  { bg: 'bg-slate-800',   border: 'border-slate-600',  text: 'text-slate-300',  dot: 'bg-slate-400',   icon: '📝' },
  architect:           { bg: 'bg-indigo-950',  border: 'border-indigo-700', text: 'text-indigo-300', dot: 'bg-indigo-400',  icon: '🏗' },
  ux_designer:         { bg: 'bg-indigo-950',  border: 'border-indigo-700', text: 'text-indigo-300', dot: 'bg-indigo-400',  icon: '🧭' },
  brand_designer:      { bg: 'bg-indigo-950',  border: 'border-indigo-700', text: 'text-indigo-300', dot: 'bg-indigo-400',  icon: '🎨' },
  content_designer:    { bg: 'bg-indigo-950',  border: 'border-indigo-700', text: 'text-indigo-300', dot: 'bg-indigo-400',  icon: '✍️' },
  build:               { bg: 'bg-blue-950',    border: 'border-blue-700',   text: 'text-blue-300',   dot: 'bg-blue-400',    icon: '⚙️' },
  py_build:            { bg: 'bg-blue-950',    border: 'border-blue-700',   text: 'text-blue-300',   dot: 'bg-blue-400',    icon: '🐍' },
  fe_build:            { bg: 'bg-blue-950',    border: 'border-blue-700',   text: 'text-blue-300',   dot: 'bg-blue-400',    icon: '🖥️' },
  devops:              { bg: 'bg-blue-950',    border: 'border-blue-700',   text: 'text-blue-300',   dot: 'bg-blue-400',    icon: '🐳' },
  qa:                  { bg: 'bg-amber-950',   border: 'border-amber-700',  text: 'text-amber-300',  dot: 'bg-amber-400',   icon: '🔬' },
  py_qa:               { bg: 'bg-amber-950',   border: 'border-amber-700',  text: 'text-amber-300',  dot: 'bg-amber-400',   icon: '🔬' },
  security:            { bg: 'bg-amber-950',   border: 'border-amber-700',  text: 'text-amber-300',  dot: 'bg-amber-400',   icon: '🛡️' },
  deploy:               { bg: 'bg-cyan-950',    border: 'border-cyan-700',   text: 'text-cyan-300',   dot: 'bg-cyan-400',    icon: '🚀' },
  launch:              { bg: 'bg-cyan-950',    border: 'border-cyan-700',   text: 'text-cyan-300',   dot: 'bg-cyan-400',    icon: '🟢' },
  demo:                { bg: 'bg-violet-950',  border: 'border-violet-700', text: 'text-violet-300', dot: 'bg-violet-400',  icon: '🎯' },
  finance:             { bg: 'bg-emerald-950', border: 'border-emerald-700', text: 'text-emerald-300', dot: 'bg-emerald-400', icon: '💰' },
  legal:               { bg: 'bg-emerald-950', border: 'border-emerald-700', text: 'text-emerald-300', dot: 'bg-emerald-400', icon: '⚖️' },
  monetization_handoff: { bg: 'bg-emerald-950', border: 'border-emerald-700', text: 'text-emerald-300', dot: 'bg-emerald-400', icon: '🤝' },
  brand_strategist:    { bg: 'bg-pink-950',    border: 'border-pink-700',   text: 'text-pink-300',   dot: 'bg-pink-400',    icon: '📣' },
  copywriter:          { bg: 'bg-pink-950',    border: 'border-pink-700',   text: 'text-pink-300',   dot: 'bg-pink-400',    icon: '✏️' },
  content_creator:     { bg: 'bg-pink-950',    border: 'border-pink-700',   text: 'text-pink-300',   dot: 'bg-pink-400',    icon: '📰' },
  seo_specialist:      { bg: 'bg-pink-950',    border: 'border-pink-700',   text: 'text-pink-300',   dot: 'bg-pink-400',    icon: '🔎' },
  docs:                { bg: 'bg-teal-950',    border: 'border-teal-700',   text: 'text-teal-300',   dot: 'bg-teal-400',    icon: '📚' },
  scribe:              { bg: 'bg-teal-950',    border: 'border-teal-700',   text: 'text-teal-300',   dot: 'bg-teal-400',    icon: '📝' },
}

function nodePhase(role: string): string {
  return ROLE_PHASE[role] ?? 'Other'
}

function roleOf(node: GraphNode): string {
  return node.role || (
    node.id.startsWith('arch') ? 'architect' :
    node.id.startsWith('build') ? 'build' :
    node.id.startsWith('qa') ? 'qa' :
    node.id.startsWith('demo') ? 'demo' :
    node.id.startsWith('scribe') ? 'scribe' :
    node.id === 'intake' ? 'intake' : 'build'
  )
}

interface Props {
  graph: GraphData
  acceptedNodes?: Set<string>
  activeNode?: string
}

export default function PhaseGraph({ graph, acceptedNodes = new Set(), activeNode }: Props) {
  if (!graph.nodes?.length) return null

  // Group nodes by phase
  const phases = new Map<string, GraphNode[]>()
  for (const n of graph.nodes) {
    const phase = nodePhase(roleOf(n))
    if (!phases.has(phase)) phases.set(phase, [])
    phases.get(phase)!.push(n)
  }

  // Only show phases that have nodes, in order
  const activePhases = PHASE_ORDER.filter(p => phases.has(p))

  return (
    <div className="space-y-3">
      {/* Phase columns */}
      <div className="flex items-start gap-0 overflow-x-auto">
        {activePhases.map((phase, phaseIdx) => {
          const nodes = phases.get(phase)!
          const isLast = phaseIdx === activePhases.length - 1
          return (
            <div key={phase} className="flex items-center gap-0 flex-shrink-0">
              {/* Phase column */}
              <div className="flex flex-col gap-2 min-w-[140px]">
                {/* Phase label */}
                <div className="text-center">
                  <span className="text-xs text-muted font-semibold uppercase tracking-widest">{phase}</span>
                </div>
                {/* Nodes */}
                <div className="flex flex-col gap-2">
                  {nodes.map(n => {
                    const role = roleOf(n)
                    const st = ROLE_STYLE[role] || DEFAULT_STYLE
                    const done = acceptedNodes.has(n.id)
                    const active = activeNode === n.id
                    const box = (
                      <div className={`px-3 py-2 rounded-lg border text-xs ${st.bg} ${st.border} ${active ? 'ring-2 ring-white/20' : ''} ${n.expand ? 'hover:border-slate-400 transition-colors' : ''}`}>
                        <div className="flex items-center gap-1.5 mb-1">
                          <span>{st.icon}</span>
                          <span className={`font-semibold ${st.text}`}>{role}</span>
                          {done && <span className="ml-auto text-emerald-400">✓</span>}
                          {active && <span className="ml-auto text-amber-400 animate-pulse">●</span>}
                        </div>
                        <div className="font-mono text-muted truncate" title={n.id}>{n.id}</div>
                        {n.gate && (
                          <div className="mt-1 text-muted/70 text-[10px] leading-tight line-clamp-2" title={n.gate}>{n.gate}</div>
                        )}
                        {n.expand && (
                          <div className="mt-1 text-indigo-300 text-[10px] font-semibold">🧩 sub-loom →</div>
                        )}
                      </div>
                    )
                    return n.expand ? (
                      <Link key={n.id} to={`/sprint/${encodeURIComponent(`${graph.id}/${n.id}`)}`} title={`Open sub-loom: ${n.expand}`}>
                        {box}
                      </Link>
                    ) : (
                      <div key={n.id}>{box}</div>
                    )
                  })}
                </div>
              </div>

              {/* Arrow to next phase */}
              {!isLast && (
                <div className="flex items-center px-2 self-stretch">
                  <div className="flex flex-col items-center justify-center h-full">
                    {nodes.map((_, i) => (
                      <div key={i} className="flex items-center">
                        <div className="w-6 h-px bg-slate-600" />
                        <span className="text-slate-600 text-xs">›</span>
                      </div>
                    ))}
                  </div>
                </div>
              )}
            </div>
          )
        })}
      </div>

      {/* Edge handoffs (collapsed) */}
      {graph.edges?.length > 0 && (
        <details className="text-xs text-muted">
          <summary className="cursor-pointer hover:text-slate-400 transition-colors select-none">
            {graph.edges.length} handoffs defined
          </summary>
          <div className="mt-2 space-y-1 pl-2 border-l border-border">
            {graph.edges.map((e, i) => (
              <div key={i} className="flex items-baseline gap-2">
                <span className="font-mono text-slate-400">{e.from}</span>
                <span className="text-muted">→</span>
                <span className="font-mono text-slate-400">{e.to}</span>
                <span className="text-muted/60 text-[10px] flex-1 truncate">{e.handoff}</span>
              </div>
            ))}
          </div>
        </details>
      )}
    </div>
  )
}

// Helper: extract accepted node IDs and active node from trail events
export function graphStatusFromTrail(events: TrailEvent[]): { accepted: Set<string>; active: string | undefined } {
  const accepted = new Set<string>()
  let active: string | undefined

  for (const e of events) {
    if (e.event_kind === 'node_accepted') {
      try { const d = JSON.parse(e.data_json); if (d.node) accepted.add(d.node) } catch {}
    }
    if (e.event_kind === 'node_started') {
      try { const d = JSON.parse(e.data_json); active = d.node } catch {}
    }
  }
  // If node was accepted, it's no longer "active"
  if (active && accepted.has(active)) active = undefined
  return { accepted, active }
}
