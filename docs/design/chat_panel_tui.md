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
│ Make this cursor blink --> █                                               │
│                                                                            │
│ Agent Name · Model v1 Provider · low                                       │
╰────────────────────────────────────────────────────────────────────────────╯
 /current/working/dir            ctrl+p commands  ctrl+b sidebar  ctrl+/ help
```

## Animated thinking indicator

Use the following character sequence: `∙ • ● ◉ ❂ ✴ ✵ ✶ ✷ ✸ ✹ ✺ ❋` for a burst
of sparkles in a bright color.

While the model reasons, a live block titled `Thinking...` shows the tail of the
reasoning: the last up to six lines, prefixed with a `...` line when there is
more above. It is not clickable. When the reasoning is done and persisted, it
settles into a collapsed `Thought` block that expands like any other.

## Modals

```
╭─ Approval needed ───────────────────────────────────╮
│ reason: free the build dir before the deploy        │
│                                                     │
│   tool details go here with darker background       │
│                                                     │
│ → allow once                                     1  │
│ ◦ always this exact command                      2  │
│ ◦ always command with any arguements             3  │
│                                                     │
│ scope: workspace                         tab/g/w/s  │
├─────────────────────────────────────────────────────┤ 
│                           enter accept   esc deny   │
╰═════════════════════════════════════════════════════╯
```

The above example showcases the approval modal. A few things to note about it.

1. It has a specific section for the accept and deny actions
2. The main actions should have the keybinding dimmer than the action
3. The choices are left aligned with the current choice indicated with an arrow
4. The current choice text is brighter than the unselected choice (maybe highlighted instead)
5. The choice keybindings are right aligned and dimmed
6. The bullets and the 'scope' label are dimmer than the choices
7. The scope keybindings are right aligned and dimmed
8. The model's `reason:` sits beneath the title, its label dimmed and its text
   normal; when there is no reason the value is a dimmed placeholder
9. The tool details sit on the darker (sunken) background, wrapped to the
   dialog's width and compacted when long, so a big command cannot grow the
   dialog without bound
10. A blank line separates the reason from the details, and the details carry
    inline padding on each side
11. The dialog keeps four columns and four rows clear of the screen edge
12. The details are the tool's own summary of the call (`read test.txt:5-30`),
    not a generic dump

Overall there should be 3 font color choices
1. normal for bullets and labels
2. dimmed for keybindings
3. the soft accent for active values (a quieter blue, not the bright accent)