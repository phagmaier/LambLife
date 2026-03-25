# λ-Soup: A Lambda Calculus Artificial Life System

## Design & Implementation Specification

---

## 1. Vision and Core Principle

Everything in the system is a lambda expression. Organisms, food, waste products, signals — all the same type. The distinction between "living" and "inert" is emergent, not designed. An expression is "alive" if it persists over time, which requires maintaining energy through interactions. Self-replication, parasitism, cooperation, and predation all emerge from the same simple physics: lambda application and energy accounting.

---

## 2. Expression Representation

### 2.1 The Lambda Calculus

The system uses untyped lambda calculus with de Bruijn indices. There are exactly three node types:

- **Var(n)** — a variable reference. The integer `n` indicates how many lambda binders to skip upward. `Var(0)` means "the nearest enclosing lambda's parameter."
- **Lam(body)** — a function definition. Binds one parameter and contains a body expression.
- **App(func, arg)** — function application. Applies `func` to `arg`.

De Bruijn indices eliminate the need for variable names entirely. Two expressions that differ only in variable names (alpha-equivalent) will have identical representations. This makes structural comparison trivial and avoids the entire class of name-collision bugs.

### 2.2 Data Structure

Represent expressions as a tree (enum/tagged union):

```
Expression =
  | Var(index: u32)
  | Lam(body: Expression)
  | App(func: Expression, arg: Expression)
```

Each expression node should also carry metadata for the simulation:

```
Organism = {
  expr: Expression,
  energy: f64,
  age: u64,
  lineage_id: u64,
  parent_lineage: Option<u64>,
  generation: u64
}
```

### 2.3 Expression Size

Define `size(expr)` recursively:
- `size(Var(_))` = 1
- `size(Lam(body))` = 1 + size(body)
- `size(App(f, a))` = 1 + size(f) + size(a)

This is used for energy costs, mutation probabilities, and size limits.

### 2.4 Why De Bruijn Indices

In standard notation, `λx.x` and `λy.y` are the same function with different names. With de Bruijn indices, both are simply `Lam(Var(0))`. This matters because:
- Structural equality check = exact equality check (no alpha-equivalence needed)
- Substitution is cleaner (no capture-avoidance needed, just index shifting)
- Hashing expressions for diversity metrics is trivial

---

## 3. The Reduction Engine

### 3.1 Beta Reduction

The one rule of computation: `App(Lam(body), arg)` reduces by substituting `arg` for `Var(0)` inside `body`, shifting indices appropriately.

Substitution with de Bruijn indices requires an index-shifting operation:
- `shift(expr, amount, cutoff)` — increment all free variables (those with index ≥ cutoff) by `amount`
- `substitute(body, target_index, replacement)` — replace `Var(target_index)` with `replacement` in `body`

