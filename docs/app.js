// RemoteSSH website: the hero handoff and download links from the latest GitHub release.
const REPO = 'Fahed-Alhammadi/RemoteSSH'
const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches

// index.html travels from "Your computer" to "Your server" once, when the panel scrolls into view.
// The finished state is the page's default (also without JS); .armed shows the start until it plays.
// Under reduced motion only the finished state is shown.
function playHandoff() {
  const handoff = document.querySelector('.handoff')
  if (!handoff || reduceMotion || !('IntersectionObserver' in window)) return
  const lane = handoff.querySelector('.lane')
  const chip = handoff.querySelector('.chip')
  handoff.classList.add('armed')
  const observer = new IntersectionObserver((entries) => {
    if (!entries.some((e) => e.isIntersecting)) return
    observer.disconnect()
    setTimeout(() => {
      const padding = parseFloat(getComputedStyle(lane).paddingLeft) * 2
      handoff.style.setProperty('--travel', `${Math.max(0, lane.clientWidth - chip.offsetWidth - padding)}px`)
      handoff.classList.add('play')
      setTimeout(() => handoff.classList.remove('play', 'armed'), 1500)
    }, 300)
  }, { threshold: 0.6 })
  observer.observe(handoff)
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

// The parsed release is kept for an hour, so repeat visits fill the links at once and spare the API's rate limit.
const CACHE_KEY = 'remotessh.release'
const CACHE_TTL = 60 * 60 * 1000

function readCache() {
  try {
    const cached = JSON.parse(localStorage.getItem(CACHE_KEY) || 'null')
    if (cached && typeof cached.at === 'number' && cached.release) return cached
  } catch {}
  return null
}

function writeCache(release) {
  try {
    localStorage.setItem(CACHE_KEY, JSON.stringify({ at: Date.now(), release }))
  } catch {}
}

function timeoutSignal(ms) {
  if (typeof AbortSignal !== 'undefined' && typeof AbortSignal.timeout === 'function') return AbortSignal.timeout(ms)
  if (typeof AbortController === 'undefined') return undefined
  const controller = new AbortController()
  setTimeout(() => controller.abort(), ms)
  return controller.signal
}

// Only what the page uses, so the cache stays small.
function trimRelease(data) {
  return {
    tag_name: String(data.tag_name || ''),
    assets: (Array.isArray(data.assets) ? data.assets : []).map((a) => ({ name: a.name, size: a.size, browser_download_url: a.browser_download_url })),
  }
}

function formatSize(bytes) {
  return bytes >= 1e6 ? `${Math.round(bytes / 1e6)} MB` : `${Math.round(bytes / 1e3)} KB`
}

// Safe to call twice (cached, then fresh): sizes are updated in place.
function applyRelease(release, os, hero) {
  const version = String(release.tag_name || '').replace(/^v/, '')
  const find = (pattern) => (release.assets || []).find((a) => new RegExp(pattern).test(a.name))

  for (const link of document.querySelectorAll('a[data-asset]')) {
    const asset = find(link.dataset.asset)
    if (!asset) continue
    link.href = asset.browser_download_url
    let size = link.querySelector('.size')
    if (!size) {
      size = document.createElement('span')
      size.className = 'size'
      link.append(size)
    }
    size.textContent = formatSize(asset.size)
  }
  if (os) {
    const asset = find(HERO_ASSET[os])
    if (asset) hero.href = asset.browser_download_url
  }
  if (version) {
    document.getElementById('release-note').textContent =
      `Version ${version}, for macOS 15+, Windows 10+ and Linux.`
    document.getElementById('download-lede').textContent =
      `Version ${version}, free for every platform. Every release includes all of them, and the apps update themselves.`
  }
}

async function wireDownloads() {
  const os = detectOS()
  const hero = document.getElementById('hero-download')
  if (os) {
    hero.querySelector('.cta-label > span').textContent = `Download for ${OS_LABEL[os]}`
    document.querySelector(`.platform[data-os="${os}"]`)?.classList.add('current')
  }

  const cached = readCache()
  if (cached) applyRelease(cached.release, os, hero)
  const age = cached ? Date.now() - cached.at : Infinity
  if (age >= 0 && age < CACHE_TTL) return

  // Without the API (offline, rate-limited, slow), every link still points at the latest release page.
  let release
  try {
    const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
      headers: { Accept: 'application/vnd.github+json' },
      signal: timeoutSignal(5000),
    })
    if (!res.ok) return
    release = trimRelease(await res.json())
  } catch {
    return
  }
  writeCache(release)
  applyRelease(release, os, hero)
}

playHandoff()
wireDownloads()
