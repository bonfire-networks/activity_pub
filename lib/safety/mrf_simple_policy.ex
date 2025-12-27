defmodule ActivityPub.MRF.SimplePolicy do
  # import Untangle
  alias ActivityPub.MRF

  @moduledoc """
  Filter activities depending on their origin instance or other criteria.

  `SimplePolicy` is capable of handling most common admin tasks.

  To use `SimplePolicy`, you must enable it. Do so by adding the following to your `:instance` config object, so that it looks like this:

  ```
  config :bonfire, :instance,
    [...]
    rewrite_policy: ActivityPub.MRF.SimplePolicy
  ```

  Once `SimplePolicy` is enabled, you can configure various groups in the `:mrf_simple` config object. These groups are:

  - `media_removal`: Servers in this group will have media stripped from incoming messages.
  - `media_nsfw`: Servers in this group will have the #nsfw tag and sensitive setting injected into incoming messages which contain media.
  - `reject`: Servers in this group will have their messages rejected.
  - `report_removal`: Servers in this group will have their reports (flags) rejected.

  Servers should be configured as lists.

  ### Example

  This example will enable `SimplePolicy`, block media from `illegalporn.biz`, mark media as NSFW from `porn.biz` and `porn.business`, reject messages from `spam.com` and block reports (flags) from `troll.mob`:

  ```
  config :activity_pub, :instance,
    rewrite_policy: [ActivityPub.MRF.SimplePolicy]

  config :activity_pub, :mrf_simple,
    media_removal: ["illegalporn.biz"],
    media_nsfw: ["porn.biz", "porn.business"],
    reject: ["spam.com"],
    report_removal: ["troll.mob"]

  ```
  """
  @behaviour MRF
  require ActivityPub.Config

  @impl true
  def filter(%{"actor" => actor} = object, _opts) do
    actor_info = URI.parse(actor)
    # |> info()

    with {:ok, object} <- check_reject(actor_info, object),
         {:ok, object} <- check_media_removal(actor_info, object),
         {:ok, object} <- check_media_nsfw(actor_info, object),
         {:ok, object} <- check_report_removal(actor_info, object) do
      {:ok, object}
    else
      {:reject, reason} -> {:reject, reason}
      _e -> {:reject, "Object blocked"}
    end
  end

  def filter(%{"id" => actor, "type" => type} = object, _opts)
      when ActivityPub.Config.is_in(type, :supported_actor_types) do
    actor_info = URI.parse(actor)

    with {:ok, object} <- check_avatar_removal(actor_info, object),
         {:ok, object} <- check_banner_removal(actor_info, object) do
      {:ok, object}
    else
      {:reject, reason} -> {:reject, reason}
      _e -> {:reject, "Actor blocked"}
    end
  end

  def filter(object, _opts), do: {:ok, object}

  def check_reject(%{host: actor_host} = _actor_info, object \\ nil) do
    rejects =
      ActivityPub.Config.get([:mrf_simple, :reject])
      |> MRF.subdomains_regex()

    if MRF.subdomain_match?(rejects, actor_host) do
      {:reject, "Instance blocked"}
    else
      {:ok, object}
    end
  end

  defp check_media_removal(
         %{host: actor_host} = _actor_info,
         %{"type" => "Create", "object" => %{"attachment" => child_attachment}} = object
       )
       when length(child_attachment) > 0 do
    media_removal =
      ActivityPub.Config.get([:mrf_simple, :media_removal])
      |> MRF.subdomains_regex()

    object =
      if MRF.subdomain_match?(media_removal, actor_host) do
        child_object = Map.delete(object["object"], "attachment")
        Map.put(object, "object", child_object)
      else
        object
      end

    {:ok, object}
  end

  defp check_media_removal(_actor_info, object), do: {:ok, object}

  defp check_media_nsfw(
         %{host: actor_host} = _actor_info,
         %{
           "type" => "Create",
           "object" => child_object
         } = object
       ) do
    media_nsfw =
      ActivityPub.Config.get([:mrf_simple, :media_nsfw])
      |> MRF.subdomains_regex()

    object =
      if MRF.subdomain_match?(media_nsfw, actor_host) do
        tags = (child_object["tag"] || []) ++ ["nsfw"]
        child_object = Map.put(child_object, "tag", tags)
        child_object = Map.put(child_object, "sensitive", true)
        Map.put(object, "object", child_object)
      else
        object
      end

    {:ok, object}
  end

  defp check_media_nsfw(_actor_info, object), do: {:ok, object}

  defp check_report_removal(
         %{host: actor_host} = _actor_info,
         %{"type" => "Flag"} = object
       ) do
    report_removal =
      ActivityPub.Config.get([:mrf_simple, :report_removal])
      |> MRF.subdomains_regex()

    if MRF.subdomain_match?(report_removal, actor_host) do
      {:reject, "Flag discarded"}
    else
      {:ok, object}
    end
  end

  defp check_report_removal(_actor_info, object), do: {:ok, object}

  defp check_avatar_removal(
         %{host: actor_host} = _actor_info,
         %{"icon" => _icon} = object
       ) do
    avatar_removal =
      ActivityPub.Config.get([:mrf_simple, :avatar_removal])
      |> MRF.subdomains_regex()

    if MRF.subdomain_match?(avatar_removal, actor_host) do
      {:ok, Map.delete(object, "icon")}
    else
      {:ok, object}
    end
  end

  defp check_avatar_removal(_actor_info, object), do: {:ok, object}

  defp check_banner_removal(
         %{host: actor_host} = _actor_info,
         %{"image" => _image} = object
       ) do
    banner_removal =
      ActivityPub.Config.get([:mrf_simple, :banner_removal])
      |> MRF.subdomains_regex()

    if MRF.subdomain_match?(banner_removal, actor_host) do
      {:ok, Map.delete(object, "image")}
    else
      {:ok, object}
    end
  end

  defp check_banner_removal(_actor_info, object), do: {:ok, object}
end
