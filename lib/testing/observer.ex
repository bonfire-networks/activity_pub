defmodule ActivityPub.Observer do
  @moduledoc """
  A seam for watching AP documents exactly as they arrive from remote instances, before any normalisation or verification.

  Two places see wire-format JSON: the inbox (documents pushed to us) and the fetcher (documents we pulled). Both are worth observing for the same reason, everything downstream is normalised, so `ap_object.data` can't answer "what did they actually send us", and documents we REJECT never reach the database at all despite being the ones most worth studying.

  The library provides only the hook. What to do with a document (record it as an interop fixture, count it, tap it into a debugging UI) is the host app's business:

      config :activity_pub, :document_observer, {MyApp.Interop, :capture}
      config :activity_pub, :document_observer, fn document, context -> ... end

  The observer is called with the decoded document and a context map describing where it came from:

    * `%{source: :inbox, headers: %{"signature" => …, "user-agent" => …}}`
    * `%{source: :fetch, url: id, status: 200, headers: […]}`

  Its return value is ignored and the document is passed through unchanged, including when the observer raises: observing must never break federation.
  """

  import Untangle

  alias ActivityPub.Config

  @doc "Hands `document` to the configured `:document_observer` (if any) and returns it unchanged."
  def maybe_observe(document, context) do
    case Config.get([:document_observer]) do
      {module, function} when is_atom(module) and is_atom(function) ->
        apply(module, function, [document, context])

      fun when is_function(fun, 2) ->
        fun.(document, context)

      nil ->
        :ok

      other ->
        warn(other, "Expected :document_observer to be a {module, function} or 2-arity fun")
    end

    document
  rescue
    e ->
      warn(e, "document_observer failed")
      document
  end
end
