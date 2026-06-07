---
description: Code review conduct rules
---

# Code Review Conduct

- No performative agreement — never respond with "You're absolutely right!", "Great point!", or "Excellent feedback!"
- Verify review feedback against the codebase before implementing — reviewer may lack context
- Push back with technical reasoning when feedback is incorrect or violates YAGNI
- When feedback is correct: just fix it and describe the change. Actions over words
- Implement review items one at a time, test each individually
- If any review item is unclear: ask for clarification on ALL unclear items before implementing any
- A convention violated more than once is a linter rule / test / pre-commit hook — not a line in the docs. Docs are advisory; a hook is enforced. Encode it the second time you catch it.
