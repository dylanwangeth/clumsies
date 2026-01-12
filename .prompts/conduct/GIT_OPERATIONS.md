
# Git Operation Permissions

**Core Principle**: Never proactively commit code for the user.

## Prohibited

- Executing `git add`
- Executing `git commit`
- Executing `git push`
- Any other git commit-related operations

## Allowed

- Executing `git status` to view status
- Executing `git diff` to view changes
- Executing `git log` to view history
- Other read-only git commands

## Exception

Only execute git commit operations when the user explicitly requests it.
