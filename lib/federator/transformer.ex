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
  Translates an Entity to an AP compatible format
  """
  def prepare_outgoing(object, opts \\ [])

  def prepare_outgoing(%{"type" => "Create", "object" => %{"type" => "Group"}} = data, opts) do
    data =
      data
      |> maybe_add_json_ld_header(:actor, opts)

    # |> Map.delete("bto")
    # |> Map.delete("bcc")

    {:ok, data}
  end

  def prepare_outgoing(%{"type" => "Create", "object" => object} = data, opts) do
    data =
      data
      |> Map.put("object", prepare_outgoing_object(object))
      |> maybe_add_json_ld_header(maybe_type(object) || :object, opts)

    # |> Map.delete("bto")
    # |> Map.delete("bcc")

    {:ok, data}
  end

  def prepare_outgoing(%{"object" => object} = data, opts) do
    data =
      data
      |> Map.put("object", prepare_outgoing_object(object))
      |> maybe_add_json_ld_header(maybe_type(object) || :object, opts)

    # |> Map.delete("bto")
    # |> Map.delete("bcc")

    {:ok, data}
  end

  # hack for mastodon accept and reject type activity formats
  def prepare_outgoing(%{"type" => type} = data, opts) do
    data =
      data
      |> maybe_add_json_ld_header(type || :object, opts)

    # |> Map.delete("bto")
    # |> Map.delete("bcc")

    {:ok, data}
  end

  def prepare_outgoing(%Object{object: %Object{} = object} = activity, opts) do
    activity.data
    |> Map.put("object", prepare_outgoing_object(object))
    |> prepare_outgoing(opts)
  end

  def prepare_outgoing(%Object{} = activity, opts) do
    prepare_outgoing(activity.data, opts)
  end

  defp maybe_type(%{"type" => type}) when is_binary(type) do
    type
  end

  defp maybe_type(_), do: nil

  defp maybe_add_json_ld_header(data, type, opts) do
    if opts[:skip_json_context_header] do
      data
    else
      data
      |> Map.merge(Utils.make_json_ld_header(type))
    end
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

  # Helper function to invalidate cache of the object being replied to
  def maybe_invalidate_reply_to_cache(%{"inReplyTo" => in_reply_to})
      when is_binary(in_reply_to) do
    case Object.get_cached(ap_id: in_reply_to) do
      {:ok, %{data: data} = reply_to_object} ->
        # Invalidate the old cache first?
        Object.invalidate_cache(reply_to_object)

        # Regenerate the object with updated replies collection
        updated_data = prepare_outgoing_object(reply_to_object)

        if data != updated_data do
          debug(in_reply_to, "Replied-to object has changed, updating cache")

          case Object.do_update_existing(reply_to_object, %{data: updated_data}) do
            {:ok, updated_object} ->
              debug(
                updated_object,
                "Successfully updated replied-to object with new replies collection"
              )

            error ->
              error(error, "Failed to update replied-to object with new replies collection")
          end
        else
          debug(updated_data, "Replied-to object unchanged")
        end

      _ ->
        debug(in_reply_to, "Could not find replied-to object in cache")
    end
  end

  def maybe_invalidate_reply_to_cache(_), do: :ok

  def preserve_privacy_of_outgoing(other, target_instance_host \\ nil, target_actor_ids \\ [])

  def preserve_privacy_of_outgoing(%{"object" => object} = data, host, target_actor_ids)
      when is_binary(host) or (is_list(target_actor_ids) and target_actor_ids != []) do
    data
    |> Map.put("object", preserve_privacy_of_outgoing(object, host, target_actor_ids))
    |> Map.update(
      "bto",
      [],
      &filter_recipients_visibility_by_instance(&1, host, target_actor_ids)
    )
    |> Map.update(
      "bcc",
      [],
      &filter_recipients_visibility_by_instance(&1, host, target_actor_ids)
    )
    |> Adapter.transform_outgoing(host, target_actor_ids)
  end

  def preserve_privacy_of_outgoing(%{} = data, host, target_actor_ids)
      when is_binary(host) or (is_list(target_actor_ids) and target_actor_ids != []) do
    data
    |> Map.update(
      "bto",
      [],
      &filter_recipients_visibility_by_instance(&1, host, target_actor_ids)
    )
    |> Map.update(
      "bcc",
      [],
      &filter_recipients_visibility_by_instance(&1, host, target_actor_ids)
    )
    |> Adapter.transform_outgoing(host, target_actor_ids)
  end

  def preserve_privacy_of_outgoing(%{"object" => object} = data, host, target_actor_ids) do
    data
    |> Map.put("object", preserve_privacy_of_outgoing(object, host, target_actor_ids))
    |> Map.drop(["bto", "bcc"])
    |> Adapter.transform_outgoing(host, target_actor_ids)
  end

  def preserve_privacy_of_outgoing(%{} = data, host, target_actor_ids) do
    data
    |> Map.drop(["bto", "bcc"])
    |> Adapter.transform_outgoing(host, target_actor_ids)
  end

  def preserve_privacy_of_outgoing(other, _, _), do: other

  defp filter_recipients_visibility_by_instance(bto, host, target_actor_ids) when is_list(bto) do
    Enum.filter(bto, &recipient_is_from_instance?(&1, host, target_actor_ids))
  end

  defp filter_recipients_visibility_by_instance(bto, host, target_actor_ids) do
    if recipient_is_from_instance?(bto, host, target_actor_ids), do: bto, else: []
  end

  defp recipient_is_from_instance?(bto, host, target_actor_ids) when is_binary(bto) do
    bto in (target_actor_ids || []) or URI.parse(bto || "").host == host
  end

  defp recipient_is_from_instance?(%{"id" => bto}, host, target_actor_ids) when is_binary(bto) do
    recipient_is_from_instance?(bto, host, target_actor_ids)
  end

  defp recipient_is_from_instance?(%{data: %{"id" => bto}}, host, target_actor_ids)
       when is_binary(bto) do
    recipient_is_from_instance?(bto, host, target_actor_ids)
  end

  defp recipient_is_from_instance?(_, _, _) do
    false
  end

  defp check_remote_object_deleted(data, true = _already_fetched) do
    if Object.is_deleted?(data) do
      {:ok, data}
    else
      {:error, :not_deleted}
    end
  end

  defp check_remote_object_deleted(object, _) do
    ap_id = Object.get_ap_id(object)
    debug(ap_id, "Checking delete permission for")

    case Fetcher.fetch_remote_object_from_id(ap_id, return_tombstones: true)
         |> debug("remote fetched") do
      {:error, :not_found} ->
        # ok it seems gone from there
        {:ok, nil}

      {:ok, %{} = data} ->
        check_remote_object_deleted(data, true)

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
  Modifies an incoming AP object (in mastodon or other apps' flexible formats) to our internal simplified AP format.
  """
  def fix_object(object, options \\ [])

  def fix_object(%{} = object, options) do
    object
    |> fix_actor()
    |> fix_type(options)
    |> fix_url()
    |> fix_mfm_content()
    |> fix_attachments()
    |> fix_context(options)
    |> fix_in_reply_to(options)
    |> fix_replies(options)
    |> fix_quote(options)
    |> fix_emoji()
    |> fix_tag()
    |> fix_content_map()
    |> fix_addressing()
    |> fix_summary()
    |> add_emoji_tags()

    # |> fetch_and_create_nested_ap_objects(options)
    |> debug("fixed object")
  end

  def fix_object(object, _options), do: object

  def fix_other_object(object, _options) do
    object
    # |> fetch_and_create_nested_ap_objects(options)
  end

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
         _ <-
           Fetcher.maybe_fetch(
             in_reply_to_id,
             options |> Keyword.put_new(:triggered_by, "fix_in_reply_to")
           )
           |> info("fetched reply_to?") do
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

  def fix_quote(object, options \\ [])

  def fix_quote(%{"quote" => quote_url} = object, options) when is_binary(quote_url) do
    object
    |> Map.delete("quote")
    |> add_quote_tag(quote_url, options)
  end

  def fix_quote(%{"quoteUrl" => quote_url} = object, options) when is_binary(quote_url) do
    object
    |> Map.delete("quoteUrl")
    |> add_quote_tag(quote_url, options)
  end

  def fix_quote(%{"quoteUri" => quote_url} = object, options) when is_binary(quote_url) do
    object
    |> Map.delete("quoteUri")
    |> add_quote_tag(quote_url, options)
  end

  def fix_quote(%{"quoteURL" => quote_url} = object, options) when is_binary(quote_url) do
    object
    |> Map.delete("quoteURL")
    |> add_quote_tag(quote_url, options)
  end

  def fix_quote(%{"_misskey_quote" => quote_url} = object, options) when is_binary(quote_url) do
    object
    |> Map.delete("_misskey_quote")
    |> add_quote_tag(quote_url, options)
  end

  def fix_quote(object, _options), do: object

  defp add_quote_tag(object, quote_url, options) when is_binary(quote_url) do
    quote_tag = %{
      "type" => "Link",
      "mediaType" => "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"",
      "rel" => "https://misskey-hub.net/ns#_misskey_quote",
      "href" => quote_url
    }

    object
    |> Map.update("tag", [quote_tag], fn existing_tags ->
      # Remove any existing quote tags to avoid duplicates
      List.wrap(existing_tags)
      |> Kernel.++([quote_tag])
      |> Enum.uniq_by(fn
        %{"type" => "Link", "rel" => rel, "href" => href}
        when rel in [
               "https://w3id.org/fep/044f#quote",
               "https://misskey-hub.net/ns#_misskey_quote",
               "quote",
               "http://fedibird.com/ns#quoteUri"
             ] ->
          href

        other ->
          other
      end)
      |> debug("normalised tags with quote")
    end)
  end

  defp add_quote_tag(object, quote_url, _options) do
    err(quote_url, "Couldn't recognise quote URL")
    object
  end

  def fix_context(object, options) do
    context = object["context"] || object["conversation"] || object["inReplyTo"]

    case Utils.single_ap_id(context) do
      context = "tag:" <> _ ->
        # TODO: how to handle Mastodon's thread IDs?
        object
        |> Map.put("context", context)

      "http" <> _ = context ->
        # FIXME: should this really fetch async?
        Fetcher.maybe_fetch(context, options |> Keyword.put_new(:triggered_by, "fix_context"))
        |> debug("fetched context?")

        object
        |> Map.put("context", context)

      context when is_binary(context) ->
        # hope for the best?
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

  def fix_tag(%{"tag" => tags} = object) when is_list(tags) do
    # tags =
    #   tag
    #   |> Enum.map(fn
    #     %{"type" => "Hashtag", "name" => "#" <> name} -> name
    #     %{"type" => "Hashtag", "name" => _} = tag -> tag
    #     _other -> nil
    #   end)
    #   |> Enum.reject(&is_nil/1)

    # Map.put(object, "tag", tags)
    object
  end

  def fix_tag(%{"tag" => %{} = tag} = object) do
    object
    |> Map.put("tag", [tag])
    |> fix_tag()
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

  defp fix_type(%{"type" => "Note", "inReplyTo" => reply_id, "name" => name} = object, options)
       when is_binary(name) do
    options = Keyword.put(options, :fetch, true)

    with %Object{data: %{"type" => "Question"}} <- Object.normalize(reply_id, options) do
      Map.put(object, "type", "Answer")
    else
      _ -> object
    end
  end

  defp fix_type(object, _options), do: object

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
    Map.update(object, "tag", [], fn existing_value ->
      existing_value ++ Enum.map(emoji, &build_emoji_tag/1)
    end)
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
    Fetcher.maybe_fetch(
      replies,
      options
      |> Keyword.put(
        :mode,
        options[:fetch_collection_entries] || false
      )
      |> Keyword.put_new(:triggered_by, "fix_replies")
    )
    |> debug("fetched replies?")

    # TODO: update the data with only IDs in case we have full objects?
    data
  end

  def fix_replies(%{"replies" => %{"items" => replies}} = data, options)
      when is_list(replies) and replies != [] do
    Fetcher.maybe_fetch(
      replies,
      options
      |> Keyword.put(
        :mode,
        options[:fetch_collection_entries] || false
      )
      |> Keyword.put_new(:triggered_by, "fix_replies")
    )
    |> debug("fetched replies?")

    # TODO: update the data with only IDs in case we have full objects?
    Map.put(data, "replies", replies)
  end

  def fix_replies(%{"replies" => %{"first" => replies}} = data, options)
      when is_list(replies) and replies != [] do
    Fetcher.maybe_fetch(
      replies,
      options
      |> Keyword.put(
        :mode,
        options[:fetch_collection_entries] || false
      )
      |> Keyword.put_new(:triggered_by, "fix_replies")
    )
    |> debug("fetched replies?")

    # TODO: update the data with only IDs in case we have full objects?
    Map.put(data, "replies", replies)
  end

  def fix_replies(%{"replies" => %{"first" => %{"items" => replies}}} = data, options)
      when is_list(replies) and replies != [] do
    Fetcher.maybe_fetch(
      replies,
      options
      |> Keyword.put(
        :mode,
        options[:fetch_collection_entries] || false
      )
      |> Keyword.put_new(:triggered_by, "fix_replies")
    )
    |> debug("fetched replies?")

    # TODO: update the data with only IDs in case we have full objects?
    Map.put(data, "replies", replies)
  end

  def fix_replies(%{"replies" => %{"first" => first}} = data, options) do
    # Note: seems like too much recursion was triggered with `entries_async`
    # with {:ok, replies} <- Fetcher.maybe_fetch_collection(first, mode: :entries_async) do
    #   Map.put(data, "replies", replies)
    # else
    #   {:error, _} ->
    #     warn(first, "Could not fetch replies")
    # Map.put(data, "replies", [])
    # end

    Fetcher.maybe_fetch_collection(
      first,
      options
      |> Keyword.put(
        :mode,
        Keyword.get(options, :fetch_collection) || options[:fetch_collection_entries] || false
      )
      |> Keyword.put_new(:triggered_by, "fix_replies")
    )
    |> debug("fetched replies collection?")

    data
  end

  def fix_replies(data, _), do: Map.delete(data, "replies")

  defp replies_limit, do: Config.get([:activity_pub, :note_replies_output_limit], 10)

  defp replies_self_only?, do: Config.get([:activity_pub, :note_replies_output_self_only], false)

  @doc """
  Serialized Mastodon-compatible `replies` collection.
  Based on Mastodon's ActivityPub::NoteSerializer#replies.
  """
  def set_replies(%Object{data: obj_data} = _object) do
    set_replies(obj_data)

    # replies_uris =
    #   with limit when limit > 0 <- replies_limit() do
    #     object
    #     |> Object.replies_ids(limit, self_only: replies_self_only?())
    #     |> debug("replies_ids on object")
    #   else
    #     _ -> []
    #   end

    # set_replies(object.data, replies_uris)
  end

  def set_replies(%{"id" => _id} = obj_data) do
    replies_uris =
      with limit when limit > 0 <- replies_limit() do
        #  %Object{} = object <- Object.get_cached(ap_id: id) do
        obj_data
        |> Object.replies_ids(limit, self_only: replies_self_only?())
        |> debug("replies_ids")
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
  def handle_incoming(%{"type" => "Flag", "object" => objects, "actor" => actor} = data, opts) do
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
        local: local?(opts),
        additional: %{
          "cc" => if(account, do: [account.data["id"]]) || []
        }
      }

      ActivityPub.flag(params, opts)
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
      |> debug("normalized incoming object")

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
      local: local?(opts),
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
      ActivityPub.create(params, opts)
    else
      %{data: %{"type" => "Tombstone"}} = _activity ->
        debug("do not save Tombstone in adapter")

        :skip

      %Object{pointer_id: nil} = activity ->
        debug(
          activity,
          "a Create for this Object already exists, but not in the Adapter, so pass it there now"
        )

        with {:ok, adapter_object} <-
               Adapter.maybe_handle_activity(
                 Map.put(activity, :data, Map.merge(activity.data, %{"object" => object})),
                 opts
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
        opts
      ) do
    info("Handle incoming follow")

    with {:ok, follower} <- Actor.get_cached_or_fetch(ap_id: follower) |> debug("follower"),
         {:ok, followed} <- Actor.get_cached(ap_id: followed) |> debug("followed") do
      ActivityPub.follow(
        %{
          actor: follower,
          object: followed,
          activity_id: data["id"],
          local: local?(opts)
        },
        opts
      )
    end
  end

  def handle_incoming(
        %{
          "type" => "Accept" = type,
          "object" => follow_object,
          "actor" => _actor
        } = data,
        opts
      ) do
    debug("Handle incoming Accept")

    with followed_actor <- Object.actor_from_data(data) |> debug("followed_actor"),
         {:ok, followed} <- Actor.get_cached(ap_id: followed_actor) |> debug("followed"),
         {:ok, follow_activity} <-
           Object.get_follow_activity(follow_object, followed) |> debug("follow_activity") do
      # Get follower from follow activity to use as default recipient
      follower_id = follow_activity.data["actor"]

      ActivityPub.accept(
        %{
          activity_id: data["id"],
          to: data["to"] || follow_activity.data["to"] || List.wrap(follower_id),
          type: type,
          actor: followed,
          object: follow_activity,
          result: debug(data["result"], "incoming accept result"),
          local: local?(opts)
        },
        opts
      )
      |> debug("accept result")
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
        opts
      ) do
    debug("Handle incoming Reject")

    with followed_actor <- Object.actor_from_data(data) |> debug("followed_actor"),
         {:ok, followed} <- Actor.get_cached(ap_id: followed_actor) |> debug("followed"),
         {:ok, follow_activity} <-
           Object.get_follow_activity(follow_object, followed) |> debug("follow_activity") do
      # Get follower from follow activity to use as default recipient
      follower_id = follow_activity.data["actor"]

      ActivityPub.reject(
        %{
          activity_id: data["id"],
          to: data["to"] || follow_activity.data["to"] || List.wrap(follower_id),
          type: type,
          actor: followed,
          object: follow_activity.data["id"],
          local: local?(opts)
        },
        opts
      )
      |> debug("reject result")
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
        opts
      ) do
    info("Handle incoming like")

    with actor <- Object.actor_from_data(data),
         {:ok, actor} <- Actor.get_cached_or_fetch(ap_id: actor),
         {:ok, object} <- object_normalize_and_maybe_fetch(object_id),
         {:ok, activity} <-
           ActivityPub.like(
             %{
               actor: actor,
               object: object,
               activity_id: data["id"],
               local: local?(opts)
             },
             opts
           ) do
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
        opts
      ) do
    info("Handle incoming boost")

    with actor <- Object.actor_from_data(data),
         {:ok, actor} <- Actor.get_cached_or_fetch(ap_id: actor),
         {:ok, object} <- object_normalize_and_maybe_fetch(object_id),
         public <- Utils.public?(data, object),
         {:ok, activity} <-
           ActivityPub.announce(
             %{
               activity_id: data["id"],
               actor: actor,
               object: object,
               local: local?(opts),
               public: public
             },
             opts
           ) do
      {:ok, activity}
    else
      e -> error(e)
    end
  end

  def handle_incoming(
        %{
          "type" => "Update",
          "object" => %{"type" => type, "id" => update_actor_id} = update_actor_data,
          "actor" => actor_id
        } = data,
        opts
      )
      when ActivityPub.Config.is_in(type, :supported_actor_types) and actor_id == update_actor_id do
    # TODO: should a Person be able to update a Group or the like?

    debug(actor_id, "update an Actor")
    debug(opts, "opts")

    #  NOTE: we avoid even passing the update_actor_data to avoid accepting invalid updates
    with {:ok, actor} <-
           Actor.update_actor(
             actor_id,
             if(opts[:local], do: update_actor_data),
             opts[:already_fetched] != true,
             opts[:local] || false
           ) do
      # Skip all of that because it's handled elsewhere after fetching
      #  {:ok, actor} <- Actor.get_cached(ap_id: actor_id),
      #  {:ok, _} <- Actor.set_cache(actor) do
      # TODO: do we need to register an Update activity for this?
      # ActivityPub.update(%{
      #   id: data["id"],
      #   local: local?(opts),
      #   to: data["to"] || [],
      #   cc: data["cc"] || [],
      #   object: actor.data, # NOTE: we use the data from update_actor which was re-fetched from the source
      #   actor: actor
      # }, opts)
      {:ok, actor}
    else
      {:error, e} ->
        error(e)

      e ->
        error(e, "Could not update actor")
    end
  end

  def handle_incoming(
        %{
          "type" => "Update",
          "object" => %{"id" => object_id} = object,
          "actor" => actor
        } = data,
        opts
      ) do
    info("Handle incoming update of an Object")

    with {:ok, actor} <- Actor.get_cached(ap_id: actor) |> flood("fetch actor for update"),
         {:ok, object} <-
           object_normalize_and_maybe_fetch(object) |> flood("fetch object for update"),
         {:ok, cached_object} <- Object.get_cached(ap_id: object_id),
         true <- can_update?(cached_object, actor, opts) || {:error, :unauthorized} do
      ActivityPub.update(
        %{
          local: local?(opts),
          to: data["to"] || [],
          cc: data["cc"] || [],
          object: object,
          actor: actor
        },
        opts
      )
    else
      {:error, :not_found} ->
        if local?(opts) do
          # C2S: object must exist to update it
          {:error, :not_found}
        else
          # S2S: pass to adapter in case it was pruned from AP db
          handle_activity_with_pruned_object(data, "Update", opts)
        end

      {:error, :unauthorized} ->
        {:error, :unauthorized}

      {:error, e} ->
        error(e)

      e ->
        error(e, "Could not update object")
    end
  end

  def handle_incoming(
        %{
          "type" => "QuoteRequest",
          "object" => object_id,
          "actor" => _actor
        } = data,
        opts
      ) do
    debug("Handle incoming quote request")

    with actor <- Object.actor_from_data(data),
         {:ok, actor} <- Actor.get_cached_or_fetch(ap_id: actor),
         {:ok, object} <- object_normalize_and_maybe_fetch(object_id),
         {:ok, instrument} <- object_normalize_and_maybe_fetch(data["instrument"]),
         {:ok, activity} <-
           ActivityPub.quote_request(
             %{
               actor: actor,
               object: object,
               instrument: instrument,
               activity_id: data["id"],
               local: local?(opts)
             },
             opts
           )
           |> debug("processed/saved incoming quote request") do
      {:ok, activity}
    else
      e -> err(e, "invalid data for incoming quote request")
    end
  end

  def handle_incoming(
        %{
          "type" => "Block",
          "object" => blocked,
          "actor" => blocker
        } = data,
        opts
      ) do
    info("Handle incoming block")

    if local?(opts) do
      # C2S: Local user is blocking someone
      # - Blocker must be a local actor (already authenticated)
      # - Blocked can be anyone (local or remote)
      handle_local_block(data, blocker, blocked, opts)
    else
      # S2S: Remote user is blocking our local user
      # - Blocker must be remote (we received this from federation)
      # - Blocked must be local (otherwise why tell us?)
      handle_remote_block(data, blocker, blocked, opts)
    end
  end

  defp handle_local_block(data, blocker, blocked, opts) do
    with {:ok, %{local: true} = blocker_actor} <- Actor.get_cached(ap_id: blocker),
         {:ok, blocked_actor} <- Actor.get_cached_or_fetch(ap_id: blocked) do
      ActivityPub.block(
        %{
          actor: blocker_actor,
          object: blocked_actor,
          activity_id: data["id"],
          local: true
        },
        opts
      )
    else
      e -> error(e, "Could not process C2S block")
    end
  end

  defp handle_remote_block(data, blocker, blocked, opts) do
    with {:ok, %{local: true} = blocked_actor} <- Actor.get_cached(ap_id: blocked),
         {:ok, %{local: false} = blocker_actor} <- Actor.get_cached_or_fetch(ap_id: blocker) do
      ActivityPub.block(
        %{
          actor: blocker_actor,
          object: blocked_actor,
          activity_id: data["id"],
          local: false
        },
        opts
      )
    else
      {:ok, %{local: false}} ->
        error("S2S Block rejected: blocked user is not local")

      {:ok, %{local: true}} ->
        error("S2S Block rejected: blocker should not be local")

      e ->
        error(e, "Could not process S2S block")
    end
  end

  def handle_incoming(
        %{
          "type" => "Delete",
          "object" => object
          # "actor" => _actor
        } = data,
        opts
      ) do
    info("Handle incoming deletion")

    object_id = Object.get_ap_id(object)

    if local?(opts) do
      # C2S: Local user is deleting their own object
      # Skip remote verification - we trust the authenticated local user
      handle_local_delete(data, object_id, opts)
    else
      # S2S: Remote user sent us a Delete activity
      # Verify the object is actually deleted at the source
      handle_remote_delete(data, object, object_id, opts)
    end
  end

  defp handle_local_delete(data, object_id, opts) do
    # For C2S deletes, verify the actor owns the object
    actor_id = Object.actor_from_data(data)

    with {:ok, cached_object} <- Object.get_cached(ap_id: object_id),
         true <- can_delete?(cached_object, actor_id, opts) || {:error, :unauthorized},
         {:ok, activity} <- ActivityPub.delete(cached_object, true, opts) do
      {:ok, activity}
    else
      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :unauthorized} ->
        {:error, :not_deleted}

      e ->
        error(e, "Could not process C2S delete")
    end
  end

  # Check if the actor can delete the object
  defp can_delete?(object, actor, opts) do
    actor_owns_object?(object, actor) or
      Adapter.call_or(:can_delete?, [opts[:current_actor] || actor, object], false)
  end

  defp can_delete?(_, _, _), do: false

  # Check if the actor can update the object
  defp can_update?(object, actor, opts) do
    actor =
      (opts[:current_actor] ||
         actor)
      |> flood("current_actor")

    flood(object, "object to update")

    actor_owns_object?(object, actor) |> flood("actor_owns_object?") or
      Adapter.call_or(:can_update?, [actor, object], false) |> flood("can_update? via adapter")
  end

  defp can_update?(_, _, _), do: false

  # Shared helper: check if actor owns the object
  defp actor_owns_object?(%Object{data: obj_data}, actor), do: actor_owns_object?(obj_data, actor)

  defp actor_owns_object?(obj_data, %{ap_id: actor_id}),
    do: actor_owns_object?(obj_data, actor_id)

  defp actor_owns_object?(obj_data, %{"id" => actor_id}),
    do: actor_owns_object?(obj_data, actor_id)

  defp actor_owns_object?(%{} = obj_data, actor_id) do
    Object.actor_id_from_data(obj_data) == actor_id
  end

  defp actor_owns_object?(_, _), do: false

  defp handle_remote_delete(data, object, object_id, opts) do
    with {:ok, cached_object} <- Object.get_cached(ap_id: object_id) |> debug("re-fetched"),
         #  {:actor, false} <- {:actor, Actor.actor?(cached_object) || Actor.actor?(object)},
         {:ok, verified_data} <-
           check_remote_object_deleted(object, opts[:already_fetched]) |> debug("re-fetched"),
         verified_object <- Object.normalize(verified_data || object, false) |> debug("normied"),
         {:actor, false} <-
           {:actor, Actor.actor?(verified_object) || Actor.actor?(verified_data)},
         {:ok, activity} <-
           ActivityPub.delete(verified_object || object_id, false, opts) |> debug("deleted!!") do
      {:ok, activity}
    else
      {:error, :not_found} ->
        handle_activity_with_pruned_object(data, "Delete", opts)

      {:actor, true} ->
        debug("it's an actor!")

        case Actor.get_cached(ap_id: object_id) do
          # FIXME: This is supposed to prevent unauthorized deletes
          # but we currently use delete activities where the activity
          # actor isn't the deleted object so we need to disable it.
          # {:ok, %Actor{data: %{"id" => ^actor}} = actor} ->
          {:ok, %Actor{} = actor} ->
            ActivityPub.delete(actor, false, opts)

          {:error, :not_found} ->
            handle_activity_with_pruned_object(data, "Delete", opts)

          e ->
            error(e, "Error while trying to find actor to delete in AP db")
        end

      {:error, :not_deleted} ->
        if opts[:local] do
          {:error, :not_deleted}
        else
          error("Could not verify incoming deletion")
        end

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
        opts
      ) do
    info("Handle incoming unboost")

    with actor <- Object.actor_from_data(data),
         {:ok, actor} <- Actor.get_cached(ap_id: actor),
         {:ok, object} <- object_normalize_and_maybe_fetch(object_id),
         {:ok, activity} <-
           ActivityPub.unannounce(
             %{
               actor: actor,
               object: object,
               activity_id: data["id"],
               local: local?(opts)
             },
             opts
           ) do
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
        opts
      ) do
    info("Handle incoming unlike")

    with actor <- Object.actor_from_data(data),
         {:ok, actor} <- Actor.get_cached(ap_id: actor),
         {:ok, object} <- object_normalize_and_maybe_fetch(object_id),
         {:ok, activity} <-
           ActivityPub.unlike(
             %{
               actor: actor,
               object: object,
               activity_id: data["id"],
               local: local?(opts)
             },
             opts
           ) do
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
        opts
      ) do
    info("Handle incoming unfollow")

    with {:ok, follower} <- Actor.get_cached(ap_id: follower),
         {:ok, followed} <- Actor.get_cached(ap_id: followed) do
      ActivityPub.unfollow(
        %{
          actor: follower,
          object: followed,
          activity_id: data["id"],
          local: local?(opts)
        },
        opts
      )
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
        opts
      ) do
    info("Handle incoming unblock")

    with {:ok, %{local: true} = blocked} <-
           Actor.get_cached(ap_id: blocked),
         {:ok, blocker} <- Actor.get_cached(ap_id: blocker),
         {:ok, activity} <-
           ActivityPub.unblock(
             %{
               actor: blocker,
               object: blocked,
               activity_id: data["id"],
               local: local?(opts)
             },
             opts
           ) do
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
        opts
      ) do
    with {:ok, %{} = origin_user} <- Actor.get_cached(ap_id: origin_actor),
         {:ok, %{} = target_user} <- Actor.get_cached_or_fetch(ap_id: target_actor) do
      ActivityPub.move(origin_user, target_user, local?(opts), opts)
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
  def handle_incoming(%{"type" => type} = data, opts)
      when ActivityPub.Config.is_in(type, :supported_activity_types) or
             ActivityPub.Config.is_in(type, :supported_intransitive_types) do
    info(
      type,
      "ActivityPub - some other Activity or Intransitive type - store it and pass to adapter..."
    )

    maybe_handle_other_activity(data, opts)
  end

  def handle_incoming(%{"type" => type} = data, opts)
      when ActivityPub.Config.is_in(type, :supported_actor_types) or type in ["Author"] do
    info(type, "Save actor or collection without an activity")

    ActivityPub.Actor.create_or_update_actor_from_object(data, opts)
  end

  def handle_incoming(%{"type" => type} = data, _opts)
      when ActivityPub.Config.is_in(type, :collection_types) do
    debug(type, "don't store Collections")

    # with {:ok, data} <- Object.prepare_data(data) do
    {:ok, data}
    # end
  end

  def handle_incoming(%{"type" => type, "object" => _} = data, opts) do
    info(type, "Save a seemingly unknown activity type")
    maybe_handle_other_activity(data, opts)
  end

  def handle_incoming(%{"id" => id} = data, opts) do
    info("Wrapping standalone non-actor and non-activity object in a Create activity?")
    # FIXME: do we actually want to do this?
    # debug(data)

    handle_incoming(
      %{
        "type" => "Create",
        "to" => data["to"],
        "cc" => data["cc"],
        "actor" => Object.actor_from_data(data),
        "object" => data,
        "id" => "#{id}#virtual_create_activity"
      }
      |> debug("generated activity"),
      opts
    )
  end

  def handle_incoming(%{"links" => _} = data, opts) do
    # maybe be webfinger
    {:ok, fingered} = ActivityPub.Federator.WebFinger.webfinger_from_json(data)

    Fetcher.fetch_object_from_id(
      fingered["id"],
      opts |> Keyword.put_new(:triggered_by, "handle_incoming:links")
    )
  end

  defp local?(opts), do: Keyword.get(opts, :local, false)

  def maybe_handle_other_activity(data, opts) do
    # Process nested objects for all activity types
    with {:ok, activity} <-
           fix_other_object(data, opts)
           |> Object.insert(local?(opts), nil, opts),
         true <-
           Map.get(
             Application.get_env(:activity_pub, :instance, %{}) |> Map.new(),
             :handle_unknown_activities
           ) || {:ok, activity},
         {:ok, adapter_object} <- Adapter.maybe_handle_activity(activity, opts),
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

  # Helper function to handle activities when objects are pruned from AP cache
  defp handle_activity_with_pruned_object(data, activity_type, opts) do
    object_id = Object.get_ap_id(data["object"])

    info(
      object_id,
      "Object is not cached in AP db - still pass to adapter in case it was pruned from AP db for #{activity_type}"
    )

    Adapter.maybe_handle_activity(%Object{data: data, local: local?(opts), public: true}, opts)
  end
end
