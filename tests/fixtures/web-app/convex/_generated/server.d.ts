/* Minimal stand-in for Convex codegen output (convex/_generated/): real apps
   commit the full generated .js + .d.ts and exclude the directory from lint.
   This stub is just enough for the fixture's imports to resolve with types. */
import { queryGeneric, mutationGeneric } from 'convex/server'

export declare const query: typeof queryGeneric
export declare const mutation: typeof mutationGeneric
