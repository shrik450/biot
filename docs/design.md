# Biot web UI design brief

This document describes the intended web UI so it can be implemented from
scratch. The prototype in `~/Downloads/design 2` is a visual and interaction
reference, not an implementation to copy and not a product contract. Preserve
its character, but derive behavior and data from `docs/model.md` and the server
boundaries in the repository.

When this document and the prototype disagree with the model, the model wins.
Do not invent data merely to reproduce a prototype row. Do not make the
LiveView call Biot's HTTP API; it should use the server application functions
directly, as specified by the model.

## Product character

Biot is a small, self-hosted control plane for development environments. The UI
should feel like a precise operator console rather than a cloud dashboard:
compact, calm, legible, and close to the terminal without imitating a terminal
everywhere.

The reference has the right overall voice:

- Nearly all copy is short, direct, and lowercase: `biots`, `nodes`, `account`,
  `start`, `publish`, `shell`.
- Information is dense but not cramped. Tables and definition lists are the
  default; large marketing cards and decorative charts are not.
- Status is communicated with text first. Color and small dots reinforce it,
  but never carry meaning alone.
- The interface exposes what is actually happening: desired state, observed
  state, the current operation, what is waiting on the user, and whether an
  access withdrawal has reached the node.
- Empty and failure states are written as useful explanations, not blank boxes.
- Actions that the actor cannot perform are absent rather than disabled.

Avoid gradients in the application chrome, glass effects, drop shadows, large
rounded cards, pill-heavy layouts, oversized typography, illustrations, and
generic dashboard iconography. The Biot mark is the one expressive graphic.

## Visual system

### Typography

Use Space Mono for the entire product, with this fallback stack:

```css
"Space Mono", ui-monospace, Menlo, monospace
```

Load it in weights 400 and 700. The base size is 13px with a line height around
1.5. Page titles are deliberately modest at 18px/700; the product name on the
login screen may reach 22px. Metadata and table headings use 11–12px.

Monospace is part of the identity, but readability wins. Long URLs, IDs,
fingerprints, source names, and failure text must wrap safely. Runtime output,
diagnostics, tokens, commands, and terminal content preserve whitespace.

### Color

Support dark, light, and system themes. Dark is the defining appearance, but
the light theme must be designed rather than mechanically inverted.

| Token | Dark | Light | Use |
| --- | --- | --- | --- |
| page | `#082A2F` | `#EEF5F0` | App background and form controls |
| surface | `#0C3139` | `#FFFFFF` | Sidebar, tables, and cards |
| raised | `#12404A` | `#DDEBE1` | Hover, selected navigation, notices |
| border | `#1B4A52` | `#C4E3CC` | Dividers and control outlines |
| text | `#DCEDE1` | `#0C3139` | Primary text |
| muted | `#8FB3A0` | `#4E7368` | Metadata and secondary labels |
| orange | `#FE771C` | `#D55314` | Primary actions, attention, active tab |
| orange text | `#1A1208` | `#FFFFFF` | Text on an orange action |
| mint | `#A5CEB4` | `#0C3139` | Healthy state, links, terminal action |
| on mint | `#082A2F` | `#EEF5F0` | Text on mint |
| inactive dot | `#3E6B66` | `#B7CFC0` | Stopped or inactive state |
| terminal | `#04181C` | `#FFFFFF` | Logs, diagnostics, and terminal canvas |

Orange means “act or attend,” not “everything important.” Mint means healthy,
available, or navigable. Failure text must include the failure label and message;
do not rely on red, and do not introduce a broad traffic-light palette unless a
real need emerges during implementation.

### Shape, spacing, and elevation

- Corners are 3–5px. A rounded rectangle should still feel rectangular.
- Use 1px borders and background contrast instead of shadows.
- The spacing rhythm is 4, 6, 8, 10, 12, 16, 20, 24, and 32px.
- Normal controls are 32–36px tall. Primary buttons use bold text; secondary
  buttons use a transparent background with a border.
