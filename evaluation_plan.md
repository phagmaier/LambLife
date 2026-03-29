# Measuring Open-Ended Evolution In `LambLife`

## 1. What We Are Actually Trying To Detect

The core question is not just "is the population alive?" or "are expressions changing?".
It is:

1. Does the system maintain a non-collapsing population for long runs?
2. Does it continue generating heritable novelty?
3. Does some of that novelty become ecologically successful?
4. Does this keep happening late in the run rather than only during startup?

That means the evaluation framework should separate four different phenomena:

- `persistence`: organisms keep surviving and reproducing
- `variation`: new structures continue appearing
- `inheritance`: successful descendants are lineage-linked rather than random one-off noise
- `open-endedness`: adaptive novelty still appears in later windows of time

If those are not separated, the simulation can look "busy" while actually being stuck.

## 2. What The Current Logs Already Support

The current implementation already logs enough to answer some useful first-pass questions:

- `metrics.csv`
  - population, resources, empty cells
  - energy, size, age
  - births, deaths, interactions
  - resources consumed, novel placements
  - periodic `unique_structures`
  - `max_generation`
- `lineage.csv`
  - tick of birth
  - child lineage
  - parent lineage
  - generation
  - expression hash

With only those logs, you can already measure:

- long-run population persistence
- whether births continue late into the run
- whether lineages keep extending
- whether structural diversity collapses or recovers
- whether novelty production slows to near zero

What you cannot yet measure well:

- whether novelty is adaptive versus junk
- whether ecological roles are changing
- whether major innovations survive for long
- whether species are turning over or just drifting in hash space
- whether later evolution is more complex than early evolution

## 3. Immediate Analysis You Can Do Right Now

Run multiple long simulations with different seeds and treat one run as anecdote, not evidence.

Recommended initial experiment set:

1. `20` seeds
2. `100k` to `1M` ticks each
3. log every `100` ticks as you do now
4. preserve `metrics.csv` and `lineage.csv` per seed
5. save snapshots every large interval for qualitative inspection

For each run, compute these time-windowed summaries using fixed windows such as `10k` ticks:

### A. Survival / Stability

- population mean and variance
- extinction events
- birth/death ratio
- fraction of ticks with nonzero births
- fraction of ticks with nonzero interactions

Interpretation:

- if population repeatedly crashes to zero, there is no sustained evolutionary process
- if population is flat but births are near zero, the system may be frozen

### B. Continued Novelty

- births per window
- novel placements per window
- increase in `max_generation` per window
- number of new expression hashes first seen in that window
- number of lineage branches born in that window

Interpretation:

- if these collapse after startup, evolution is front-loaded
- if they remain positive late in the run, novelty is still entering the system

### C. Retention Of Novelty

For each new hash or lineage first appearing in a window, ask:

- did it survive at least `T` ticks? such as `1000`
- did it produce descendants?
- did it ever exceed a population threshold? such as `10` organisms

Interpretation:

- constant novelty with zero retention is mostly noise
- retained novelty is closer to genuine innovation

### D. Diversity Dynamics

- `unique_structures` trend over time
- rolling diversity slope
- dominant-hash concentration
- lineage size distribution
- lineage lifetime distribution

Interpretation:

- a one-time burst followed by permanent dominance suggests closure
- repeated diversity loss and recovery can indicate ongoing ecological turnover

## 4. The Minimum Decision Rule For "Continued Evolution"

Use a conservative rule. A run counts as showing continued evolution only if all of the following hold in the late-run windows, not just early-run windows:

1. `population persistence`
   - population stays above a minimum threshold for the final `50%` of the run
2. `continued novelty`
   - new hashes, new branches, or generation growth continue in the final `25%` of the run
3. `retained novelty`
   - some innovations born in the final `25%` survive at least `T` ticks and leave descendants
4. `nontrivial turnover`
   - the successful lineages or dominant structures in late windows are not exactly the same as the startup winners

At the experiment level, call the system promising only if this happens in a meaningful fraction of seeds, for example:

- at least `30%` of runs satisfy the late-run criteria
- and at least some runs continue producing retained novelty all the way to the end

This avoids declaring success because of one lucky seed.

## 5. The Main Missing Piece: Innovation Success Tracking

The most important gap in current instrumentation is that you log how much novelty is produced, but not whether that novelty mattered.

Add a post-processing concept called an `innovation event`:

- the first time an `expr_hash` appears in the population, record its birth tick
- track its later survival time
- track its peak population
- track whether it produced descendant hashes
- track whether its descendants persisted

This lets you classify each novelty event as:

- `noise`: appears and dies quickly
- `survivor`: persists but does not spread
- `expander`: reaches meaningful population
- `innovator`: founds a lineage that keeps diversifying

This classification is the cleanest bridge between raw logs and evolutionary interpretation.

## 6. Instrumentation To Add Next

The current CSV is a good base, but for open-ended evolution you should add four more data products.

### A. Per-Organism Snapshot Table

At coarse intervals such as every `1000` ticks, write one row per organism:

- tick
- lineage_id
- parent_lineage
- generation
- expr_hash
- energy
- age
- size
- x
- y

Why:

- enables true species abundance curves
- enables lineage survival analysis
- enables spatial clustering analysis

### B. Birth Event Log

For every birth, log:

- tick
- parent_lineage
- child_lineage
- parent_hash
- child_hash
- parent_generation
- child_generation
- reproduction_mode
  - `self_similar`
  - `novel_placement`
