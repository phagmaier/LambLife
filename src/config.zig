/// Central configuration for all tunable simulation parameters.
/// All fields have defaults matching plan.md §18.
pub const Config = struct {
    // Grid
    width: u32 = 150,
    height: u32 = 150,

    // Energy
    maintenance_base: f64 = 0.5,
    maintenance_per_node: f64 = 0.1,
    interaction_base_cost: f64 = 2.0,
    reduction_step_cost: f64 = 0.3,
    neighbor_interaction_cost: f64 = 1.0,
    reproduction_energy_fraction: f64 = 0.5,
    simplification_bonus_per_node: f64 = 2.0,
    resource_consumption_bonus: f64 = 10.0,
    self_similarity_bonus: f64 = 5.0,
    novel_offspring_initial_energy: f64 = 15.0,
    size_penalty_threshold: u32 = 100,
    size_penalty_per_node: f64 = 0.5,
    initial_organism_energy: f64 = 100.0,

    // Reduction
    max_reduction_steps: u32 = 200,
    max_expression_size: u32 = 500,

    // Resources
    resource_injection_rate: f32 = 0.005,
    resource_max_age: u16 = 50,
    num_biomes: u32 = 5,

    // Mutation
    mutations_min: u32 = 1,
    mutations_max: u32 = 3,
    random_expr_max_depth: u32 = 3,

    // Population
    initial_organism_fraction: f32 = 0.25,
    initial_resource_fraction: f32 = 0.10,
    max_organism_age: u64 = 10_000,
    initial_expr_min_depth: u32 = 3,
    initial_expr_max_depth: u32 = 5,
    seed_replicator_count: u32 = 75,

    // Similarity
    similarity_threshold: f64 = 0.80,
    hash_depth_limit: u32 = 3,

    // Simulation
    log_interval: u64 = 100,
    snapshot_interval: u64 = 10_000,

    pub fn gridSize(self: Config) u32 {
        return self.width * self.height;
    }
};
