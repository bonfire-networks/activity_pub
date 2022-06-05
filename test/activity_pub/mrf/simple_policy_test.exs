defmodule ActivityPubWeb.MRF.SimplePolicyTest do
  use ActivityPub.DataCase
  alias ActivityPub.Config
  alias ActivityPub.MRF.SimplePolicy

  setup do
    orig = Config.get!(:mrf_simple)

    Config.put(:mrf_simple,
      media_removal: [],
      media_nsfw: [],
      federated_timeline_removal: [],
      report_removal: [],
      reject: [],
      accept: [],
      avatar_removal: [],
      banner_removal: []
    )

    on_exit(fn ->
      Config.put(:mrf_simple, orig)
    end)
  end

  defp build_local_message do
    ap_base_path = System.get_env("AP_BASE_PATH", "/pub")

    %{
      "actor" => ActivityPubWeb.base_url() <> ap_base_path <> "/actors/alice",
      "to" => [],
      "cc" => []
    }
  end

  defp build_remote_message do
    %{"actor" => "https://remote.instance/users/bob"}
  end

  defp build_remote_user do
    %{
      "id" => "https://remote.instance/users/bob",
      "icon" => %{
        "url" => "http://example.com/image.jpg",
        "type" => "Image"
      },
      "image" => %{
        "url" => "http://example.com/image.jpg",
        "type" => "Image"
      },
      "type" => "Person"
    }
  end

  defp build_media_message do
    %{
      "actor" => "https://remote.instance/users/bob",
      "type" => "Create",
      "object" => %{
        "attachment" => [%{}],
        "tag" => ["foo"],
        "sensitive" => false
      }
    }
  end

  defp build_report_message do
    %{
      "actor" => "https://remote.instance/users/bob",
      "type" => "Flag"
    }
  end

  describe "when :media_removal" do
    test "is empty" do
      Config.put([:mrf_simple, :media_removal], [])
      media_message = build_media_message()
      local_message = build_local_message()

      assert SimplePolicy.filter(media_message, false) == {:ok, media_message}
      assert SimplePolicy.filter(local_message, true) == {:ok, local_message}
    end

    test "has a matching host" do
      Config.put([:mrf_simple, :media_removal], ["remote.instance"])
      media_message = build_media_message()
      local_message = build_local_message()

      assert SimplePolicy.filter(media_message, false) ==
               {:ok,
                media_message
                |> Map.put("object", Map.delete(media_message["object"], "attachment"))}

      assert SimplePolicy.filter(local_message, true) == {:ok, local_message}
    end

    test "match with wildcard domain" do
      Config.put([:mrf_simple, :media_removal], ["*remote.instance"])
      media_message = build_media_message()
      local_message = build_local_message()

      assert SimplePolicy.filter(media_message, false) ==
               {:ok,
                media_message
                |> Map.put("object", Map.delete(media_message["object"], "attachment"))}

      assert SimplePolicy.filter(local_message, true) == {:ok, local_message}
    end
  end

  describe "when :media_nsfw" do
    test "is empty" do
      Config.put([:mrf_simple, :media_nsfw], [])
      media_message = build_media_message()
      local_message = build_local_message()

      assert SimplePolicy.filter(media_message, false) == {:ok, media_message}
      assert SimplePolicy.filter(local_message, true) == {:ok, local_message}
    end

    test "has a matching host" do
      Config.put([:mrf_simple, :media_nsfw], ["remote.instance"])
      media_message = build_media_message()
      local_message = build_local_message()

      assert SimplePolicy.filter(media_message, false) ==
               {:ok,
                media_message
                |> put_in(["object", "tag"], ["foo", "nsfw"])
                |> put_in(["object", "sensitive"], true)}

      assert SimplePolicy.filter(local_message, true) == {:ok, local_message}
    end

    test "match with wildcard domain" do
      Config.put([:mrf_simple, :media_nsfw], ["*remote.instance"])
      media_message = build_media_message()
      local_message = build_local_message()

      assert SimplePolicy.filter(media_message, false) ==
               {:ok,
                media_message
                |> put_in(["object", "tag"], ["foo", "nsfw"])
                |> put_in(["object", "sensitive"], true)}

      assert SimplePolicy.filter(local_message, true) == {:ok, local_message}
    end
  end

  describe "when :report_removal" do
    test "is empty" do
      Config.put([:mrf_simple, :report_removal], [])
      report_message = build_report_message()
      local_message = build_local_message()

      assert SimplePolicy.filter(report_message, false) == {:ok, report_message}
      assert SimplePolicy.filter(local_message, true) == {:ok, local_message}
    end

    test "has a matching host" do
      Config.put([:mrf_simple, :report_removal], ["remote.instance"])
      report_message = build_report_message()
      local_message = build_local_message()

      assert {:reject, _} = SimplePolicy.filter(report_message, false)
      assert SimplePolicy.filter(local_message, true) == {:ok, local_message}
    end

    test "match with wildcard domain" do
      Config.put([:mrf_simple, :report_removal], ["*remote.instance"])
      report_message = build_report_message()
      local_message = build_local_message()

      assert {:reject, _} = SimplePolicy.filter(report_message, false)
      assert SimplePolicy.filter(local_message, true) == {:ok, local_message}
    end
  end

  describe "when :reject" do
    test "is empty" do
      Config.put([:mrf_simple, :reject], [])

      remote_message = build_remote_message()

      assert SimplePolicy.filter(remote_message, false) == {:ok, remote_message}
    end

    test "has a matching host" do
      Config.put([:mrf_simple, :reject], ["remote.instance"])

      remote_message = build_remote_message()

      assert {:reject, _} = SimplePolicy.filter(remote_message, false)
    end

    test "match with wildcard domain" do
      Config.put([:mrf_simple, :reject], ["*remote.instance"])

      remote_message = build_remote_message()

      assert {:reject, _} = SimplePolicy.filter(remote_message, false)
    end
  end

  describe "when :avatar_removal" do
    test "is empty" do
      Config.put([:mrf_simple, :avatar_removal], [])

      remote_user = build_remote_user()

      assert SimplePolicy.filter(remote_user, false) == {:ok, remote_user}
    end

    test "is not empty but it doesn't have a matching host" do
      Config.put([:mrf_simple, :avatar_removal], ["non.matching.remote"])

      remote_user = build_remote_user()

      assert SimplePolicy.filter(remote_user, false) == {:ok, remote_user}
    end

    test "has a matching host" do
      Config.put([:mrf_simple, :avatar_removal], ["remote.instance"])

      remote_user = build_remote_user()
      {:ok, filtered} = SimplePolicy.filter(remote_user, false)

      refute filtered["icon"]
    end

    test "match with wildcard domain" do
      Config.put([:mrf_simple, :avatar_removal], ["*remote.instance"])

      remote_user = build_remote_user()
      {:ok, filtered} = SimplePolicy.filter(remote_user, false)

      refute filtered["icon"]
    end
  end

  describe "when :banner_removal" do
    test "is empty" do
      Config.put([:mrf_simple, :banner_removal], [])

      remote_user = build_remote_user()

      assert SimplePolicy.filter(remote_user, false) == {:ok, remote_user}
    end

    test "is not empty but it doesn't have a matching host" do
      Config.put([:mrf_simple, :banner_removal], ["non.matching.remote"])

      remote_user = build_remote_user()

      assert SimplePolicy.filter(remote_user, false) == {:ok, remote_user}
    end

    test "has a matching host" do
      Config.put([:mrf_simple, :banner_removal], ["remote.instance"])

      remote_user = build_remote_user()
      {:ok, filtered} = SimplePolicy.filter(remote_user, false)

      refute filtered["image"]
    end

    test "match with wildcard domain" do
      Config.put([:mrf_simple, :banner_removal], ["*remote.instance"])

      remote_user = build_remote_user()
      {:ok, filtered} = SimplePolicy.filter(remote_user, false)

      refute filtered["image"]
    end
  end
end
