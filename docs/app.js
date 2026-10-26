// RemoteSSH website: the typed Quickconnect hero and download links from the latest GitHub release.
const REPO = 'Fahed-Alhammadi/RemoteSSH'
const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches

// Hero: type the address, then show the connection log line by line (once, on load).
function playConsole() {
  const consoleEl = document.querySelector('.console')
  const typed = document.getElementById('typed')
  const log = document.getElementById('log')
  if (!consoleEl || !typed || !log) return
  const finish = () => {
    log.classList.remove('typing')
    consoleEl.classList.add('connected')
  }
  if (reduceMotion) return finish()

  const text = typed.textContent
  const lines = [...log.children]
  typed.textContent = ''
  log.classList.add('typing')
  let i = 0
  const typeNext = () => {
    typed.textContent = text.slice(0, ++i)
    if (i < text.length) return setTimeout(typeNext, 38)
    lines.forEach((line, n) => setTimeout(() => {
      line.classList.add('shown')
      if (n === lines.length - 1) finish()
    }, 350 + n * 420))
  }
  setTimeout(typeNext, 500)
}

function detectOS() {
  const platform = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || ''
  const ua = navigator.userAgent
  if (/mac/i.test(platform) && !/iphone|ipad/i.test(ua)) return 'mac'
  if (/win/i.test(platform)) return 'windows'
  if (/linux/i.test(platform) && !/android/i.test(ua)) return 'linux'
  return null
}

const OS_LABEL = { mac: 'macOS', windows: 'Windows', linux: 'Linux' }
// The file the hero button offers on each system.
const HERO_ASSET = { mac: '-macos\\.zip$', windows: '-win-x64\\.exe$', linux: '-linux-x86_64\\.AppImage$' }

function formatSize(bytes) {
  return bytes >= 1e6 ? `${Math.round(bytes / 1e6)} MB` : `${Math.round(bytes / 1e3)} KB`
}

async function wireDownloads() {
  const os = detectOS()
  const hero = document.getElementById('hero-download')
  if (os) {
    hero.textContent = `Download for ${OS_LABEL[os]}`
    document.querySelector(`.platform[data-os="${os}"]`)?.classList.add('current')
  }

  // Without the API (offline, rate-limited), every link still points at the latest release page.
  let release
  try {
    const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers: { Accept: 'application/vnd.github+json' } })
    if (!res.ok) return
    release = await res.json()
  } catch {
    return
  }
  const version = String(release.tag_name || '').replace(/^v/, '')
  const find = (pattern) => (release.assets || []).find((a) => new RegExp(pattern).test(a.name))

  for (const link of document.querySelectorAll('a[data-asset]')) {
    const asset = find(link.dataset.asset)
    if (!asset) continue
    link.href = asset.browser_download_url
    const size = document.createElement('span')
    size.className = 'size'
    size.textContent = formatSize(asset.size)
    link.append(size)
  }
  if (os) {
    const asset = find(HERO_ASSET[os])
    if (asset) hero.href = asset.browser_download_url
  }
  if (version) {
    document.getElementById('release-note').textContent =
      `Version ${version}, for macOS 15+, Windows 10+ and Linux. MIT licensed.`
    document.getElementById('download-lede').textContent =
      `Version ${version} includes all platforms. Pick the file for your system.`
  }
}

playConsole()
wireDownloads()
