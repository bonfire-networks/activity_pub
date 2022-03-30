defmodule ActivityPub.Test.Helpers do

  def repo, do: Application.get_env(:activity_pub, :test_repo, ActivityPub.TestRepo)
  def endpoint, do: Application.get_env(:activity_pub, :endpoint_module, ActivityPubWeb.Endpoint)

  def test_path, do: Path.expand("../", __DIR__)

  def follow(actor_1, actor_2) do
    if ActivityPub.Adapter.adapter() == Bonfire.Federate.ActivityPub.Adapter and Code.ensure_loaded?(Bonfire.Social.Follows) do # TODO: make into a generic adapter callback?
      Bonfire.Social.Follows.follow(actor_1.user, actor_2.user)
    else
      ActivityPub.LocalActor.follow(actor_1, actor_2)
    end
  end

end
