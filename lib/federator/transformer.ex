defmodule ActivityPub.Federator.Transformer do
  @moduledoc """
  This module normalises outgoing data to conform with AS2/AP specs
  and handles incoming objects and activities
  """
  import Untangle
  use Arrows

  require ActivityPub.Config

  alias ActivityPub.Config
  alias ActivityPub.Actor
  alias ActivityPub.Federator.Adapter
  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Object
  alias ActivityPub.Utils
  # alias ActivityPub.Safety.Containment

  @doc """
  Translates MN Entity to an AP compatible format
  """
  def prepare_outgoing(%{"type" => "Create", "object" => %{"type" => "Group"}} = data) do
    data =
      data
      |> Map.merge(Utils.make_json_ld_header(:actor))

    # |> Map.delete("bto")
    # |> Map.delete("bcc")

    {:ok, data}
  end

  def prepare_outgoing(%{"type" => "Create", "object" => object} = data) do
    data =
      data
      |> Map.put("object", prepare_outgoing_object(object))
      |> Map.merge(Utils.make_json_ld_header(:object))

    # |> Map.delete("bto")
    # |> Map.delete("bcc")

    {:ok, data}
  end

  def prepare_outgoing(%{"object" => object} = data) do
    data =
      data
      |> Map.put("object", prepare_outgoing_object(object))
      |> Map.merge(Utils.make_json_ld_header(:object))

    # |> Map.delete("bto")
    # |> Map.delete("bcc")

    {:ok, data}
  end

  # hack for mastodon accept and reject type activity formats
  def prepare_outgoing(%{"type" => _type} = data) do
    data =
      data
      |> Map.merge(Utils.make_json_ld_header(:object))

    # |> Map.delete("bto")
    # |> Map.delete("bcc")

    {:ok, data}
  end

  def prepare_outgoing(%Object{object: %Object{} = object} = activity) do
    activity.data
    |> Map.put("object", prepare_outgoing_object(object))
    |> prepare_outgoing()
  end

  def prepare_outgoing(%Object{} = activity) do
    prepare_outgoing(activity.data)
  end

  defp prepare_outgoing_object(nil), do: nil

  defp prepare_outgoing_object(%Object{} = object) do
    object
    |> set_replies()

    # |> Map.get(:data) # done by set_replies/2
    # |> Map.delete("bto")
    # |> Map.delete("bcc")

    # |> debug
  end

  defp prepare_outgoing_object(object) do
    case Object.normalize(object, false) do
      %Object{} = object ->
        prepare_outgoing_object(object)

      %{ap_id: ap_id} = _object ->
        ap_id

      nil ->
        debug(object, "Normalization returned nil, just return the non-normalised object")

      other ->
        if is_list(object) do
          # support for list of objects (eg. in flags)
          # TODO: should each object in the list be normalised?
          object
        else
          warn(other, "Unexpected normalised object")
          debug(object, "Just return the non-normalised object")
        end
    end
  end

  def preserve_privacy_of_outgoing(other, target_instance_uri \\ nil)

  def preserve_privacy_of_outgoing(%{"object" => object} = data, %{host: host}) do
    data
    |> Map.put("object", preserve_privacy_of_outgoing(object, %{host: host}))
    |> Map.update("bto", [], &filter_recipients_visibility_by_instance(&1, host))
    |> Map.update("bcc", [], &filter_recipients_visibility_by_instance(&1, host))
  end

  def preserve_privacy_of_outgoing(%{} = data, %{host: host}) do
    data
    |> Map.update("bto", [], &filter_recipients_visibility_by_instance(&1, host))
    |> Map.update("bcc", [], &filter_recipients_visibility_by_instance(&1, host))
  end

  def preserve_privacy_of_outgoing(%{"object" => object} = data, _) do
    data
    |> Map.put("object", preserve_privacy_of_outgoing(object, nil))
    |> Map.delete("bto")
    |> Map.delete("bcc")
  end

  def preserve_privacy_of_outgoing(%{} = data, _) do
    data
    |> Map.delete("bto")
    |> Map.delete("bcc")
  end

  def preserve_privacy_of_outgoing(other, _), do: other

  defp filter_recipients_visibility_by_instance(bto, host) when is_list(bto) do
    Enum.filter(bto, &recipient_is_from_instance?(&1, host))
  end

  defp filter_recipients_visibility_by_instance(bto, host) do
    if recipient_is_from_instance?(bto, host), do: host, else: []
  end

  defp recipient_is_from_instance?(bto, host) when is_binary(bto) do
    URI.parse(bto).host == host
  end

  defp recipient_is_from_instance?(%{"id" => bto}, host) when is_binary(bto) do
    recipient_is_from_instance?(bto, host)
  end

  defp recipient_is_from_instance?(%{data: %{"id" => bto}}, host) when is_binary(bto) do
    recipient_is_from_instance?(bto, host)
  end

  defp check_remote_object_deleted(data, true) do
    if Object.is_deleted?(data) do
      {:ok, data}
    else
      {:error, :not_deleted}
    end
  end

  defp check_remote_object_deleted(object, _) do
    ap_id = Object.get_ap_id(object)
    debug(ap_id, "Checking delete permission for")

    case Fetcher.fetch_remote_object_from_id(ap_id, return_tombstones: true, only_fetch: true)
         |> debug("remote fetched") do
      {:error, :not_found} ->
        # ok it seems gone from there
        {:ok, nil}

      {:ok, %{} = data} ->
        if Object.is_deleted?(data) do
          {:ok, data}
        else
          {:error, :not_deleted}
        end

      {:error, :nxdomain} ->
        warn(ap_id, "could not reach the instance to verify deletion")
        # TODO: keep in Oban queue to retry a few times?
        {:error, :not_deleted}

      e ->
        error(e)
        {:error, :not_deleted}
    end
  end

  # incoming activities

  @doc """
  Modifies an incoming AP object (mastodon format) to our internal format.
  """
  def fix_object(object, options \\ [])

  def fix_object(%{} = object, options) do
    object
    |> fix_actor()
    |> fix_url()
    |> fix_mfm_content()
    |> fix_attachments()
    |> fix_context(options)
    |> fix_in_reply_to(options)
    |> fix_replies(options)
    |> fix_quote_url(options)
    |> fix_emoji()
    |> fix_tag()
    |> fix_content_map()
    |> fix_addressing()
    |> fix_summary()
  end

  def fix_object(object, _options), do: object

  def fix_summary(%{"summary" => nil} = object) do
    Map.put(object, "summary", "")
  end

  def fix_summary(%{"summary" => _} = object) do
    # summary is present, nothing to do
    object
  end

  def fix_summary(object), do: Map.put(object, "summary", "")

  def fix_addressing(object) do
    # {:ok, %User{follower_address: follower_collection}} =
    #   object
    #   |> Object.actor_id_from_data()
    #   |> Actor.get_cached(ap_id: ...)

    object
    |> Object.normalise_tos()

    # TODO?
    # |> fix_explicit_addressing(follower_collection)
    # |> CommonFixes.fix_implicit_addressing(follower_collection)
  end

  # if directMessage flag is set to true, leave the addressing alone
  # def fix_explicit_addressing(%{"directMessage" => true} = object, _follower_collection),
  #   do: object

  # def fix_explicit_addressing(%{"to" => to, "cc" => cc} = object, follower_collection) do
  #   explicit_mentions =
  #     determine_explicit_mentions(object) ++
  #       [ActivityPub.Config.public_uri(), follower_collection]

  #   explicit_to = Enum.filter(to, fn x -> x in explicit_mentions end)
  #   explicit_cc = Enum.filter(to, fn x -> x not in explicit_mentions end)

  #   final_cc =
  #     (cc ++ explicit_cc)
  #     |> Enum.filter(& &1)
  #     |> Enum.reject(fn x -> String.ends_with?(x, "/followers") and x != follower_collection end)
  #     |> Enum.uniq()

  #   object
  #   |> Map.put("to", explicit_to)
  #   |> Map.put("cc", final_cc)
  # end

  # @spec determine_explicit_mentions(map()) :: [any]
  # def determine_explicit_mentions(%{"tag" => tag}) when is_list(tag) do
  #   Enum.flat_map(tag, fn
  #     %{"type" => "Mention", "href" => href} -> [href]
  #     _ -> []
  #   end)
  # end

  # def determine_explicit_mentions(%{"tag" => tag} = object) when is_map(tag) do
  #   object
  #   |> Map.put("tag", [tag])
  #   |> determine_explicit_mentions()
  # end

  # def determine_explicit_mentions(_), do: []

  def fix_actor(data) do
    actor =
      data
      |> Map.put_new("actor", data["attributedTo"])
      |> Object.actor_id_from_data()

    data
    |> Map.put("actor", actor)
    |> Map.put("attributedTo", actor)
  end

  def fix_in_reply_to(object, options \\ [])

  def fix_in_reply_to(%{"inReplyTo" => in_reply_to} = object, options)
      when not is_nil(in_reply_to) do
    with in_reply_to_id when is_binary(in_reply_to_id) <- Utils.single_ap_id(in_reply_to),
         _ <- Fetcher.maybe_fetch(in_reply_to_id, options) |> info("fetched reply_to?") do
      object
      |> Map.put("inReplyTo", in_reply_to_id)
      # |> Map.put("context", replied_object.data["context"] || object["conversation"]) # TODO as an update when we get the async inReplyTo?
      |> Map.drop(["conversation", "inReplyToAtomUri"])
    else
      e ->
        warn(e, "Couldn't find reply_to @ #{inspect(in_reply_to)}")
        object
    end
  end

  def fix_in_reply_to(object, _options), do: object

  def fix_quote_url(object, options \\ [])

  def fix_quote_url(%{"quoteUri" => quote_url} = object, options)
      when not is_nil(quote_url) do
    with quote_ap_id when is_binary(quote_ap_id) <- Utils.single_ap_id(quote_url),
         _ <- Fetcher.maybe_fetch(quote_ap_id, options) do
      object
      |> Map.put("quoteUri", quote_ap_id)
    else
      e ->
        warn(e, "Couldn't fetch quote@#{inspect(quote_url)}")
        object
    end
  end

  # Soapbox
  def fix_quote_url(%{"quoteUrl" => quote_url} = object, options) do
    object
    |> Map.put("quoteUri", quote_url)
    |> Map.delete("quoteUrl")
    |> fix_quote_url(options)
  end

  # Old Fedibird (bug)
  # https://github.com/fedibird/mastodon/issues/9
  def fix_quote_url(%{"quoteURL" => quote_url} = object, options) do
    object
    |> Map.put("quoteUri", quote_url)
    |> Map.delete("quoteURL")
    |> fix_quote_url(options)
  end

  def fix_quote_url(%{"_misskey_quote" => quote_url} = object, options) do
    object
    |> Map.put("quoteUri", quote_url)
    |> Map.delete("_misskey_quote")
    |> fix_quote_url(options)
  end

  def fix_quote_url(object, _), do: object

  def fix_context(object, options) do
    context = object["context"] || object["conversation"] || object["inReplyTo"]

    case Utils.single_ap_id(context) do
      context = "tag:" <> _ ->
        # TODO: how to handle Mastodon's thread IDs?
        object
        |> Map.put("context", context)

      context when is_binary(context) ->
        # fetching async
        Fetcher.maybe_fetch(context, options)
        |> debug("fetched context?")

        object
        |> Map.put("context", context)

      _ ->
        warn(context, "Couldn't find context, use self")

        object
        |> Map.put("context", object["id"])
    end
    |> Map.drop(["conversation"])
  end

  def fix_attachments(%{"attachment" => attachments} = object) when is_list(attachments) do
    attachments
    |> debug()
    |> Enum.map(fn data ->
      url =
        cond do
          is_list(data["url"]) -> List.first(data["url"])
          is_map(data["url"]) -> data["url"]
          true -> nil
        end
        |> debug()

      media_type =
        cond do
          is_map(url) and is_bitstring(url["mediaType"]) and
              MIME.extensions(url["mediaType"]) != [] ->
            url["mediaType"]

          is_bitstring(data["mediaType"]) and MIME.extensions(data["mediaType"]) != [] ->
            data["mediaType"]

          is_bitstring(data["mimeType"]) and MIME.extensions(data["mimeType"]) != [] ->
            data["mimeType"]

          true ->
            nil
        end

      href =
        cond do
          is_map(url) && is_binary(url["href"]) -> url["href"]
          is_binary(data["url"]) -> data["url"]
          is_binary(data["href"]) -> data["href"]
          true -> nil
        end
        |> debug()

      if href do
        attachment_url =
          %{
            "href" => href,
            "type" => Map.get(url || %{}, "type", "Link")
          }
          |> Utils.put_if_present("mediaType", media_type)
          |> Utils.put_if_present("width", (url || %{})["width"] || data["width"])
          |> Utils.put_if_present("height", (url || %{})["height"] || data["height"])

        %{
          "url" => [attachment_url],
          "type" => data["type"] || "Document"
        }
        |> Utils.put_if_present("mediaType", media_type)
        |> Utils.put_if_present("name", data["name"])
        |> Utils.put_if_present("blurhash", data["blurhash"])
      else
        nil
      end
    end)
    |> Enum.filter(& &1)
    |> debug()
    |> Map.put(object, "attachment", ...)
  end

  def fix_attachments(%{"attachment" => attachment} = object) when is_map(attachment) do
    object
    |> Map.put("attachment", [attachment])
    |> fix_attachments()
  end

  def fix_attachments(object), do: object

  def fix_url(%{"url" => url} = object) when is_map(url) do
    if object == %{"url" => url}, do: Map.put(object, "url", url["href"]), else: object
  end

  def fix_url(%{"url" => [url]} = object) do
    fix_url(%{"url" => url})
  end

  # def fix_url(%{"url" => url} = object) when is_list(url) do
  #   first_element = Enum.at(url, 0)

  #   url_string =
  #     cond do
  #       is_bitstring(first_element) -> first_element
  #       is_map(first_element) -> first_element["href"] || ""
  #       true -> ""
  #     end

  #   Map.put(object, "url", url_string)
  # end

  def fix_url(object), do: object

  def fix_emoji(%{"emoji" => emoji} = object) when is_list(emoji) do
    object
  end

  def fix_emoji(%{"tag" => tags} = object) when is_list(tags) do
    emoji =
      tags
      |> Enum.filter(fn data -> is_map(data) and data["type"] == "Emoji" and data["icon"] end)
      |> Enum.reduce(%{}, fn data, mapping ->
        name = String.trim(data["name"], ":")

        Map.put(mapping, name, data["icon"]["url"])
      end)

    Map.put(object, "emoji", emoji)
  end

  def fix_emoji(%{"tag" => %{"type" => "Emoji"} = tag} = object) do
    name = String.trim(tag["name"], ":")
    emoji = %{name => tag["icon"]["url"]}

    Map.put(object, "emoji", emoji)
  end

  def fix_emoji(object), do: object

  def fix_tag(%{"tag" => tag} = object) when is_list(tag) do
    tags =
      tag
      |> Enum.map(fn
        %{"type" => "Hashtag", "name" => "#" <> name} -> name
        %{"type" => "Hashtag", "name" => name} -> name
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    Map.put(object, "tag", tag ++ tags)
  end

  def fix_tag(%{"tag" => %{} = tag} = object) do
    object
    |> Map.put("tag", [tag])
    |> fix_tag
  end

  def fix_tag(object), do: object

  def fix_content_map(%{"contentMap" => content_map} = object) when is_map(content_map) do
    if Enum.count(content_map) == 1 do
      # content usually has the same data as single language so this should do for now
      Map.put_new_lazy(
        object,
        "content",
        fn -> List.first(Map.values(content_map)) end
      )
    else
      Map.put(
        object,
        "content",
        Enum.map(content_map, fn {locale, content} ->
          lang =
            with {:ok, lang_localized} <- Cldr.LocaleDisplay.display_name(locale, locale: locale) do
              String.capitalize(lang_localized)
            else
              _ -> String.upcase(locale)
            end

          "<div lang='#{locale}'><em data-role='lang'>#{lang}</em>:\n#{content}</div>"
        end)
        |> Enum.join("\n")
      )
    end
  end

  def fix_content_map(object), do: object

  # defp fix_type(%{"type" => "Note", "inReplyTo" => reply_id, "name" => _} = object, options)
  #      when is_binary(reply_id) do
  #   options = Keyword.put(options, :fetch, true)

  #   with %Object{data: %{"type" => "Question"}} <- Object.normalize(reply_id, options) do
  #     Map.put(object, "type", "Answer")
  #   else
  #     _ -> object
  #   end
  # end

  # defp fix_type(object, _options), do: object

  # See https://akkoma.dev/FoundKeyGang/FoundKey/issues/343
  # Misskey/Foundkey drops some of the custom formatting when it sends remotely
  # So this basically reprocesses the MFM source
  defp fix_mfm_content(
         %{"source" => %{"mediaType" => "text/x.misskeymarkdown", "content" => content}} = object
       )
       when is_binary(content) do
    formatted = format_input(content, "text/x.misskeymarkdown")

    Map.put(object, "content", formatted)
  end

  # See https://github.com/misskey-dev/misskey/pull/8787
  # This is for compatibility with older Misskey instances
  defp fix_mfm_content(%{"_misskey_content" => content} = object) when is_binary(content) do
    formatted = format_input(content, "text/x.misskeymarkdown")

    object
    |> Map.put("source", %{
      "content" => content,
      "mediaType" => "text/x.misskeymarkdown"
    })
    |> Map.put("content", formatted)
    |> Map.delete("_misskey_content")
  end

  defp fix_mfm_content(data), do: data

  def format_input(text, "text/x.misskeymarkdown", _options \\ []) do
    if Code.ensure_loaded?(MfmParser.Parser) and
         Code.ensure_loaded?(Earmark) do
      text
      |> Earmark.as_html!(breaks: true, compact_output: true)
      |> MfmParser.Parser.parse()
      |> MfmParser.Encoder.to_html()
    else
      warn("MFM parser or Earmark not available, returning original text")
      text
    end
  end

  def take_emoji_tags(%{emoji: emoji}) do
    emoji
    |> Map.to_list()
    |> Enum.map(&build_emoji_tag/1)
  end

  def take_emoji_tags(_) do
    []
  end

  # TODO: we should probably send mtime instead of unix epoch time for updated
  def add_emoji_tags(%{"emoji" => emoji} = object) do
    tags = object["tag"] || []

    out = Enum.map(emoji, &build_emoji_tag/1)

    Map.put(object, "tag", tags ++ out)
  end

  def add_emoji_tags(object), do: object

  defp build_emoji_tag({name, url}) do
    %{
      "icon" => %{"url" => "#{URI.encode(url)}", "type" => "Image"},
      "name" => ":" <> name <> ":",
      "type" => "Emoji",
      "updated" => "1970-01-01T00:00:00Z",
      "id" => url
    }
  end

  def fix_replies(%{"replies" => replies} = data, options)
      when is_list(replies) and replies != [] do
    Fetcher.maybe_fetch(replies, options)
    |> info("fetched replies?")

    # TODO: update the data with only IDs in case we have full objects?
    data
  end

  def fix_replies(%{"replies" => %{"items" => replies}} = data, options)
      when is_list(replies) and replies != [] do
    Fetcher.maybe_fetch(replies, options)
    |> info("fetched replies?")

    # TODO: update the data with only IDs in case we have full objects?
    Map.put(data, "replies", replies)
  end

  def fix_replies(%{"replies" => %{"first" => replies}} = data, options)
      when is_list(replies) and replies != [] do
    Fetcher.maybe_fetch(replies, options)
    |> info("fetched replies?")

    # TODO: update the data with only IDs in case we have full objects?
    Map.put(data, "replies", replies)
  end

  def fix_replies(%{"replies" => %{"first" => %{"items" => replies}}} = data, options)
      when is_list(replies) and replies != [] do
    Fetcher.maybe_fetch(replies, options)
    |> info("fetched replies?")

    # TODO: update the data with only IDs in case we have full objects?
    Map.put(data, "replies", replies)
  end

  def fix_replies(%{"replies" => %{"first" => first}} = data, options) do
    # Note: seems like too much recursion was triggered with `entries_async`
    # with {:ok, replies} <- Fetcher.fetch_collection(first, mode: :entries_async) do
    #   Map.put(data, "replies", replies)
    # else
    #   {:error, _} ->
    #     warn(first, "Could not fetch replies")
    # Map.put(data, "replies", [])
    # end

    Fetcher.fetch_collection(
      first,
      Keyword.merge(
        [mode: options[:fetch_collection] || options[:fetch_collection_entries]],
        options
      )
      |> debug("opts")
    )
    |> info("fetched collection?")

    data
  end

  def fix_replies(data, _), do: Map.delete(data, "replies")

  defp replies_limit, do: Config.get([:activity_pub, :note_replies_output_limit], 10)

  @doc """
  Serialized Mastodon-compatible `replies` collection containing _self-replies_.
  Based on Mastodon's ActivityPub::NoteSerializer#replies.
  """
  def set_replies(%Object{} = object) do
    replies_uris =
      with limit when limit > 0 <- replies_limit() do
        object
        |> Object.self_replies_ids(limit)
        |> debug("self_replies_ids")
      else
        _ -> []
      end

    set_replies(object.data, replies_uris)
  end

  def set_replies(%{"id" => id} = obj_data) do
    replies_uris =
      with limit when limit > 0 <- replies_limit(),
           %Object{} = object <- Object.get_cached(ap_id: id) do
        object
        |> Object.self_replies_ids(limit)
        |> debug("self_replies_ids")
      else
        _ -> []
      end

    set_replies(obj_data, replies_uris)
  end

  defp set_replies(obj, []) do
    obj
  end

  defp set_replies(obj, replies_uris) do
    replies_collection = %{
      "type" => "Collection",
      "items" => replies_uris
    }

    Map.merge(obj, %{"replies" => replies_collection})
  end

  def replies(%{"replies" => %{"first" => %{"items" => items}}}) when not is_nil(items) do
    items
  end

  def replies(%{"replies" => %{"items" => items}}) when not is_nil(items) do
    items
  end

  def replies(_), do: []

  @doc """
  Handles incoming data, inserts it into the database and triggers side effects if the data is a supported activity type.
  """
  def handle_incoming(data, opts \\ [])

  # Flag objects are placed ahead of the ID check because Mastodon 2.8 and earlier send them
  # with nil ID.
  def handle_incoming(%{"type" => "Flag", "object" => objects, "actor" => actor} = data, _opts) do
    with objects = List.wrap(objects),
         context <- data["context"],
         content <- data["content"] || "",
         {:ok, actor} <- Actor.get_cached_or_fetch(ap_id: actor),

         # Reduce the object list to find the reported user.
         account <-
           Enum.reduce_while(objects, nil, fn ap_id, _ ->
             with {:ok, actor} <- Actor.get_cached(ap_id: ap_id) do
               {:halt, actor}
             else
               _ -> {:cont, nil}
             end
           end),

         # Remove the reported user from the object list.
         statuses <-
           if(account, do: Enum.filter(objects, fn ap_id -> ap_id != account.data["id"] end)) do
      params = %{
        activity_id: data["id"],
        actor: actor,
        context: context,
        account: account,
        statuses: statuses || objects,
        content: content,
        local: false,
        additional: %{
          "cc" => if(account, do: [account.data["id"]]) || []
        }
      }

      ActivityPub.flag(params)
    end
  end

  # disallow objects with bogus IDs
  def handle_incoming(%{"id" => nil}, _opts), do: {:error, "No object ID"}
  def handle_incoming(%{"id" => ""}, _opts), do: {:error, "No object ID"}
  # length of https:// = 8, should validate better, but good enough for now.
  def handle_incoming(%{"id" => id}, _opts) when is_binary(id) and byte_size(id) < 8,
    do: {:error, "No object ID"}

  # Incoming actor create, just fetch from source
  def handle_incoming(
        %{
          "type" => "Create",
          "object" => %{"type" => "Group", "id" => ap_id}
        },
        _opts
      ),
      do: Actor.get_cached_or_fetch(ap_id: ap_id)

  def handle_incoming(%{"type" => "Create", "object" => _object} = data, opts) do
    info("Handle incoming creation of an object")

    %{"object" => object} = data = Object.normalize_actors(data)

    # |> debug("with actors normalized")

    object =
      fix_object(object, opts)
      |> info("normalized incoming object")

    actor_id =
      Object.actor_id_from_data(data)
      |> debug("the actor_id")

    {:ok, actor} =
      with {:ok, actor} <- is_binary(actor_id) and Actor.get_cached_or_fetch(ap_id: actor_id) do
        {:ok, actor}
      else
        e ->
          warn(e, "could not get or fetch actor: #{inspect(actor_id)}")
          Utils.service_actor()
      end

    params = %{
      activity_id: data["id"],
      to: data["to"],
      object: object,
      actor: actor,
      context: if(is_map(object), do: object["context"] || object["conversation"]),
      local: false,
      published: data["published"],
      additional:
        Map.take(data, [
          "cc",
          "bto",
          "bcc",
          "directMessage",
          "id"
        ])
    }

    with nil <- Object.get_activity_for_object_ap_id(object) do
      ActivityPub.create(params)
    else
      %{data: %{"type" => "Tombstone"}} = _activity ->
        debug("do not save Tombstone in adapter")

        :skip

      %Object{pointer_id: nil} = activity ->
        debug(
          activity,
          "a Create for this Object already exists, but not in the Adapter, try again"
        )

        with {:ok, adapter_object} <-
               Adapter.maybe_handle_activity(
                 Map.put(activity, :data, Map.merge(activity.data, %{"object" => object}))
               ) do
          {:ok, Map.put(activity, :pointer, adapter_object)}
        end

      %Object{} = activity ->
        debug("a Create for this Object already exists")
        {:ok, activity}

      e ->
        error(e)
    end
  end

  def handle_incoming(
        %{
          "type" => "Follow",
          "object" => followed,
          "actor" => follower
        } = data,
        _opts
      ) do
    info("Handle incoming follow")

    with {:ok, follower} <- Actor.get_cached_or_fetch(ap_id: follower) |> debug("follower"),
         {:ok, followed} <- Actor.get_cached(ap_id: followed) |> debug("followed") do
      ActivityPub.follow(%{
        actor: follower,
        object: followed,
        activity_id: data["id"],
        local: false
      })
    end
  end

  def handle_incoming(
        %{
          "type" => "Accept" = type,
          "object" => follow_object,
          "actor" => _actor
        } = data,
        _opts
      ) do
    debug("Handle incoming Accept")

    with followed_actor <- Object.actor_from_data(data) |> debug(),
         {:ok, followed} <- Actor.get_cached(ap_id: followed_actor) |> debug(),
         {:ok, follow_activity} <- Object.get_follow_activity(follow_object, followed) |> debug() do
      ActivityPub.accept(%{
        activity_id: data["id"],
        to: follow_activity.data["to"],
        type: type,
        actor: followed,
        object: follow_activity.data["id"],
        local: false
      })
      |> debug()
    else
      e ->
        error(e, "Could not handle incoming Accept")
    end
  end

  def handle_incoming(
        %{
          "type" => "Reject" = type,
          "object" => follow_object,
          "actor" => _actor
        } = data,
        _opts
      ) do
    debug("Handle incoming Reject")

    with followed_actor <- Object.actor_from_data(data) |> debug(),
         {:ok, followed} <- Actor.get_cached(ap_id: followed_actor) |> debug(),
         {:ok, follow_activity} <- Object.get_follow_activity(follow_object, followed) |> debug() do
      ActivityPub.reject(%{
        activity_id: data["id"],
        to: follow_activity.data["to"],
        type: type,
        actor: followed,
        object: follow_activity.data["id"],
        local: false
      })
      |> debug()
    else
      e ->
        error(e, "Could not handle incoming Reject")
    end
  end

  def handle_incoming(
        %{
          "type" => "Like",
          "object" => object_id,
          "actor" => _actor
        } = data,
        _opts
      ) do
    info("Handle incoming like")

    with actor <- Object.actor_from_data(data),
         {:ok, actor} <- Actor.get_cached_or_fetch(ap_id: actor),
         {:ok, object} <- object_normalize_and_maybe_fetch(object_id),
         {:ok, activity} <-
           ActivityPub.like(%{
             actor: actor,
             object: object,
             activity_id: data["id"],
             local: false
           }) do
      {:ok, activity}
    else
      e -> error(e)
    end
  end

  def handle_incoming(
        %{
          "type" => "Announce",
          "object" => object_id,
          "actor" => _actor
        } = data,
        _opts
      ) do
    info("Handle incoming boost")

    with actor <- Object.actor_from_data(data),
         {:ok, actor} <- Actor.get_cached_or_fetch(ap_id: actor),
         {:ok, object} <- object_normalize_and_maybe_fetch(object_id),
         public <- Utils.public?(data, object),
         {:ok, activity} <-
           ActivityPub.announce(%{
             activity_id: data["id"],
             actor: actor,
             object: object,
             local: false,
             public: public
           }) do
      {:ok, activity}
    else
      e -> error(e)
    end
  end

  def handle_incoming(
        %{
          "type" => "Update",
          "object" => %{"type" => type, "id" => update_actor_id} = _update_actor_data,
          "actor" => actor_id
        } = data,
        opts
      )
      when ActivityPub.Config.is_in(type, :supported_actor_types) and actor_id == update_actor_id do
    # TODO: should a Person be able to update a Group or the like?

    debug(actor_id, "update an Actor")
    debug(opts, "opts")

    #  NOTE: we avoid even passing the update_actor_data to avoid accepting invalid updates
    with {:ok, actor} <- Actor.update_actor(actor_id, nil, opts[:already_fetched] != true) do
      # Skip all of that because it's handled elsewhere after fetching
      #  {:ok, actor} <- Actor.get_cached(ap_id: actor_id),
      #  {:ok, _} <- Actor.set_cache(actor) do
      # TODO: do we need to register an Update activity for this?
      # ActivityPub.update(%{
      #   id: data["id"],
      #   local: false,
      #   to: data["to"] || [],
      #   cc: data["cc"] || [],
      #   object: actor.data, # NOTE: we use the data from update_actor which was re-fetched from the source
      #   actor: actor
      # })
      {:ok, actor}
    else
      e ->
        error(e, "could not update")
    end
  end

  def handle_incoming(
        %{
          "type" => "Update",
          "object" => %{"type" => _object_type} = object,
          "actor" => actor
        } = data,
        _opts
      ) do
    info("Handle incoming update of an Object")

    with {:ok, actor} <- Actor.get_cached(ap_id: actor) do
      #  {:ok, actor} <- Actor.get_cached(ap_id: actor_id),
      #  {:ok, _} <- Actor.set_cache(actor) do
      ActivityPub.update(%{
        local: false,
        to: data["to"] || [],
        cc: data["cc"] || [],
        object: object,
        actor: actor
      })
    else
      e ->
        error(e, "could not update")
    end
  end

  def handle_incoming(
        %{
          "type" => "Block",
          "object" => blocked,
          "actor" => blocker
        } = data,
        _opts
      ) do
    info("Handle incoming block")

    with {:ok, %{local: true} = blocked} <- Actor.get_cached(ap_id: blocked),
         {:ok, blocker} <- Actor.get_cached(ap_id: blocker),
         {:ok, activity} <-
           ActivityPub.block(%{
             actor: blocker,
             object: blocked,
             activity_id: data["id"],
             local: false
           }) do
      {:ok, activity}
    else
      e -> error(e)
    end
  end

  def handle_incoming(
        %{
          "type" => "Delete",
          "object" => object
          # "actor" => _actor
        } = _data,
        opts
      ) do
    info("Handle incoming deletion")

    object_id = Object.get_ap_id(object)

    with {:ok, cached_object} <- Object.get_cached(ap_id: object_id) |> debug("re-fetched"),
         #  {:actor, false} <- {:actor, Actor.actor?(cached_object) || Actor.actor?(object)},
         {:ok, verified_data} <-
           check_remote_object_deleted(object, opts[:already_fetched]) |> debug("re-fetched"),
         verified_object <- Object.normalize(verified_data || object, false) |> debug("normied"),
         {:actor, false} <-
           {:actor, Actor.actor?(verified_object) || Actor.actor?(verified_data)},
         {:ok, activity} <-
           ActivityPub.delete(verified_object || object_id, false) |> debug("deleted!!") do
      {:ok, activity}
    else
      {:actor, true} ->
        debug("it's an actor!")

        case Actor.get_cached(ap_id: object_id) do
          # FIXME: This is supposed to prevent unauthorized deletes
          # but we currently use delete activities where the activity
          # actor isn't the deleted object so we need to disable it.
          # {:ok, %Actor{data: %{"id" => ^actor}} = actor} ->
          {:ok, %Actor{} = actor} ->
            ActivityPub.delete(actor, false)

          e ->
            error(e, "Could not find actor to delete")
            # so oban doesn't try again
            {:ok, nil}
        end

      {:error, :not_found} ->
        # TODO: optimise / short circuit incoming Delete activities for unknown remote objects/actors, see https://github.com/bonfire-networks/bonfire-app/issues/850
        error(object_id, "Object is not cached locally, so deletion was skipped")
        {:ok, nil}

      {:error, :not_deleted} ->
        error("Could not verify incoming deletion")

      {:error, e} ->
        error(e)

      e ->
        error(e, "Could not handle incoming deletion")
    end
  end

  def handle_incoming(
        %{
          "type" => "Undo",
          "object" => %{"type" => "Announce", "object" => object_id},
          "actor" => _actor
        } = data,
        _opts
      ) do
    info("Handle incoming unboost")

    with actor <- Object.actor_from_data(data),
         {:ok, actor} <- Actor.get_cached(ap_id: actor),
         {:ok, object} <- object_normalize_and_maybe_fetch(object_id),
         {:ok, activity} <-
           ActivityPub.unannounce(%{
             actor: actor,
             object: object,
             activity_id: data["id"],
             local: false
           }) do
      {:ok, activity}
    else
      e -> error(e)
    end
  end

  def handle_incoming(
        %{
          "type" => "Undo",
          "object" => %{"type" => "Like", "object" => object_id},
          "actor" => _actor
        } = data,
        _opts
      ) do
    info("Handle incoming unlike")

    with actor <- Object.actor_from_data(data),
         {:ok, actor} <- Actor.get_cached(ap_id: actor),
         {:ok, object} <- object_normalize_and_maybe_fetch(object_id),
         {:ok, activity} <-
           ActivityPub.unlike(%{
             actor: actor,
             object: object,
             activity_id: data["id"],
             local: false
           }) do
      {:ok, activity}
    else
      e -> error(e)
    end
  end

  def handle_incoming(
        %{
          "type" => "Undo",
          "object" => %{"type" => "Follow", "object" => followed},
          "actor" => follower
        } = data,
        _opts
      ) do
    info("Handle incoming unfollow")

    with {:ok, follower} <- Actor.get_cached(ap_id: follower),
         {:ok, followed} <- Actor.get_cached(ap_id: followed) do
      ActivityPub.unfollow(%{
        actor: follower,
        object: followed,
        activity_id: data["id"],
        local: false
      })
    else
      e -> error(e)
    end
  end

  def handle_incoming(
        %{
          "type" => "Undo",
          "object" => %{"type" => "Block", "object" => blocked},
          "actor" => blocker
        } = data,
        _opts
      ) do
    info("Handle incoming unblock")

    with {:ok, %{local: true} = blocked} <-
           Actor.get_cached(ap_id: blocked),
         {:ok, blocker} <- Actor.get_cached(ap_id: blocker),
         {:ok, activity} <-
           ActivityPub.unblock(%{
             actor: blocker,
             object: blocked,
             activity_id: data["id"],
             local: false
           }) do
      {:ok, activity}
    else
      e -> error(e)
    end
  end

  def handle_incoming(
        %{
          "type" => "Move",
          "actor" => origin_actor,
          "object" => origin_actor,
          "target" => target_actor
        },
        _opts
      ) do
    with {:ok, %{} = origin_user} <- Actor.get_cached(ap_id: origin_actor),
         {:ok, %{} = target_user} <- Actor.get_cached_or_fetch(ap_id: target_actor) do
      ActivityPub.move(origin_user, target_user, false)
    else
      e -> error(e)
    end
  end

  def handle_incoming(
        %{"type" => "Tombstone"} = object,
        opts
      ) do
    handle_incoming(
      %{
        "type" => "Delete",
        "object" => object
      },
      opts
    )
  end

  # Handle other activity types (and their object)
  def handle_incoming(%{"type" => type} = data, _opts)
      when ActivityPub.Config.is_in(type, :supported_activity_types) do
    info(type, "ActivityPub - some other Activity type - store it and pass to adapter...")

    maybe_handle_other_activity(data)
  end

  def handle_incoming(%{"type" => type} = data, opts)
      when ActivityPub.Config.is_in(type, :supported_actor_types) or type in ["Author"] do
    info(type, "Save actor or collection without an activity")

    ActivityPub.Actor.create_or_update_actor_from_object(data, opts)
  end

  def handle_incoming(%{"type" => type} = data, _opts)
      when ActivityPub.Config.is_in(type, :collection_types) do
    debug(type, "don't store Collections")

    with {:ok, object} <- Object.prepare_data(data) do
      {:ok, object}
    end
  end

  def handle_incoming(%{"type" => type, "object" => _} = data, _opts) do
    info(type, "Save a seemingly unknown activity type")
    maybe_handle_other_activity(data)
  end

  def handle_incoming(%{"id" => id} = data, opts) do
    info("Wrapping standalone non-actor object in a Create activity?")
    # debug(data)

    handle_incoming(
      %{
        "type" => "Create",
        "to" => data["to"],
        "cc" => data["cc"],
        "actor" => Object.actor_from_data(data),
        "object" => data,
        "id" => "#{id}?virtual_create_activity"
      }
      |> debug("generated activity"),
      opts
    )
  end

  def handle_incoming(%{"links" => _} = data, opts) do
    # maybe be webfinger
    {:ok, fingered} = ActivityPub.Federator.WebFinger.webfinger_from_json(data)
    Fetcher.fetch_object_from_id(fingered["id"], opts)
  end

  def maybe_handle_other_activity(data) do
    with {:ok, activity} <- Object.insert(data, false),
         true <-
           Keyword.get(
             Application.get_env(:activity_pub, :instance),
             :handle_unknown_activities
           ) || {:ok, activity},
         {:ok, adapter_object} <- Adapter.maybe_handle_activity(activity),
         activity <- Map.put(activity, :pointer, adapter_object) do
      {:ok, activity}
    end
  end

  defp object_normalize_and_maybe_fetch(id, opts \\ []) do
    if object = Object.normalize(id, Fetcher.allowed_recursion?(opts[:depth])) do
      {:ok, object}
    else
      warn(id, "no such object found")
      {:error, :not_found}
    end
  end
end
