defmodule Tokengate.SmartRouter.Versions do
  @moduledoc """
  Version management for the SmartRouter configuration: clone, promote, shadow,
  archive and diff.

  A **version** is a complete `router_configs` row plus its own
  `router_use_cases` (with their `router_use_case_models` destinations) and
  `router_rules`. Exactly one version is the **Default** and serves live
  traffic; the rest are candidates that can be edited, diffed, evaluated as a
  Shadow and promoted in one click.

  ## Why one serving Default

  Live A/B splitting per request would break `SessionPin` and the upstream
  prompt cache, and would make the kill switch ambiguous ("is it on for this
  version?"). So the model is: one version serves, every other version is
  compared against it out of band.

  ## The write paths

    * `clone_version!/2` — copy a version (config + use cases + destinations +
      rules) in a single transaction. The copy is never the Default and never a
      shadow: it is a draft.
    * `promote_to_default!/2` — atomically swap `is_default`. The outgoing
      Default keeps its row as a candidate version, and the **global** state
      (`enabled` kill switch, `baseline_model_id` counterfactual) is carried
      over from the outgoing Default by default (`preserve_global: true`), so a
      promotion can never flip the kill switch or silently move the savings
      baseline.
    * `toggle_shadow!/3` — evaluate a candidate in parallel. Rejected for the
      Default: shadowing it against itself can only ever agree.
    * `archive_version!/1` / `unarchive_version!/1` — retire a version. The
      Default cannot be archived, and archiving always turns the shadow off.
    * `update_version/2` — rename and re-describe a version. Metadata only: no
      routing knob, use case or rule is touched here.
    * `delete_version/1` — permanently remove a non-Default version with its use
      cases, destinations, rules and shadow history. Unlike archiving (which
      keeps the row so old `request_logs` stay explainable), this is the way to
      throw away a draft or a retired experiment for good.

  Every mutation invalidates the routing snapshot
  (`Tokengate.SmartRouter.invalidate/0`): the snapshot is cached for a minute
  and every one of these operations changes what the next decision must see.

  ## Consequences you must not skip

  **Promotion** clears the session pins (`SessionPin.clear_all/0`): a pin
  points at a destination row that belongs to a *version*, so keeping it after
  the swap would route the next turn of every open conversation into the
  previous version's catalogue.

  Toggling a shadow, archiving or unarchiving does NOT touch the pins: the
  Default keeps serving the same destinations, so a live pin is still valid
  and dropping it would rebuild (and re-pay for) every hot prompt prefix for no
  reason. Those paths only drop the cached snapshots
  (`SmartRouter.invalidate/1`).

  ## Concurrency

  Every write path opens its transaction with a transaction-scoped advisory
  lock (`pg_advisory_xact_lock(hashtext('smart_router_default_promotion'))`)
  BEFORE reading or locking any row. Promotion, archive and shadow toggling all
  rewrite the same small set of `router_configs` rows and are checked against
  partial unique indexes and CHECK constraints, so serialising them turns a
  possible "unique violation / constraint race" into a plain queue.
  """

  import Ecto.Query, only: [from: 2]

  alias Tokengate.Repo
  alias Tokengate.SmartRouter

  alias Tokengate.SmartRouter.{
    Config,
    Rule,
    SessionPin,
    ShadowEvaluation,
    UseCase,
    UseCaseModel
  }

  # Fields a clone copies verbatim from its source version. Deliberately
  # excluded: `id`, `is_default`, `shadow_enabled`, `archived_at` (a clone is a
  # live-capable draft, never the Default and never a shadow) and the
  # timestamps.
  @config_copy_fields ~w(enabled policy decision_timeout_ms decision_context_chars
    fast_path_max_tokens sticky_ttl_seconds lock_tool_loops charge_decision_to_subject
    decision_model_id default_model_id baseline_model_id shadow_sample_pct
    description)a

  @use_case_copy_fields ~w(key name description tags requires_tools requires_vision
    requires_structured_output critical_accuracy allow_downgrade pin_session
    keep_last_n_images max_history_turns compact_json
    stale_tool_trim_threshold_pct priority enabled fallback_model_id)a

  @use_case_model_copy_fields ~w(target_model_id effort_tier effort_override
    supports_tools supports_vision supports_structured_output min_confidence
    tags flags priority enabled)a

  @rule_copy_fields ~w(name description priority enabled match_conditions action
    target_use_case_keys)a

  # What `diff_versions/2` reports per version.
  @config_diff_fields ~w(name description enabled policy decision_timeout_ms
    decision_context_chars fast_path_max_tokens sticky_ttl_seconds
    lock_tool_loops charge_decision_to_subject decision_model_id
    default_model_id baseline_model_id shadow_enabled shadow_sample_pct)a

  @use_case_diff_fields ~w(name description tags requires_tools requires_vision
    requires_structured_output critical_accuracy allow_downgrade pin_session
    keep_last_n_images max_history_turns compact_json
    stale_tool_trim_threshold_pct priority enabled fallback_model_id)a

  @destination_diff_fields ~w(effort_override supports_tools supports_vision
    supports_structured_output min_confidence tags flags priority enabled)a

  @rule_diff_fields ~w(description priority enabled match_conditions action
    target_use_case_keys)a

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  @doc """
  Every version, Default first.

  Order is `is_default DESC, shadow_enabled DESC, inserted_at ASC`: the serving
  Default, then the versions currently under evaluation (the operator's most
  active interest), then the remaining candidates oldest-first.

  Options:

    * `:include_archived` — `true` also returns retired versions (default
      `false`: the switcher never offers them).
  """
  @spec list_versions(keyword()) :: [Config.t()]
  def list_versions(opts \\ []) do
    ordered = [desc: :is_default, desc: :shadow_enabled, asc: :inserted_at]

    query =
      if Keyword.get(opts, :include_archived, false) do
        from c in Config, order_by: ^ordered
      else
        from c in Config, where: is_nil(c.archived_at), order_by: ^ordered
      end

    Repo.all(query)
  end

  @doc "One version by id. Raises `Ecto.NoResultsError` when it does not exist."
  @spec get_version!(String.t()) :: Config.t()
  def get_version!(id), do: Repo.get!(Config, id)

  @doc """
  The serving Default. Raises when no version is flagged `is_default`.

  `Config.get/0` falls back to the sentinel row for backward compatibility; a
  caller that is about to mutate the serving version must not fall back, so it
  uses this instead.
  """
  @spec get_default!() :: Config.t()
  def get_default!, do: Repo.one!(from c in Config, where: c.is_default == true)

  # ---------------------------------------------------------------------------
  # Writes
  # ---------------------------------------------------------------------------

  @doc """
  Creates a version from `attrs`.

  Returns `{:ok, version}` / `{:error, changeset}`. A version created this way
  is a draft: it is neither the Default nor a shadow, and it starts with no use
  cases or rules (seed them with `Presets.ensure_all!/1` or clone a version
  instead).
  """
  @spec create_version(map()) :: {:ok, Config.t()} | {:error, Ecto.Changeset.t()}
  def create_version(attrs) when is_map(attrs) do
    %Config{}
    |> Config.changeset(
      attrs
      |> atomize()
      # A version created through this door is ALWAYS a draft: accepting
      # `is_default`/`shadow_enabled` from caller attrs would let a form (or a
      # retried request) create a second Default or shadow something by
      # accident.
      |> Map.put(:is_default, false)
      |> Map.put(:shadow_enabled, false)
    )
    |> Repo.insert()
  end

  @doc """
  Clones `source_id` into a new draft version, atomically.

  Copies, inside one transaction: the config row (knobs and model pointers),
  every use case with its `router_use_case_models` destinations
  (`fallback_model_id`, tiers, flags, priorities preserved) and every rule.
  The copy gets new ids everywhere, `is_default: false`,
  `shadow_enabled: false`, `archived_at: nil` and the name
  `"<source name> (copy)"` unless `attrs` overrides it.

  `attrs` accepts any `Config` field the operator wants to set on the copy
  (typically `name` and `description`), atom or string keys.

  Returns the new version (bang semantics: a failure raises and rolls back).
  """
  @spec clone_version!(String.t(), map()) :: Config.t()
  def clone_version!(source_id, attrs \\ %{}) when is_map(attrs) do
    unwrap!(
      Repo.transaction(fn ->
        source = Repo.get!(Config, source_id)

        version =
          %Config{}
          |> Config.changeset(clone_config_attrs(source, attrs))
          |> Repo.insert!()

        clone_use_cases!(source.id, version.id)
        clone_rules!(source.id, version.id)

        version
      end)
    )
  end

  @doc """
  Makes `version_id` the serving Default, atomically.

  Steps, in one transaction:

    1. lock the outgoing Default, then the target (a stable lock order, so two
       concurrent promotions queue instead of deadlocking);
    2. refuse an archived target (`{:error, :archived_version}`);
    3. unset `is_default` on the outgoing Default **before** setting it on the
       target — the partial unique index is checked per statement;
    4. set `is_default: true` and `shadow_enabled: false` on the target;
    5. with `preserve_global: true` (the default) copy the outgoing Default's
       `enabled` and `baseline_model_id` onto the target: those two are global
       policy, not version content, so promoting can never turn the router on
       or off, nor move the counterfactual baseline;

  then, after the commit, drop the routing snapshot and every session pin (a
  pin points at a destination of the *old* version).

  Returns `{:ok, version}` / `{:error, :archived_version}`. Raises
  `Ecto.NoResultsError` for an unknown id.
  """
  @spec promote_to_default!(String.t(), keyword()) ::
          {:ok, Config.t()} | {:error, :archived_version}
  def promote_to_default!(version_id, opts \\ []) do
    preserve_global = Keyword.get(opts, :preserve_global, true)

    result =
      Repo.transaction(fn ->
        lock_default_promotion!()
        outgoing = lock_default()
        target = lock_version!(version_id)

        cond do
          target.archived_at ->
            Repo.rollback(:archived_version)

          target.is_default ->
            target

          true ->
            # Order matters: release the partial unique index first.
            if outgoing, do: Repo.update!(Config.changeset(outgoing, %{is_default: false}))

            Repo.update!(Config.changeset(target, promotion_attrs(outgoing, preserve_global)))
        end
      end)

    case result do
      {:ok, version} ->
        # The serving catalogue moved: pins point at the OUTGOING version's
        # destinations, so they cannot survive this one.
        invalidate_promotion!()
        {:ok, version}

      {:error, :archived_version} ->
        {:error, :archived_version}
    end
  end

  @doc """
  Turns a candidate's parallel evaluation on or off.

  Rejected for the Default (`{:error, :cannot_shadow_default}`) and for an
  archived version (`{:error, :archived_version}`) — both are states where the
  comparison cannot produce an actionable number. `sample_pct` (1..100, nil =
  keep the current value) is the deterministic sample of live requests the
  version sees: `phash2({config_id, session_or_subject}, 100) < sample_pct`.

  Returns `{:ok, version}` / `{:error, changeset}` for an out-of-range sample,
  and drops the routing snapshot on success.
  """
  @spec toggle_shadow!(String.t(), boolean(), integer() | nil) ::
          {:ok, Config.t()} | {:error, Ecto.Changeset.t() | atom()}
  def toggle_shadow!(version_id, enabled?, sample_pct \\ nil) do
    result =
      Repo.transaction(fn ->
        lock_default_promotion!()
        version = lock_version!(version_id)

        cond do
          enabled? and version.is_default ->
            Repo.rollback(:cannot_shadow_default)

          enabled? and version.archived_at != nil ->
            Repo.rollback(:archived_version)

          true ->
            attrs =
              %{shadow_enabled: enabled?}
              |> maybe_put_sample_pct(sample_pct)

            update_version!(version, attrs)
        end
      end)

    case result do
      {:ok, updated} ->
        # A shadow toggle changes the sampler, not the serving catalogue:
        # live pins stay valid.
        invalidate_version!(updated.id)
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Retires a version: sets `archived_at` and turns its shadow off.

  The Default cannot be archived (`{:error, :cannot_archive_default}`): the
  router always has exactly one serving version. An archived version stays in
  the database (and keeps its use cases and rules) so its `request_logs` rows
  stay explainable; it is just not offered anywhere.

  Session pins are NOT dropped: archiving a candidate leaves the serving
  Default untouched.
  """
  @spec archive_version!(String.t()) :: {:ok, Config.t()} | {:error, atom() | Ecto.Changeset.t()}
  def archive_version!(version_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      Repo.transaction(fn ->
        lock_default_promotion!()
        version = lock_version!(version_id)

        if version.is_default do
          Repo.rollback(:cannot_archive_default)
        else
          update_version!(version, %{
            archived_at: version.archived_at || now,
            shadow_enabled: false
          })
        end
      end)

    case result do
      {:ok, archived} ->
        invalidate_version!(archived.id)
        {:ok, archived}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Brings a retired version back as a draft (`archived_at: nil`). It does not
  become the Default nor regain its shadow flag: promotion and shadowing are
  explicit decisions.

  Session pins are NOT dropped: the serving Default never stopped serving.
  """
  @spec unarchive_version!(String.t()) ::
          {:ok, Config.t()} | {:error, atom() | Ecto.Changeset.t()}
  def unarchive_version!(version_id) do
    result =
      Repo.transaction(fn ->
        lock_default_promotion!()
        version = lock_version!(version_id)
        update_version!(version, %{archived_at: nil})
      end)

    case result do
      {:ok, restored} ->
        invalidate_version!(restored.id)
        {:ok, restored}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Renames and/or re-describes a version.

  Accepts only `name` and `description` (atom or string keys) — everything else
  about a version is edited through the engine and rules tabs, where the
  changeset validation that belongs to each field lives. Nothing here can move
  `is_default`, `shadow_enabled` or `archived_at`, so a rename is safe to run on
  the serving Default.

  Returns `{:ok, version}` / `{:error, changeset}` and drops the routing
  snapshot: the version name is part of what `/stats/router` and the log detail
  render.
  """
  @spec update_version(String.t(), map()) ::
          {:ok, Config.t()} | {:error, Ecto.Changeset.t() | atom()}
  def update_version(version_id, attrs) when is_map(attrs) do
    metadata = Map.take(atomize(attrs), [:name, :description])

    result =
      Repo.transaction(fn ->
        lock_default_promotion!()
        version = lock_version!(version_id)
        update_version!(version, metadata)
      end)

    case result do
      {:ok, updated} ->
        invalidate_version!(updated.id)
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Permanently deletes a version that is **not** the serving Default.

  Removes, in one transaction: the version's `router_use_case_models`
  destinations, its `router_use_cases`, its `router_rules`, its
  `router_shadow_evaluations` and finally the `router_configs` row itself.

  Refused for the Default (`{:error, :cannot_delete_default}`): the router must
  always have exactly one serving version, and the only way to stop serving a
  version is promoting another one.

  `request_logs` rows are untouched: they carry `router_config_id` as a plain
  `uuid` with no FK, deliberately, so history survives the deletion. What is
  lost with the version is its shadow history — the delete confirmation in the
  UI says so before it runs.

  Returns `{:ok, version}` (the deleted row, for the audit entry) /
  `{:error, :cannot_delete_default}`. Raises `Ecto.NoResultsError` for an
  unknown id.
  """
  @spec delete_version(String.t()) :: {:ok, Config.t()} | {:error, :cannot_delete_default}
  def delete_version(version_id) do
    result =
      Repo.transaction(fn ->
        lock_default_promotion!()
        version = lock_version!(version_id)

        if version.is_default do
          Repo.rollback(:cannot_delete_default)
        else
          delete_children!(version.id)
          Repo.delete!(version)
        end
      end)

    case result do
      {:ok, deleted} ->
        invalidate_version!(deleted.id)
        {:ok, deleted}

      {:error, :cannot_delete_default} ->
        {:error, :cannot_delete_default}
    end
  end

  @doc """
  What `delete_version/1` would destroy, for the confirmation dialog.
  """
  @spec delete_preview(String.t()) :: %{use_cases: non_neg_integer(), rules: non_neg_integer()}
  def delete_preview(version_id) do
    %{
      use_cases:
        Repo.aggregate(from(u in UseCase, where: u.router_config_id == ^version_id), :count),
      rules: Repo.aggregate(from(r in Rule, where: r.router_config_id == ^version_id), :count)
    }
  end

  # ---------------------------------------------------------------------------
  # Diff
  # ---------------------------------------------------------------------------
  @doc """
  Structured difference between two versions.

  Returns

      %{
        config_diffs:   [%{field: atom, left: term, right: term}],
        use_case_diffs: [%{key: String.t(), status: :only_in_left | :only_in_right | :changed,
                           fields: [...], destinations: %{added: [...], removed: [...],
                                                          changed: [...]}}],
        rule_diffs:     [%{name: String.t(), status: :only_in_left | :only_in_right | :changed,
                           fields: [...]}]
      }

  Only disagreements appear: identical versions produce three empty lists, and
  a use case/rule that is the same in both versions is omitted instead of being
  reported as an unchanged entry. Destination entries are keyed by
  `(target_model_id, effort_tier)`, the binding's identity, so re-tiering a
  destination reads as a removal plus an addition, and only the fields of a
  binding that really differ are listed.
  """
  @spec diff_versions(String.t(), String.t()) :: %{
          config_diffs: [map()],
          use_case_diffs: [map()],
          rule_diffs: [map()]
        }
  def diff_versions(left_id, right_id) do
    left = get_version!(left_id)
    right = get_version!(right_id)

    %{
      config_diffs: config_diffs(left, right),
      use_case_diffs: use_case_diffs(left.id, right.id),
      rule_diffs: rule_diffs(left.id, right.id)
    }
  end

  # ---------------------------------------------------------------------------
  # Clone internals
  # ---------------------------------------------------------------------------

  defp clone_config_attrs(source, attrs) do
    base =
      source
      |> Map.from_struct()
      |> Map.take(@config_copy_fields)
      |> Map.put(:name, "#{source.name} (copy)")

    # Forced AFTER the merge: a clone is always a live-capable draft. Caller
    # attrs may rename it or change any knob, but they can never hand it the
    # Default flag, the shadow flag or a retirement timestamp (cloning an
    # archived version must produce a usable draft, not another archived row).
    base
    |> Map.merge(atomize(attrs))
    |> Map.put(:is_default, false)
    |> Map.put(:shadow_enabled, false)
    |> Map.put(:archived_at, nil)
  end

  defp clone_use_cases!(source_config_id, new_config_id) do
    for use_case <- list_use_cases(source_config_id) do
      copy =
        %UseCase{}
        |> UseCase.changeset(
          use_case
          |> copy_attrs(@use_case_copy_fields, %{router_config_id: new_config_id})
        )
        |> Repo.insert!()

      for binding <- use_case.use_case_models do
        %UseCaseModel{}
        |> UseCaseModel.changeset(
          binding
          |> copy_attrs(@use_case_model_copy_fields, %{router_use_case_id: copy.id})
        )
        |> Repo.insert!()
      end
    end
  end

  defp clone_rules!(source_config_id, new_config_id) do
    for rule <- list_rules(source_config_id) do
      %Rule{}
      |> Rule.changeset(rule |> copy_attrs(@rule_copy_fields, %{router_config_id: new_config_id}))
      |> Repo.insert!()
    end
  end

  defp copy_attrs(struct, fields, extra) do
    struct
    |> Map.from_struct()
    |> Map.take(fields)
    |> Map.merge(extra)
  end

  # ---------------------------------------------------------------------------
  # Write internals
  # ---------------------------------------------------------------------------

  defp promotion_attrs(outgoing, preserve_global) do
    attrs = %{is_default: true, shadow_enabled: false}

    if preserve_global and outgoing do
      Map.merge(attrs, %{enabled: outgoing.enabled, baseline_model_id: outgoing.baseline_model_id})
    else
      attrs
    end
  end

  defp maybe_put_sample_pct(attrs, nil), do: attrs

  defp maybe_put_sample_pct(attrs, pct) when is_integer(pct),
    do: Map.put(attrs, :shadow_sample_pct, pct)

  defp update_version!(version, attrs) do
    case Repo.update(Config.changeset(version, attrs)) do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # Children before parent, in one transaction. `router_use_case_models` and
  # `router_shadow_evaluations` also carry `on_delete: :delete_all`, but the
  # delete is spelled out so the query count is predictable and so a change to
  # those FKs can never silently turn this path into a constraint violation.
  defp delete_children!(config_id) do
    use_case_ids =
      from(u in UseCase, where: u.router_config_id == ^config_id, select: u.id)

    Repo.delete_all(
      from(b in UseCaseModel, where: b.router_use_case_id in subquery(use_case_ids))
    )

    Repo.delete_all(from(u in UseCase, where: u.router_config_id == ^config_id))
    Repo.delete_all(from(r in Rule, where: r.router_config_id == ^config_id))
    Repo.delete_all(from(e in ShadowEvaluation, where: e.shadow_config_id == ^config_id))

    :ok
  end

  # One transaction-scoped advisory lock for every write that rewrites
  # `router_configs`: promotion (two rows + partial unique index), archive and
  # shadow toggling (CHECK constraints) all race on the same tiny row set.
  # Taking it BEFORE any read/lock makes those operations queue instead of
  # failing on a unique violation or a stale snapshot of `is_default`.
  defp lock_default_promotion! do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext('smart_router_default_promotion'))")
  end

  defp lock_default,
    do: Repo.one(from c in Config, where: c.is_default == true, lock: "FOR UPDATE")

  defp lock_version!(id) do
    Repo.one!(from c in Config, where: c.id == ^id, lock: "FOR UPDATE")
  end

  # Promotion moves the serving catalogue: the snapshot is stale AND every pin
  # points at a destination row of the OLD version.
  defp invalidate_promotion! do
    SmartRouter.invalidate()
    SessionPin.clear_all()
    :ok
  end

  # Toggle/archive/unarchive change what the version switcher and the sampler
  # see, but the Default keeps serving the same destinations: live pins stay
  # valid, so only the cached snapshots are dropped.
  defp invalidate_version!(config_id) do
    SmartRouter.invalidate(config_id)
    :ok
  end

  defp unwrap!({:ok, value}), do: value

  defp unwrap!({:error, reason}) do
    raise "SmartRouter version transaction failed: #{inspect(reason)}"
  end

  # ---------------------------------------------------------------------------
  # Loaders
  # ---------------------------------------------------------------------------

  # One query for the use cases and one for ALL their destinations: the clone
  # and the diff both walk `use_case_models` per use case, and a per-use-case
  # read made those paths 12–24 queries deep.
  defp list_use_cases(config_id) do
    from(u in UseCase,
      where: u.router_config_id == ^config_id,
      order_by: [asc: u.priority, asc: u.inserted_at]
    )
    |> Repo.all()
    |> Repo.preload(
      use_case_models: fn use_case_ids ->
        from(b in UseCaseModel,
          where: b.router_use_case_id in ^use_case_ids,
          order_by: [asc: b.priority, asc: b.inserted_at]
        )
        |> Repo.all()
      end
    )
  end

  defp list_rules(config_id) do
    Repo.all(
      from r in Rule,
        where: r.router_config_id == ^config_id,
        order_by: [asc: r.priority, asc: r.inserted_at]
    )
  end

  # ---------------------------------------------------------------------------
  # Diff internals
  # ---------------------------------------------------------------------------

  defp config_diffs(left, right) do
    field_diffs(left, right, @config_diff_fields)
  end

  defp use_case_diffs(left_config_id, right_config_id) do
    left = use_cases_by_key(left_config_id)
    right = use_cases_by_key(right_config_id)

    (Map.keys(left) ++ Map.keys(right))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn key ->
      case {Map.get(left, key), Map.get(right, key)} do
        {nil, right_entry} ->
          [
            %{
              key: key,
              status: :only_in_right,
              fields: [],
              destinations: destination_diff(%{}, right_entry.models)
            }
          ]

        {left_entry, nil} ->
          [
            %{
              key: key,
              status: :only_in_left,
              fields: [],
              destinations: destination_diff(left_entry.models, %{})
            }
          ]

        {left_entry, right_entry} ->
          fields = field_diffs(left_entry.row, right_entry.row, @use_case_diff_fields)
          destinations = destination_diff(left_entry.models, right_entry.models)

          if fields == [] and empty_destination_diff?(destinations) do
            []
          else
            [%{key: key, status: :changed, fields: fields, destinations: destinations}]
          end
      end
    end)
  end

  defp rule_diffs(left_config_id, right_config_id) do
    left = rules_by_name(left_config_id)
    right = rules_by_name(right_config_id)

    (Map.keys(left) ++ Map.keys(right))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      case {Map.get(left, name), Map.get(right, name)} do
        {nil, _} ->
          [%{name: name, status: :only_in_right, fields: []}]

        {_, nil} ->
          [%{name: name, status: :only_in_left, fields: []}]

        {left_row, right_row} ->
          case field_diffs(left_row, right_row, @rule_diff_fields) do
            [] -> []
            fields -> [%{name: name, status: :changed, fields: fields}]
          end
      end
    end)
  end

  defp use_cases_by_key(config_id) do
    config_id
    |> list_use_cases()
    |> Map.new(fn use_case ->
      models =
        use_case.use_case_models
        |> Map.new(fn binding -> {{binding.target_model_id, binding.effort_tier}, binding} end)

      {use_case.key, %{row: use_case, models: models}}
    end)
  end

  defp rules_by_name(config_id) do
    config_id
    |> list_rules()
    |> Map.new(fn rule -> {rule.name, rule} end)
  end

  defp destination_diff(left_models, right_models) do
    (Map.keys(left_models) ++ Map.keys(right_models))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce(%{added: [], removed: [], changed: []}, fn {model_id, tier} = key, acc ->
      case {Map.get(left_models, key), Map.get(right_models, key)} do
        {nil, right_binding} ->
          %{acc | added: acc.added ++ [destination_ref(right_binding)]}

        {left_binding, nil} ->
          %{acc | removed: acc.removed ++ [destination_ref(left_binding)]}

        {left_binding, right_binding} ->
          case field_diffs(left_binding, right_binding, @destination_diff_fields) do
            [] ->
              acc

            fields ->
              changed = %{
                model_id: model_id,
                effort_tier: tier,
                fields: fields
              }

              %{acc | changed: acc.changed ++ [changed]}
          end
      end
    end)
  end

  defp destination_ref(binding) do
    %{model_id: binding.target_model_id, effort_tier: binding.effort_tier}
  end

  defp empty_destination_diff?(diff) do
    diff.added == [] and diff.removed == [] and diff.changed == []
  end

  defp field_diffs(left, right, fields) do
    Enum.flat_map(fields, fn field ->
      left_value = Map.get(left, field)
      right_value = Map.get(right, field)

      if left_value == right_value do
        []
      else
        [%{field: field, left: left_value, right: right_value}]
      end
    end)
  end

  # `cast/3` accepts string or atom keys but refuses a map that carries the same
  # field twice; clones are built by merging struct field maps with caller
  # attrs, so the attrs are normalised to atoms once, here.
  defp atomize(attrs) do
    Map.new(attrs, fn {key, value} -> {atomize_key(key), value} end)
  end

  defp atomize_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp atomize_key(key), do: key
end
