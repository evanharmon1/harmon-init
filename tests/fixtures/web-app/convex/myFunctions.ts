import { query } from './_generated/server'
import { v } from 'convex/values'

export const get = query({
  args: { id: v.string() },
  handler: (_ctx, args) => args.id
})
