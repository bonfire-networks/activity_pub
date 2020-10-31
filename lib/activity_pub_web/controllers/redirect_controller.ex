defmodule ActivityPubWeb.RedirectController do
  # This entire module was pretty MN specific so need to figure out a way to make it generic

  # use ActivityPubWeb, :controller

  def object(id), do: ActivityPub.Adapter.call_or(:redirect_to_object, [id], nil)

  def actor(id), do: ActivityPub.Adapter.call_or(:redirect_to_actor, [id], nil)

end
