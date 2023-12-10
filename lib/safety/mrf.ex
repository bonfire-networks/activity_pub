defmodule ActivityPub.MRF do
  # import Untangle

  @callback filter(Map.t(), boolean()) :: {:ok | :reject, Map.t()}

  def filter(policies, %{} = object, is_local?) do
    policies
    |> Enum.reduce({:ok, object}, fn
      policy, {:ok, object} ->
        policy.filter(object, is_local?)

      _, error ->
        error
    end)
  end

  def filter(%{} = object, is_local?),
    do: get_policies() |> filter(object, is_local?)

  def get_policies do
    Keyword.get(
      Application.get_env(:activity_pub, :instance, []),
      :rewrite_policy,
      []
    )
    |> get_policies()
  end

  defp get_policies(policy) when is_atom(policy), do: [policy]
  defp get_policies(policies) when is_list(policies), do: policies
  defp get_policies(_), do: []

  @spec subdomains_regex([String.t()]) :: [Regex.t()]
  def subdomains_regex(domains) when is_list(domains) do
    for domain <- List.flatten(domains) do
      domain =
        case domain do
          {domain, _} -> domain
          _ -> domain
        end
        |> String.replace(".", "\\.")
        |> String.replace("*", ".*")

      ~r(^#{domain}$)
    end
  end

  @spec subdomain_match?([Regex.t()], String.t()) :: boolean()
  def subdomain_match?(domains, host) do
    Enum.any?(domains, fn domain ->
      # info(domains)
      # info(host)
      Regex.match?(domain, host)
      # |> info()
    end)
  end
end
