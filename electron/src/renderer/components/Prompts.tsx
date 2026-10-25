import { useState } from 'react'
import { FilePen, Fingerprint, KeyRound, ShieldAlert, ShieldQuestion, SquareTerminal, TriangleAlert } from 'lucide-react'
import type { ChmodAnswer, OverwriteAnswer, PromptRequest, TrustAnswer } from '../../shared/types'
import { formatDate, formatSize, Permissions } from '../../shared/util'
import { Modal } from './ui'

/** One dialog for whichever question is first in the queue. `done(null)` means dismissed. */
export function PromptDialog({ request, done }: { request: PromptRequest; done: (value: unknown) => void }) {
  switch (request.kind) {
    case 'text':
    case 'password':
      return <TextPrompt request={request} done={done} />
    case 'confirm':
      return (
        <Modal title={request.title} icon={TriangleAlert} onClose={() => done(false)} width={440}
          footer={<>
            <button type="button" onClick={() => done(false)}>Cancel</button>
            <button type="button" className={request.destructive ? 'danger' : 'primary'} autoFocus onClick={() => done(true)}>{request.confirm}</button>
          </>}>
          <p className="prewrap">{request.message}</p>
        </Modal>
      )
    case 'hostKey':
      return (
        <TrustPrompt
          title={request.changed ? 'Host key has CHANGED' : 'Unknown host key'}
          warning={request.changed}
          done={done}
          details={[
            ['Host', `${request.host}:${request.port}`],
            ['Key type', request.keyType],
            ['Fingerprint', request.fingerprint],
          ]}
          message={request.changed
            ? 'The server sent a different host key than the one you trusted before. This can mean someone is intercepting the connection. Only continue if you know the key was replaced.'
            : 'The server’s host key is not known. Compare the fingerprint with the one your administrator gave you before trusting it.'}
        />
      )
    case 'certificate':
      return (
        <TrustPrompt
          title="Unknown certificate"
          warning={false}
          done={done}
          message={`The server’s certificate could not be verified: ${request.reason}`}
          details={[
            ['Host', `${request.host}:${request.port}`],
            ['Subject', request.subject],
            ['Issuer', request.issuer],
            ['Valid', `${request.validFrom} – ${request.validTo}`],
            ['SHA-256', request.fingerprint],
          ]}
        />
      )
    case 'overwrite':
      return <OverwritePrompt request={request} done={done} />
    case 'chmod':
      return <ChmodPrompt request={request} done={done} />
  }
}

function TextPrompt({ request, done }: { request: Extract<PromptRequest, { kind: 'text' | 'password' }>; done: (v: string | null) => void }) {
  const [value, setValue] = useState(request.kind === 'text' ? request.initial : '')
  return (
    <Modal title={request.title} icon={request.kind === 'password' ? KeyRound : SquareTerminal} onClose={() => done(null)} width={440}
      footer={<>
        <button type="button" onClick={() => done(null)}>Cancel</button>
        <button type="submit" form="text-prompt" className="primary">OK</button>
      </>}>
      <form id="text-prompt" onSubmit={(e) => (e.preventDefault(), done(value))}>
        <label className="field">
          <span>{request.message}</span>
          <input
            type={request.kind === 'password' ? 'password' : 'text'}
            value={value}
            autoFocus
            spellCheck={false}
            onFocus={(e) => {
              const dot = e.target.value.lastIndexOf('.')
              e.target.setSelectionRange(0, dot > 0 ? dot : e.target.value.length)
            }}
            onChange={(e) => setValue(e.target.value)}
          />
        </label>
      </form>
    </Modal>
  )
}

function TrustPrompt(props: { title: string; message: string; details: [string, string][]; warning: boolean; done: (v: TrustAnswer) => void }) {
  return (
    <Modal title={props.title} icon={props.warning ? ShieldAlert : ShieldQuestion} onClose={() => props.done('reject')} width={560}
      footer={<>
        <button type="button" onClick={() => props.done('reject')} autoFocus>Cancel</button>
        <button type="button" onClick={() => props.done('once')}>Trust Once</button>
        <button type="button" className={props.warning ? 'danger' : 'primary'} onClick={() => props.done('always')}>Always Trust</button>
      </>}>
      <p className={props.warning ? 'warning' : undefined}>{props.message}</p>
      <dl className="details">
        {props.details.map(([k, v]) => (
          <div key={k}>
            <dt>{k === 'Fingerprint' || k === 'SHA-256' ? <><Fingerprint size={13} /> {k}</> : k}</dt>
            <dd className={k === 'Fingerprint' || k === 'SHA-256' ? 'mono' : undefined}>{v}</dd>
          </div>
        ))}
      </dl>
    </Modal>
  )
}

