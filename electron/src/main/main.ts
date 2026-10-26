import path from 'node:path'
import { app, BrowserWindow, ipcMain, Menu, nativeTheme, safeStorage, shell, type MenuItemConstructorOptions } from 'electron'
import { Events, invokeMethods } from '../shared/api'
import type { MenuAction } from '../shared/types'
import { Controller } from './controller'
import type { SecretCipher } from './store/siteStore'
import { Updater } from './updater'

app.setName('RemoteSSH')
if (process.platform === 'win32') app.setAppUserModelId('app.remotessh.RemoteSSH')

let window: BrowserWindow | null = null
const updater = new Updater(() => window)

/** OS keyring encryption. Linux's "basic_text" fallback is plain obfuscation, so it counts as unavailable. */
const cipher: SecretCipher = {
  available: () =>
    safeStorage.isEncryptionAvailable() &&
    (process.platform !== 'linux' || safeStorage.getSelectedStorageBackend() !== 'basic_text'),
  encrypt: (plain) => safeStorage.encryptString(plain).toString('base64'),
  decrypt: (encoded) => safeStorage.decryptString(Buffer.from(encoded, 'base64')),
}

function createWindow(controller: Controller): void {
  // The appearance setting drives prefers-color-scheme in the page and the native menus and dialogs.
  nativeTheme.themeSource = controller.settings.theme
  window = new BrowserWindow({
    width: 1280,
    height: 860,
    minWidth: 900,
    minHeight: 600,
    title: 'RemoteSSH',
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#161b24' : '#ffffff',
    icon: path.join(__dirname, 'icon.png'),
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
      spellcheck: false,
    },
  })
  window.once('ready-to-show', () => window?.show())
  // External links open in the browser; the app itself never navigates away.
  window.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:\/\//.test(url)) void shell.openExternal(url)
    return { action: 'deny' }
  })
  window.webContents.on('will-navigate', (e) => e.preventDefault())
  window.on('closed', () => {
    window = null
  })
  // Development aid: REMOTESSH_CAPTURE=<file.png> saves a screenshot of the window and quits.
  const capture = !app.isPackaged && process.env.REMOTESSH_CAPTURE
  if (capture) {
    window.webContents.once('did-finish-load', () => {
      setTimeout(async () => {
        const image = await window!.webContents.capturePage()
        require('node:fs').writeFileSync(capture, image.toPNG())
        app.quit()
      }, Number(process.env.REMOTESSH_CAPTURE_DELAY ?? 1500))
    })
  }
  if (process.env.REMOTESSH_DEV_URL) void window.loadURL(process.env.REMOTESSH_DEV_URL)
  else void window.loadFile(path.join(__dirname, 'renderer', 'index.html'))
  Menu.setApplicationMenu(buildMenu(controller))
}

function buildMenu(controller: Controller): Menu {
  const send = (action: MenuAction) => () => controller.send(Events.menu, action)
  const isMac = process.platform === 'darwin'
  const template: MenuItemConstructorOptions[] = [
    ...(isMac ? [{ role: 'appMenu' as const }] : []),
    {
      label: '&File',
      submenu: [
        { label: 'Site Manager…', accelerator: 'CmdOrCtrl+S', click: send('siteManager') },
        { type: 'separator' },
        { label: 'Import from RemoteSSH…', accelerator: 'CmdOrCtrl+Shift+I', click: send('importSites') },
        { label: 'Export Sites…', accelerator: 'CmdOrCtrl+Shift+E', click: send('exportSites') },
        { type: 'separator' },
        { label: 'Settings…', accelerator: 'CmdOrCtrl+,', click: send('settings') },
        { type: 'separator' },
        isMac ? { role: 'close' } : { role: 'quit', label: 'E&xit' },
      ],
    },
    { role: 'editMenu' },
    {
      label: '&Server',
      submenu: [
        { label: 'Reconnect', accelerator: 'CmdOrCtrl+R', click: send('reconnect') },
        { label: 'Disconnect', accelerator: 'CmdOrCtrl+D', click: send('disconnect') },
        { label: 'Refresh', accelerator: 'F5', click: send('refresh') },
        { type: 'separator' },
        { label: 'Enter Custom Command…', click: send('customCommand') },
      ],
    },
    {
      label: '&Transfer',
      submenu: [
        { label: 'Pause / Resume Queue', accelerator: 'CmdOrCtrl+P', click: send('toggleQueue') },
        { label: 'Stop All Transfers', accelerator: 'CmdOrCtrl+.', click: send('stopAll') },
        { label: 'Clear Completed', click: send('clearFinished') },
      ],
    },
    {
      label: '&View',
      submenu: [
        { label: 'Show Hidden Files', accelerator: 'CmdOrCtrl+Shift+H', click: send('toggleHidden') },
        { label: 'Directory Comparison', accelerator: 'CmdOrCtrl+Shift+C', click: send('toggleCompare') },
        { label: 'Synchronized Browsing', accelerator: 'CmdOrCtrl+Shift+Y', click: send('toggleSync') },
        { label: 'Message Log', accelerator: 'CmdOrCtrl+Shift+L', click: send('toggleLog') },
        { label: 'Terminal', accelerator: 'Ctrl+`', click: send('toggleTerminal') },
        { type: 'separator' },
        { role: 'resetZoom' },
        { role: 'zoomIn' },
        { role: 'zoomOut' },
        { type: 'separator' },
        { role: 'togglefullscreen' },
        ...(app.isPackaged ? [] : [{ role: 'toggleDevTools' as const }]),
      ],
    },
    {
      label: '&Help',
      submenu: [
        { label: 'Check for Updates…', click: () => void updater.check(true) },
        { type: 'separator' },
        { label: 'About RemoteSSH', click: send('about') },
      ],
    },
  ]
  return Menu.buildFromTemplate(template)
}

if (!app.requestSingleInstanceLock()) {
  app.quit()
} else {
  app.on('second-instance', () => {
    if (window?.isMinimized()) window.restore()
    window?.focus()
  })

  void app.whenReady().then(() => {
    const controller = new Controller(app.getPath('userData'), cipher, () => window)
    const handlers = controller.handlers()
    for (const method of invokeMethods) {
      ipcMain.handle(method, (_event, ...args: unknown[]) => (handlers[method] as (...a: unknown[]) => unknown)(...args))
    }
    createWindow(controller)
    if (controller.settings.checkForUpdates) setTimeout(() => void updater.check(false), 5000)
    app.on('activate', () => {
      if (!window) createWindow(controller)
    })
    app.on('before-quit', () => controller.shutdown())
  })

  app.on('window-all-closed', () => app.quit())
}
