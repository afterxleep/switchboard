You are working on {{ISSUE_IDENTIFIER}}: {{ISSUE_TITLE}}.

PR #{{PR_NUMBER}} has merge conflicts with the main branch.

## Your Task

Rebase this branch onto main and resolve all conflicts. Do not lose any of your work.

git fetch origin
git rebase origin/main

Resolve conflicts, run swift test, commit, force-push.

Before committing:
git config user.email "james@flowdeck.studio"
git config user.name "James Harper"

## Important Rules
- DO NOT post any GitHub PR comments — ever
- DO NOT use `gh pr comment` or any GitHub CLI comment command
- Communication is handled by a separate agent — your job is code only
