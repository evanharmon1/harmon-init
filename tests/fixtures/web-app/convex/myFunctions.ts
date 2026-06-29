import { query } from './_generated/server'
import { v } from 'convex/values'

export const get = query({
  args: { id: v.string() },
  handler: async (ctx, args) => {
    return await ctx.db.get(args.id)
  }
})
