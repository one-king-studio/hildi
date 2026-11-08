# Component Specification: Form Widgets v1

**Related Feature:** [FEATURE.md](FEATURE.md)
**Requested by:** the operator, reviewing the `/provider` dialog — *"the provider
modal is pretty bland. I think we need more reusable components."*
**Blocks:** card #38 (MCP add form), and the provider/agent lanes' existing forms.

## Purpose

A form container and form fields, with the behaviour of an HTML form: the
container owns submission and produces a field→value mapping; fields register
with a parent form and bubble `touched` / `valid` / `invalid`; on submit the form
broadcasts a validation pass and each field renders its own invalid state.

**The gap it closes.** Three forms already exist and each hand-rolled the same
machinery:

| Existing form | Duplicated |
| --- | --- |
| `HildiProviderForm.pas` | `TContainer` of `TPromptLine`s, index-based focus cycling with wrap, validation in the widget, `SetError`/`SetBusy`, a `RenderContent` override to paint the message, deferred-close callback |
| `HildiAgentForm.pas` | the same, again |
| MCP add form (card #38) | **not yet written — this is why it is blocked** |

A fourth copy is the point at which the duplication becomes permanent.

## Requirements

### Functional

- [ ] A `TForm` arranges fields and owns **submission**: on submit it validates
      every field, marks the invalid ones, and emits a name→value mapping **only**
      when all are valid.
- [ ] A field registers with its parent form at construction, and duplicate names
      are refused **at add time**, not discovered at submit.
- [ ] A field reports `Touched`, `FieldValid` and `ErrorText` to its form.
- [ ] A field renders its **own** invalid state; the form does not paint errors on
      a field's behalf.
- [ ] `Touched` is set on **blur**, not on keystroke.
- [ ] A field can read a **sibling's** value while validating (see rule 2).
- [ ] Four field kinds cover every existing need: text, pick-from-list, secret
      (masked, clearable), optional number.

### Non-Functional

- Performance: no per-frame allocation beyond text; a form of 10 fields costs the
  same per frame as 10 loose widgets.
- Reliability: no leaks; `make check` green.
- Portability: no terminal dependency in these units.
- **Compatibility:** `TPromptLine` stays as-is; `TTextField` wraps or reuses it
  rather than replacing it, so existing callers keep working.

## Contracts & Interfaces

> Types only. The implementer decides the bodies.

### The form

```pascal
type
  TFormState = (fsPristine, fsValid, fsInvalid);

  { The field→value mapping handed to OnSubmit. Ordered, so a caller can rely on
    registration order rather than sorting. }
  TFieldValueArray = array of record
    Name: string;
    Value: string;
  end;

  TFormSubmitEvent = procedure(const AValues: TFieldValueArray) of object;
  TFormEvent = procedure of object;

  { The container. Owns arrangement and submission; draws no chrome itself, so a
    caller can put it inside a TModal, a TPanel or nothing at all. }
  TForm = class(TContainer)
  public
    { Registers AField under AName. Returns the field for chaining.
      Duplicate AName => refused here, at add time. }
    function Add(AField: TFormField; const AName: string): TFormField;

    { Read a sibling during validation. '' when absent. }
    function ValueOf(const AName: string): string;
    function FieldNamed(const AName: string): TFormField;

    { Validate every field, mark the invalid ones, then either emit the mapping
      or fire OnInvalid. ONE entry point: a caller cannot submit without
      validating. }
    procedure Submit;

    function State: TFormState;
    procedure ClearErrors;         // e.g. after a server-side failure

    property OnSubmit: TFormSubmitEvent;
    property OnInvalid: TFormEvent;
    property OnDirty: TFormEvent;  // any field touched or changed
  end;
```

### The field

```pascal
  TFormField = class(TWidget)
  public
    { Registers with AForm. Nil is allowed — a field may be used standalone —
      but then it cannot take part in submission. }
    constructor Create(AForm: TForm; const AName: string);

    function Value: string; virtual; abstract;
    procedure SetValue(const AValue: string); virtual; abstract;

    { Whether THIS field's value is acceptable. May consult the form's ValueOf
      for a cross-field rule (rule 2). }
    function FieldValid: Boolean; virtual; abstract;

    { Why it is invalid. '' when valid. RENDERED BY THE FIELD. }
    function ErrorText: string; virtual; abstract;

    { Set on BLUR. A field that has never been touched shows no error even if
      its value would be rejected (rule 1). }
    property Touched: Boolean;

    { Label for a form-level summary or an accessibility hint. }
    property LabelText: string;
  end;
```

### The four kinds

```pascal
  { A single line of text. Reuses TPromptLine rather than replacing it. }
  TTextField = class(TFormField)
  public
    property Placeholder: string;
  end;

  { Cycles a known list with a chord; the value is the selected item. This is
    the provider/model pick, and it is deliberately a PICK: a free-typed name
    that does not resolve is how a broken row gets created. }
  TPickField = class(TFormField)
  public
    procedure SetItems(const AItems: TStringArray);
    property AllowEmpty: Boolean;   // "" is a valid choice (inherit)
  end;

  { Masked on screen, plain in value. With a clear action, because '' cannot
    mean both "leave it" and "delete it". }
  TSecretField = class(TFormField)
  public
    property Masked: Boolean;       // default True
    procedure Clear;                // marks for removal
    function WantsClear: Boolean;
  end;

  { OPTIONAL number: empty => Has=false. NOT zero. }
  TNumberField = class(TFormField)
  public
    property HasValue: Boolean;
    property AsFloat: Double;
    property AsInteger: Integer;
    property Whole: Boolean;        // reject 1.5
    property MinValue, MaxValue: Double;
  end;
```

## Architecture

### Prior Art & Reuse

- **`TPromptLine`** (`src/tui/widgets/TUIWidgetsPrompt.pas`) — already does text
  editing, a `Mask` property added for the API-key field, and caret handling.
  `TTextField` composes it; do not write a second editor.
- **`TContainer`** (`src/tui/widgets/TUIWidgetsPanel.pas`) — grid arrangement with
  `Auto`/`Fill`. `TForm` extends it rather than inventing layout.
- **`TFocusGroup`** — already moves focus with `Tab`/`Shift-Tab` and on click. A
  form should **use** it, not reimplement index arithmetic; the two existing
  forms both hand-rolled `FocusField`/`MoveFocus` with a wrap, which is exactly
  what `TFocusGroup` exists to prevent.
- **`TWidget`** — `HitTest`, `Measure`, `Render`, `HandleEvent`. A field is an
  ordinary widget; nothing in the protocol changes.
- **`OnBg`** (`TUITheme`) — every attribute in a field is derived, never literal.

### Component Boundaries

- `src/tui/widgets/TUIWidgetsForm.pas` — `TForm`, `TFormField`, the four kinds,
  and the `ParseOptFloat`/`ParseOptInt` helpers currently duplicated in
  `HildiAgentForm.pas`.
- **No dependency on `HildiStore` or any app unit.** The form deals in strings;
  mapping a field to a `TProviderRow` stays with the caller.

### Data Flow

1. Caller constructs a `TForm`, adds fields with names, and arranges it.
2. The operator types. Each keystroke updates a field's value; `Touched` stays
   false until the field is left.
3. Submit (a chord, a footer CTA, or the host calling `Submit`):
   the form walks its fields, calls `FieldValid` on each, and marks failures.
4. All valid → `OnSubmit(values)`. Any invalid → `OnInvalid`, and each failing
   field draws its own `ErrorText`.

## Validation Rules

### Input

- A duplicate field name is **refused when added**.
- `TNumberField`: unparseable → invalid with a message; out of range → invalid,
  **never clamped**.
- `TPickField`: a value not in its items is invalid unless `AllowEmpty`.

### Output Guarantees

- `OnSubmit` fires only when every field is valid; the mapping is in registration
  order.
- An untouched field never displays an error, even if its value is unacceptable.
- An unset `TNumberField` is absent from the mapping, not `"0"`.

## Error Handling

- Validation is a **state**, not an exception: an invalid form fires `OnInvalid`
  and stays open.
- A field's `ErrorText` is rendered by the field. (See the note below — this is
  the one rule that has already been violated once in this codebase.)

