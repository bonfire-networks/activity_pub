defmodule ActivityPub.MRF do
  @moduledoc """
  Message Rewrite Facility

  **WARNING: Due to how this app currently handles its configuration, MRF is only usable if you're building your own docker image.**

  The Message Rewrite Facility (MRF) is a subsystem that is implemented as a series of hooks that allows the administrator to rewrite or discard messages.

  Possible uses include:

  - marking incoming messages with media from a given account or instance as sensitive
  - rejecting messages from a specific instance
  - rejecting reports (flags) from a specific instance
  - removing/unlisting messages from the public timelines
  - removing media from messages
  - sending only public messages to a specific instance

  The MRF provides user-configurable policies. The default policy is `NoOpPolicy`, which disables the MRF functionality. Bonfire also includes an easy to use policy called `SimplePolicy` which maps messages matching certain pre-defined criterion to actions built into the policy module. It is possible to use multiple, active MRF policies at the same time.

  > See the docs of `ActivityPub.MRF.SimplePolicy` for details about how to use it.


  ### Use with Care

  The effects of MRF policies can be very drastic. It is important to use this functionality carefully. Always try to talk to an admin before writing an MRF policy concerning their instance.

  ## Writing your own MRF Policy

  As discussed above, the MRF system is a modular system that supports pluggable policies. This means that an admin may write a custom MRF policy in Elixir or any other language that runs on the Erlang VM, by specifying the module name in the `rewrite_policy` config setting.

  For example, here is a sample policy module which rewrites all messages to "new message content":

  ```elixir
  # This is a sample MRF policy which rewrites all Notes to have "new message
  # content."
  defmodule Site.RewritePolicy do
    @behavior ActivityPub.MRF

    # Catch messages which contain Note objects with actual data to filter.
    # Capture the object as `object`, the message content as `content` and the
    # entire activity itself as `activity`.
    @impl true
    def filter(%{"type" => "Create", "object" => %{"type" => "Note", "content" => content} = object} = message)
        when is_binary(content) do
      # Subject / CW is stored as summary instead of `name` like other AS2 objects
      # because of Mastodon doing it that way.
      summary = object["summary"]

      # edits go here.
      content = "new message content"

      # Assemble the mutated object.
      object =
        object
        |> Map.put("content", content)
        |> Map.put("summary", summary)

      # Assemble the mutated activity.
      {:ok, Map.put(activity, "object", object)}
    end

    # Let all other messages through without modifying them.
    @impl true
    def filter(message), do: {:ok, message}
  end
  ```

  If you save this file as `lib/site/mrf/rewrite_policy.ex`, it will be included when you next rebuild Bonfire. You can enable it in the configuration like so:

  ```
  config :activity_pub, :instance,
    rewrite_policy: [
      ActivityPub.MRF.SimplePolicy,
      Site.RewritePolicy
    ]
  ```
  """

  # import Untangle

  @callback filter(Map.t(), Keyword.t()) :: {:ok | :reject, Map.t()}

  def filter(policies, object, is_local?) when is_boolean(is_local?) do
    filter(policies, object, is_local: is_local?)
  end

  def filter(policies, %{} = object, opts) do
    policies
    |> Enum.reduce({:ok, object}, fn
      policy, {:ok, object} ->
        policy.filter(object, opts)

      _, error ->
        error
    end)
  end

  def filter(%{} = object, opts),
    do: get_policies() |> filter(object, opts)

  def get_policies do
    Application.get_env(:activity_pub, :instance, %{})
    |> Map.new()
    |> Map.get(
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
