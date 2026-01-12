
# Review Commit

## Description

Check current git changes, analyze modifications, and generate commit message suggestions that comply with project standards.

## Execution Steps

1. **View modification status**
   - Run `git status` to view list of modified files
   - Identify modules and scope affected by changes

2. **View specific changes**
   - Run `git diff` to view unstaged changes
   - Run `git diff --cached` to view staged changes
   - Analyze the nature of changes (new feature, fix, refactor, etc.)

3. **Generate commit message**
   - Analyze change type per `conduct/GIT_COMMIT.md` standards
   - Determine commit type: feat/fix/refactor/docs/chore, etc.
   - Write concise and accurate title (under 50 characters)
   - If needed, write the reason for the change (one sentence)
   - If needed, write core changes list (sorted by importance)

4. **Output suggestions**
   - Present suggested commit message to user
   - Explain reasoning for choosing that type and description
   - Wait for user confirmation or modification

## Notes

- **Never auto-commit**: Only generate suggestions, never execute `git add` or `git commit`
- **Follow standards**: Strictly follow `conduct/GIT_COMMIT.md` format requirements
- **Use English**: Commit messages must be in English
- **Accuracy first**: If changes are complex, suggest user split into multiple commits
- **Check sensitive info**: If .env, credentials, or other sensitive files are found, warn user not to commit
- **Add AI signature**: Add code agent contribution signature at the end of commit message
- **List item principles**:
  - Avoid dogmatism, don't over-detail
  - Merge related changes, one logical point per list item
  - Example: ❌ List 5 items for delete, move, update details → ✅ Merge into one "Merge X into Y"
  - Concise over comprehensive
- **Simple change judgment (CRITICAL)**:
  - **Title only** situations:
    - UI adjustments: remove/add/adjust single component, change layout columns, etc.
    - Simple refactoring: remove unused import, remove single feature, rename variable
    - Config changes: update 1-3 config items, adjust single parameter
    - Single-purpose changes: changes that can be explained in one sentence
  - **Bad examples**:
    - ❌ `fix: restrict to Sepolia\n- Remove mainnet\n- Remove arbitrum\n- Remove base`
    - ❌ `refactor: remove Token Holders\n\nRemoved the card...\nUpdated grid layout...`
  - **Good examples**:
    - ✅ `fix: restrict wallet connection to Sepolia testnet only`
    - ✅ `refactor: remove Token Holders card from Users tab`
    - ✅ `style: adjust header search component layout`
  - **When to use lists**: multiple modules / multiple logical points / complex cause-effect relationships

## Example Output

**Complex changes (with reason and list)**:
```
Suggested commit message:

fix: correct unit conversion in price calculations

Division by 1e12 should be multiplication in reserve price formula.

- Fix reserve price calculation in ido_service, user_service, token_service
- Update price display to show correct values

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>

Reasoning:
Type 'fix': Bug fix in price calculation, affects multiple services
```

**Simple changes (title only)**:
```
Suggested commit message:

fix: restrict wallet connection to Sepolia testnet only

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>

Reasoning:
Simple config change, title clearly explains everything, no need for reason and list
```