## Testing Requirements

> The implementer decides how. Each item is a named fpcunit case.

### Unit Tests

- [ ] A field registers with its form and `ValueOf` reads it back.
- [ ] A duplicate name is refused at `Add`, not at `Submit`.
- [ ] `Submit` with an invalid field fires `OnInvalid` and **not** `OnSubmit`.
- [ ] `Submit` with all valid fires `OnSubmit` with the mapping in order.
- [ ] An untouched invalid field renders no error; after blur it does.
- [ ] A cross-field rule: field B is invalid when field A has a given value.
- [ ] `TNumberField` empty → `HasValue = False` and absent from the mapping.
- [ ] `TNumberField` with `0` → `HasValue = True` and present as `"0"`.
- [ ] `TSecretField` with a mask renders no part of its value.
- [ ] `TSecretField.Clear` sets `WantsClear` but leaves the value empty.
- [ ] No leaks under `make test-leak`.

### Integration Tests

- [ ] `HildiProviderForm` rebuilt on `TForm` passes its existing suite
      unchanged — the strongest proof the abstraction actually fits, and it
      deletes ~400 lines from that unit.

## Three rules the existing code already paid for

1. **`Touched` is set on BLUR, not on keystroke.** Marking a field invalid before
   the operator has finished typing is hostile. Both existing forms clear the
   error on every keystroke — a workaround for the missing concept.

2. **`FieldValid` is pairwise, not per-field.** A model id is only meaningful with
   its provider (`openai/gpt-4o` is an OpenRouter id; the same string under
   another provider means nothing). A field must be able to see its siblings
   during validation, which is why `TForm.ValueOf` exists.

3. **The error must be RENDERED BY THE FIELD.** `HildiProviderForm` shipped with
   `FError` set and **nothing painting it** — every "name is required" went
   unseen for weeks, until a later commit added a `RenderContent` override. A
   field that can be invalid but cannot draw why is worse than no validation at
   all, because it looks like a hang.

## Success Criteria

- [ ] `TForm` + four field kinds exist in `src/tui/widgets/`, with no app
      dependency.
- [ ] Card #38 can build the MCP add form on it without a fifth hand-rolled form.
- [ ] `HildiProviderForm` and `HildiAgentForm` are rebuilt on it, and the
      duplicated focus/validation/error code is deleted.
- [ ] `make check` green.

## Out of Scope

- Nested forms, dynamic field removal, multi-step wizards.
- Async validation (a check that needs I/O). The provider form's connection check
  is host-side today and should stay there: the form deals in strings.
- Rich text or multi-line editors beyond `TPromptLine`.
