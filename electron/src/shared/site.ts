import type { Site } from './types'

export function newID(): string {
  return crypto.randomUUID().toUpperCase()
}

export function makeSite(fields: Partial<Site> = {}): Site {
  return {
    id: newID(),
    name: 'New site',
    folder: '',
    host: '',
    port: 0,
    serverProtocol: 'sftp',
    encryption: 'explicitIfAvailable',
    logonType: 'normal',
    user: '',
    keyFilePath: '',
    transferMode: 'passive',
    defaultLocalDirectory: '',
    defaultRemoteDirectory: '',
    comments: '',
    trustInvalidCertificate: false,
    ...fields,
  }
}

/** Fills in fields missing from older or foreign site JSON. */
export function normalizeSite(raw: Partial<Site>): Site {
  const site = makeSite(raw)
  site.id = String(site.id).toUpperCase()
  return site
}

export function effectivePort(site: Site): number {
  if (site.port > 0) return site.port
  if (site.serverProtocol === 'ftp' && site.encryption === 'requireImplicit') return 990
  return site.serverProtocol === 'sftp' ? 22 : 21
}

export function effectiveUser(site: Site): string {
  return site.logonType === 'anonymous' ? 'anonymous' : site.user
}

export function displayAddress(site: Site): string {
  const scheme = site.serverProtocol === 'sftp' ? 'sftp' : site.encryption === 'requireImplicit' ? 'ftps' : 'ftp'
  const user = effectiveUser(site)
  return `${scheme}://${user ? `${user}@` : ''}${site.host}:${effectivePort(site)}`
}

export class InputError extends Error {}

interface QuickConnectInput {
  site: Site
  password: string
  initialPath: string | null
}

function decode(s: string): string {
  try {
    return decodeURIComponent(s)
  } catch {
    return s
  }
}

/**
 * Parses quickconnect input. The host field may carry a scheme and credentials,
 * e.g. `sftp://user:pass@example.com:2222/var/www`.
 */
export function parseQuickConnect(rawHost: string, user: string, password: string, port: string): QuickConnectInput {
  let host = rawHost.trim()
  if (!host) throw new InputError('You have to enter a hostname.')
  const site = makeSite({ name: host, serverProtocol: 'ftp', logonType: 'normal', user })
  let pass = password
  let initialPath: string | null = null

  const schemeAt = host.indexOf('://')
  if (schemeAt >= 0) {
    const scheme = host.slice(0, schemeAt).toLowerCase()
    host = host.slice(schemeAt + 3)
    switch (scheme) {
      case 'ftp': site.serverProtocol = 'ftp'; site.encryption = 'explicitIfAvailable'; break
      case 'ftpes': site.serverProtocol = 'ftp'; site.encryption = 'requireExplicit'; break
      case 'ftps': site.serverProtocol = 'ftp'; site.encryption = 'requireImplicit'; break
      case 'sftp': case 'ssh': site.serverProtocol = 'sftp'; break
      default:
        throw new InputError('Invalid protocol specified. Valid protocols are: ftp://, ftps://, ftpes://, sftp://')
    }
  }

  const slash = host.indexOf('/')
  if (slash >= 0) {
    initialPath = decode(host.slice(slash))
    host = host.slice(0, slash)
  }
  const at = host.lastIndexOf('@')
  if (at >= 0) {
    const credentials = host.slice(0, at)
    host = host.slice(at + 1)
    const colon = credentials.indexOf(':')
    if (colon >= 0) {
      site.user = decode(credentials.slice(0, colon))
      pass = decode(credentials.slice(colon + 1))
    } else {
      site.user = decode(credentials)
    }
  }
  // host:port, with IPv6 literals in brackets
  if (host.startsWith('[') && host.includes(']')) {
    const close = host.indexOf(']')
    const after = host.slice(close + 1)
    if (after.startsWith(':') && /^\d+$/.test(after.slice(1))) site.port = Number(after.slice(1))
    host = host.slice(1, close)
  } else {
    const colon = host.lastIndexOf(':')
    if (colon >= 0 && /^\d+$/.test(host.slice(colon + 1))) {
      site.port = Number(host.slice(colon + 1))
      host = host.slice(0, colon)
    }
  }

  const explicitPort = Number(port.trim())
  if (port.trim() && Number.isInteger(explicitPort) && explicitPort > 0) site.port = explicitPort
  if (!(site.port >= 0 && site.port <= 65535)) throw new InputError('Invalid port given.')
  if (site.port === 22 && schemeAt < 0) site.serverProtocol = 'sftp'

  site.host = host
  site.name = host
  if (!site.user || site.user === 'anonymous') {
    site.logonType = !site.user && !pass && site.serverProtocol === 'ftp' ? 'anonymous' : 'normal'
  }
  return { site, password: pass, initialPath }
}
