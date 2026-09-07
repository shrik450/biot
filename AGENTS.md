# Biot

Read README.md to understand the design. `docs/map.md` has a map of the codebase
and an inventory of features, tools etc. In the early stages, the map may not
exist.

## Good Software

The goal here is to produce *good* software.

Correctness is necessary but not sufficient to produce good software.

When aiming to produce good software, consider:

1. Is this understandable? Can a human see this or read the code and get a
   complete understanding of how it works?
2. Is it evolvable? Would changing something require rewriting large chunks, or
   would it be simple and easy to do so?
3. Is it reasonable? Are we spending a ton of complexity considering impractical
   edge cases, or does the software intentionally cut scope when something is
   outside our failure and threat modelling? Correctness is useful, but it
   always comes at a cost. Always be cognizant of those tradeoffs.

A few guidelines help produce good software:

1. Before implementing, consider the low-level design and cut points of what
   you're building. Is this an API or purely internal? How does one work with
   this? Think in terms of the shapes of data and how it flows.
2. The Functional Core, Imperative Shell pattern really helps in producing good
   design with loosely coupled cut points.
3. Testing should focus on unit tests for pure functions ONLY, and everything
   else should be tested either via integration or end to end tests with real or
   faked environments. Mocking is evil and breaks trust in tests. A test that
   asserts implementation details is worse than no test at all.
4. When debugging an issue, don't stop at the first explanation for it. Dig into
   five whys to get to the root cause. Don't paper over issues, figure them out
   and fix the root. If the good fix requires redesigning systems, do it.
5. You can follow the make it work, make it good, make it fast principle. Make
   it work: try stuff until it works, take notes and learn from that, then throw
   it away. Then design a *good and fast* solution for it from first principles.
   That's the solution that makes it into a commit.
6. Lean into the tooling. Try to make the systems the language gives you prevent
   and catch as many issues as possible. Defensive programming is a sign you're
   focusing on correctness over goodness. Parse at boundaries instead of
   validating at every step, build good designs with explicit invariants that
   are maintained simply via the interface.

Code that works but is messy, hard to evolve and hard to understand is not
allowed.
