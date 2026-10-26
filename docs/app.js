// RemoteSSH website: the hero handoff and download links from the latest GitHub release.
const REPO = 'Fahed-Alhammadi/RemoteSSH'
const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches

// Hero: index.html travels from "Your computer" to "Your server" once, then the finished state stays.
function playHandoff() {
  const handoff = document.querySelector('.handoff')
  if (!handoff) return
  if (reduceMotion) return handoff.classList.add('done')
  const lane = handoff.querySelector('.lane')
  const chip = handoff.querySelector('.chip')
  setTimeout(() => {
    const padding = parseFloat(getComputedStyle(lane).paddingLeft) * 2
    handoff.style.setProperty('--travel', `${Math.max(0, lane.clientWidth - chip.offsetWidth - padding)}px`)
    handoff.classList.add('play')
    setTimeout(() => handoff.classList.replace('play', 'done'), 1500)
  }, 700)
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

playHandoff()
wireDownloads()