- child_size
- child_initial_energy
- mutated_from_parent_similarity

Why:

- separates ordinary reproduction from structurally novel birth
- makes heritable novelty measurable instead of inferred indirectly

### C. Interaction Outcome Log Or Sampled Interaction Log

You do not need every interaction forever, but you need samples.

For sampled interactions, log:

- tick
- actor lineage/hash
- partner type: organism or resource
- partner lineage/hash or resource kind
- steps in reduction
- input sizes
- output size
- similarity to actor
- similarity to partner
- whether resource was consumed
- energy delta from the event

Why:

- reveals ecological roles
- reveals whether a lineage is a resource specialist, parasite, simplifier, or inert replicator

### D. Species/Lineage Summary Table

At analysis time, aggregate by `expr_hash` and by `lineage_id`:

- first_seen_tick
- last_seen_tick
- lifetime
- total_births
- peak_population
- descendant_count
- max_generation_reached

Why:

- this becomes the main dataset for deciding whether innovations accumulate

## 7. Analysis Pipeline To Build In Python

Python is the right tool for this stage. Zig should keep owning the simulator; Python should own analysis.

Recommended structure:

1. `analysis/load.py`
   - load run outputs
2. `analysis/window_metrics.py`
   - compute rolling or fixed-window summaries
3. `analysis/innovation.py`
   - identify innovation events and classify them
4. `analysis/lineage.py`
   - compute lineage lifetimes, branching, descendants
5. `analysis/plots.py`
   - generate standard figures
6. `analysis/report.py`
   - emit one per-run summary plus one cross-seed summary

Recommended outputs:

- time-series plots
- innovation survival curves
- lineage lifetime histograms
- "late novelty" scorecards
- a final markdown or HTML report per experiment batch

## 8. Core Plots That Actually Matter

If you only make a few plots, make these:

1. population, births, deaths, and interactions over time
2. unique structures and max generation over time
3. new hashes per window and retained new hashes per window
4. top lineage or top hash abundance over time
5. innovation survival curve:
   - fraction of novel hashes still alive after `t` ticks
6. founder impact plot:
   - innovations by birth tick versus later descendant count

The most important single plot is:

- `retained novelty per late window`

If that plot trends to zero, the system is probably not open-ended.

## 9. A Concrete Scoring Framework

Avoid relying on one metric. Use a small scorecard.

For each run, compute:

- `Persistence Score`
  - based on no extinction and stable interaction activity
- `Novelty Score`
  - based on new hashes and new branches in late windows
- `Retention Score`
  - based on fraction of late innovations that survive and reproduce
- `Turnover Score`
  - based on whether dominant lineages change over time
- `Complexification Score`
  - based on late-run trends in generation, size, or interaction depth

Then classify the run:

- `dead`
  - extinction or near-extinction
- `static`
  - persistent but novelty effectively stops
- `drifting`
  - novelty continues but little retention or ecological effect
- `evolving`
  - retained novelty and lineage turnover continue late
- `promisingly open-ended`
  - repeated late retained novelty across multiple seeds

This is intentionally stricter than "the graph moves".

## 10. How To Decide If The System Is Still Evolving

Use a sliding late-window test.

For every window after the first third of the run, ask:

1. Were new heritable variants born?
2. Did any survive beyond the window?
3. Did any spread or found descendant branches?
4. Did they alter which lineages or hashes were common?

If the answer is repeatedly "yes", evolution is ongoing.
If the answer becomes "no" and stays "no", the system has effectively closed.

Operationally, I would use:

- continued evolution is happening if, in the final `25%` of the run:
  - births remain nonzero in most windows
  - max generation keeps increasing
  - new hashes continue appearing
  - some late new hashes survive at least `1000` ticks
  - some late new hashes either exceed population `10` or produce descendants

You can tighten those thresholds later once you have empirical distributions.

## 11. What Counts As Evidence For Open-Ended Evolution

Strong evidence would look like this:

- long runs do not collapse
- dominant lineages turn over multiple times
- late-arising innovations sometimes become important
- diversity does not only spike at startup
- lineage trees keep branching late
- ecological roles inferred from interaction logs keep changing

Weak evidence would look like this:

- population survives
- max generation rises
- hashes keep changing

That weaker pattern may only mean neutral drift, hash churn, or mutation-selection balance.

## 12. Recommended Next Implementation Order

Do this in order:

1. build Python analysis for the current `metrics.csv` and `lineage.csv`
2. run a multi-seed experiment batch
3. establish baseline plots and failure modes
4. add per-organism snapshots
5. add birth-event logging
6. add sampled interaction logging
7. upgrade the analysis to compute retained novelty and innovation classes

This order matters because it gives you feedback quickly without overbuilding instrumentation first.

## 13. Immediate Deliverable To Aim For

The first useful report for one batch of runs should answer:

1. Which seeds go extinct?
2. Which seeds remain active late?
3. In which seeds does novelty persist late?
4. In which seeds does late novelty survive and spread?
5. Are the same lineages dominant at the end as near the beginning?

Once you can answer those five questions automatically, you will be in a good position to judge whether the system is genuinely evolving or just remaining dynamic.

## 14. Bottom Line

Right now, the best defensible claim you can aim for is:

- `sustained adaptive novelty` rather than immediately claiming `open-ended evolution`

That is the right standard because open-ended evolution is hard to prove, but sustained adaptive novelty across many seeds and late time windows is a strong sign that the system is on the right track.
