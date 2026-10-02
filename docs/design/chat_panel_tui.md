# Chat Panel TUI

```
╭────────────────────────────────────────────────────────────────────────────╮
│ ╭────────────────────────────────────────────────────────────────────────╮ │
│ │ This is the user's message. It should be rendered with a slightly      │ ┃
│ │ lighter background to distinguish it from the rest of the contnt. Make │ ┃
│ │ The border be a dimmed accent color to not make it too distracting.    │ ┃
│ │                                                                        │ ┃
│ │ The chat input box below should also have the same background and      │ ┃
│ │ border color combination.                                              │ ┃
│ ╰════════════════════════════════════════════════════════════════════════┘ ┃
│                                                                            ┃
│  ─ Thought · 8.2s ─────────────────────────────────────────────────── ▼ ─  ┃
│                                                                            ┃
│  Assistant message between thoughts                                        ┃
│                                                                            ┃
│ ┌─ Thought · 8.2s ─────────────────────────────────────────────────── ▲ ─┐ ┃
│ │ This is an expanded though block. Then entire block is clickable even  │ ┃
│ │ when collapsed and clicking the block toggles between expand and       │ ┃
│ │ collapsed. The borders and text in this entire block should be renderd │ ┃
│ │ with a dimmed color with the default background color. The same goes   │ ┃
│ │ for the collapsed form where it just falls into the background when    │ ┃
│ │ scanning the messages.                                                 │ ┃
│ └────────────────────────────────────────────────────────────────────────┘ ┃
│                                                                            ┃
│  ═ Reason for tool call (collapsed) ═════════════════════════════════ ▼ ═  ┃
│                                                                            ┃
│ ┌─ Reason for tool call (expanded) ────────────────────────────────── ▲ ─┐ ┃
│ │ $ ls .                                                                 | ┃
│ │                                                                        | ┃
│ │ AGENTS.md  Makefile   deps       examples   src                        | ┃
│ │ (this entire block should be a darker color and full contrast text)    | ┃
│ └────────────────────────────────────────────────────────────────────────┘ ┃
│                                                                            ┃
│  Final assistant message. Some note about the UI -- the scrollbar ----->   ┃
│  is the same character but should be rendered in different colors with a   │
│  darker (closer to background) track and lighter (contrasting) thumb       │
│                                                                            │
│  A multi-paragraph response simply apply a gap between. This should be     │
│  handled by a markdown to terminal render in the future, but the raw text  │
│  from the LLM should already contain the right amount of blank lines to    │
│  denote a new content block.                                               │
│                                                                            │
│  ✵ Thinking                                                                │
│                                                                            │
│                                                                            │
│                                                                            │
│                                                                            │
│                                                                            │
│                                                                            │
│                                                                            │
│  this line can additionally be used to display other stats, hints, or CTAs │
╭════════════════════════════════════════════════════════════════════════════╮
│ › Make this cursor blink --> █                                             │
│                                                                            │
│ Agent Name · Model v1 Provider · low                                       │
╰────────────────────────────────────────────────────────────────────────────╯
 /current/working/dir            ctrl+p commands  ctrl+b sidebar  ctrl+/ help
```

## Animated thinking indicator

Use the following character sequence: `∙ • ● ◉ ❂ ✴ ✵ ✶ ✷ ✸ ✹ ✺ ❋` for a burst
of sparkles in a bright color.