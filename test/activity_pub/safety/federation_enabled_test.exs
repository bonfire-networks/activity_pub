defmodule ActivityPub.Web.FederationEnabledTest do
  use ActivityPub.DataCase
  use Mneme

  alias ActivityPub.Config

  setup do
    orig = Config.get([:instance, :federating])

    on_exit(fn ->
      Config.put([:instance, :federating], orig)
    end)
  end

  test "can disable federation entirely" do
    Config.put([:instance, :federating], false)

    assert false == Config.federating?()
  end

  test "can set federation to manual mode" do
    Config.put([:instance, :federating], nil)

    assert nil == Config.federating?()
  end

  test "can enable federation" do
    Config.put([:instance, :federating], true)

    assert true == Config.federating?()
  end
end
