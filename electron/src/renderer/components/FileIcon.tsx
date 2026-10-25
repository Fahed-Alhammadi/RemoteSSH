import {
  Braces,
  Database,
  File,
  FileArchive,
  FileAudio,
  FileCode,
  FileImage,
  FileKey,
  FileSpreadsheet,
  FileText,
  FileVideo,
  Folder,
  FolderSymlink,
  HardDrive,
  Package,
  Terminal,
  type LucideIcon,
} from 'lucide-react'

type Kind = { icon: LucideIcon; color: string }

const kinds: Record<string, Kind> = {
  image: { icon: FileImage, color: 'var(--c-purple)' },
  video: { icon: FileVideo, color: 'var(--c-pink)' },
  audio: { icon: FileAudio, color: 'var(--c-pink)' },
  archive: { icon: FileArchive, color: 'var(--c-orange)' },
  code: { icon: FileCode, color: 'var(--c-blue)' },
  data: { icon: Braces, color: 'var(--c-teal)' },
  sheet: { icon: FileSpreadsheet, color: 'var(--c-green)' },
  key: { icon: FileKey, color: 'var(--c-yellow)' },
  db: { icon: Database, color: 'var(--c-teal)' },
  shell: { icon: Terminal, color: 'var(--c-green)' },
  package: { icon: Package, color: 'var(--c-orange)' },
  text: { icon: FileText, color: 'var(--c-muted)' },
}

const byExtension: Record<string, keyof typeof kinds> = {}
const groups: Record<keyof typeof kinds, string> = {
  image: 'png jpg jpeg gif webp svg bmp ico tif tiff heic avif psd',
  video: 'mp4 mov mkv avi webm m4v wmv flv',
  audio: 'mp3 wav flac aac ogg m4a opus wma',
  archive: 'zip tar gz tgz bz2 xz 7z rar zst lz4',
  code: 'js mjs cjs ts tsx jsx py rb go rs java kt swift c h cpp hpp cs php html htm css scss vue svelte lua pl r dart',
  data: 'json yaml yml toml xml ini conf cfg env plist',
  sheet: 'csv tsv xls xlsx ods numbers',
  key: 'pem key crt cer der p12 pfx pub ppk gpg asc',
  db: 'sql sqlite sqlite3 db mdb',
  shell: 'sh bash zsh fish ps1 bat cmd',
  package: 'deb rpm apk dmg pkg msi exe appimage jar war whl',
  text: 'txt md markdown log rtf pdf doc docx odt pages',
}
for (const [kind, exts] of Object.entries(groups)) for (const ext of exts.split(' ')) byExtension[ext] = kind

/** Icon + tint for a file name (pure lookup, cheap enough for every row). */
export function fileKind(name: string, isDirectory: boolean, isLink: boolean): Kind {
  if (isDirectory) return { icon: isLink ? FolderSymlink : /^[A-Z]:\\$/.test(name) ? HardDrive : Folder, color: 'var(--c-folder)' }
  const lower = name.toLowerCase()
  if (lower.startsWith('id_') || lower === 'authorized_keys' || lower === 'known_hosts') return kinds.key
  const dot = lower.lastIndexOf('.')
  const kind = dot >= 0 ? byExtension[lower.slice(dot + 1)] : undefined
  return kind ? kinds[kind] : { icon: File, color: 'var(--c-muted)' }
}

export function FileIcon({ name, isDirectory, isLink }: { name: string; isDirectory: boolean; isLink: boolean }) {
  const { icon: Icon, color } = fileKind(name, isDirectory, isLink)
  return <Icon size={16} strokeWidth={1.75} color={color} fill={isDirectory ? 'var(--c-folder-fill)' : 'none'} />
}
