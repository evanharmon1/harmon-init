import { createFileRoute } from '@tanstack/react-router'

export const Route = createFileRoute('/')({
  loader: () => ({ ok: true }),
  component: Index
})

function Index() {
  return <h1>Home</h1>
}