- Table cells use roughly 9px vertical and 12px horizontal padding. Column
  headings are uppercase, muted, 11px, and slightly letter-spaced.
- State dots are 7–8px circles. Animate only genuinely transitional states with
  a slow opacity pulse. Respect `prefers-reduced-motion`.
- Focus is obvious: use an orange outline or border with sufficient contrast,
  not color change alone.

### Logo

The reference mark is an isometric “chamber”: interlocking pale-mint and deep
petrol shells surround a recessed orange core, with a short orange status light
on the lower face. It feels like a contained workspace or machine, not a leaf,
cloud, or generic container cube.

If the provided mark is adopted as a product asset, strip provenance metadata
and optimize it before shipping. Display it on a subtle `raised` background: a
small 30px tile in navigation and a larger approximately 92px tile on login.
Do not redesign surrounding screens around the illustration.

## Application frame

On desktop, use a fixed 200px left sidebar and a content column. The sidebar is
the `surface` color, remains visible while the page scrolls, and fills the
viewport. Its header contains the small mark and `biot`. The primary links are:

- `biots`, with the readable Biot count
- `nodes`, with the node count
- `account`

The current section uses the `raised` background. Hover uses the same background
more subtly. Keep the navigation plain; it does not need icons.

The main column has 28px top and 32px horizontal padding, a maximum width around
1080px, and remains left-aligned. A wide monitor should not turn the UI into an
edge-to-edge dashboard.

At narrow widths, do not preserve a squeezed 200px column. Replace the sidebar
with a compact top bar containing the mark/product name and an accessible
navigation disclosure or a second, horizontally scrollable navigation row.
Reduce content padding to 16px. Forms become one column. Tables may scroll when
the columns are intrinsically technical, but the primary Biot list should
switch to stacked rows so name, state, and action remain readable without
horizontal scrolling.

Use real routes for pages and tabs so refresh, browser history, deep links, and
return paths behave normally. LiveView should enhance navigation, not turn the
application into a hidden client-side page state machine.

### Data cut points

Keep the web layer thin. It may compose product-facing server queries, but it
must not reach into Ecto schemas to fill gaps in a screen. At the time this
brief was written, several pieces of the reference are not available in the
current projections:

- `BiotView` identifies the selected environment but does not expose the
  repository or `EnvironmentSelection`. Either introduce an intentional
  server-owned detail projection or omit those overview rows; do not query the
  tables from the LiveView.
- `AccessView` returns principal IDs, while the desired screen labels grants by
  email. Add a server-owned display projection if email labels are required, or
  display IDs. Email-to-principal resolution for a new grant remains a separate
  boundary action.
- There is no product-facing query for ports merely listening inside a Biot.
  Manual publishing still works; do not derive discovery from logs.
- `NodeView` does not contain a host address, negotiated protocol version, or a
  generic last-report timestamp. Those prototype columns are not part of this
  design.
- `CredentialView` and `SshKeyView` do not contain creation times. Do not
  synthesize them.

Credential creation is intentionally absent from the bearer API, but it is a
valid control-session application function for the account LiveView. Initial
credential setup on the creation page is likewise a UI-orchestrated sequence of
existing lifecycle, fetch-credential, and secret boundaries—not an expanded
create command.

## Shared components and behavior

### Page header

A page header contains a small title and, when applicable, one primary action at
the opposite edge. It wraps cleanly. Detail pages add a muted breadcrumb above
the header and put lifecycle actions at the right.

### Buttons and links

- Orange filled: the single primary action in a context, such as `create` or
  `create token`.
- Mint filled: entering the terminal, a distinct positive navigation action.
- Bordered: ordinary mutations such as `start`, `stop`, `publish`, and `share`.
- Text link: row-local navigation and low-emphasis actions.
- Destructive: bordered and orange text. The first activation arms an inline
  confirmation; the second confirms. Do not use a surprise modal.

