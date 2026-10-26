import { useState } from 'react'
import { Settings } from 'lucide-react'
import type { AppSettings, OverwriteAction } from '../../shared/types'
import { Modal } from './ui'

const overwriteLabels: Record<OverwriteAction, string> = {
  ask: 'Ask for action',
  overwrite: 'Overwrite file',
  overwriteIfNewer: 'Overwrite file if source newer',
  overwriteIfDifferentSize: 'Overwrite file if size differs',
  resume: 'Resume file transfer',
  rename: 'Rename file',
  skip: 'Skip file',
}

export function SettingsDialog(props: { initial: AppSettings; onClose: () => void; onSave: (s: AppSettings) => void }) {
  const [s, setS] = useState(props.initial)
  const num = (key: keyof AppSettings, min: number, max: number) => (
    <input type="number" min={min} max={max} value={s[key] as number}
      onChange={(e) => setS({ ...s, [key]: Math.max(min, Math.min(max, Number(e.target.value) || 0)) })} />
  )
  const overwrite = (key: 'defaultOverwriteDownload' | 'defaultOverwriteUpload') => (
    <select value={s[key]} onChange={(e) => setS({ ...s, [key]: e.target.value as OverwriteAction })}>
      {Object.entries(overwriteLabels).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
    </select>
  )
  return (
    <Modal title="Settings" icon={Settings} onClose={props.onClose} width={520}
      footer={<>
        <button type="button" onClick={props.onClose}>Cancel</button>
        <button type="button" className="primary" onClick={() => props.onSave(s)}>Save</button>
      </>}>
      <div className="form-grid">
        <h3>Transfers</h3>
        <label>Concurrent transfers</label>{num('maxConcurrentTransfers', 1, 10)}
        <label>Retries on failure</label>{num('retryCount', 0, 10)}
        <label>Download limit (KiB/s)</label>{num('downloadLimitKiB', 0, 10_000_000)}
        <label>Upload limit (KiB/s)</label>{num('uploadLimitKiB', 0, 10_000_000)}
        <span /><span className="muted small hint">0 means no limit. Changes apply to new transfers.</span>
        <label>Existing downloads</label>{overwrite('defaultOverwriteDownload')}
        <label>Existing uploads</label>{overwrite('defaultOverwriteUpload')}
        <h3>Connection</h3>
        <label>Timeout (seconds)</label>{num('connectTimeout', 5, 600)}
        <label>Keep-alive</label>
        <label className="check"><input type="checkbox" checked={s.keepAlive} onChange={(e) => setS({ ...s, keepAlive: e.target.checked })} /> Send keep-alive packets</label>
        <h3>Interface</h3>
        <label>Hidden files</label>
        <label className="check"><input type="checkbox" checked={s.showHiddenFiles} onChange={(e) => setS({ ...s, showHiddenFiles: e.target.checked })} /> Show hidden files</label>
        <label>Comparison</label>
        <label className="check"><input type="checkbox" checked={s.showDirectoryComparison} onChange={(e) => setS({ ...s, showDirectoryComparison: e.target.checked })} /> Highlight differences between panes</label>
        <h3>Updates</h3>
        <label>New versions</label>
        <label className="check"><input type="checkbox" checked={s.checkForUpdates} onChange={(e) => setS({ ...s, checkForUpdates: e.target.checked })} /> Check for updates at startup</label>
      </div>
    </Modal>
  )
}
