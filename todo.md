 1. Run long headless experiments with fixed seeds and save
     metrics.csv, lineage.csv, and snapshots every few thousand ticks.
  2. Add an analysis script or small Zig tool that summarizes:
      - population stability
      - unique structures over time
      - lineage survival length
      - generation depth
      - dominant-expression turnover
  3. Define concrete success criteria before tuning:
      - population does not collapse immediately
      - diversity does not flatline
      - some lineages persist for many generations
      - dominant hashes change over time instead of one structure
        freezing everything
  4. Add a replay workflow: run headless to a saved snapshot, then
     resume that snapshot in --viz mode to inspect interesting epochs
     instead of watching from tick 0.
  5. If the data looks dead or frozen, start parameter sweeps on a few
     sensitive knobs:
      - maintenance_*
      - resource_injection_rate
      - self_similarity_bonus
      - similarity_threshold
      - max_reduction_steps

  The highest-value coding task now is probably a lightweight experiment
  harness plus a results summarizer. Without that, you’ll end up tuning
  by feel. With it, you can compare seeds and configs objectively.

  If you want, I can implement the next piece directly:

  1. Perturbation — only if equilibrium is too stable
