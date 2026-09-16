# ADR 0005 – The cover pipeline, and two ways to make it twenty times too slow

Date: 2026-09-16 · Status: accepted

## Context

A library of 8 000 books is a grid of 8 000 pictures. Selector solved the same
problem for photographs and wrote down the answer in its ADR 0003: requests
carry a priority, a gate limits how many decode at once, warming spreads
outwards from the selection, and background work yields to a click. Those parts
were copied into `ShelfCore` (`LoadPriority`, `DecodeGate`, `WarmOrder`,
`InteractionWindow`) rather than shared, because the two apps decode different
things.

Three things are different here, and they are the reasons this ADR exists.

## Decision

1. **Two sizes, not three tiers.** `.grid` (400 px) and `.large` (1 000 px).
   A grid cover is ~40 KB decoded, so *every* book can keep one in memory –
   8 000 of them fit in a 500 MB budget – which is what makes a jump to the far
   end of the library show a picture at once. The large one is held for the
   selection only. There is no "full resolution": nobody zooms into a cover.
2. **The cover size slider does not multiply the cache.** A cell asks for the
   tier its pixel width falls into, not for its exact width. A cache with a file
   per slider position would decode the whole library again every time the
   slider moved.
3. **The disk cache exists from Sprint 1** and lives **inside the library**
   (`.shelf/covers/`), keyed by the book's UUID and the pixel size. Selector's
   preview cache arrived in Sprint 6c after a sprint of "why is the second open
   slow"; with 8 000 books that is not a polish item (CONCEPT §13). Inside the
   library because the key is the book: the cache moves with the library and an
   external disk carries its covers along.
4. **The key is UUID + size + generation**, not path + size + date as in
   Selector. A cover belongs to the *book* and outlives any one of its files;
   the generation number is what replaces the modification date, so a replaced
   cover misses rather than matching something stale.
5. **The disk is read before the gate, written behind it.** Reading back a small
   HEIC is a fraction of decoding a JPEG, and queueing that behind four running
   decodes would throw away most of the saving.
6. **Trackpad scrolling does not pause warming.** `onScrollPhaseChange` needs
   macOS 15 and Shelf targets 14. What pauses warming is what the user actually
   does: moving the selection, dragging the slider, typing in the search field.
   A cover decode is a few milliseconds where Selector's RAW decode was 600, so
   the gate's background limit is enough on its own here. (See below for the
   substitute that was tried and refuted.)

## Two measurements, and what they cost

Measured against the 5 000-book synthetic library (`make proof`, then the app
opened on it with the cover cache emptied first), counting the files appearing
in `.shelf/covers/`:

| | covers per second | CPU |
|---|---|---|
| first attempt | 3.5 | 2–13 % |
| after fixing the feedback loop | 3.5 | 5–27 % |
| after fixing the QoS | **24** | 40–46 % |

Two separate faults, both of which produced a pipeline that was busy doing
nothing, and neither of which a unit test could have found.

### 1. Warming paused itself, through the view

`onScrollPhaseChange` being unavailable, cell *appearance* was used as the
signal that the user is scrolling – a cell only comes into existence when the
grid scrolls or the window resizes, which seemed exactly right.

It is a loop. The warmer finished a cover → published its progress → the
sidebar's footer observed that and was invalidated → the grid re-laid out →
cells appeared → that counted as an interaction → `DecodeGate.setInteracting(true)`
→ warming stood still for the 250 ms quiet period → one cover per ~285 ms.

Two changes, because either alone would leave the loop half-built:

* **Progress is published every 25 covers**, not every cover. At 8 000 books,
  per-cover updates are 8 000 view invalidations for a run that should take
  seconds.
* **Cell appearance is no longer an interaction signal at all** (decision 6).
  It is a property of rendering, not of the user, and coupling the pipeline's
  throttle to the view's layout is what created the loop.

### 2. The cache write ran at throttled QoS, holding a slot

After each decode, the encoded cover is written on its own task through the
gate's background lane. That task was created with `Task.detached(priority:
.background)`.

`LoadPriority.background.taskPriority` is `.utility`, deliberately, and its
comment says why: *"the system throttles `.background` so hard that warming a
library of thousands would take many minutes. What keeps clicks fast is the
gate, not a lower QoS."* The write-behind task was given `.background` anyway –
one line away from that comment – and because it holds one of the gate's two
background slots while the system throttles it, the warmer behind it starved.

Fixed by using `LoadPriority.background.taskPriority`, which is the rule the
core already stated. **The lesson is not "use utility":** it is that a
throttled task holding a limited slot is worse than no limit at all, and that a
constant copied from another project needs its *reason* copied with it.

## Consequences

* + The first screenful of covers is on screen in well under a second, cold,
  because warming starts at the selection and spreads outwards.
* + A second open of the same library reads HEIC files instead of decoding, and
  writes nothing.
* + Memory stayed between 200 and 290 MB throughout, against the 1.5 GB the
  concept allows – the byte budgets are not close to being the limit.
* − A full cold warm of 5 000 books takes about three and a half minutes in the
  background at 24 covers a second. That is slot-limited, not CPU-limited: the
  gate gives background work two of its four slots, and each cover uses a slot
  twice (decode, then encode-and-write). Raising `backgroundLimit` is one
  constant in one place, and it is on the list of things to measure on the real
  machines rather than guess at (`docs/BACKLOG.md`).
* − Trackpad scrolling no longer pauses warming. With 3 ms decodes and half the
  slots reserved this is very likely fine, and it is the honest state of things
  rather than a claim; when Shelf's deployment target reaches macOS 15,
  `onScrollPhaseChange` is the right signal and should be used.
* − The progress in the footer moves in steps of 25. Nobody will notice, and it
  is what keeps the run a run rather than a conversation with SwiftUI.
