# Issue tracker: Local Markdown

Issues and PRDs for this repo live as markdown files in `.scratch/`. There is no issue tracker
service — create and read files.

The repository itself is still hosted on GitHub, so pull requests can arrive from outside
contributors. They are not the tracker and are not triased here.

## Conventions

- One feature per directory: `.scratch/<feature-slug>/`
- The PRD is `.scratch/<feature-slug>/spec.md`
- Implementation issues are one file per ticket at `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01` — never a single combined tickets file
- Triage state is recorded as a `Status:` line near the top of each issue file (see `triage-labels.md` for the role strings)
- Comments and conversation history append to the bottom of the file under a `## Comments` heading
- `.scratch/` is **committed**. It is the tracker of record, not scratch space.

## Naming

- **PRDs** are titled `PRD: <feature>` in their first heading.
- **Tickets** split from a PRD are numbered consecutively per PRD and each carries a `Part of: .scratch/<feature-slug>/spec.md` line near the top of the body.

## Reading and writing

- **Publish a PRD**: create `.scratch/<feature-slug>/spec.md`.
- **Publish a ticket**: create `.scratch/<feature-slug>/issues/<NN>-<slug>.md`.
- **Fetch a ticket**: read the file at the referenced path. The user will normally pass the path or the ticket number.
- **Comment**: append to the file under `## Comments`.
- **Change triage state**: edit the `Status:` line.
- **Close**: set `Status:` to `wontfix` or move the file to `.scratch/<feature-slug>/issues/closed/`.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a file with one **child** file per ticket.

- **Map**: `.scratch/<effort>/map.md` — the Notes / Decisions-so-far / Fog body.
- **Child ticket**: `.scratch/<effort>/issues/NN-<slug>.md`, numbered from `01`, with the question in the body. A `Type:` line records the ticket type (`research`/`prototype`/`grilling`/`task`); a `Status:` line records `claimed`/`resolved`.
- **Blocking**: a `Blocked by: NN, NN` line near the top. A ticket is unblocked when every file it lists is `resolved`.
- **Frontier**: scan `.scratch/<effort>/issues/` for files that are open, unblocked and unclaimed; first by number wins.
- **Claim**: set `Status: claimed` and save before any work.
- **Resolve**: append the answer under an `## Answer` heading, set `Status: resolved`, then append a context pointer to the map's Decisions-so-far in `map.md`.

## When a skill says "publish to the issue tracker"

Create a file under `.scratch/`.

## When a skill says "fetch the relevant ticket"

Read the file at the referenced path.
