/* eslint-disable */

// @ts-nocheck

// Minimal stand-in for TanStack Router codegen (src/routeTree.gen.ts): real
// apps commit the generated file, exclude it from lint/format, and its module
// augmentation is what makes `createFileRoute('/')` type-check. This fixture
// copy registers just the '/' route so the fixture behaves like a real app.

import { Route as rootRouteImport } from './routes/__root'
import { Route as IndexRouteImport } from './routes/index'

const IndexRoute = IndexRouteImport.update({
  id: '/',
  path: '/',
  getParentRoute: () => rootRouteImport,
} as any)

declare module '@tanstack/react-router' {
  interface FileRoutesByPath {
    '/': {
      id: '/'
      path: '/'
      fullPath: '/'
      preLoaderRoute: typeof IndexRouteImport
      parentRoute: typeof rootRouteImport
    }
  }
}

export const routeTree = rootRouteImport._addFileChildren({
  IndexRoute,
})
