# Plate Game (fictional — not a real registration checker)
## Setup (all free)
1. supabase.com → New project (Free). SQL Editor → paste `supabase/migrations/001_game.sql` → Run.
2. Authentication → Providers → Email: turn OFF "Confirm email" for instant signup (optional).
3. Project Settings → API: copy URL + anon key into `.env` (see `.env.example`).
4. `npm install && npm run dev` to test locally.
5. Deploy: push to GitHub → vercel.com → Import → add the two env vars → Deploy. You get `project.vercel.app`.
## Security model
Clients can only SELECT (RLS). Every write runs through SECURITY DEFINER functions using auth.uid(), row locks, a PRIMARY KEY on `plates.plate` (global uniqueness), a partial unique index (one active listing per plate), and `CHECK(balance>=0)`.
## Not yet implemented
Auctions, chat, player-to-player trades, missions/quests, achievements, lucky hours, valuation by demand, profile pages, sounds, notifications.
