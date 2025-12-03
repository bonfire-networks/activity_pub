defmodule ActivityPub.C2S do
  @moduledoc """
  Formats ActivityPub Client-to-Server activities into Bonfire's internal format.

  Handles the translation between ActivityPub JSON-LD activities and the
  format expected by Bonfire's internal modules like Posts, Likes, etc.
  """

  use Untangle
  use Arrows

  @doc """
  Handles POST requests to /actors/:username/outbox for C2S API.

  Validates the authenticated user matches the actor, formats the ActivityPub
  activity, and delegates to appropriate Bonfire modules.
  """
  def handle_c2s_activity(conn, %{"username" => username} = params) do
    current_actor = conn.assigns[:current_actor]
    current_user = conn.assigns[:current_user]

    with true <- validate_actor_match?(current_actor, username) || {:error, :actor_mismatch},
         true <- not is_nil(current_user) || {:error, :unauthorized} do
      do_handle_c2s_activity(current_user, current_actor, params)
    end
  end

  def do_handle_c2s_activity(current_user, current_actor, params) do
    # Ensure actor is set from the authenticated actor
    params = ensure_actor(params, current_actor)

    with {:ok, activity_type, formatted_attrs} <-
           format_activity(params, current_user),
         {:ok, result} <-
           dispatch_activity(activity_type, formatted_attrs, current_user, params) do
      {:ok, result}
    else
      {:error, reason} ->
        error(reason)

      reason ->
        err(reason, "failed to handle C2S activity")
    end
  end

  defp ensure_actor(params, current_actor) do
    case Map.get(params, "actor") do
      nil ->
        Map.put(params, "actor", current_actor.ap_id)

      _existing ->
        params
    end
  end

  defp validate_actor_match?(%{username: actor_username}, username) when is_binary(username) do
    actor_username == username
  end

  defp validate_actor_match?(_, _) do
    false
  end

  ############################################################################
  # TODO: remove/refactor or move the following to adapter 

  def validate_authorized_scopes(conn, required_scopes) do
    required_scopes = required_scopes |> List.wrap()

    # TODO: should not call Bonfire modules here
    Enum.empty?(required_scopes) or
      Bonfire.OpenID.Plugs.Authorize.authorized_scopes?(conn, required_scopes)
  end

  # TODO: dispatch_activity should instead dispatch to ActivityPub.Federator.Transformer.handle_incoming(attrs, local: true, current_actor: current_actor, current_user: current_user)

  def dispatch_activity("Create", attrs, user, _params) do
    # Only Create activities with a prepared post_content (i.e., Notes) are mapped to posts
    if Map.has_key?(attrs, :post_content) do
      with {:ok, result} <-
             Bonfire.Posts.publish(
               current_user: user,
               post_attrs: attrs,
               boundary: "public"
             ) do
        return_json(result)
      else
        e ->
          err(e, "failed to publish post from C2S Create activity")
      end
    else
      dispatch_activity(nil, attrs, user, %{})
    end
  end

  # Process activities through APActivities for proper Bonfire integration
  def dispatch_activity(_activity_type, _attrs, user, params) do
    # Store in ap_object for C2S inbox compliance
    with {:ok, object} <- ActivityPub.Object.insert(params, true) do
      # Also create APActivity for Bonfire UI display
      case Bonfire.Social.APActivities.ap_receive(user, params, nil, true) do
        {:ok, _apactivity} ->
          {:ok, object}

        e ->
          err(e, "failed to create APActivity for received C2S activity")
          # Still return success if ap_object was created
          {:ok, object}
      end
    else
      e ->
        err(e, "failed to store C2S activity as ap_object")
    end
    |> return_json()
  end

  defp return_json({:ok, object}), do: return_json(object)

  defp return_json(%{} = object) do
    case object do
      %{activity: %{federate_activity_pub: object}} -> {:ok, object}
      %{federate_activity_pub: object} -> {:ok, object}
      _ -> {:ok, object}
    end
  end

  defp return_json(other), do: other

  @doc """
  Formats an ActivityPub activity for processing by Bonfire modules.

  Returns {:ok, activity_type, formatted_attrs} or {:error, reason}.
  """
  def format_activity(params, current_user) do
    case Map.get(params, "type") do
      "Create" ->
        # Only handle Create as post if object is a Note
        with {:ok, object} <- extract_object(params) do
          case object["type"] do
            "Note" -> format_note_activity("Create", params, current_user)
            _ -> format_generic_activity("Create", params, current_user)
          end
        end

      "Note" ->
        format_auto_note(params, current_user)

      type when is_binary(type) ->
        format_generic_activity(type, params, current_user)

      _ ->
        {:error, :unsupported_activity}
    end
  end

  defp format_note_activity("Create", params, user) do
    with {:ok, object} <- extract_object(params),
         {:ok, content_attrs} <- format_object_for_post(object),
         {:ok, boundaries} <- extract_boundaries(params, user) do
      attrs =
        Map.merge(content_attrs, %{
          to_circles: boundaries[:to_circles],
          to_boundaries: boundaries[:to_boundaries]
        })

      {:ok, "Create", attrs}
    end
  end

  defp format_auto_note(params, user) do
    # Only for bare Note objects
    with {:ok, content_attrs} <- format_object_for_post(params),
         {:ok, boundaries} <- extract_boundaries(params, user) do
      attrs =
        Map.merge(content_attrs, %{
          to_circles: boundaries[:to_circles],
          to_boundaries: boundaries[:to_boundaries]
        })

      {:ok, "Create", attrs}
    end
  end

  defp format_generic_activity(type, params, user) do
    # For any activity type, just extract basic boundaries for visibility
    with {:ok, boundaries} <- extract_boundaries(params, user) do
      attrs = %{
        to_circles: boundaries[:to_circles],
        to_boundaries: boundaries[:to_boundaries]
      }

      {:ok, type, attrs}
    end
  end

  defp extract_object(%{"object" => object}) when is_map(object), do: {:ok, object}

  defp extract_object(%{"object" => object_id}) when is_binary(object_id) do
    # For object references, we might need to fetch or resolve them
    # For now, return the ID and let the handler deal with it
    {:ok, %{"id" => object_id}}
  end

  defp extract_object(_), do: {:error, "Missing or invalid object"}

  defp extract_target(%{"object" => object}), do: {:ok, object}
  defp extract_target(%{"target" => target}), do: {:ok, target}
  defp extract_target(_), do: {:error, "Missing object or target"}

  defp format_object_for_post(%{"type" => "Note"} = object) do
    attrs = %{
      post_content: %{
        html_body: Map.get(object, "content", ""),
        summary: Map.get(object, "summary"),
        name: Map.get(object, "name")
      }
    }

    # Handle reply_to
    attrs =
      case Map.get(object, "inReplyTo") do
        reply_id when is_binary(reply_id) ->
          Map.put(attrs, :reply_to_id, reply_id)

        _ ->
          attrs
      end

    {:ok, attrs}
  end

  defp format_object_for_post(%{"type" => "Article"} = object) do
    # Articles are similar to Notes but might have richer content
    format_object_for_post(Map.put(object, "type", "Note"))
  end

  defp format_object_for_post(object) when is_map(object) do
    # Generic object handling - treat as Note
    format_object_for_post(Map.put(object, "type", "Note"))
  end

  defp format_object_for_post(_) do
    {:error, "Unsupported object type"}
  end

  defp extract_boundaries(params, user) do
    to_list = parse_addressing(Map.get(params, "to", []))
    cc_list = parse_addressing(Map.get(params, "cc", []))
    bto_list = parse_addressing(Map.get(params, "bto", []))
    bcc_list = parse_addressing(Map.get(params, "bcc", []))

    # Combine all addressing
    all_recipients = to_list ++ cc_list ++ bto_list ++ bcc_list

    # Convert to Bonfire boundaries
    cond do
      public_addressed?(to_list ++ cc_list) ->
        {:ok, [to_circles: [:guests], to_boundaries: [:public]]}

      followers_addressed?(to_list ++ cc_list, user) ->
        {:ok, [to_circles: [user], to_boundaries: [:followers]]}

      true ->
        # Direct message or specific addressing
        circles = extract_user_circles(all_recipients)
        {:ok, [to_circles: circles, to_boundaries: [:mentions]]}
    end
  end

  defp parse_addressing(addresses) when is_list(addresses), do: addresses
  defp parse_addressing(address) when is_binary(address), do: [address]
  defp parse_addressing(_), do: []

  defp public_addressed?(addresses) do
    Enum.any?(
      addresses,
      &(&1 == "https://www.w3.org/ns/activitystreams#Public" || &1 == "Public")
    )
  end

  defp followers_addressed?(addresses, user) do
    user_followers_url = get_followers_url(user)
    Enum.any?(addresses, &(&1 == user_followers_url))
  end

  defp get_followers_url(user) do
    # Get the user's followers collection URL - simplified for now
    # In a full implementation, this would use the actual actor lookup
    username = get_in(user, [:character, :username]) || Map.get(user, :username)

    if username do
      "#{ActivityPub.Web.base_url()}/pub/actors/#{username}/followers"
    else
      nil
    end
  end

  defp extract_user_circles(addresses) do
    # For now, return empty list - in a full implementation this would
    # resolve ActivityPub actor URLs to Bonfire users and create appropriate circles
    []
  end
end
