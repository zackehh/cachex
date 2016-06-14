defmodule Cachex.State do
  @moduledoc false
  # This module controls the state of caches being handled by Cachex. This is part
  # of an experiment to see if it's viable to remove the internal GenServer to
  # avoid several bottleneck scenarios, at well as letting the developer choose
  # how to control their concurrency.
  #
  # States are stored inside an ETS table which is started via `Cachex.Application`
  # and should only be accessed via this module. The interface is deliberately
  # small in order to reduce potential complexity.

  # add any aliases
  alias Cachex.Hook
  alias Cachex.Worker

  # name of internal table
  @state_table :cachex_state_table

  # transaction manager
  @transaction_manager :cachex_transaction_manager

  @doc false
  def init do
    setup = fn ->
      :ets.new(@state_table, [
        :named_table,
        { :read_concurrency, true },
        { :write_concurrency, true }
      ])
    end
    Agent.start_link(setup, [ name: @transaction_manager ])
  end

  @doc """
  Retrieves a state from the local state table, or `nil` if none exists.
  """
  @spec get(cache :: atom) :: state :: Worker.t | nil
  def get(cache) when is_atom(cache) do
    case :ets.lookup(@state_table, cache) do
      [{ @state_table, ^cache, state }] ->
        state
      _other ->
        nil
    end
  end

  @doc """
  Determines whether the given cache is provided in the state table.
  """
  @spec member?(cache :: atom) :: true | false
  def member?(cache) when is_atom(cache) do
    :ets.member(@state_table, cache)
  end

  @doc """
  Sets a state in the local state table.
  """
  @spec set(cache :: atom, state :: Worker.t) :: true
  def set(cache, %Worker{ } = state) when is_atom(cache) do
    :ets.insert(@state_table, { @state_table, cache, state })
  end

  @doc """
  Determines whether the tables for this module have been setup correctly.
  """
  @spec setup? :: true | false
  def setup? do
    Enum.member?(:ets.all, @state_table)
  end

  @doc """
  Returns the name of the local state table.
  """
  @spec table_name :: table_name :: atom
  def table_name do
    @state_table
  end

  @doc """
  Updates a state inside the local state table.

  This is atomic and happens inside a transaction to ensure that we don't get
  out of sync. Hooks are notified of the change, and the new state is returned.
  """
  @spec update(cache :: atom, function :: (Worker.t -> Worker.t)) :: state :: Worker.t
  def update(cache, fun) when is_atom(cache) and is_function(fun) do
    Agent.get(@transaction_manager, fn(_) ->
      cstate = get(cache)
      nstate = fun.(cstate)

      set(cache, nstate)

      nstate.options
      |> Hook.combine
      |> Enum.filter(&(&1.provide |> List.wrap |> Enum.member?(:worker)))
      |> Enum.each(&(Hook.provision(&1, { :worker, nstate })))

      nstate
    end)
  end

end