function Experiment(
    ::Val{:Dopamine},
    ::Val{:Rainbow},
    ::Val{:Atari},
    name::AbstractString;
    save_dir = nothing,
    seed = 123,
)
    @warn "Currently setting the `seed` will not guarantee the reproducibility. The instability seems to be caused by the `CrossCor` layer when calculating gradient."
    rng = StableRNG(seed)
    if isnothing(save_dir)
        t = Dates.format(now(), "yyyy_mm_dd_HH_MM_SS")
        save_dir = joinpath(pwd(), "checkpoints", "Dopamine_Rainbow_Atari_$(name)_$(t)")
    end

    lg = TBLogger(joinpath(save_dir, "tb_log"), min_level = Logging.Info)

    N_FRAMES = 4
    STATE_SIZE = (84, 84)
    env = atari_env_factory(name, STATE_SIZE, N_FRAMES; seed = hash(seed + 1))
    N_ACTIONS = length(action_space(env))
    N_ATOMS = 51
    init = glorot_uniform(rng)

    create_model() =
        Chain(
            x -> x ./ 255,
            CrossCor((8, 8), N_FRAMES => 32, relu; stride = 4, pad = 2, init = init),
            CrossCor((4, 4), 32 => 64, relu; stride = 2, pad = 2, init = init),
            CrossCor((3, 3), 64 => 64, relu; stride = 1, pad = 1, init = init),
            x -> reshape(x, :, size(x)[end]),
            Dense(11 * 11 * 64, 512, relu; init = init),
            Dense(512, N_ATOMS * N_ACTIONS; init = init),
        ) |> gpu

    agent = Agent(
        policy = QBasedPolicy(
            learner = RainbowLearner(
                approximator = NeuralNetworkApproximator(
                    model = create_model(),
                    optimizer = ADAM(0.0000625),
                ),  # epsilon is not set here
                target_approximator = NeuralNetworkApproximator(model = create_model()),
                n_actions = N_ACTIONS,
                n_atoms = N_ATOMS,
                Vₘₐₓ = 10.0f0,
                Vₘᵢₙ = -10.0f0,
                update_freq = 4,
                γ = 0.99f0,
                update_horizon = 3,
                batch_size = 32,
                stack_size = N_FRAMES,
                min_replay_history = 20_000,
                loss_func = (ŷ, y) -> logitcrossentropy(ŷ, y; agg = identity),
                target_update_freq = 8_000,
                rng = rng,
            ),
            explorer = EpsilonGreedyExplorer(
                ϵ_init = 1.0,
                ϵ_stable = 0.01,
                decay_steps = 250_000,
                kind = :linear,
                rng = rng,
            ),
        ),
        trajectory = CircularArrayPSARTTrajectory(
            capacity = 1_000_000,
            state = Matrix{Float32} => STATE_SIZE,
        ),
    )

    evaluation_result = []
    EVALUATION_FREQ = 250_000
    MAX_EPISODE_STEPS_EVAL = 27_000
    N_CHECKPOINTS = 3

    total_reward_per_episode = TotalOriginalRewardPerEpisode()
    time_per_step = TimePerStep()
    steps_per_episode = StepsPerEpisode()
    hook = ComposedHook(
        total_reward_per_episode,
        time_per_step,
        steps_per_episode,
        DoEveryNStep() do t, agent, env
            with_logger(lg) do
                @info "training" loss = agent.policy.learner.loss
            end
        end,
        DoEveryNEpisode() do t, agent, env
            with_logger(lg) do
                @info "training" reward = total_reward_per_episode.rewards[end] episode_length =
                    steps_per_episode.steps[end] log_step_increment = 0
            end
        end,
        DoEveryNStep(;n=EVALUATION_FREQ) do t, agent, env
            @info "evaluating agent at $t step..."
            p = agent.policy
            p = @set p.explorer = EpsilonGreedyExplorer(0.001; rng = rng)  # set evaluation epsilon
            h = ComposedHook(TotalOriginalRewardPerEpisode(), StepsPerEpisode())
            s = @elapsed run(
                p,
                atari_env_factory(
                    name,
                    STATE_SIZE,
                    N_FRAMES,
                    MAX_EPISODE_STEPS_EVAL;
                    seed = hash(seed + t),
                ),
                StopAfterStep(125_000; is_show_progress = false),
                h,
            )
            res = (
                avg_length = mean(h[2].steps[1:end-1]),
                avg_score = mean(h[1].rewards[1:end-1]),
            )
            push!(evaluation_result, res)

            @info "finished evaluating agent in $s seconds" avg_length = res.avg_length avg_score =
                res.avg_score
            with_logger(lg) do
                @info "evaluating" avg_length = res.avg_length avg_score = res.avg_score log_step_increment = 0
            end

            policy = cpu(p)
            mkdir(joinpath(save_dir, string(t)))
            BSON.@save joinpath(save_dir, string(t), "policy.bson") policy
            BSON.@save joinpath(save_dir, string(t), "stats.bson") total_reward_per_episode time_per_step evaluation_result

            # only keep recent 3 checkpoints
            old_checkpoint_folder =
                joinpath(save_dir, string(t - EVALUATION_FREQ * N_CHECKPOINTS))
            if isdir(old_checkpoint_folder)
                rm(old_checkpoint_folder; force = true, recursive = true)
            end
        end,
    )

    N_TRAINING_STEPS = 50_000_000
    stop_condition = StopAfterStep(N_TRAINING_STEPS)

    description = """
    This experiment uses alomost the same config in [dopamine](https://github.com/google/dopamine/blob/master/dopamine/agents/rainbow/configs/rainbow.gin). But do notice that there are some minor differences:

    - The epsilon in ADAM optimizer is not changed
    - The image resize method used here is provided by ImageTransformers, which is not the same with the one in cv2.

    The testing environment is $name.
    Agent and statistic info will be saved to: `$(joinpath(save_dir, string(N_TRAINING_STEPS)))`
    You can also view the tensorboard logs with `tensorboard --logdir $(joinpath(save_dir, "tb_log"))`

    To load the agent and statistic info:
    ```
    BSON.@load joinpath("$(joinpath(save_dir, string(N_TRAINING_STEPS)))", "policy.bson") policy
    BSON.@load joinpath("$(joinpath(save_dir, string(N_TRAINING_STEPS)))", "stats.bson") total_reward_per_episode time_per_step evaluation_result
    ```
    """

    Experiment(agent, env, stop_condition, hook, description)
end
