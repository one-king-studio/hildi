A paragraph that refers to a footnote.[^note] And again.[^note]

[^note]: The footnote definition itself, which has no v1 equivalent and must
    report lossy through the compat adapter.

[shared]: https://example.com/shared "The shared title"

A [shared link][shared] and a second [use][shared] of the same definition.

$$
E = mc^2
$$

:::callout
A custom block whose body is real markdown:

- one
- two
:::

<div class="note">
  <p>Raw HTML, preserved verbatim and never interpreted.</p>
</div>

Term one
: Its definition, which may run on.

Term two
: Another definition.
