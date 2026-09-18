# Component Specification: [Component Name]

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

What this component does and its role within the feature.

## Requirements

### Functional

- [ ] Core capability: `<what it must do>`
- [ ] Input handling: `<what it accepts>`
- [ ] Output generation: `<what it produces>`
- [ ] Integration points: `<what it connects to>`

### Non-Functional

- Performance: `<target metrics>`
- Reliability: `<error/leak expectations>`
- Portability: `<platforms>`

## Contracts & Interfaces

> Contracts are expressed as Pascal type declarations. This section defines
> *what* crosses the boundary; the implementer decides the bodies. Do not put
> implementation code here.

### Public API

```pascal
type
  { Input contract. }
  T<Component>Input = record
    // required fields
    // optional fields and their defaults
  end;

  { Output contract: success and failure shapes. }
  T<Component>Output = record
    // success case
    // error case (e.g. an error code plus message)
  end;

  { Configuration contract. }
  T<Component>Config = record
    // required configuration
    // optional overrides
  end;

  { The component's external surface. }
  T<Component> = class
  public
    constructor Create(const AConfig: T<Component>Config);
    function Run(const AInput: T<Component>Input): T<Component>Output;
  end;
```

### Data Contracts

```pascal
type
  { Core data model. Essential fields only; relationships to other models. }
  T<Model> = record
    // ...
  end;

  { State snapshot and the transitions it supports. }
  T<Component>State = (csIdle, csRunning, csDone, csFailed);
```

### Event Contracts

Define callbacks/events the component emits. State whether they fire on the
caller's thread or the component's own thread, and what that means for the
callback.

```pascal
type
  TOutputKind = (okStarted, okStdout, okStderr, okFinished);

  { NOTE: invoked from the component's thread; the handler must be thread-safe. }
  T<Component>Event = procedure(const AText: string;
    AKind: TOutputKind; ACode: Integer) of object;
```

## Architecture

### Prior Art & Reuse

Which existing units (`src/hildegard.helper.*`), RTL/FCL facilities, native platform
features, or `deps/` units already cover part of this - and what genuinely
remains to be built. Apply the Ponytail ladder (`docs/guidelines/ponytail.md`)
and design only the gap.

### Component Boundaries

- **Responsibilities:** what this component owns
- **Dependencies:** what it needs from other units
- **Side effects:** external state it mutates

### Data Flow

1. **Input validation:** how incoming data is checked
2. **Processing:** the core transformation
3. **Output generation:** how results are produced
4. **Error handling:** failure modes and recovery

### Integration Patterns

- Synchronous vs asynchronous (threads, queues, callbacks)
- Ownership and lifetime of objects and threads
- How state is shared across threads and how it is guarded

## Validation Rules

### Input

- Required fields and their constraints
- Type and range checks
- Business-rule validation

### Output Guarantees

- Data integrity and format consistency
- Error reporting standards

## Error Handling

### Error Types

- **Validation errors:** invalid input
- **Business errors:** rule violations
- **System errors:** infrastructure failures
- **Timeout errors:** operation limits

### Error Contracts

```pascal
type
  { Error reporting contract. }
  T<Component>Error = record
    Code: Integer;      // stable, documented codes
    Message: string;    // human readable
    Detail: string;     // diagnostic detail
  end;
```

Common codes used across the harness (follow existing conventions):

- `0` success
- `124` timed out
- `128 + signal` killed by signal
- `130` cancelled

## Testing Requirements

> What to test; the implementer decides how. Each item should become a named
> fpcunit `TTestCase` method.

### Unit Tests

- [ ] Input validation and boundaries
- [ ] Core logic
- [ ] Error and timeout conditions
- [ ] Concurrency and thread-safety (where relevant)
- [ ] Resource cleanup (no leaks under `make test-leak`)

### Integration Tests

- [ ] Interaction with adjacent units
- [ ] Contract compliance at the boundary

## Performance Targets

- Latency/overhead, throughput, memory limits, concurrency limits

## Security Considerations

- Input sanitization, command injection, privilege, data handling

## Success Criteria

### Functional

- [ ] All contracts implemented
- [ ] All validation rules enforced
- [ ] All error scenarios handled
- [ ] All tests passing (`make check`)

### Quality

- [ ] Contract compliance verified
- [ ] Performance targets met
- [ ] No memory leaks
- [ ] Documentation complete

## Future Considerations

- Contract extensions, scalability, new integration patterns
