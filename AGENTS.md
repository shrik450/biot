# Biot

Read README.md to understand the design. `docs/map.md` has a map of the codebase
and an inventory of features, tools etc. In the early stages, the map may not
exist.

## Good Software

The goal here is to produce *good* software.

Correctness is necessary but not sufficient to produce good software.

When aiming to produce good software, consider:

1. Is this understandable? Can a human see this or read the code and get a
   complete understanding of how it works? Understanding can be both from a
   developer perspective and from a user perspective. Code and features can be
   surprising or hard to understand.

2. Is it evolvable? Would changing something require rewriting large chunks, or
   would it be simple and easy to do so?

3. Is it reasonable? Are we spending a ton of complexity considering impractical
   edge cases, or does the software intentionally cut scope when something is
   outside our failure and threat modelling? Correctness is useful, but it
   always comes at a cost. Always be cognizant of those tradeoffs.

A few guidelines help produce good software:

01. Before implementing, consider the low-level design and cut points of what
    you're building. Is this an API or purely internal? How does one work with
    this? Think in terms of the shapes of data and how it flows.
02. Thinking hard about responsibilities and where the code that does what
    belongs is very useful in producing modules that stay in "local memory". If
    you bundle too many things together, it's harder to test *and* understand.
    On the other hand, finding the right cut points and designing simple
    interfaces that let you accomplish much while maintaining invariants will
    make code that's easy for others to work with and reuse.
03. Approach features and systems from the perspective of the user: will they
    intuit how this works? Or will some aspect of this be surprising to them?
04. The Functional Core, Imperative Shell pattern really helps in producing good
    design with loosely coupled cut points.
05. Testing should focus on unit tests for pure functions ONLY, and everything
    else should be tested either via integration or end to end tests with real
    or faked environments. Mocking is evil and breaks trust in tests. A test
    that asserts implementation details is worse than no test at all.
06. When debugging an issue, don't stop at the first explanation for it. Dig
    into five whys to get to the root cause. Don't paper over issues, figure
    them out and fix the root. If the good fix requires redesigning systems, do
    it.
07. You can follow the make it work, make it good, make it fast principle. Make
    it work: try stuff until it works, take notes and learn from that, then
    throw it away. Then design a *good and fast* solution for it from first
    principles. That's the solution that makes it into a commit.
08. Lean into the tooling. Try to make the systems the language gives you
    prevent and catch as many issues as possible. Defensive programming is a
    sign you're focusing on correctness over goodness. Parse at boundaries
    instead of validating at every step, build good designs with explicit
    invariants that are maintained simply via the interface.
09. Likewise, always check if the language or framework we're using gives you
    the tools to model, design or solve a problem better than rolling your own.
10. A good question to understand if a solution is reasonable is to ask if it is
    convoluted. A convoluted but correct solution is usually not reasonable. It
    might make more sense to re-model or re-design, or document a scope cut
    instead.

Code that works but is messy, hard to evolve and hard to understand is not
allowed.

## The Full Picture Rule

Every request (bug, feature, or an idea) is a response to a gap between what the
system does and what it needs to do. Before bridging the gap, you must get the
*Full Picture* of the gap and the request. A solution proposed without that
understanding is a guess, however well it's implemented.

You understand the gap when you can explain, in terms of the system's actual
design and history, why it exists: what the system was built to do, what changed
or was never accounted for, and how the existing parts interact to produce the
current behavior. If you can't explain that, you don't have the full picture
yet. Keep digging, and tell me what you're still unsure of rather than proposing
anyway. When digging, the five whys framework is a useful reference point.

Once you have the full picture, the right solution usually follows from it, and
it is often not the one that was asked for. Say so. Any idea (even mine), or the
first fix that comes to mind, is a candidate to be tested against your
understanding, not a spec to implement. If the picture points elsewhere, lead
with that.

Adding a new system is sometimes right. But it should be a conclusion you reach
after ruling out the alternatives, not the starting point.

The full picture rule can be relevant in reviewing as well. When you're
questioning decisions and choices, think of the full picture to judge if they're
good choices in that context.

## Good UI

All web UI work must pass the project-local `web-design-guidelines` skill at
`.agents/skills/web-design-guidelines/SKILL.md` before it is considered
complete. Run the skill against every web UI file changed by the work and
resolve every finding.
