# Symphony

Repository-wide agent instructions. Sub-directories may add their own `AGENTS.md`
(for example [`elixir/AGENTS.md`](elixir/AGENTS.md)); those cover directory-specific
conventions, this file covers rules that apply to the whole repo.

## Pull Requests

The `pr-description-lint` workflow runs `mix pr_body.check` on every PR body and
fails the PR if the body does not match [`.github/pull_request_template.md`](.github/pull_request_template.md).
Treat the template as a hard contract, not a suggestion.

### PR body rules

- Start the body with the template. Do not paste working notes, changelogs, or
  scratch summaries above `#### Context`.
- Include all five headings, spelled exactly and in this order:
  `#### Context`, `#### TL;DR`, `#### Summary`, `#### Alternatives`, `#### Test Plan`.
- Remove every template placeholder comment. The body must not contain `<!--`
  anywhere — this is the most common failure.
- Leave no section empty.
- `#### Summary` and `#### Alternatives` need at least one `- ` bullet each.
- `#### Test Plan` needs at least one `- [ ]` / `- [x]` checkbox item.

### Required check before opening or updating a PR

Write the body to a file and validate it before it reaches GitHub:

```bash
cd elixir && mix pr_body.check --file /path/to/pr_body.md
gh pr create --body-file /path/to/pr_body.md   # or: gh pr edit <n> --body-file ...
```

`mix pr_body.check` must print `PR body format OK` first. Never hand-type the body
into `--body` or the web editor — that is how placeholders survive. If the check
already failed in CI, fix the body and re-run the command locally before pushing
the update.