Buttons must expose pending state without changing width, prevent duplicate
submissions, and retain a comprehensible label. Do not disable a whole page
while one row action runs.

### Tables and compact panels

Wrap tables in a `surface` panel with a 4px radius and no shadow. The panel has
12px top padding; headers sit above rows, whose separators use `border`.
Clickable rows have a full-row hover state and a real accessible link target.

Use cards only for small, coherent summaries such as “operation” and
“environment.” They should read like bordered sections or definition lists,
not promotional tiles.

### Forms

Labels are visible above controls, uppercase where they name a domain field.
Place help immediately beneath the relevant control. Show validation errors at
the field and provide an error summary when submission fails. Preserve values
after server errors.

Inputs use the page background, a 1px border, 3px corners, and an orange focus
border. Never place a secret value back into rendered HTML after submission.
Secret fields are password inputs and should not have reveal affordances unless
that behavior is intentionally designed and tested.

### Feedback and live state

Live updates should be quiet. Update the relevant status, row, or panel in
place; do not toast routine convergence. Use a restrained inline notice for a
completed mutation when the result would otherwise be ambiguous. Failures stay
visible beside the thing that failed and explain the next useful action.

Any timestamps should be semantic `<time>` elements. Relative display is fine,
but the full absolute time belongs in the accessible label or title.

### Authorization and truthful state

Render from the actor's projected role and the application function results.
Do not infer authority from whether a control happens to be on screen. Owners,
shell collaborators, and view-only collaborators see different detail pages.

Do not collapse Biot state into one optimistic badge. The UI has four related
facts:

1. desired lifecycle state (`running`, `stopped`, or `destroyed`),
2. the latest observation and its freshness,
3. the current operation and outcome,
4. assigned-node and access-enforcement state.

The list may compute a concise summary, but the detail view must show the facts
separately. Priority for the summary is: failure or user-owned block, active
operation, unavailable/disabled/abandoned node, observed container state, then
desired state. A running container does not imply healthy services.

Operations can be `pending`, `working`, `succeeded`, `failed`, or `superseded`.
Pending and working may pulse orange. A failed operation shows its stage, code,
message, and retry policy. If it carries a diagnostic reference, offer a clear
`view diagnostic` action and render the diagnostic in the terminal-style panel.

When access enforcement is pending, show `access update pending on <node>` near
the access controls. A synchronous policy response does not mean the assigned
node has applied a withdrawal yet.

## Screens

### Login

The login page has no application chrome. Center a column no wider than 360px in
the viewport. Show the large mark, `biot`, one sentence describing the product
and control host, then a full-width orange sign-in button with a right arrow.

The identity provider is configured OIDC, not necessarily PocketID. Use the
configured provider name only if the server genuinely exposes one; otherwise
say `sign in`. Preserve a valid same-origin return path through the login round
trip. Authentication failure should be a clear, generic message with a retry,
without exposing callback details.

### Biot list — `/biots`

Header: `biots` and `+ create`.

Desktop columns:

- name
- desired/observed state summary
- current operation or user-owned wait
- role (`owner`, `shell`, `view :<port>`, or the collaborator combination)
- assigned node and its availability
- active published ports

The entire row navigates to the Biot. Keep the name bold. Show the historical
`direct_secret_exposure_possible` marker as concise orange text with an
explanatory accessible label; do not claim that a secret is currently present.
Published ports can be summarized as `:3000 :4000`.

Provide explicit loading, empty, and error states. The empty state should say
what a Biot is and link to creation. Pagination must follow the server's page
contract rather than assuming every Biot is loaded.

### New Biot — `/biots/new`

Use a single-column form with a maximum width around 560px. Fields appear in
this order:

1. repository HTTPS URL,
2. Biot name,
3. node, defaulting to `server picks`,
4. base package-set source and its ref,
5. zero or more ordered layer sources and refs,
6. after creation: `start` or `stay stopped`,
7. optional initial runtime secrets and source-fetch credentials.