Beta reduction step:
1. Given `App(Lam(body), arg)`:
2. Shift `arg` up by 1 (it's moving under one binder)
3. Substitute the shifted `arg` for `Var(0)` in `body`
4. Shift the result down by 1 (the outer binder is gone)

### 3.2 Reduction Strategy

Use **normal order** (leftmost-outermost redex first). This finds normal forms when they exist, which is important — we don't want expressions diverging when a result exists.

### 3.3 Resource Limits

Every reduction is bounded by two hard limits:

- **Step limit**: maximum 200 beta-reduction steps per interaction. If the expression hasn't reached normal form by then, return whatever intermediate state exists. This is not an error — it represents an "ongoing computation" and the expression lives with whatever it's become.
- **Size limit**: maximum 500 nodes. If at any point during reduction the expression exceeds this, abort and return the pre-reduction expression unchanged. The interaction "failed" — the organism tried to do something too expensive.

These limits are both simulation parameters you should expose for tuning.

### 3.4 Normal Form Detection

An expression is in normal form when no beta-redex exists (no `App(Lam(_), _)` pattern anywhere in the tree). Detecting this requires a tree traversal. If reduction reaches normal form before hitting limits, stop early — no point in wasting steps.

---

## 4. The Spatial Grid

### 4.1 Structure

A 2D toroidal grid of dimensions W × H (recommended starting size: 150 × 150 = 22,500 cells). Toroidal means edges wrap — the top connects to the bottom, left connects to right. No edges, no boundaries. This prevents edge effects and ensures uniform spatial dynamics.

Each cell is one of:
- **Empty** — contains nothing
- **Resource** — contains a resource expression (see §6)
- **Organism** — contains an organism (expression + energy + metadata)

### 4.2 Neighborhoods

Use the **Moore neighborhood** (8 surrounding cells). When an organism acts, it can interact with any of its 8 neighbors.

### 4.3 Initial Population Density

Start with approximately 20–30% of cells occupied by organisms and 10–15% occupied by resources. The remaining cells are empty. This gives enough organisms for interactions while leaving room for reproduction.

---

## 5. Energy System

### 5.1 Energy as the Universal Currency

Energy is the sole determinant of survival. There is no fitness function, no score, no programmer-defined objective. An organism survives if it maintains positive energy. It dies when energy reaches zero.

### 5.2 Energy Costs

All costs are per simulation tick (one tick = one full pass over the grid):

| Action | Cost |
|--------|------|
| Existence (maintenance) | 0.5 + 0.1 × size(expr) |
| Interaction attempt | 2.0 per interaction |
| Reduction steps | 0.3 per beta-reduction step taken |
| Reproduction | 50% of parent's current energy (transferred to child) |
| Size penalty (if size > 100) | additional 0.5 × (size - 100) |

The size-dependent maintenance cost is critical: it creates pressure against bloat. Larger organisms must earn more energy to survive.

### 5.3 Energy Income

| Source | Amount |
|--------|--------|
| Simplification bonus | 2.0 × (input_total_size - output_size), only if output is smaller |
| Resource consumption | 10.0 per resource successfully metabolized |
| Interaction output is self-similar | 5.0 bonus (promotes self-replication, see §7.3) |

### 5.4 Energy Conservation Details

The simplification bonus deserves explanation. When organism A interacts with expression B and produces result C, if `size(A) + size(B) > size(C)`, the interaction produced a more compact result — it "simplified." This is rewarded because simplification represents useful computation (the expression did real work, not just grew). If the result is larger, no bonus and the organism still pays the reduction cost.

### 5.5 Energy Parameters

All numeric values above are tunable parameters. Store them in a configuration structure. You will need to experiment to find the right balance. The guiding principle: organisms should be able to survive if they do something useful, and should die if they're inert. Start with these values and adjust.

---

## 6. Resources

### 6.1 Resources Are Lambda Expressions

Resources are small, simple lambda expressions that get injected into empty grid cells at a steady rate. They serve as "food" — raw material that organisms can interact with to gain energy.

### 6.2 Resource Types

Define 4-6 resource types. Each is a fixed lambda expression:

| Resource | Expression | Intuition |
|----------|-----------|-----------|
| Identity | `Lam(Var(0))` | The simplest possible function, easy to consume |
| Constant-True | `Lam(Lam(Var(1)))` | Church boolean TRUE — selects first argument |
| Constant-False | `Lam(Lam(Var(0)))` | Church boolean FALSE — selects second argument |
| Self-Apply | `Lam(App(Var(0), Var(0)))` | The omega seed — interacts interestingly with many expressions |
| Pair | `Lam(Lam(Lam(App(App(Var(0), Var(2)), Var(1)))))` | Church pair constructor — enables data structuring |
| Zero | `Lam(Lam(Var(0)))` | Church numeral 0 — base for arithmetic |

### 6.3 Resource Injection

Each tick, inject resources into `R` randomly chosen empty cells (recommended: R = grid_size × 0.005, so about 112 new resources per tick on a 150×150 grid). The type of resource injected at each cell should vary spatially to create ecological niches:

- Divide the grid into 4-6 **biomes** (large irregular regions, generated via Voronoi tessellation or simple noise)
- Each biome has a distribution over resource types (e.g., biome A is 60% Identity + 30% True + 10% False; biome B is 50% Self-Apply + 40% Pair + 10% Zero)
- This means organisms in different parts of the grid face different environments, encouraging speciation

### 6.4 Resource Decay

Resources that go unconsumed for 50 ticks are removed. This prevents resource accumulation and maintains flow.

---

## 7. Interactions

### 7.1 Interaction Protocol

Each tick, process every organism once (in random order to prevent positional bias):

1. Select a random occupied neighbor cell (organism or resource)
2. Let A = this organism's expression, B = neighbor's expression (or resource expression)
3. Compute both `reduce(App(A, B))` → result_AB, and `reduce(App(B, A))` → result_BA
4. Each reduction is subject to the step limit and size limit from §3.3
5. Apply energy costs to A (interaction base cost + reduction step costs for both reductions)
6. Process both results through the **output handler** (§7.2)

If no occupied neighbor exists, the organism does nothing this tick (but still pays maintenance).

### 7.2 Output Handler

For each result (result_AB and result_BA):

1. If the result exceeds the size limit or is a bare free variable, discard it.
2. If the result is smaller than the sum of inputs, award A the simplification bonus.
3. If the result is structurally similar to A (see §7.3), award A the self-replication bonus, and treat the result as a reproductive event (see §8).
4. If the result is novel (not similar to either input), attempt to place it in an empty adjacent cell as a new independent organism. It receives a small initial energy grant (15.0). If no empty cell is available, the result is discarded.
5. If the neighbor was a resource and the interaction produced a non-trivial result (not just the resource unchanged), the resource is consumed (removed from its cell) and A receives the resource consumption bonus.

### 7.3 Self-Similarity Detection

Two expressions are "similar" if their tree-edit distance is less than 20% of the smaller expression's size. For efficiency, you can approximate this:

- Compute a hash of the top 3 levels of each expression tree
- If hashes match, do a full structural comparison
- Two expressions are similar if they share at least 80% of their structure

This doesn't need to be perfect — it's a heuristic for detecting reproduction. False positives just give an occasional undeserved bonus; false negatives just mean some reproductive events aren't recognized. Neither breaks the system.

### 7.4 Interaction With Resources vs. Organisms

When the neighbor is a resource, only organism A pays energy and only A receives bonuses. The resource is simply consumed or left.

When the neighbor is another organism (B), both organisms participate: B also pays a small interaction cost (1.0 — less than A since A initiated). Novel outputs can benefit either organism depending on similarity.

---

## 8. Reproduction

### 8.1 Reproduction Is Emergent

There is no explicit "reproduce" action. Reproduction occurs when an interaction produces an output that is structurally similar to the parent (§7.3). The output is the child.

### 8.2 Reproduction Mechanics

When a reproductive event is detected:

1. Check if an adjacent cell is empty. If not, reproduction fails (carrying capacity).
2. Create a child organism from the result expression.
3. Apply mutation to the child (see §9).
4. Transfer 50% of the parent's current energy to the child.
5. Place the child in the empty adjacent cell.
6. Record lineage: child gets a new lineage_id, its parent_lineage = parent's lineage_id, generation = parent's generation + 1.

### 8.3 Maximum Reproduction Rate

An organism can reproduce at most once per tick. This prevents fast replicators from instantly filling the grid.

---

## 9. Mutation

### 9.1 Mutation Rate

Each child undergoes mutation. Apply between 1 and 3 mutation operations (chosen randomly) per reproduction event. This is relatively high compared to biology, but the space is smaller and we want rapid exploration.

### 9.2 Mutation Operators

Each operator is chosen with the listed probability weight:

| Operator | Weight | Description |
|----------|--------|-------------|
| Point — change variable index | 25 | Select a random Var node, change its index to a random valid index (0 to current binding depth - 1). Must remain a valid de Bruijn index. |
| Point — change node type | 15 | Replace a Var with a Lam(Var(0)), or replace a Lam with its body, or replace an App with one of its children. |
| Subtree replacement | 15 | Select a random subtree, replace it with a randomly generated expression of depth 1-3. |
| Lambda wrapping | 15 | Select a random subtree S, replace it with Lam(S). Increment all free variable indices in S by 1. |
| Application wrapping | 10 | Select a random subtree S, replace it with App(S, Var(0)) or App(Var(0), S). |
| Subtree duplication | 10 | Select a random subtree, copy it to replace a different random subtree. |
| Subtree deletion | 10 | Select a random non-root subtree, replace it with Var(0). |

### 9.3 Validity Maintenance

After every mutation, validate that all Var indices are within scope (each Var(n) must be under at least n+1 enclosing Lam nodes). If a mutation produces an invalid index, clamp it to the maximum valid value. Never produce an invalid expression.

### 9.4 Random Expression Generation

For subtree replacement and initial population, generate random expressions:

```
random_expr(max_depth, current_depth, binding_depth):
  if current_depth >= max_depth:
    if binding_depth > 0:
      return Var(random(0, binding_depth - 1))
    else:
      return Lam(Var(0))

  choice = random():
  if choice < 0.3 and binding_depth > 0:
    return Var(random(0, binding_depth - 1))
  elif choice < 0.6:
    return Lam(random_expr(max_depth, current_depth + 1, binding_depth + 1))
  else:
    return App(
      random_expr(max_depth, current_depth + 1, binding_depth),
      random_expr(max_depth, current_depth + 1, binding_depth)
    )
```

For initial population, use max_depth = 4-6. For mutation subtree replacement, use max_depth = 2-3.

---

## 10. Death

### 10.1 Energy Death

After all interactions and costs are applied for a tick, any organism with energy ≤ 0 is removed. Its cell becomes empty.

### 10.2 Age Death

Optional but recommended: impose a maximum age of 10,000 ticks. This prevents immortal expressions from permanently occupying space. When an organism dies of old age, it simply frees its cell. This is tunable and can be disabled.

### 10.3 No Corpses

Dead organisms leave nothing behind. Their cell becomes empty immediately, available for resource injection or colonization by neighbors' offspring.

---

## 11. Simulation Loop

### 11.1 Tick Structure

Each simulation tick proceeds in this order:

```
for each tick:
  1. INJECT RESOURCES
     - Select R random empty cells
     - Place resource expressions based on biome distribution

  2. DECAY RESOURCES
     - Increment age of all resources
     - Remove resources older than 50 ticks

  3. ORGANISM ACTIONS (random order)
     For each organism (shuffled):
       a. Select random occupied neighbor
       b. Execute interaction protocol (§7)
       c. Handle outputs (placement, reproduction)
       d. Deduct maintenance cost

  4. DEATH SWEEP
     - Remove all organisms with energy ≤ 0
     - Remove all organisms with age > max_age (if enabled)

  5. AGE INCREMENT
     - Increment age of all surviving organisms

  6. LOGGING (every N ticks)
     - Record metrics (§13)
     - Write snapshot if checkpoint interval reached
```

### 11.2 Tick Rate Guidance

On a 150×150 grid with medium-complexity expressions, expect roughly 1,000–5,000 ticks per second depending on language and hardware. Plan for runs of 500,000+ ticks (several hours) to see interesting dynamics.

---

## 12. Initial Conditions

### 12.1 Seeding the Grid

Generate the initial population as follows:

1. Generate biomes using 5 Voronoi seed points placed randomly on the grid.
2. Fill ~25% of cells with random organisms (random expressions of depth 3-5, each with starting energy = 100.0).
3. Fill ~10% of cells with resources according to biome distributions.
4. Leave the rest empty.

### 12.2 Bootstrapping Problem

Most random expressions won't be self-replicators — they'll just interact, spend energy, and die. This is fine and expected. What matters is that among thousands of random expressions, some will be efficient enough to gain more energy than they spend, and a few will produce self-similar outputs. Natural selection does the rest.

However, if the system consistently collapses to zero population, it means the energy parameters are too harsh. Tuning approach:
- First run: set maintenance costs very low and resource injection very high. You should see population stability.
- Gradually increase costs and decrease resources until you see population pressure (deaths, competition).
- The sweet spot is where population fluctuates between 40-80% capacity.

### 12.3 Optional: Seed Replicators

If you want to skip the bootstrapping phase, seed the grid with a few known self-replicators. The simplest lambda self-replicator is a variant of the omega combinator:

```
Lam(App(Var(0), Var(0)))
```

When this applies to itself: `App(Lam(App(Var(0), Var(0))), Lam(App(Var(0), Var(0))))` reduces to `App(Lam(App(Var(0), Var(0))), Lam(App(Var(0), Var(0))))` — itself. Place 50-100 of these (with slight mutations) in the initial population to guarantee some reproductive activity from tick 1.

---

## 13. Metrics and Logging

### 13.1 Per-Tick Metrics (log every 100 ticks)

| Metric | Description |
|--------|-------------|
| population_count | Number of living organisms |
| resource_count | Number of resources on the grid |
| empty_count | Number of empty cells |
| mean_energy | Average energy across organisms |
| max_energy | Highest energy organism |
| mean_size | Average expression size (node count) |
| max_size | Largest expression |
| mean_age | Average organism age |
| max_age | Oldest organism |
| births | Reproductive events this tick |
| deaths_energy | Deaths from energy depletion |
| deaths_age | Deaths from age limit |
| interactions | Total interactions attempted |
| unique_structures | Number of structurally distinct expressions (hash-based) |
| max_generation | Highest generation number in the population |

### 13.2 Diversity Tracking (log every 1,000 ticks)

Compute a structural hash for every organism. Count the number of distinct hashes. Track the top 10 most common hashes (these are your "species"). Log their expression structure, population count, spatial distribution (center of mass and spread), and average energy.

### 13.3 Lineage Tracking

Maintain a running record of lineage relationships. Every birth logs: `(tick, child_lineage_id, parent_lineage_id, generation, expression_hash)`. This allows you to reconstruct phylogenetic trees after the run.

### 13.4 Snapshots

Every 10,000 ticks, serialize the entire grid state to a checkpoint file (binary or JSON). This allows you to resume runs and to inspect the grid at any point.

---

## 14. Visualization

### 14.1 Grid View

The primary visualization is a 2D rendering of the grid where each cell is colored:

| Cell State | Color |
|-----------|-------|
| Empty | Black |
| Resource (type 1-6) | Shades of blue/cyan (one shade per type) |
| Organism | Colored by species hash (map hash → hue, so same species = same color) |

Brightness can encode energy level (dim = low energy, bright = high energy).

### 14.2 Graphs Over Time

Plot the following as time series:
- Total population (line)
- Number of distinct species (line)
- Top 5 species populations (stacked area or multiple lines)
- Mean energy (line)
- Mean expression size (line)
- Birth and death rates (line)
- Maximum generation (line — this is your "evolutionary progress" indicator)

### 14.3 Expression Inspector

When you click on a cell, display:
- The expression in both de Bruijn notation and pretty-printed with variable names
- Its energy, age, generation, lineage
- Its recent interaction history (last 5 interactions and their results)

### 14.4 Implementation Note

Don't build visualization first. Get the simulation running headless with logging, verify the dynamics are interesting via the logged metrics, then add visualization. A simple terminal output showing population count, diversity, and a tiny ASCII grid is sufficient for early development.

---

### 15.1 Module Structure

Organize the codebase into these modules:

```
src/
  expr.zig          — Expression type, de Bruijn operations, hashing, display
  reduce.zig        — Beta reduction engine with step/size limits
  grid.zig          — 2D toroidal grid, cell types, neighbor iteration
  organism.zig      — Organism struct, energy accounting
  resource.zig      — Resource types, biome generation, injection logic
  interaction.zig   — Interaction protocol, output handler, similarity detection
  mutation.zig      — Mutation operators, random expression generation
  simulation.zig    — Main tick loop, orchestration
  metrics.zig       — Metric collection, logging, snapshot serialization
  config.zig        — All tunable parameters in one place
  main.zig          — CLI argument parsing, run loop, optional visualization
```

### 15.3 Build Order

Build and test in this order:

1. **expr.zig + reduce.zig** — Get expressions and reduction working first. Write thorough unit tests: verify that `App(Lam(Var(0)), X)` reduces to `X` for various X, that the step limit works, that size limit aborts correctly, that index shifting is correct. This is the foundation; bugs here will produce mysterious behavior later.

2. **mutation.zig** — Implement all mutation operators. Test that they always produce valid expressions (no out-of-scope variable indices). Generate 10,000 random mutations and verify all outputs are valid.

3. **grid.zig + organism.zig + resource.zig** — Grid mechanics, placement, neighbor lookup, resource injection. Test toroidal wrapping.

4. **interaction.zig** — Wire up the interaction protocol. Test with known expression pairs and verify results match hand-computed reductions.

5. **simulation.zig + config.zig** — The main loop. Run headless with text logging. Verify population doesn't immediately crash to zero or explode to fill every cell.

6. **metrics.zig** — Add proper logging. Run for 10,000+ ticks and examine metrics.

7. **Tuning** — Adjust energy parameters until the system shows dynamic equilibrium (population fluctuating, not monotonically dying or growing).

8. **Visualization** — Add graphical output last.

### 15.4 Performance Tips

- **Hash expressions eagerly**: compute and cache a structural hash whenever an expression is created or mutated. Use this for equality checks and diversity metrics instead of full tree comparison.
- **Arena allocation**: allocate expression nodes from a pre-allocated pool rather than individual heap allocations. This dramatically reduces allocation overhead and improves cache locality.
- **Lazy reduction**: if two expressions are identical to a pair that interacted recently (same hashes), cache and reuse the result.
- **Parallel grid processing**: the grid can be processed in parallel with a checkerboard pattern (like cellular automata) — process all "black" cells simultaneously, then all "white" cells. This doubles throughput on multi-core machines.

---

## 16. Tuning Guide

### 16.1 What to Watch For

| Symptom | Likely Cause | Adjustment |
|---------|-------------|------------|
| Population crashes to 0 within 1,000 ticks | Maintenance costs too high or resources too scarce | Halve maintenance costs, double resource injection rate |
| Grid fills to 100% and stays there | Energy too abundant, no selection pressure | Increase maintenance cost, reduce resource bonuses |
| Population stable but no diversity (one species dominates) | Selection pressure too high, winner-take-all | Increase mutation rate, add more resource type variation across biomes |
| Expressions grow without bound until hitting size limit | No cost for size, bloat is free | Increase the size-dependent maintenance cost |
| Nothing interesting happens (flat metrics) | Parameters create a boring equilibrium | Introduce environmental perturbation (see §16.2) |
| Lots of births but all children die immediately | Initial child energy too low | Increase the energy transfer percentage or the initial energy grant |

### 16.2 Environmental Perturbation

If the system reaches a stable but boring equilibrium, introduce periodic disruptions:

- **Resource shifts**: every 50,000 ticks, randomly reassign biome boundaries. Organisms adapted to one resource distribution suddenly face a different one.
- **Catastrophes**: every 100,000 ticks, kill 50% of organisms in a random circular region. This opens up space and breaks dominant species' hold.
- **New resource types**: at tick 200,000 and 400,000, introduce 1-2 new resource expressions that didn't exist at the start. Organisms that can metabolize the new resource have a new niche to exploit.

These are optional and should only be added if the baseline system equilibrates too quickly.

---

## 17. What Success Looks Like

### 17.1 Minimum Viable Success

The system is working if you observe:
- Stable population with fluctuations (not flat, not crashing)
- Multiple coexisting "species" (structurally distinct expression families)
- Species turnover (dominant species change over time)
- Spatial structure (species cluster rather than being uniformly mixed)
- Increasing maximum generation number (lineages persist and evolve)

### 17.2 Interesting Success

The system is producing genuinely interesting dynamics if you observe:
- **Parasitism**: expressions that gain energy primarily by interacting with a specific other species (exploiting their structure to produce simplifications)
- **Arms races**: a parasite-host pair where both species' structures change over time in response to each other
- **Ecological succession**: after a catastrophe, a predictable sequence of species colonize the empty space (fast simple replicators first, then more complex ones displace them)
- **Autocatalytic cycles**: groups of 3+ species where A needs B, B needs C, C needs A — none can survive alone but the group persists

### 17.3 Open-Ended Evolution

True OEE would be indicated by:
- Unbounded increase in maximum expression complexity over time (not asymptoting)
- Ongoing generation of functionally novel species (new metabolic strategies, new interaction modes) throughout the run, not just at the beginning
- Hierarchical organization: organisms that contain sub-structures which are themselves former organisms (incorporation)
- Meta-evolution: the *evolvability* of the population increases — later evolution is faster or more inventive than earlier evolution

---

## 18. Parameter Reference

All tunable parameters in one place:

```
[grid]
width = 150
height = 150

[energy]
maintenance_base = 0.5
maintenance_per_node = 0.1
interaction_base_cost = 2.0
reduction_step_cost = 0.3
reproduction_energy_fraction = 0.5
simplification_bonus_per_node = 2.0
resource_consumption_bonus = 10.0
self_similarity_bonus = 5.0
novel_offspring_initial_energy = 15.0
size_penalty_threshold = 100
size_penalty_per_node = 0.5
initial_organism_energy = 100.0

[reduction]
max_steps = 200
max_size = 500

[resources]
injection_rate_fraction = 0.005
resource_max_age = 50
num_biomes = 5

[mutation]
mutations_per_reproduction_min = 1
mutations_per_reproduction_max = 3
random_expr_max_depth = 3

[population]
initial_organism_fraction = 0.25
initial_resource_fraction = 0.10
max_organism_age = 10000

[simulation]
log_interval = 100
diversity_log_interval = 1000
snapshot_interval = 10000

[perturbation]
biome_shift_interval = 50000
catastrophe_interval = 100000
catastrophe_kill_fraction = 0.5
new_resource_ticks = [200000, 400000]
```

---

## 19. Extensions (Post-V1)

After the core system is working and producing interesting dynamics, consider these extensions in order of impact:

1. **Chemical signaling**: organisms can emit small "signal" expressions into their cell that neighbors can read as additional input. This enables communication and coordination.

2. **Expression trading**: instead of just application, allow organisms to exchange subtrees directly (horizontal gene transfer). This massively accelerates the spread of useful sub-structures.

3. **Multi-cell organisms**: allow organisms to form persistent spatial bonds with neighbors, creating multi-cell structures that act as a unit. This is a major step toward complex organization.

4. **Programmable physics**: let the set of available reduction rules itself evolve. Some cells might have modified reduction semantics, creating environments where different computational strategies are favored.

5. **3D grid**: extend to three dimensions. More neighbors, richer spatial structure, but much higher computational cost.

---

## Appendix A: De Bruijn Index Reference

Example translations between standard notation and de Bruijn:

| Standard | De Bruijn |
|----------|-----------|
| λx.x | Lam(Var(0)) |
| λx.λy.x | Lam(Lam(Var(1))) |
| λx.λy.y | Lam(Lam(Var(0))) |
| λf.λx.f x | Lam(Lam(App(Var(1), Var(0)))) |
| λf.λx.f(f x) | Lam(Lam(App(Var(1), App(Var(1), Var(0))))) |
| (λx.x x)(λx.x x) | App(Lam(App(Var(0), Var(0))), Lam(App(Var(0), Var(0)))) |
| λx.λy.λz.x z (y z) | Lam(Lam(Lam(App(App(Var(2), Var(0)), App(Var(1), Var(0)))))) |

## Appendix B: Known Self-Replicators to Seed

| Name | Expression | Behavior |
|------|-----------|----------|
| Omega | Lam(App(Var(0), Var(0))) | Applied to itself, reproduces exactly |
| Eager Omega | App(Lam(App(Var(0), Var(0))), Lam(App(Var(0), Var(0)))) | Already in self-application form |
| Mockingbird | Lam(App(Var(0), Var(0))) | Same as Omega — the M combinator |
| Guarded Replicator | Lam(Lam(App(Var(1), App(Var(1), Var(0))))) | Replicates when given an argument, also processes data |