const overwriteChoices: { action: OverwriteAnswer['action']; label: string }[] = [
  { action: 'overwrite', label: 'Overwrite' },
  { action: 'overwriteIfNewer', label: 'Overwrite if source is newer' },
  { action: 'overwriteIfDifferentSize', label: 'Overwrite if size differs' },
  { action: 'resume', label: 'Resume' },
  { action: 'rename', label: 'Rename' },
  { action: 'skip', label: 'Skip' },
]

function OverwritePrompt({ request, done }: { request: Extract<PromptRequest, { kind: 'overwrite' }>; done: (v: OverwriteAnswer | null) => void }) {
  const [action, setAction] = useState<OverwriteAnswer['action']>('overwrite')
  const [all, setAll] = useState(false)
  const name = request.target.split(/[\\/]/).pop() ?? ''
  const [newName, setNewName] = useState(name)
  const side = (label: string, path: string, size: number | null, modified: number | null) => (
    <div className="file-card">
      <strong>{label}</strong>
      <span className="path" title={path}>{path}</span>
      <span>{size == null ? 'Unknown size' : `${formatSize(size)} (${size.toLocaleString()} bytes)`}</span>
      <span>{formatDate(modified) || 'Unknown date'}</span>
    </div>
  )
  return (
    <Modal title="Target file already exists" icon={FilePen} onClose={() => done(null)} width={600}
      footer={<>
        <label className="check"><input type="checkbox" checked={all} onChange={(e) => setAll(e.target.checked)} /> Always use this action</label>
        <span className="spacer" />
        <button type="button" onClick={() => done(null)}>Cancel</button>
        <button type="button" className="primary" autoFocus
          onClick={() => done({ action, applyToAll: all, newName: action === 'rename' && !all ? newName : undefined })}>OK</button>
      </>}>
      <div className="file-cards">
        {side('Source', request.source, request.sourceSize, request.sourceModified)}
        {side('Target', request.target, request.targetSize, request.targetModified)}
      </div>
      <div className="radio-grid">
        {overwriteChoices.map((c) => (
          <label key={c.action} className="check">
            <input type="radio" name="overwrite" checked={action === c.action} onChange={() => setAction(c.action)} />
            {c.label}
          </label>
        ))}
      </div>
      {action === 'rename' && !all && (
        <label className="field">
          <span>New name</span>
          <input value={newName} onChange={(e) => setNewName(e.target.value)} />
        </label>
      )}
    </Modal>
  )
}

function ChmodPrompt({ request, done }: { request: Extract<PromptRequest, { kind: 'chmod' }>; done: (v: ChmodAnswer | null) => void }) {
  const [mode, setMode] = useState(request.mode ?? 0o644)
  const [text, setText] = useState(Permissions.octal(request.mode ?? 0o644))
  const [recursive, setRecursive] = useState(false)
  const update = (m: number) => {
    setMode(m)
    setText(Permissions.octal(m))
  }
  const groups = [['Owner', 6], ['Group', 3], ['Public', 0]] as const
  const bits = [['Read', 4], ['Write', 2], ['Execute', 1]] as const
  const title = request.names.length === 1 ? request.names[0] : `${request.names.length} items`
  return (
    <Modal title={`Change permissions – ${title}`} icon={KeyRound} onClose={() => done(null)} width={460}
      footer={<>
        <button type="button" onClick={() => done(null)}>Cancel</button>
        <button type="button" className="primary" onClick={() => done({ mode, recursive })}>Apply</button>
      </>}>
      <div className="chmod-grid">
        <span />
        {bits.map(([b]) => <span key={b} className="chmod-head">{b}</span>)}
        {groups.map(([g, shift]) => (
          <div key={g} className="chmod-row">
            <span>{g}</span>
            {bits.map(([b, bit]) => (
              <input key={b} type="checkbox" aria-label={`${g} ${b}`} checked={(mode & (bit << shift)) !== 0}
                onChange={(e) => update(e.target.checked ? mode | (bit << shift) : mode & ~(bit << shift))} />
            ))}
          </div>
        ))}
      </div>
      <label className="field inline">
        <span>Numeric value</span>
        <input className="mono" value={text} maxLength={3}
          onChange={(e) => {
            setText(e.target.value)
            if (/^[0-7]{3}$/.test(e.target.value)) setMode(parseInt(e.target.value, 8))
          }} />
      </label>
      <label className="check"><input type="checkbox" checked={recursive} onChange={(e) => setRecursive(e.target.checked)} /> Apply to subdirectories and files</label>
    </Modal>
  )
}
