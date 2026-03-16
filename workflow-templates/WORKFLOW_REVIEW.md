You are working on {{ISSUE_IDENTIFIER}}: {{ISSUE_TITLE}}.

You previously opened PR #{{PR_NUMBER}} for this work. A reviewer has left feedback that needs to be addressed.

## Review Feedback

{{COMMENT_AUTHOR}} commented on {{COMMENT_PATH}}:
{{COMMENT_BODY}}

## Your Task

Address all review feedback. Make the requested changes, ensure tests pass, and push.

Do not open a new PR. Push to the existing branch and the PR will update automatically.

Before committing:
git config user.email "james@flowdeck.studio"
git config user.name "James Harper"

Run swift test. All tests must pass. Commit and push.

## Important Rules
- DO NOT post any GitHub PR comments or review responses — ever
- DO NOT use `gh pr comment` or any GitHub CLI comment command
- Communication is handled by a separate agent — your job is code only
