import { diffWords } from 'diff'

interface Props {
  before: string
  after: string
  beforeLabel?: string
  afterLabel?: string
}

export default function DiffViewer({ before, after, beforeLabel = 'Before', afterLabel = 'After (AI-improved)' }: Props) {
  const changes = diffWords(before, after)

  // Split into before/after sequences
  const beforeParts: { text: string; removed: boolean }[] = []
  const afterParts: { text: string; added: boolean }[] = []

  for (const c of changes) {
    if (c.removed) {
      beforeParts.push({ text: c.value, removed: true })
    } else if (c.added) {
      afterParts.push({ text: c.value, added: true })
    } else {
      beforeParts.push({ text: c.value, removed: false })
      afterParts.push({ text: c.value, added: false })
    }
  }

  const addedWords = changes.filter(c => c.added).reduce((n, c) => n + c.value.split(/\s+/).filter(Boolean).length, 0)
  const removedWords = changes.filter(c => c.removed).reduce((n, c) => n + c.value.split(/\s+/).filter(Boolean).length, 0)

  function renderBefore() {
    return beforeParts.map((p, i) =>
      p.removed ? (
        <mark key={i} className="bg-rose-900/50 text-rose-300 rounded px-0.5">{p.text}</mark>
      ) : (
        <span key={i} className="text-slate-300">{p.text}</span>
      )
    )
  }

  function renderAfter() {
    return afterParts.map((p, i) =>
      p.added ? (
        <mark key={i} className="bg-emerald-900/50 text-emerald-300 rounded px-0.5">{p.text}</mark>
      ) : (
        <span key={i} className="text-slate-300">{p.text}</span>
      )
    )
  }

  return (
    <div className="space-y-3">
      <div className="flex items-center gap-4 text-sm text-muted">
        <span className="flex items-center gap-1.5 text-rose-400">
          <span className="text-base">−</span> {removedWords} words removed
        </span>
        <span className="flex items-center gap-1.5 text-emerald-400">
          <span className="text-base">+</span> {addedWords} words added
        </span>
        <span className="text-muted ml-auto">AI rewrote this prompt — no human input</span>
      </div>

      <div className="grid grid-cols-2 gap-3">
        <div className="bg-bg border border-border rounded-lg overflow-hidden">
          <div className="px-3 py-2 bg-rose-950/30 border-b border-border flex items-center gap-2">
            <span className="w-2 h-2 rounded-full bg-rose-500" />
            <span className="text-xs text-muted font-medium">{beforeLabel}</span>
          </div>
          <pre className="p-4 text-xs leading-relaxed font-mono whitespace-pre-wrap overflow-auto max-h-80">
            {renderBefore()}
          </pre>
        </div>

        <div className="bg-bg border border-border rounded-lg overflow-hidden">
          <div className="px-3 py-2 bg-emerald-950/30 border-b border-border flex items-center gap-2">
            <span className="w-2 h-2 rounded-full bg-emerald-500" />
            <span className="text-xs text-muted font-medium">{afterLabel}</span>
          </div>
          <pre className="p-4 text-xs leading-relaxed font-mono whitespace-pre-wrap overflow-auto max-h-80">
            {renderAfter()}
          </pre>
        </div>
      </div>
    </div>
  )
}