Layers are repeatable rows with explicit add/remove controls; preserve their
order. Model the actual `EnvironmentSelection` rather than treating each layer
as one unparsed display string.

Initial credentials are a workflow, not fields in the create command. If any
are supplied, choose stopped creation and communicate the sequence: allocate,
deliver source credentials as required, finish preparation, deliver runtime
secrets, then start. A failed or uncertain delivery leaves the Biot stopped and
the UI must say so. Never imply that the server persists secret values.

The primary `create` action is disabled only when required client-known input is
missing. Server validation remains authoritative. On accepted creation, route to
the detail page and show the real operation rather than a fake progress timer.

### Biot detail — `/biots/:id`

The header contains:

- a `← biots` breadcrumb,
- name, desired-state marker, and concise operation state,
- ID, assigned node, and owner/actor role as muted metadata,
- permitted actions at the right.

The `terminal` action is present only for an owner or shell collaborator when a
shell can actually be opened. Owner lifecycle actions are `start` or `stop`,
`rebuild`, and `destroy` as applicable. Send the revision last loaded with start,
stop, and environment changes; on `revision_conflict`, reload and explain that
the Biot changed. Destroy remains an armed, explicit two-step action.

Below the header, use route-backed tabs with an orange 2px active underline:
`overview`, `publications`, `access`, `secrets`, and `logs`. Hide tabs the role
cannot read. Keep counts beside labels in muted text.

#### Overview

Use a responsive two-column grid of compact panels.

The operation panel shows kind, outcome, target revision, and useful detail. If
the latest observation is waiting for a fetch credential, make that the most
prominent line, show the exact source URL, and link directly to the delivery
control. If the operation failed, include the failure and diagnostic action.

The environment/execution panel shows the repository, selected package set and
ordered layers, desired revision, latest installed environment when reported,
container state/incarnation when reported, observation freshness/time, data
state, assigned-node state, and the SSH command when shell access is permitted.
Use the deployment view for the advertised SSH host and port; never hard-code
either.

Show access revision/enforcement as a small separate fact. Notices that require
action, such as a missing fetch credential or failed initial-secret delivery,
span the full grid width and use the `raised` background.

#### Publications

Show active publications as port and HTTPS URL. Owners also see listening ports
that the product can actually discover; do not fabricate discovery from runtime
logs. If no discovery boundary is available at implementation time, omit the
“listening, not published” rows and retain the manual port input.

Publication URLs open in a new tab and visibly identify that behavior. Owners
can publish a valid port or unpublish an active one. Explain that unpublishing
retains the stable hostname for later republishing but removes that port's view
grants. Collaborators see only publication URLs allowed by their projected view
ports and no mutation controls.

#### Access

Owner-only. Show the owner first, then grants in a compact table. A grant is
either `shell` for a principal or `view :<port>` for one active publication.
Resolve a typed email through the principal boundary before granting and surface
“unknown principal” clearly; do not treat arbitrary email text as an ID.

Sharing uses an email input, a grant-kind selector, and `share`. Each explicit
grant has a row-local `revoke`. A view option exists only for an active
publication. Show the current access revision and whether enforcement is
applied or pending. Unpublishing a port removes its view grants, and destroying
the Biot removes all grants.

#### Secrets

Owner-only. Separate two concepts even if they share one tab:

- Runtime secrets are listed by name from the node. Values are never listed.
  Owners can deliver/replace a value or remove the name. Listing may be
  unavailable while the node is offline; do not replace that with an empty
  list.
- A source-fetch credential prompt appears when the observation reports
  `waiting_for: fetch_credential(source)`. Show the source URL and accept the
  authorization value for that exact source. It stays with trusted node fetch
  code and is not a runtime secret.

After a successful runtime-secret delivery, display only a short-lived success
acknowledgement; the durable query knows names, not delivery timestamps. The
historical exposure marker belongs on the Biot, not on individual secret rows.

#### Logs

