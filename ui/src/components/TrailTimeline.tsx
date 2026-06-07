import type { TrailEvent } from '../types'

const KIND_META: Record<string, { icon: string; color: string; label?: string }> = {
  sprint_started:   { icon: '🚀', color: 'text-slate-300', label: 'Sprint started' },
  sprint_manifest:  { icon: '📋', color: 'text-slate-400' },
  node_started:     { icon: '▶', color: 'text-blue-400' },
  node_accepted:    { icon: '✓', color: 'text-emerald-400' },
  node_retrying:    { icon: '↺', color: 'text-amber-400' },
  phase_advanced:   { icon: '→', color: 'text-indigo-400', label: 'Phase advanced' },
  phase_cast:       { icon: '🎭', color: 'text-purple-400', label: 'Agents cast' },
  phase_manifest:   { icon: '📄', color: 'text-slate-400' },
  graph_validated:  { icon: '✔', color: 'text-emerald-300' },
  graph_rejected:   { icon: '✖', color: 'text-rose-400' },
  llm_start:        { icon: '·', color: 'text-slate-600' },
  llm_done:         { icon: '·', color: 'text-slate-600' },
  digest_produced:  { icon: '📝', color: 'text-amber-400', label: 'Digest produced' },
  digest_saved:     { icon: '💾', color: 'text-amber-300' },
  phase_improved:   { icon: '⬆', color: 'text-emerald-400', label: 'Agents improved' },
  sprint_complete:  { icon: '🏁', color: 'text-slate-100', label: 'Sprint complete' },
  sprint_failed:    { icon: '✗', color: 'text-rose-400', label: 'Sprint failed' },
}

const HIDDEN = new Set(['llm_start', 'llm_done', 'sprint_manifest', 'phase_manifest'])

function parseData(json: string): Record<string, unknown> {
  try { return JSON.parse(json) || {} } catch { return {} }
}

function eventLabel(e: TrailEvent): string {
  const meta = KIND_META[e.event_kind]
  if (meta?.label) return meta.label
  const d = parseData(e.data_json)
  if (e.event_kind === 'node_started') return `Node started: ${d.node as string} (${d.role as string})`
  if (e.event_kind === 'node_accepted') return `Node accepted: ${d.node as string}`
  if (e.event_kind === 'node_retrying') return `Retrying: ${d.node as string}`
  if (e.event_kind === 'phase_advanced') return `${d.from as string} → ${d.to as string}`
  if (e.event_kind === 'phase_cast') return `${d.agents as number} agents cast`
  if (e.event_kind === 'graph_validated') return `Graph validated (${d.nodes as number} nodes)`
  if (e.event_kind === 'graph_rejected') return `Graph rejected: ${d.reason as string}`
  if (e.event_kind === 'phase_improved') return `Improved ${(d as any).count ?? ''} agent(s)`
  if (e.event_kind === 'sprint_complete') return `Sprint ${(d as any).success ? 'succeeded' : 'failed'}`
  return e.event_kind.replace(/_/g, ' ')
}

interface Props {
  events: TrailEvent[]
  compact?: boolean
}

export default function TrailTimeline({ events, compact = false }: Props) {
  const visible = events.filter(e => !HIDDEN.has(e.event_kind))

  if (visible.length === 0) {
    return <div className="text-muted text-sm py-4 text-center">No events yet</div>
  }

  return (
    <div className="relative">
      <div className="absolute left-4 top-0 bottom-0 w-px bg-border" />
      <div className="space-y-1">
        {visible.map((e, i) => {
          const meta = KIND_META[e.event_kind] || { icon: '·', color: 'text-muted' }
          const isKey = ['phase_advanced', 'node_accepted', 'sprint_complete', 'sprint_failed', 'phase_improved', 'digest_produced'].includes(e.event_kind)
          return (
            <div key={i} className={`flex items-start gap-3 pl-8 pr-2 py-1 rounded-lg relative fade-in ${isKey && !compact ? 'bg-slate-800/30' : ''}`}
              style={{ animationDelay: `${Math.min(i * 15, 300)}ms` }}>
              <div className={`absolute left-[13px] top-2.5 w-2.5 h-2.5 rounded-full flex items-center justify-center text-[8px] ${
                e.event_kind === 'sprint_complete' ? 'bg-emerald-600' :
                e.event_kind === 'sprint_failed' ? 'bg-rose-600' :
                e.event_kind === 'phase_advanced' ? 'bg-indigo-600' :
                e.event_kind === 'phase_improved' ? 'bg-emerald-700' :
                'bg-slate-700'
              }`} />
              <div className="flex-1 min-w-0">
                <div className="flex items-baseline gap-2">
                  <span className={`font-mono text-sm ${meta.color}`}>{meta.icon}</span>
                  <span className={`text-sm ${isKey ? 'text-slate-200 font-medium' : 'text-slate-400'}`}>
                    {eventLabel(e)}
                  </span>
                  <span className="text-muted text-xs ml-auto font-mono flex-shrink-0">
                    {new Date(e.ts).toLocaleTimeString()}
                  </span>
                </div>
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}
