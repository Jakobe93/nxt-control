# nxt-control

The admin menu.

## Read first

The shared guides live in the private repo `Jakobe93/nxt-md`. They are not copied
here: attach that repo read-only at the start of a session and read

- `WORKING.md` — how work is done on this server. Always.
- `THEME.md` and `ui/` — before designing or building any UI.
- `CONTRACTS.md` — before adding, changing, removing or calling an export, event or callback.

If `nxt-md` cannot be attached, say so and work from the short rules below.

## Rules that always apply

- Mockup before build: no production UI code until a render is approved.
- Build only what was asked. No extra visual treatments.
- Mark anything unconfirmed `[VERIFY]`; say what has not been tested in game.
- This thread owns this repo only. Changes for another resource go to that repo as an issue or pull request.
- Check this repo's open issues and pull requests at the start of a session.
- Push only when Jakobe says so, except for what WORKING.md rule 10 lists as already having his go-ahead (a bug fix among them). Merge your own pull requests by fast-forward, never with GitHub's merge button, and delete the branch (WORKING.md rule 11).
- An idea Jakobe mentions, for any script, existing or not, is written down in `nxt-md` `ideas/<script-name>/` when it comes up; read that folder first (WORKING.md, Ideas).
- A change players would notice gets a `devlog:` line in its commit message: the line Serverboard drafts for the changelog (WORKING.md, The changelog line).
- A file keeps the line endings it has: change it with exact replacements, never by writing the whole file out again (WORKING.md, Line endings).
- Keep the README and reference docs current: major design changes, changes to exports or events, new features, and any change to how the UI looks (WORKING.md rule 16).
- Load the account skill that fits before code work: `lua-best-practices`, `typescript-best-practices`, `fivem-resource-architecture`, `ponytail`, and `deslop` before committing (WORKING.md, Skills).

## This repo

- Resource name in game: `nxt-control`
- No NUI.

## Checks

Run these before every merge. `nxt checks` (`.github/workflows/nxt-checks.yml`) runs the same on GitHub only when started by hand:

```
python3 .github/nxt/nxt_check.py lua                 # Lua syntax, Cfx extensions allowed
python3 .github/nxt/nxt_check.py contracts --check   # contracts.json is current
python3 .github/nxt/nxt_check.py required            # the files every resource repo must have
python3 .github/nxt/nxt_check.py eol                 # no file's line endings were converted
```

`.github/nxt/` and the workflow are copies from `nxt-md`. Change them there, not here.

## Contracts

`contracts.json` lists what this resource provides to others and what it calls on them.
It is generated: after changing an export, net event or ox_lib callback, run
`python3 .github/nxt/nxt_check.py contracts` and commit the result. If something was
removed or renamed, look up who uses it in `CONTRACTS.md` (in `nxt-md`) and open an
issue on each of those repos before merging.
