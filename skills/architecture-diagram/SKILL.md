---
name: architecture-diagram
description: Generate a professional architecture diagram from codebase analysis
argument-hint: "[output-path] [-- description]"
user-invocable: true
---

# Architecture Diagram

Generate a professional architecture diagram as a standalone HTML/SVG file by analyzing the current codebase.

## Input

Arguments via `$ARGUMENTS`:
- **No arguments**: analyze codebase, output to `architecture-diagram.html` in project root
- **`path/to/output.html`**: custom output path
- **`-- description text`**: skip codebase analysis, use the provided description instead
- **`path/to/output.html -- description text`**: both custom path and description

## Execution

Spawn the `architecture-diagram` agent with the following prompt, adapted based on arguments:

### When no description is provided (default — codebase analysis mode):

```
Analyze the codebase in the current working directory and generate an architecture diagram.

Output file: [resolved output path]

Follow your full Discovery → Generation workflow:
1. Explore the codebase to identify all components (frontend, backend, databases, infrastructure, external services)
2. Map relationships and data flows between components
3. Present the component inventory to the user and ask for confirmation
4. After confirmation, generate the HTML diagram file
5. Report the output file path

If docker-compose.yml or similar orchestration files exist, use them as the primary source of truth for services and their relationships.
```

### When a description is provided:

```
Generate an architecture diagram from this description:

[user's description]

Output file: [resolved output path]

Skip codebase analysis. Parse the description to identify components and relationships, then:
1. Present the component inventory to the user and ask for confirmation
2. After confirmation, generate the HTML diagram file
3. Report the output file path
```

## Agent Configuration

- **Agent**: `architecture-diagram`
- **Run in foreground** — the agent needs user confirmation before generating

## After Completion

Report the output path and suggest:
- Open in browser to view
- Print to PDF for sharing
- Run `/architecture-diagram` again with feedback to iterate
