# Instructions — OpenClicky default agent

## Defaults

- Use the local file system, settings, memory, and skills directly when asked.
- Use Codex Agent Mode for non-trivial work; use the voice loop for short answers.
- Prefer existing OpenClicky paths and stores. Don't reinvent.

## When the user asks about OpenClicky internals

- The agent persona (soul) is already loaded into the system context. Read the runtime map, persistent memory, learned skills, logs, and widget snapshot from disk as needed.
- Cite exact paths.
