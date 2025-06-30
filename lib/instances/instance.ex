defmodule ActivityPub.Instances.Instance do
  @moduledoc "Instance."

  alias ActivityPub.Config
  alias ActivityPub.Instances
  alias ActivityPub.Instances.Instance
  import ActivityPub.Utils
  import Untangle

  use Ecto.Schema
  import Ecto.Query
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "ap_instance" do
    field(:host, :string)
    field(:unreachable_since, :naive_datetime_usec)

    timestamps()
  end

  defdelegate host(url_or_host), to: Instances

  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, [:host, :unreachable_since])
    |> validate_required([:host])
    |> unique_constraint(:host)
  end

  def filter_reachable([]), do: %{}

  def filter_reachable(urls) when is_list(urls) do
    urls
    |> Map.new(fn url -> {url, nil} end)
    |> filter_reachable()
  end

  def filter_reachable(url_map) when is_map(url_map) do
    urls =
      Map.keys(url_map)
      |> Enum.reject(&is_nil/1)

    hosts =
      urls
      |> Enum.map(&host/1)
      |> Enum.filter(&(&1 && &1 != ""))

    unreachable_since_by_host =
      repo().all(
        from(i in Instance,
          where: i.host in ^hosts,
          select: {i.host, i.unreachable_since}
        )
      )
      |> Map.new()

    threshold = Instances.reachability_datetime_threshold()

    urls
    |> Enum.reduce(%{}, fn url, acc ->
      h = host(url)
      usince = unreachable_since_by_host[h]

      if !usince || NaiveDateTime.compare(usince, threshold) == :gt do
        previous_val = url_map[url]

        val =
          if is_map(previous_val) do
            Map.put(previous_val, :unreachable_since, usince)
          else
            usince
          end

        Map.put(acc, url, val)
      else
        acc
      end
    end)
  end

  def reachable?(uri_or_host) do
    host = host(uri_or_host)

    host &&
      not repo().exists?(
        from(i in Instance,
          where:
            i.host == ^host and
              i.unreachable_since <= ^Instances.reachability_datetime_threshold(),
          select: true
        )
      )
  end

  def set_reachable(uri_or_host, opts \\ [])

  def set_reachable(%{"id" => id}, opts), do: set_reachable(id, opts)

  def set_reachable(uri_or_host, opts) do
    with host when is_binary(host) <- host(uri_or_host) || {:error, "no host"} do
      if Keyword.get_lazy(opts, :async, fn -> Config.env() != :test end) do
        Task.start(fn -> do_set_reachable(host) end)
      else
        do_set_reachable(host)
      end
    end
  end

  def do_set_reachable(host) do
    with %Instance{} = existing_record <- repo().get_by(Instance, %{host: host}) do
      existing_record
      |> changeset(%{unreachable_since: nil})
      |> repo().update()
    end
    |> debug("set_reachable?")
  end

  def set_unreachable(uri_or_host, unreachable_since \\ nil)

  def set_unreachable(uri_or_host, unreachable_since) do
    unreachable_since = unreachable_since || DateTime.utc_now()
    host = host(uri_or_host)

    if host do
      existing_record = repo().get_by(Instance, %{host: host})

      changes = %{unreachable_since: unreachable_since}

      cond do
        is_nil(existing_record) ->
          %Instance{}
          |> changeset(Map.put(changes, :host, host))
          |> repo().insert()

        existing_record.unreachable_since &&
            NaiveDateTime.compare(
              existing_record.unreachable_since,
              unreachable_since
            ) != :gt ->
          {:ok, existing_record}

        true ->
          existing_record
          |> changeset(changes)
          |> repo().update()
      end
    else
      error(uri_or_host, "Invalid URI or host")
    end
  end
end