Owners and shell collaborators may read runtime logs; view-only collaborators
may not. Use a terminal-style panel with preserved whitespace, horizontal
overflow, the reported incarnation ID, and a clear marker when content was
truncated. Treat `not_found` and `temporarily_unavailable` as distinct states.
Do not poll so aggressively that an idle page continuously queries the node.

### Terminal — `/biots/:id/terminal`

The terminal is a full-viewport surface outside the normal app frame. A slim
top bar contains `← <biot name>`, `terminal`, assigned node and Biot ID, plus a
text connection state. The rest of the viewport belongs to Ghostty Web.

Use the orange block cursor and terminal background from the theme. The terminal
must resize with its container, send PTY dimensions, preserve focus, and expose
connected, reconnecting, closed, lost, expired, and policy-closed states. Never
present a missing exit frame as success. Leaving the route closes the stream.

### Nodes — `/nodes`

This is an inventory, not a node administration screen. Use the real `NodeView`
fields:

- node ID,
- configured status (`enabled`, `disabled`, `retired`, or `abandoned`),
- connection (`connecting`, `ready`, or `unavailable`),
- platform when known,
- assigned Biots against maximum capacity,
- latest orphan report.

Render capacity as a narrow mint bar plus `assigned/max`; text remains the
authoritative value. Do not reproduce the prototype's host address, protocol
version, or “last report” columns because `NodeView` does not expose them.

Orphaned allocations are operationally important. A node row with orphans must
expand or link to a compact list of Biot ID and UID range, with the report time.
`never_reported` is different from an empty orphan list. There are no enable,
disable, retire, or abandon controls here; node administration is operator
configuration.

### Account — `/account`

Use one vertical page with four restrained sections.

`api credentials` lists label, expiry, last used, and revoke. Token creation
asks for a label and intended expiry within the configured maximum. After
creation, show the clear token once in a `raised` notice with copy and dismiss
actions and an explicit “shown once” warning. Never render it again or retain it
in LiveView state longer than needed. Do not show a created date unless the
application projection is intentionally extended to supply it.

`ssh keys` lists label, fingerprint, canonical public key when useful, and
remove. Adding a key requires both the public key line and a label. Do not infer
or display a fake added date.

`appearance` is a three-way segmented control: `dark`, `system`, `light`.
Persist the explicit choice locally; system follows `prefers-color-scheme` and
updates when it changes.

`session` shows the authenticated principal's name/email and a `log out` action.
The action ends this control session and its previews; it must not claim to log
out every browser session or revoke API credentials.

## Accessibility and quality bar

- Meet WCAG 2.2 AA contrast and keyboard requirements in both themes.
- Every control has a programmatic name; every field has a real label; every
  table has an accessible name and correct headings.
- Full-row navigation, tabs, segmented controls, disclosures, and armed
  destructive actions must be operable without a pointer.
- Announce meaningful async changes and terminal connection changes through a
  restrained live region. Do not announce every log chunk.
- Do not use `title` as the only explanation for secret exposure, truncation,
  or state.
- Preserve visible focus. Respect reduced motion. Give the terminal an
  accessible escape route back to the Biot.
- Test owner, shell collaborator, view-only collaborator, disabled principal,
  unavailable node, stale observation, pending access enforcement, credential
  wait, failed operation with diagnostics, empty lists, and narrow layouts.

## Implementation acceptance

The implementation is faithful when it has the reference's quiet, dense,
petrol/mint/orange identity while remaining truthful to Biot's domain. A user
should be able to answer, without guessing:

- What did I ask this Biot to do?
- What has its node actually reported?
- Is work active, blocked on me, failed, or complete?
- What can I access, and why?
- Has an access withdrawal reached the node?
- Where do I publish, share, deliver a secret, inspect logs, or open a shell?

Do not reproduce the prototype's inline styles, fake timers, mock terminal,
hard-coded identity provider/domain/SSH endpoint, simulated node fields, or
client-side permission projection. Rebuild the visual system as maintainable
components and CSS, and let server-owned projections and policies determine
what the user sees.
