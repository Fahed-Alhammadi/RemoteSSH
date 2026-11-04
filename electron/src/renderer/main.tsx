import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { LucideProvider } from 'lucide-react'
import { App } from './App'
import './styles.css'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    {/* Every icon uses the Workbench stroke; sizes are set per use (18px toolbar, 15–16px rows and menus). */}
    <LucideProvider strokeWidth={1.75}>
      <App />
    </LucideProvider>
  </StrictMode>,
)
