import fs from 'node:fs'
import path from 'node:path'
import { app, dialog, net, shell, type BrowserWindow, type MessageBoxOptions } from 'electron'
import { autoUpdater } from 'electron-updater'
import { compareVersions, errorMessage } from '../shared/util'

/** Releases come from this GitHub repository (also set as `build.publish` in package.json). */
const REPO = 'Fahed-Alhammadi/RemoteSSH'

/**
 * Updates from GitHub releases. The Windows installer, AppImage and .deb builds download and install
 * the new version (electron-updater checks its SHA-512); the portable .exe and .tar.gz builds can only
 * point to the download page.
 */
export class Updater {
  private busy = false

  constructor(private readonly window: () => BrowserWindow | null) {}

  /** `manual` checks report "up to date" and errors; startup checks stay silent unless there is an update. */
  async check(manual: boolean): Promise<void> {
    if (this.busy) return
    this.busy = true
    try {
      if (this.canInstall) await this.checkAndInstall(manual)
      else await this.checkOnly(manual)
    } catch (e) {
      if (manual) await this.box({ type: 'error', message: 'Could not check for updates', detail: errorMessage(e) })
    } finally {
      this.busy = false
    }
  }

  private get canInstall(): boolean {
    if (!app.isPackaged) return false
    if (process.platform === 'win32') return !process.env.PORTABLE_EXECUTABLE_DIR
    if (process.platform === 'linux') return !!process.env.APPIMAGE || packageType() === 'deb'
    return false
  }

  private async checkAndInstall(manual: boolean): Promise<void> {
    autoUpdater.autoDownload = false
    autoUpdater.autoInstallOnAppQuit = true
    const result = await autoUpdater.checkForUpdates()
    if (!result?.isUpdateAvailable) return this.upToDate(manual)
    const version = result.updateInfo.version
    const choice = await this.box({
      message: `RemoteSSH ${version} is available`,
      detail: `You have version ${app.getVersion()}. Download and install it now?`,
      buttons: ['Download', 'Later'],
      defaultId: 0,
      cancelId: 1,
    })
    if (choice !== 0) return

    const onProgress = (p: { percent: number }) => this.window()?.setProgressBar(p.percent / 100)
    autoUpdater.on('download-progress', onProgress)
    try {
      await autoUpdater.downloadUpdate()
    } finally {
      autoUpdater.off('download-progress', onProgress)
      this.window()?.setProgressBar(-1)
    }
    const restart = await this.box({
      message: `RemoteSSH ${version} is ready to install`,
      detail: 'Restart now to finish updating, or it will be installed when you quit.',
      buttons: ['Restart Now', 'Later'],
      defaultId: 0,
      cancelId: 1,
    })
    if (restart === 0) autoUpdater.quitAndInstall()
  }

  private async checkOnly(manual: boolean): Promise<void> {
    const res = await net.fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
      headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'RemoteSSH' },
    })
    if (res.status === 404) return this.upToDate(manual) // no published release yet
    if (!res.ok) throw new Error(`GitHub returned HTTP ${res.status}.`)
    const release = (await res.json()) as { tag_name: string; html_url: string }
    if (compareVersions(release.tag_name, app.getVersion()) <= 0) return this.upToDate(manual)
    const choice = await this.box({
      message: `RemoteSSH ${release.tag_name.replace(/^v/, '')} is available`,
      detail: `You have version ${app.getVersion()}. This build can't update itself; download the new version from GitHub.`,
      buttons: ['Open Download Page', 'Later'],
      defaultId: 0,
      cancelId: 1,
    })
    if (choice === 0 && release.html_url.startsWith('https://github.com/')) await shell.openExternal(release.html_url)
  }

  private async upToDate(manual: boolean): Promise<void> {
    if (manual) await this.box({ message: "You're up to date", detail: `RemoteSSH ${app.getVersion()} is the latest version.` })
  }

  private async box(options: MessageBoxOptions): Promise<number> {
    const win = this.window()
    const opts = { type: 'info' as const, title: 'Software Update', ...options }
    return (win ? await dialog.showMessageBox(win, opts) : await dialog.showMessageBox(opts)).response
  }
}

/** electron-builder writes `package-type` into resources for .deb/.rpm builds. */
function packageType(): string | null {
  try {
    return fs.readFileSync(path.join(process.resourcesPath, 'package-type'), 'utf8').trim()
  } catch {
    return null
  }
}
