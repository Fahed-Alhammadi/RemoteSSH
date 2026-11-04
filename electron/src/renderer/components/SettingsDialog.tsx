import { useState } from 'react'
import { Monitor, Moon, Settings, Sun } from 'lucide-react'
import type { AppSettings, OverwriteAction, ThemeMode } from '../../shared/types'
import { Modal } from './ui'

const themes: { id: ThemeMode; label: string; icon: typeof Sun }[] = [
  { id: 'system', label: 'System', icon: Monitor },
  { id: 'light', label: 'Light', icon: Sun },
  { id: 'dark', label: 'Dark', icon: Moon },
]

const overwriteLabels: Record<OverwriteAction, string> = {
  ask: 'Ask for action',
  overwrite: 'Overwrite file',
  overwriteIfNewer: 'Overwrite file if source newer',
  overwriteIfDifferentSize: 'Overwrite file if size differs',
  resume: 'Resume file transfer',
  rename: 'Rename file',
  skip: 'Skip file',
}

type NumberKey = 'maxConcurrentTransfers' | 'retryCount' | 'downloadLimitKiB' | 'uploadLimitKiB' | 'connectTimeout'

/** A number field that can be cleared and retyped; the setting takes the value clamped to its range. */
function NumberField(props: { id: string; value: number; min: number; max: number; onChange: (n: number) => void }) {
  const { id, value, min, max, onChange } = props
  const [text, setText] = useState(String(value))
  const clamp = (n: number) => Math.max(min, Math.min(max, Math.round(n)))
  return (
    <input id={id} type="number" min={min} max={max} value={text}
      onChange={(e) => {
        setText(e.target.value)
        if (e.target.value.trim() !== '' && Number.isFinite(Number(e.target.value))) onChange(clamp(Number(e.target.value)))
      }}
      onBlur={() => setText(String(value))} />
  )
}

export function SettingsDialog(props: { initial: AppSettings; onClose: () => void; onSave: (s: AppSettings) => void }) {
  const [s, setS] = useState(props.initial)
  const num = (key: NumberKey, min: number, max: number) => (
    <NumberField id={`setting-${key}`} value={s[key]} min={min} max={max} onChange={(n) => setS((cur) => ({ ...cur, [key]: n }))} />
  )
  const overwrite = (key: 'defaultOverwriteDownload' | 'defaultOverwriteUpload') => (
    <select id={`setting-${key}`} value={s[key]} onChange={(e) => setS({ ...s, [key]: e.target.value as OverwriteAction })}>
      {Object.entries(overwriteLabels).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
    </select>
  )
  return (
    <Modal title="Settings" icon={Settings} onClose={props.onClose} closeOnBackdrop={false} width={520}
      footer={<>
        <button type="button" onClick={props.onClose}>Cancel</button>
        <button type="button" className="primary" onClick={() => props.onSave(s)}>Save</button>
      </>}>
      <div className="form-grid">
        <h3>Transfers</h3>
        <label htmlFor="setting-maxConcurrentTransfers">Concurrent transfers</label>{num('maxConcurrentTransfers', 1, 10)}
        <label htmlFor="setting-retryCount">Retries on failure</label>{num('retryCount', 0, 10)}
        <label htmlFor="setting-downloadLimitKiB">Download limit (KiB/s)</label>{num('downloadLimitKiB', 0, 10_000_000)}
        <label htmlFor="setting-uploadLimitKiB">Upload limit (KiB/s)</label>{num('uploadLimitKiB', 0, 10_000_000)}
        <span /><span className="muted small hint">0 means no limit. Changes apply to new transfers.</span>
        <label htmlFor="setting-defaultOverwriteDownload">Existing downloads</label>{overwrite('defaultOverwriteDownload')}
        <label htmlFor="setting-defaultOverwriteUpload">Existing uploads</label>{overwrite('defaultOverwriteUpload')}
        <h3>Connection</h3>
        <label htmlFor="setting-connectTimeout">Timeout (seconds)</label>{num('connectTimeout', 5, 600)}
        <span className="form-label">Keep-alive</span>
        <label className="check"><input type="checkbox" checked={s.keepAlive} onChange={(e) => setS({ ...s, keepAlive: e.target.checked })} /> Send keep-alive packets</label>
        <h3>Interface</h3>
        <span className="form-label" id="appearance-label">Appearance</span>
        <div className="segmented theme-choice" role="radiogroup" aria-labelledby="appearance-label">
          {themes.map((t) => (
            <button key={t.id} type="button" role="radio" aria-checked={s.theme === t.id} className={s.theme === t.id ? 'active' : ''} onClick={() => setS({ ...s, theme: t.id })}>
              <t.icon size={15} /> {t.label}
            </button>
          ))}
        </div>
        <span className="form-label">Hidden files</span>
        <label className="check"><input type="checkbox" checked={s.showHiddenFiles} onChange={(e) => setS({ ...s, showHiddenFiles: e.target.checked })} /> Show hidden files</label>
        <span className="form-label">Comparison</span>
        <label className="check"><input type="checkbox" checked={s.showDirectoryComparison} onChange={(e) => setS({ ...s, showDirectoryComparison: e.target.checked })} /> Highlight differences between panes</label>
        <h3>Updates</h3>
        <span className="form-label">New versions</span>
        <label className="check"><input type="checkbox" checked={s.checkForUpdates} onChange={(e) => setS({ ...s, checkForUpdates: e.target.checked })} /> Check for updates at startup</label>
      </div>
    </Modal>
  )
}
