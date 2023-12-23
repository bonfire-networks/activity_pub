defmodule ActivityPub.Fixtures do
  import Untangle
  use Arrows

  # alias ActivityPub.Utils

  @mod_path __DIR__
  def file(path), do: File.read!(@mod_path <> "/../test/" <> path)

  def insert_all() do
    previous_adapter = mock_prepare()

    for {url, fun} <- fixtures() do
      maybe_mock_insert(url, fun)
    end

    Application.put_env(:tesla, :adapter, previous_adapter)

    IO.info("DONE WITH INSERTING FIXTURES")
  end

  def insert(url) do
    previous_adapter = mock_prepare()

    maybe_mock_insert(url, fixtures()[url])

    Application.put_env(:tesla, :adapter, previous_adapter)
  end

  defp mock_prepare do
    previous_adapter = Application.get_env(:tesla, :adapter)

    Application.put_env(:tesla, :adapter, {Tesla.Mock, []})

    mock_global(fn env -> request(env) end)

    previous_adapter
  end

  def mock_global(fun) do
    case Agent.start_link(fn -> fun end, name: Tesla.Mock) do
      {:error, {:already_started, pid}} ->
        Agent.update(pid, fn _ -> fun end)

      other ->
        other
    end
  end

  defp maybe_mock_insert(url, fun) do
    case fun do
      _ when is_function(fun, 1) -> fun.(url)
      _ when is_function(fun, 4) -> fun.(url, nil, nil, nil)
    end
    |> maybe_insert()
  rescue
    e ->
      error(e, "a fixture could not be read")
  end

  defp maybe_insert(%{body: data}) when is_binary(data) do
    data
    |> Jason.decode()
    ~> ActivityPub.Federator.Transformer.handle_incoming()
    |> debug("done")

    :done
  rescue
    e ->
      error(e, "a fixture could not be inserted")
  end

  defp maybe_insert(skip) do
    debug(skip, "skipping")
  end

  def fixtures, do: Map.merge(fixtures_generic(), fixtures_get())

  def fixtures_generic,
    do: %{
      "https://404" => fn "https://404" ->
        %Tesla.Env{
          status: 404
        }
      end,
      "https://mocked.local/2" => fn "https://mocked.local/2" ->
        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "application/activity+json"}],
          body: @sample_object
        }
      end,
      "https://mocked.local/2" => fn "https://mocked.local/2" ->
        %Tesla.Env{
          status: 200,
          headers: [
            {"content-type",
             "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\""}
          ],
          body: @sample_object
        }
      end,
      "https://mocked.local/2" => fn "https://mocked.local/2" ->
        %Tesla.Env{
          status: 200,
          headers: [
            {"content-type",
             "application/ld+json; profile=\"http://www.w3.org/ns/activitystreams\""}
          ],
          body: @sample_object
        }
      end,
      "https://wedistribute.local/wp-json/pterotype/v1/actor/-blog" =>
        fn "https://wedistribute.local/wp-json/pterotype/v1/actor/-blog" ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/wedistribute-user.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://wedistribute.local/wp-json/pterotype/v1/object/85809" =>
        fn "https://wedistribute.local/wp-json/pterotype/v1/object/85809" ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/wedistribute-create-article.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://lemmy.local/post/3" => fn "https://lemmy.local/post/3" ->
        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "application/activity+json"}],
          body: file("fixtures/tesla_mock/lemmy-page.json")
        }
      end,
      "https://lemmy.local/u/nutomic" => fn "https://lemmy.local/u/nutomic" ->
        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "application/activity+json"}],
          body: file("fixtures/tesla_mock/lemmy-user.json")
        }
      end,
      "https://mobilizon.local/events/252d5816-00a3-4a89-a66f-15bf65c33e39" =>
        fn "https://mobilizon.local/events/252d5816-00a3-4a89-a66f-15bf65c33e39" ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/mobilizon.org-event.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://mobilizon.local/@tcit" => fn "https://mobilizon.local/@tcit" ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/mobilizon.org-user.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://funkwhale.local/federation/actors/compositions" =>
        fn "https://funkwhale.local/federation/actors/compositions" ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/funkwhale_channel.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://xyz.local/~/PlumeDevelopment/this-month-in-plume-june-2018/" =>
        fn "https://xyz.local/~/PlumeDevelopment/this-month-in-plume-june-2018/" ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/baptiste.gelex.xyz-article.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://xyz.local/@/BaptisteGelez" => fn "https://xyz.local/@/BaptisteGelez" ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/baptiste.gelex.xyz-user.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://prismo.local/@mxb" => fn "https://prismo.local/@mxb" ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/https___prismo.news__mxb.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://sakamoto.local/notice/9wTkLEnuq47B25EehM" =>
        fn "https://sakamoto.local/notice/9wTkLEnuq47B25EehM" ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/fetch_mocks/9wTkLEnuq47B25EehM.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://sakamoto.local/users/eal" => fn "https://sakamoto.local/users/eal" ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/fetch_mocks/eal.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://busshi.local/users/tuxcrafting/statuses/104410921027210069" =>
        fn "https://busshi.local/users/tuxcrafting/statuses/104410921027210069" ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/fetch_mocks/104410921027210069.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://busshi.local/users/tuxcrafting" => fn "https://busshi.local/users/tuxcrafting" ->
        %Tesla.Env{
          status: 500
        }
      end,
      "https://stereophonic.space/objects/02997b83-3ea7-4b63-94af-ef3aa2d4ed17" =>
        fn "https://stereophonic.space/objects/02997b83-3ea7-4b63-94af-ef3aa2d4ed17" ->
          %Tesla.Env{
            status: 500
          }
        end,
      "https://mastodon.local/users/userisgone" => fn "https://mastodon.local/users/userisgone" ->
        %Tesla.Env{status: 410}
      end,
      "https://mastodon.local/users/userisgone404" =>
        fn "https://mastodon.local/users/userisgone404" ->
          %Tesla.Env{status: 404}
        end,
      "https://patch.local/media/03ca3c8b4ac3ddd08bf0f84be7885f2f88de0f709112131a22d83650819e36c2.json" =>
        fn "https://patch.local/media/03ca3c8b4ac3ddd08bf0f84be7885f2f88de0f709112131a22d83650819e36c2.json" ->
          %Tesla.Env{
            status: 200,
            headers: [{"content-type", "application/json"}],
            body: file("fixtures/spoofed-object.json")
          }
        end,
      "https://fedi.local/objects/410" => fn "https://fedi.local/objects/410" ->
        %Tesla.Env{status: 410}
      end,
      "http://mastodon.local/hello" => fn "http://mastodon.local/hello" ->
        %Tesla.Env{status: 200, body: "hello"}
      end,
      "https://fedi.local/userisgone404" => fn "https://fedi.local/userisgone404" ->
        %Tesla.Env{status: 404}
      end,
      "https://fedi.local/userisgone410" => fn "https://fedi.local/userisgone410" ->
        %Tesla.Env{status: 410}
      end,
      "https://fedi.local/userisgone502" => fn "https://fedi.local/userisgone502" ->
        %Tesla.Env{status: 502}
      end,
      "https://fedi.local/userisgone502" => fn "https://fedi.local/userisgone502" ->
        %Tesla.Env{status: 502}
      end,
      "https://mocked.local/users/emelie/collections/featured" =>
        fn "https://mocked.local/users/emelie/collections/featured" ->
          %Tesla.Env{
            status: 200,
            headers: [{"content-type", "application/activity+json"}],
            body:
              Jason.encode!(%{
                "id" => "https://mocked.local/users/emelie/collections/featured",
                "type" => "OrderedCollection",
                "actor" => "https://mocked.local/users/emelie",
                "attributedTo" => "https://mocked.local/users/emelie",
                "orderedItems" => [],
                "totalItems" => 0
              })
          }
        end,
      "https://mocked.local/users/emelie/collections/featured" =>
        fn "https://mocked.local/users/emelie/collections/featured" ->
          %Tesla.Env{
            status: 200,
            headers: [{"content-type", "application/activity+json"}],
            body:
              Jason.encode!(%{
                "id" => "https://mocked.local/users/emelie/collections/featured",
                "type" => "OrderedCollection",
                "actor" => "https://mocked.local/users/emelie",
                "attributedTo" => "https://mocked.local/users/emelie",
                "orderedItems" => [],
                "totalItems" => 0
              })
          }
        end,
      "https://misskey.local/notes/934gok3482" => fn "https://misskey.local/notes/934gok3482" ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/misskey/recursive_quote.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://misskey.local/notes/92j1n3owja" => fn "https://misskey.local/notes/92j1n3owja" ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/misskey/mfm_underscore_format.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://misskey.local/notes/92j1n3owja_x" =>
        fn "https://misskey.local/notes/92j1n3owja_x" ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/misskey/mfm_x_format.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end
      # "https://mastodon.local/objects/43479e20-c0f8-4f49-bf7f-13fab8234924" =>
      #   fn "https://mastodon.local/objects/43479e20-c0f8-4f49-bf7f-13fab8234924" ->
      #     %Tesla.Env{
      #       status: 200,
      #       body: file("fixtures/quoted_status.json"),
      #       headers: ActivityPub.Utils.activitypub_object_headers()
      #     }
      #   end,
      # "https://mastodon.local/objects/43479e20-c0f8-4f49-bf7f-13fab8234924" =>
      #   fn "https://mastodon.local/objects/43479e20-c0f8-4f49-bf7f-13fab8234924" ->
      #     %Tesla.Env{
      #       status: 200,
      #       body: file("fixtures/quoted_status.json"),
      #       headers: ActivityPub.Utils.activitypub_object_headers()
      #     }
      #   end
    }

  def fixtures_get,
    do: %{
      "https://mastodon.local/users/admin/statuses/99512778738411822/activity" =>
        fn "https://mastodon.local/users/admin/statuses/99512778738411822/activity", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/mastodon/mastodon-post-activity.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://mastodon.local/@admin/99512778738411822" =>
        fn "https://mastodon.local/@admin/99512778738411822", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/mastodon/mastodon-note-object.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://mastodon.local/users/admin/statuses/99512778738411822" =>
        fn "https://mastodon.local/users/admin/statuses/99512778738411822", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/mastodon/mastodon-note-object.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://mocked.local/users/karen" => fn "https://mocked.local/users/karen", _, _, _ ->
        %Tesla.Env{status: 200, body: file("fixtures/pleroma_user_actor.json")}
      end,
      "https://testing.local/users/karen" => fn "https://testing.local/users/karen", _, _, _ ->
        %Tesla.Env{status: 200, body: file("fixtures/pleroma_user_actor2.json")}
      end,
      "https://group.local/u/bernie2020" => fn "https://group.local/u/bernie2020", _, _, _ ->
        %Tesla.Env{status: 200, body: file("fixtures/guppe-actor.json")}
      end,
      "https://mocked.local/objects/eb3b1181-38cc-4eaf-ba1b-3f5431fa9779" =>
        fn "https://mocked.local/objects/eb3b1181-38cc-4eaf-ba1b-3f5431fa9779", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/pleroma_note.json")
          }
        end,
      "https://testing.local/objects/d953809b-d968-49c8-aa8f-7545b9480a12" =>
        fn "https://testing.local/objects/d953809b-d968-49c8-aa8f-7545b9480a12", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/pleroma_private_note.json")
          }
        end,
      "https://instance.local/objects/89a60bfd-6b05-42c0-acde-ce73cc9780e6" =>
        fn "https://instance.local/objects/89a60bfd-6b05-42c0-acde-ce73cc9780e6", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/spoofed_pleroma_note.json")
          }
        end,
      "https://home.local/1" => fn "https://home.local/1", _, _, _ ->
        %Tesla.Env{status: 200, body: file("fixtures/mooglenet_person_actor.json")}
      end,
      "https://mocked.local/.well-known/webfinger?resource=acct:karen@mocked.local" =>
        fn "https://mocked.local/.well-known/webfinger?resource=acct:karen@mocked.local",
           _,
           _,
           _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/pleroma_webfinger.json")
          }
        end,
      "http://mocked.local/.well-known/webfinger?resource=acct:karen@mocked.local" =>
        fn "http://mocked.local/.well-known/webfinger?resource=acct:karen@mocked.local",
           _,
           _,
           _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/pleroma_webfinger.json")
          }
        end,
      "https://mastodon.local/.well-known/webfinger?resource=acct:karen@mastodon.local" =>
        fn "https://mastodon.local/.well-known/webfinger?resource=acct:karen@mastodon.local",
           _,
           _,
           _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/mastodon/mastodon_webfinger.json")
          }
        end,
      "https://mastodon.local/.well-known/webfinger?resource=acct:karen@mastodon.local" =>
        fn "https://mastodon.local/.well-known/webfinger?resource=acct:karen@mastodon.local",
           _,
           _,
           _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/mastodon/mastodon_webfinger.json")
          }
        end,
      "https://osada.local/channel/mike" => fn "https://osada.local/channel/mike", _, _, _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/https___osada.macgirvin.com_channel_mike.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://sposter.local/users/moonman" => fn "https://sposter.local/users/moonman",
                                                  _,
                                                  _,
                                                  _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/moonman@shitposter.club.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://mocked.local/users/emelie/statuses/101849165031453009" =>
        fn "https://mocked.local/users/emelie/statuses/101849165031453009", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/status.emelie.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://mocked.local/users/emelie/statuses/101849165031453404" =>
        fn "https://mocked.local/users/emelie/statuses/101849165031453404", _, _, _ ->
          %Tesla.Env{
            status: 404,
            body: ""
          }
        end,
      "https://mocked.local/users/emelie" => fn "https://mocked.local/users/emelie", _, _, _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/emelie.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://mocked.local/users/not_found" => fn "https://mocked.local/users/not_found",
                                                   _,
                                                   _,
                                                   _ ->
        %Tesla.Env{status: 404}
      end,
      "https://masto.local/users/rinpatch" => fn "https://masto.local/users/rinpatch", _, _, _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/rinpatch.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      # "https://masto.local/users/rinpatch/collections/featured" =>
      #   fn "https://masto.local/users/rinpatch/collections/featured", _, _, _ ->
      #     %Tesla.Env{
      #       status: 200,
      #       body:
      #         file("fixtures/users_mock/masto_featured.json")
      #         |> String.replace("{{domain}}", "mastodon.sdf.org")
      #         |> String.replace("{{nickname}}", "rinpatch"),
      #       headers: [{"content-type", "application/activity+json"}]
      #     }
      #   end,
      "https://patch.local/objects/tesla_mock/poll_attachment" =>
        fn "https://patch.local/objects/tesla_mock/poll_attachment", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/poll_attachment.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://mocked.local/.well-known/webfinger?resource=https://mocked.local/users/emelie" =>
        fn "https://mocked.local/.well-known/webfinger?resource=https://mocked.local/users/emelie",
           _,
           _,
           _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/webfinger_emelie.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://osada.local/.well-known/webfinger?resource=acct:mike@osada.macgirvin.com" =>
        fn "https://osada.local/.well-known/webfinger?resource=acct:mike@osada.macgirvin.com",
           _,
           _,
           _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/mike@osada.macgirvin.com.json"),
            headers: [{"content-type", "application/jrd+json"}]
          }
        end,
      "https://social.local/.well-known/webfinger?resource=https://social.local/user/29191" =>
        fn "https://social.local/.well-known/webfinger?resource=https://social.local/user/29191",
           _,
           _,
           _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/https___social.heldscal.la_user_29191.xml")
          }
        end,
      "https://pawoo.local/.well-known/webfinger?resource=acct:https://pawoo.local/users/pekorino" =>
        fn "https://pawoo.local/.well-known/webfinger?resource=acct:https://pawoo.local/users/pekorino",
           _,
           _,
           _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/https___pawoo.net_users_pekorino.xml")
          }
        end,
      "https://stopwatchingus.local/.well-known/webfinger?resource=acct:https://stopwatchingus.local/user/18330" =>
        fn "https://stopwatchingus.local/.well-known/webfinger?resource=acct:https://stopwatchingus.local/user/18330",
           _,
           _,
           _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/atarifrosch_webfinger.xml")
          }
        end,
      "https://social.local/.well-known/webfinger?resource=nonexistant@social.heldscal.la" =>
        fn "https://social.local/.well-known/webfinger?resource=nonexistant@social.heldscal.la",
           _,
           _,
           _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/nonexistant@social.heldscal.la.xml")
          }
        end,
      "https://me.local/xrd/?uri=acct:lain@squeet.me" =>
        fn "https://me.local/xrd/?uri=acct:lain@squeet.me", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/lain_squeet.me_webfinger.xml"),
            headers: [{"content-type", "application/xrd+xml"}]
          }
        end,
      "https://interlinked.local/users/luciferMysticus" =>
        fn "https://interlinked.local/users/luciferMysticus", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/lucifermysticus.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://prismo.local/@mxb" => fn "https://prismo.local/@mxb", _, _, _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/https___prismo.news__mxb.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://hubzilla.local/channel/kaniini" => fn "https://hubzilla.local/channel/kaniini",
                                                     _,
                                                     _,
                                                     _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/kaniini@hubzilla.example.org.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://niu.local/users/rye" => fn "https://niu.local/users/rye", _, _, _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/rye.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://n1u.moe/users/rye" => fn "https://n1u.moe/users/rye", _, _, _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/rye.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://mastodon.local/users/admin/statuses/100787282858396771" =>
        fn "https://mastodon.local/users/admin/statuses/100787282858396771", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body:
              file("fixtures/tesla_mock/http___mastodon.example.org_users_admin_status_1234.json")
          }
        end,
      "https://puckipedia.local/" => fn "https://puckipedia.local/", _, _, _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/puckipedia.com.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://group.local/accounts/7even" => fn "https://group.local/accounts/7even", _, _, _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/7even.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://peertube.local/accounts/createurs" =>
        fn "https://peertube.local/accounts/createurs", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/peertube/actor-person.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://group.local/videos/watch/df5f464b-be8d-46fb-ad81-2d4c2d1630e3" =>
        fn "https://group.local/videos/watch/df5f464b-be8d-46fb-ad81-2d4c2d1630e3", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/peertube.moe-vid.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://framatube.local/accounts/framasoft" =>
        fn "https://framatube.local/accounts/framasoft", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/https___framatube.org_accounts_framasoft.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://framatube.local/videos/watch/6050732a-8a7a-43d4-a6cd-809525a1d206" =>
        fn "https://framatube.local/videos/watch/6050732a-8a7a-43d4-a6cd-809525a1d206", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/framatube.org-video.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://peertube.local/accounts/craigmaloney" =>
        fn "https://peertube.local/accounts/craigmaloney", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/craigmaloney.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://peertube.local/videos/watch/278d2b7c-0f38-4aaa-afe6-9ecc0c4a34fe" =>
        fn "https://peertube.local/videos/watch/278d2b7c-0f38-4aaa-afe6-9ecc0c4a34fe", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/peertube-social.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://mobilizon.local/events/252d5816-00a3-4a89-a66f-15bf65c33e39" =>
        fn "https://mobilizon.local/events/252d5816-00a3-4a89-a66f-15bf65c33e39", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/mobilizon.org-event.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://mobilizon.local/@tcit" => fn "https://mobilizon.local/@tcit", _, _, _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/mobilizon.org-user.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://xyz.local/@/BaptisteGelez" => fn "https://xyz.local/@/BaptisteGelez", _, _, _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/baptiste.gelex.xyz-user.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://xyz.local/~/PlumeDevelopment/this-month-in-plume-june-2018/" =>
        fn "https://xyz.local/~/PlumeDevelopment/this-month-in-plume-june-2018/", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/baptiste.gelex.xyz-article.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://wedistribute.local/wp-json/pterotype/v1/object/85810" =>
        fn "https://wedistribute.local/wp-json/pterotype/v1/object/85810", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/wedistribute-article.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://wedistribute.local/wp-json/pterotype/v1/actor/-blog" =>
        fn "https://wedistribute.local/wp-json/pterotype/v1/actor/-blog", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/wedistribute-user.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://mastodon.local/users/admin/statuses/99512778738411822/replies?min_id=99512778738411824&page=true" =>
        fn "https://mastodon.local/users/admin/statuses/99512778738411822/replies?min_id=99512778738411824&page=true",
           _,
           _,
           _ ->
          %Tesla.Env{status: 404, body: ""}
        end,
      "https://mastodon.local/users/relay" => fn "https://mastodon.local/users/relay", _, _, _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/relay@mastdon.example.org.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://mastodon.local/users/admin" => fn "https://mastodon.local/users/admin", _, _, _ ->
        %Tesla.Env{status: 200, body: file("fixtures/mastodon/mastodon-actor.json")}
      end,
      "https://mastodon.local/user/karen" => fn "https://mastodon.local/user/karen", _, _, _ ->
        %Tesla.Env{status: 200, body: file("fixtures/mastodon/mastodon-actor.json")}
      end,
      "https://mastodon.local/@karen" => fn "https://mastodon.local/@karen", _, _, _ ->
        %Tesla.Env{status: 200, body: file("fixtures/mastodon/mastodon-actor.json")}
      end,
      #       "https://mastodon.local/users/admin" => fn "https://mastodon.local/users/admin", _, _, _ ->
      #   %Tesla.Env{
      #     status: 200,
      #     body: file("fixtures/tesla_mock/admin@mastdon.example.org.json"),
      #     headers: ActivityPub.Utils.activitypub_object_headers()
      #   }
      # end,
      #  [
      #    {"Accept", "application/activity+json"}
      #  ]
      "https://mastodon.local/users/deleted" => fn "https://mastodon.local/users/deleted",
                                                   _,
                                                   _,
                                                   _ ->
        {:error, :nxdomain}
      end,
      "https://osada.local/.well-known/host-meta" =>
        fn "https://osada.local/.well-known/host-meta", _, _, _ ->
          %Tesla.Env{status: 404, body: ""}
        end,
      "http://masto.local/.well-known/host-meta" => fn "http://masto.local/.well-known/host-meta",
                                                       _,
                                                       _,
                                                       _ ->
        %Tesla.Env{status: 200, body: file("fixtures/tesla_mock/sdf.org_host_meta")}
      end,
      "https://masto.local/.well-known/host-meta" =>
        fn "https://masto.local/.well-known/host-meta", _, _, _ ->
          %Tesla.Env{status: 200, body: file("fixtures/tesla_mock/sdf.org_host_meta")}
        end,
      "https://masto.local/.well-known/webfinger?resource=https://masto.local/users/snowdusk" =>
        fn "https://masto.local/.well-known/webfinger?resource=https://masto.local/users/snowdusk",
           _,
           _,
           _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/snowdusk@sdf.org_host_meta.json")
          }
        end,
      "http://mstdn.local/.well-known/host-meta" => fn "http://mstdn.local/.well-known/host-meta",
                                                       _,
                                                       _,
                                                       _ ->
        %Tesla.Env{status: 200, body: file("fixtures/tesla_mock/mstdn.jp_host_meta")}
      end,
      "https://mstdn.local/.well-known/host-meta" =>
        fn "https://mstdn.local/.well-known/host-meta", _, _, _ ->
          %Tesla.Env{status: 200, body: file("fixtures/tesla_mock/mstdn.jp_host_meta")}
        end,
      "https://mstdn.local/.well-known/webfinger?resource=kpherox@mstdn.jp" =>
        fn "https://mstdn.local/.well-known/webfinger?resource=kpherox@mstdn.jp", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/kpherox@mstdn.jp.xml")
          }
        end,
      "http://mamot.local/.well-known/host-meta" => fn "http://mamot.local/.well-known/host-meta",
                                                       _,
                                                       _,
                                                       _ ->
        %Tesla.Env{status: 200, body: file("fixtures/tesla_mock/mamot.fr_host_meta")}
      end,
      "https://mamot.local/.well-known/host-meta" =>
        fn "https://mamot.local/.well-known/host-meta", _, _, _ ->
          %Tesla.Env{status: 200, body: file("fixtures/tesla_mock/mamot.fr_host_meta")}
        end,
      "http://pawoo.local/.well-known/host-meta" => fn "http://pawoo.local/.well-known/host-meta",
                                                       _,
                                                       _,
                                                       _ ->
        %Tesla.Env{status: 200, body: file("fixtures/tesla_mock/pawoo.net_host_meta")}
      end,
      "https://pawoo.local/.well-known/host-meta" =>
        fn "https://pawoo.local/.well-known/host-meta", _, _, _ ->
          %Tesla.Env{status: 200, body: file("fixtures/tesla_mock/pawoo.net_host_meta")}
        end,
      "https://pawoo.local/.well-known/webfinger?resource=https://pawoo.local/users/pekorino" =>
        fn "https://pawoo.local/.well-known/webfinger?resource=https://pawoo.local/users/pekorino",
           _,
           _,
           _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/pekorino@pawoo.net_host_meta.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "http://akkoma.local/.well-known/host-meta" =>
        fn "http://akkoma.local/.well-known/host-meta", _, _, _ ->
          %Tesla.Env{status: 200, body: file("fixtures/tesla_mock/soykaf.com_host_meta")}
        end,
      "https://akkoma.local/.well-known/host-meta" =>
        fn "https://akkoma.local/.well-known/host-meta", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/soykaf.com_host_meta")
          }
        end,
      "http://stopwatchingus.local/.well-known/host-meta" =>
        fn "http://stopwatchingus.local/.well-known/host-meta", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/stopwatchingus-heidelberg.de_host_meta")
          }
        end,
      "https://stopwatchingus.local/.well-known/host-meta" =>
        fn "https://stopwatchingus.local/.well-known/host-meta", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/stopwatchingus-heidelberg.de_host_meta")
          }
        end,
      "https://mastodon.local/@admin/99541947525187368" =>
        fn "https://mastodon.local/@admin/99541947525187368", _, _, _ ->
          %Tesla.Env{
            status: 404,
            body: ""
          }
        end,
      "https://sposter.local/notice/7369654" => fn "https://sposter.local/notice/7369654",
                                                   _,
                                                   _,
                                                   _ ->
        %Tesla.Env{status: 200, body: file("fixtures/tesla_mock/7369654.html")}
      end,
      "https://mstdn.local/users/mayuutann" => fn "https://mstdn.local/users/mayuutann",
                                                  _,
                                                  _,
                                                  _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/mayumayu.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://mstdn.local/users/mayuutann/statuses/99568293732299394" =>
        fn "https://mstdn.local/users/mayuutann/statuses/99568293732299394", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/mayumayupost.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://akkoma.local/.well-known/webfinger?resource=acct:https://akkoma.local/users/lain" =>
        fn "https://akkoma.local/.well-known/webfinger?resource=acct:https://akkoma.local/users/lain",
           _,
           _,
           _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/https___pleroma.soykaf.com_users_lain.xml")
          }
        end,
      "https://akkoma.local/.well-known/webfinger?resource=https://akkoma.local/users/lain" =>
        fn "https://akkoma.local/.well-known/webfinger?resource=https://akkoma.local/users/lain",
           _,
           _,
           _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/https___pleroma.soykaf.com_users_lain.xml")
          }
        end,
      "https://sposter.local/.well-known/webfinger?resource=https://sposter.local/user/1" =>
        fn "https://sposter.local/.well-known/webfinger?resource=https://sposter.local/user/1",
           _,
           _,
           _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/https___shitposter.club_user_1.xml")
          }
        end,
      "https://akkoma.local/objects/b319022a-4946-44c5-9de9-34801f95507b" =>
        fn "https://akkoma.local/objects/b319022a-4946-44c5-9de9-34801f95507b", _, _, _ ->
          %Tesla.Env{status: 200}
        end,
      "https://sposter.local/.well-known/webfinger?resource=https://sposter.local/user/5381" =>
        fn "https://sposter.local/.well-known/webfinger?resource=https://sposter.local/user/5381",
           _,
           _,
           _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/spc_5381_xrd.xml")
          }
        end,
      "http://sposter.local/.well-known/host-meta" =>
        fn "http://sposter.local/.well-known/host-meta", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/shitposter.club_host_meta")
          }
        end,
      "https://sposter.local/notice/4027863" => fn "https://sposter.local/notice/4027863",
                                                   _,
                                                   _,
                                                   _ ->
        %Tesla.Env{status: 200, body: file("fixtures/tesla_mock/7369654.html")}
      end,
      "http://sakamoto.local/.well-known/host-meta" =>
        fn "http://sakamoto.local/.well-known/host-meta", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/social.sakamoto.gq_host_meta")
          }
        end,
      "https://sakamoto.local/.well-known/webfinger?resource=https://sakamoto.local/users/eal" =>
        fn "https://sakamoto.local/.well-known/webfinger?resource=https://sakamoto.local/users/eal",
           _,
           _,
           _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/eal_sakamoto.xml")
          }
        end,
      "http://mocked.local/.well-known/host-meta" =>
        fn "http://mocked.local/.well-known/host-meta", _, _, _ ->
          %Tesla.Env{status: 200, body: file("fixtures/tesla_mock/mastodon.social_host_meta")}
        end,
      "https://mocked.local/.well-known/webfinger?resource=https://mocked.local/users/lambadalambda" =>
        fn "https://mocked.local/.well-known/webfinger?resource=https://mocked.local/users/lambadalambda",
           _,
           _,
           _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/https___mastodon.social_users_lambadalambda.xml")
          }
        end,
      "https://mocked.local/.well-known/webfinger?resource=acct:not_found@mocked.local" =>
        fn "https://mocked.local/.well-known/webfinger?resource=acct:not_found@mocked.local",
           _,
           _,
           _ ->
          %Tesla.Env{status: 404}
        end,
      "http://gs.local/.well-known/host-meta" => fn "http://gs.local/.well-known/host-meta",
                                                    _,
                                                    _,
                                                    _ ->
        %Tesla.Env{status: 200, body: file("fixtures/tesla_mock/gs.example.org_host_meta")}
      end,
      "http://gs.local/.well-known/webfinger?resource=http://gs.local:4040/index.php/user/1" =>
        fn "http://gs.local/.well-known/webfinger?resource=http://gs.local:4040/index.php/user/1",
           _,
           _,
           _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/http___gs.example.org_4040_index.php_user_1.xml")
          }
        end,
      "http://gs.local:4040/index.php/user/1" => fn "http://gs.local:4040/index.php/user/1",
                                                    _,
                                                    _,
                                                    _ ->
        %Tesla.Env{status: 406, body: ""}
      end,
      "https://me.local/.well-known/host-meta" => fn "https://me.local/.well-known/host-meta",
                                                     _,
                                                     _,
                                                     _ ->
        %Tesla.Env{status: 200, body: file("fixtures/tesla_mock/squeet.me_host_meta")}
      end,
      "https://me.local/xrd?uri=lain@squeet.me" => fn "https://me.local/xrd?uri=lain@squeet.me",
                                                      _,
                                                      _,
                                                      _ ->
        %Tesla.Env{status: 200, body: file("fixtures/tesla_mock/lain_squeet.me_webfinger.xml")}
      end,
      "https://social.local/.well-known/webfinger?resource=acct:shp@social.heldscal.la" =>
        fn "https://social.local/.well-known/webfinger?resource=acct:shp@social.heldscal.la",
           _,
           _,
           _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/shp@social.heldscal.la.xml"),
            headers: [{"content-type", "application/xrd+xml"}]
          }
        end,
      "https://social.local/.well-known/webfinger?resource=acct:invalid_content@social.heldscal.la" =>
        fn "https://social.local/.well-known/webfinger?resource=acct:invalid_content@social.heldscal.la",
           _,
           _,
           _ ->
          %Tesla.Env{status: 200, body: "", headers: [{"content-type", "application/jrd+json"}]}
        end,
      "https://framatube.local/.well-known/host-meta" =>
        fn "https://framatube.local/.well-known/host-meta", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/framatube.org_host_meta")
          }
        end,
      "https://framatube.local/main/xrd?uri=acct:framasoft@framatube.org" =>
        fn "https://framatube.local/main/xrd?uri=acct:framasoft@framatube.org", _, _, _ ->
          %Tesla.Env{
            status: 200,
            headers: [{"content-type", "application/jrd+json"}],
            body: file("fixtures/tesla_mock/framasoft@framatube.org.json")
          }
        end,
      "http://gnusocial.local/.well-known/host-meta" =>
        fn "http://gnusocial.local/.well-known/host-meta", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/gnusocial.de_host_meta")
          }
        end,
      "http://gnusocial.local/main/xrd?uri=winterdienst@gnusocial.local" =>
        fn "http://gnusocial.local/main/xrd?uri=winterdienst@gnusocial.local", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/winterdienst_webfinger.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://status.alpicola.com/.well-known/host-meta" =>
        fn "https://status.alpicola.com/.well-known/host-meta", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/status.alpicola.com_host_meta")
          }
        end,
      "https://macgirvin.local/.well-known/host-meta" =>
        fn "https://macgirvin.local/.well-known/host-meta", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/macgirvin.com_host_meta")
          }
        end,
      "https://gerzilla.de/.well-known/host-meta" =>
        fn "https://gerzilla.de/.well-known/host-meta", _, _, _ ->
          %Tesla.Env{status: 200, body: file("fixtures/tesla_mock/gerzilla.de_host_meta")}
        end,
      "https://gerzilla.de/xrd/?uri=acct:kaniini@gerzilla.de" =>
        fn "https://gerzilla.de/xrd/?uri=acct:kaniini@gerzilla.de", _, _, _ ->
          %Tesla.Env{
            status: 200,
            headers: [{"content-type", "application/jrd+json"}],
            body: file("fixtures/tesla_mock/kaniini@gerzilla.de.json")
          }
        end,
      "https://social.local/.well-known/webfinger?resource=https://social.local/user/23211" =>
        fn "https://social.local/.well-known/webfinger?resource=https://social.local/user/23211",
           _,
           _,
           _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/https___social.heldscal.la_user_23211.xml")
          }
        end,
      "http://social.local/.well-known/host-meta" =>
        fn "http://social.local/.well-known/host-meta", _, _, _ ->
          %Tesla.Env{status: 200, body: file("fixtures/tesla_mock/social.heldscal.la_host_meta")}
        end,
      "https://social.local/.well-known/host-meta" =>
        fn "https://social.local/.well-known/host-meta", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/social.heldscal.la_host_meta")
          }
        end,
      "https://mocked.local/users/lambadalambda" => fn "https://mocked.local/users/lambadalambda",
                                                       _,
                                                       _,
                                                       _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/lambadalambda.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      # "https://mocked.local/users/lambadalambda/collections/featured" =>
      #   fn "https://mocked.local/users/lambadalambda/collections/featured", _, _, _ ->
      #     %Tesla.Env{
      #       status: 200,
      #       body:
      #         file("fixtures/users_mock/masto_featured.json")
      #         |> String.replace("{{domain}}", "mocked.local")
      #         |> String.replace("{{nickname}}", "lambadalambda"),
      #       headers: ActivityPub.Utils.activitypub_object_headers()
      #     }
      #   end,
      "https://apfed.local/channel/indio" => fn "https://apfed.local/channel/indio", _, _, _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/osada-user-indio.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://social.local/user/23211" => fn "https://social.local/user/23211", _, _, _ ->
        Tesla.Mock.json(%{"id" => "https://social.local/user/23211"}, status: 200)
      end,
      # "http://mastodon.local/ogp" => fn "http://mastodon.local/ogp", _, _, _ ->
      #   %Tesla.Env{status: 200, body: file("fixtures/rich_media/ogp.html")}
      # end,
      # "https://akomma.local/notice/9kCP7V" => fn "https://akomma.local/notice/9kCP7V", _, _, _ ->
      #   %Tesla.Env{status: 200, body: file("fixtures/rich_media/ogp.html")}
      # end,
      "http://localhost:4001/" => fn "http://localhost:4001/", _, _, _ ->
        %Tesla.Env{status: 200, body: file("fixtures/tesla_mock/7369654.html")}
      end,
      # "http://localhost:4001/users/masto_closed/followers" =>
      #   fn "http://localhost:4001/users/masto_closed/followers", _, _, _ ->
      #     %Tesla.Env{
      #       status: 200,
      #       body: file("fixtures/users_mock/masto_closed_followers.json"),
      #       headers: ActivityPub.Utils.activitypub_object_headers()
      #     }
      #   end,
      # "http://localhost:4001/users/masto_closed/followers?page=1" =>
      #   fn "http://localhost:4001/users/masto_closed/followers?page=1", _, _, _ ->
      #     %Tesla.Env{
      #       status: 200,
      #       body: file("fixtures/users_mock/masto_closed_followers_page.json"),
      #       headers: ActivityPub.Utils.activitypub_object_headers()
      #     }
      #   end,
      # "http://localhost:4001/users/masto_closed/following" =>
      #   fn "http://localhost:4001/users/masto_closed/following", _, _, _ ->
      #     %Tesla.Env{
      #       status: 200,
      #       body: file("fixtures/users_mock/masto_closed_following.json"),
      #       headers: ActivityPub.Utils.activitypub_object_headers()
      #     }
      #   end,
      # "http://localhost:4001/users/masto_closed/following?page=1" =>
      #   fn "http://localhost:4001/users/masto_closed/following?page=1", _, _, _ ->
      #     %Tesla.Env{
      #       status: 200,
      #       body: file("fixtures/users_mock/masto_closed_following_page.json"),
      #       headers: ActivityPub.Utils.activitypub_object_headers()
      #     }
      #   end,
      # "http://localhost:8080/followers/fuser3" => fn "http://localhost:8080/followers/fuser3",
      #                                                _,
      #                                                _,
      #                                                _ ->
      #   %Tesla.Env{
      #     status: 200,
      #     body: file("fixtures/users_mock/friendica_followers.json"),
      #     headers: ActivityPub.Utils.activitypub_object_headers()
      #   }
      # end,
      # "http://localhost:8080/following/fuser3" => fn "http://localhost:8080/following/fuser3",
      #                                                _,
      #                                                _,
      #                                                _ ->
      #   %Tesla.Env{
      #     status: 200,
      #     body: file("fixtures/users_mock/friendica_following.json"),
      #     headers: ActivityPub.Utils.activitypub_object_headers()
      #   }
      # end,
      # "http://localhost:4001/users/fuser2/followers" =>
      #   fn "http://localhost:4001/users/fuser2/followers", _, _, _ ->
      #     %Tesla.Env{
      #       status: 200,
      #       body: file("fixtures/users_mock/pleroma_followers.json"),
      #       headers: ActivityPub.Utils.activitypub_object_headers()
      #     }
      #   end,
      # "http://localhost:4001/users/fuser2/following" =>
      #   fn "http://localhost:4001/users/fuser2/following", _, _, _ ->
      #     %Tesla.Env{
      #       status: 200,
      #       body: file("fixtures/users_mock/pleroma_following.json"),
      #       headers: ActivityPub.Utils.activitypub_object_headers()
      #     }
      #   end,
      "http://domain-with-errors:4001/users/fuser1/followers" =>
        fn "http://domain-with-errors:4001/users/fuser1/followers", _, _, _ ->
          %Tesla.Env{
            status: 504,
            body: ""
          }
        end,
      "http://domain-with-errors:4001/users/fuser1/following" =>
        fn "http://domain-with-errors:4001/users/fuser1/following", _, _, _ ->
          %Tesla.Env{
            status: 504,
            body: ""
          }
        end,
      # "http://mastodon.local/ogp-missing-data" => fn "http://mastodon.local/ogp-missing-data",
      #                                                _,
      #                                                _,
      #                                                _ ->
      #   %Tesla.Env{status: 200, body: file("fixtures/rich_media/ogp-missing-data.html")}
      # end,
      # "https://mastodon.local/ogp-missing-data" => fn "https://mastodon.local/ogp-missing-data",
      #                                                 _,
      #                                                 _,
      #                                                 _ ->
      #   %Tesla.Env{status: 200, body: file("fixtures/rich_media/ogp-missing-data.html")}
      # end,
      # "http://mastodon.local/malformed" => fn "http://mastodon.local/malformed", _, _, _ ->
      #   %Tesla.Env{status: 200, body: file("fixtures/rich_media/malformed-data.html")}
      # end,
      "http://mastodon.local/empty" => fn "http://mastodon.local/empty", _, _, _ ->
        %Tesla.Env{status: 200, body: "hello"}
      end,
      "http://404.site" => fn "http://404.site" <> _, _, _, _ ->
        %Tesla.Env{status: 404, body: ""}
      end,
      # "https://zetsubou.xn--q9jyb4c/.well-known/webfinger?resource=acct:lain@zetsubou.xn--q9jyb4c" =>
      #   fn "https://zetsubou.xn--q9jyb4c/.well-known/webfinger?resource=acct:lain@zetsubou.xn--q9jyb4c",
      #      _,
      #      _,
      #      _ ->
      #     %Tesla.Env{
      #       status: 200,
      #       body: file("fixtures/lain.xml"),
      #       headers: [{"content-type", "application/xrd+xml"}]
      #     }
      #   end,
      # "https://zetsubou.xn--q9jyb4c/.well-known/webfinger?resource=acct:https://zetsubou.xn--q9jyb4c/users/lain" =>
      #   fn "https://zetsubou.xn--q9jyb4c/.well-known/webfinger?resource=acct:https://zetsubou.xn--q9jyb4c/users/lain",
      #      _,
      #      _,
      #      _ ->
      #     %Tesla.Env{
      #       status: 200,
      #       body: file("fixtures/lain.xml"),
      #       headers: [{"content-type", "application/xrd+xml"}]
      #     }
      #   end,
      # "http://zetsubou.xn--q9jyb4c/.well-known/host-meta" =>
      #   fn "http://zetsubou.xn--q9jyb4c/.well-known/host-meta", _, _, _ ->
      #     %Tesla.Env{
      #       status: 200,
      #       body: file("fixtures/host-meta-zetsubou.xn--q9jyb4c.xml")
      #     }
      #   end,

      "http://moe.local/.well-known/host-meta" => fn "http://moe.local/.well-known/host-meta",
                                                     _,
                                                     _,
                                                     _ ->
        %Tesla.Env{status: 200, body: file("fixtures/tesla_mock/lm.kazv.moe_host_meta")}
      end,
      "https://moe.local/.well-known/host-meta" => fn "https://moe.local/.well-known/host-meta",
                                                      _,
                                                      _,
                                                      _ ->
        %Tesla.Env{status: 200, body: file("fixtures/tesla_mock/lm.kazv.moe_host_meta")}
      end,
      "https://moe.local/.well-known/webfinger?resource=acct:mewmew@lm.kazv.moe" =>
        fn "https://moe.local/.well-known/webfinger?resource=acct:mewmew@lm.kazv.moe", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/https___lm.kazv.moe_users_mewmew.xml"),
            headers: [{"content-type", "application/xrd+xml"}]
          }
        end,
      "https://moe.local/users/mewmew" => fn "https://moe.local/users/mewmew", _, _, _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/mewmew@lm.kazv.moe.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      # "https://moe.local/users/mewmew/collections/featured" =>
      #   fn "https://moe.local/users/mewmew/collections/featured", _, _, _ ->
      #     %Tesla.Env{
      #       status: 200,
      #       body:
      #         file("fixtures/users_mock/masto_featured.json")
      #         |> String.replace("{{domain}}", "lm.kazv.moe")
      #         |> String.replace("{{nickname}}", "mewmew"),
      #       headers: [{"content-type", "application/activity+json"}]
      #     }
      #   end,
      "https://akkoma.local/activity.json" => fn "https://akkoma.local/activity.json", _, _, _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/https__info.pleroma.site_activity.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://akkoma.local/activity.json" => fn "https://akkoma.local/activity.json", _, _, _ ->
        %Tesla.Env{status: 404, body: ""}
      end,
      "https://akkoma.local/activity2.json" => fn "https://akkoma.local/activity2.json",
                                                  _,
                                                  _,
                                                  _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/https__info.pleroma.site_activity2.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://akkoma.local/activity2.json" => fn "https://akkoma.local/activity2.json",
                                                  _,
                                                  _,
                                                  _ ->
        %Tesla.Env{status: 404, body: ""}
      end,
      "https://akkoma.local/activity3.json" => fn "https://akkoma.local/activity3.json",
                                                  _,
                                                  _,
                                                  _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/https__info.pleroma.site_activity3.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://akkoma.local/activity3.json" => fn "https://akkoma.local/activity3.json",
                                                  _,
                                                  _,
                                                  _ ->
        %Tesla.Env{status: 404, body: ""}
      end,
      "https://mstdn.local/.well-known/webfinger?resource=acct:kpherox@mstdn.jp" =>
        fn "https://mstdn.local/.well-known/webfinger?resource=acct:kpherox@mstdn.jp", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/kpherox@mstdn.jp.xml"),
            headers: [{"content-type", "application/xrd+xml"}]
          }
        end,
      "https://10.111.10.1/notice/9kCP7V" => fn "https://10.111.10.1/notice/9kCP7V", _, _, _ ->
        %Tesla.Env{status: 200, body: ""}
      end,
      "https://172.16.32.40/notice/9kCP7V" => fn "https://172.16.32.40/notice/9kCP7V", _, _, _ ->
        %Tesla.Env{status: 200, body: ""}
      end,
      "https://192.168.10.40/notice/9kCP7V" => fn "https://192.168.10.40/notice/9kCP7V",
                                                  _,
                                                  _,
                                                  _ ->
        %Tesla.Env{status: 200, body: ""}
      end,
      "https://www.patreon.com/posts/mastodon-2-9-and-28121681" =>
        fn "https://www.patreon.com/posts/mastodon-2-9-and-28121681", _, _, _ ->
          %Tesla.Env{status: 200, body: ""}
        end,
      "https://akkoma.local/activity4.json" => fn "https://akkoma.local/activity4.json",
                                                  _,
                                                  _,
                                                  _ ->
        %Tesla.Env{status: 500, body: "Error occurred"}
      end,
      # "http://mastodon.local/rel_me/anchor" => fn "http://mastodon.local/rel_me/anchor",
      #                                             _,
      #                                             _,
      #                                             _ ->
      #   %Tesla.Env{status: 200, body: file("fixtures/rel_me_anchor.html")}
      # end,
      # "http://mastodon.local/rel_me/anchor_nofollow" =>
      #   fn "http://mastodon.local/rel_me/anchor_nofollow", _, _, _ ->
      #     %Tesla.Env{status: 200, body: file("fixtures/rel_me_anchor_nofollow.html")}
      #   end,
      # "http://mastodon.local/rel_me/link" => fn "http://mastodon.local/rel_me/link", _, _, _ ->
      #   %Tesla.Env{status: 200, body: file("fixtures/rel_me_link.html")}
      # end,
      # "http://mastodon.local/rel_me/null" => fn "http://mastodon.local/rel_me/null", _, _, _ ->
      #   %Tesla.Env{status: 200, body: file("fixtures/rel_me_null.html")}
      # end,
      "https://miss.local/notes/7x9tmrp97i" => fn "https://miss.local/notes/7x9tmrp97i",
                                                  _,
                                                  _,
                                                  _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/misskey_poll_no_end_date.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://exampleorg.local/emoji/firedfox.png" =>
        fn "https://exampleorg.local/emoji/firedfox.png", _, _, _ ->
          %Tesla.Env{status: 200, body: file("fixtures/images/150.png")}
        end,
      "https://miss.local/users/7v1w1r8ce6" => fn "https://miss.local/users/7v1w1r8ce6",
                                                  _,
                                                  _,
                                                  _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/sjw.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://patch.local/users/rin" => fn "https://patch.local/users/rin", _, _, _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/rin.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://funkwhale.local/federation/music/uploads/42342395-0208-4fee-a38d-259a6dae0871" =>
        fn "https://funkwhale.local/federation/music/uploads/42342395-0208-4fee-a38d-259a6dae0871",
           _,
           _,
           _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/funkwhale_audio.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://funkwhale.local/federation/actors/compositions" =>
        fn "https://funkwhale.local/federation/actors/compositions", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/funkwhale_channel.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "http://mastodon.local/rel_me/error" => fn "http://mastodon.local/rel_me/error", _, _, _ ->
        %Tesla.Env{status: 404, body: ""}
      end,
      # "https://relay.mastodon.host/actor" => fn "https://relay.mastodon.host/actor", _, _, _ ->
      #   %Tesla.Env{
      #     status: 200,
      #     body: file("fixtures/relay/relay.json"),
      #     headers: ActivityPub.Utils.activitypub_object_headers()
      #   }
      # end,

      "https://osada.local/" => fn "https://osada.local/", _, "", _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/https___osada.macgirvin.com.html")
        }
      end,
      "https://patch.local/objects/a399c28e-c821-4820-bc3e-4afeb044c16f" =>
        fn "https://patch.local/objects/a399c28e-c821-4820-bc3e-4afeb044c16f", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/emoji-in-summary.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://mk.local/users/8ozbzjs3o8" => fn "https://mk.local/users/8ozbzjs3o8", _, _, _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/mametsuko@mk.absturztau.be.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://moe.local/users/helene" => fn "https://moe.local/users/helene", _, _, _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/helene@p.helene.moe.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://mk.local/notes/93e7nm8wqg" => fn "https://mk.local/notes/93e7nm8wqg", _, _, _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/tesla_mock/mk.absturztau.be-93e7nm8wqg.json"),
          headers: ActivityPub.Utils.activitypub_object_headers()
        }
      end,
      "https://moe.local/objects/fd5910ac-d9dc-412e-8d1d-914b203296c4" =>
        fn "https://moe.local/objects/fd5910ac-d9dc-412e-8d1d-914b203296c4", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/tesla_mock/p.helene.moe-AM7S6vZQmL6pI9TgPY.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://puckipedia.local/ae4ee4e8be/activity" =>
        fn "https://puckipedia.local/ae4ee4e8be/activity", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/kroeg-post-activity.json"),
            headers: ActivityPub.Utils.activitypub_object_headers()
          }
        end,
      "https://oembed.com/providers.json" => fn "https://oembed.com/providers.json", _, _, _ ->
        %Tesla.Env{
          status: 200,
          body: file("fixtures/oembed/providers.json")
        }
      end,
      "https://mastodon.local/users/admin/statuses/99542391527669785/activity" =>
        fn "https://mastodon.local/users/admin/statuses/99542391527669785/activity", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/mastodon/mastodon-announce.json")
          }
        end,
      "https://mocked.local/videos/watch/abece3c3-b9c6-47f4-8040-f3eed8c602e6" =>
        fn "https://mocked.local/videos/watch/abece3c3-b9c6-47f4-8040-f3eed8c602e6", _, _, _ ->
          %Tesla.Env{
            status: 200,
            body: file("fixtures/peertube/video.json")
          }
        end
    }

  def request(env) do
    case env do
      %Tesla.Env{
        url: url,
        method: method,
        headers: headers,
        query: query,
        body: body
      } ->
        with nil <- apply(__MODULE__, method, [url, query, body, headers]) do
          case fixtures_generic()[url] do
            nil ->
              none(url, query, body, headers)

            fun ->
              fun.(url)
          end
        else
          other ->
            other
        end
    end

    # |> IO.inspect(label: "moccck")
  end

  # GET Requests
  #
  def get(url, query \\ [], body \\ [], headers \\ [])

  def get(url, query, body, headers) when is_list(headers) and headers != [] do
    # case [{"Accept", headers[:Accept] || headers[:"Accept"]}] do
    #   ^headers ->
    #     debug("try with maybe_get_local")
    #     maybe_get_local(url, query, body, headers)
    #   head ->
    #   debug("try with get/4")

    get(url, query, body, [])
    # end
  end

  def get(url, query, body, headers) do
    case fixtures_get()[url] do
      nil ->
        debug(url, "none in fixtures_get")
        maybe_get_local(url, query, body, headers)

      fun ->
        debug("try with fixtures_get")
        fun.(url, query, body, headers)
    end
  end

  def maybe_get_local(url, query, body, headers) do
    # there must be a better way to bypass mocks for local URLs?
    base_url = ActivityPub.Web.base_url()

    if String.starts_with?(url, base_url) do
      # TODO: use headers?
      with %{resp_body: resp_body, status: status} <-
             ConnTest.build_conn()
             |> ConnTest.get(String.trim(url, base_url)) do
        %Tesla.Env{status: status, body: resp_body}
      end
    end
  end

  def none(url, query, body, headers) do
    raise "No implemented mock response for get #{inspect(url)}, #{inspect(query)}, #{inspect(headers)}"

    # error(body,
    #   "No implemented mock response for get #{inspect(url)}, #{inspect query}, #{inspect(headers)}"
    # )

    # %Tesla.Env{status: 304, body: "{}"}
  end

  # Most of the rich media mocks are missing HEAD requests, so we just return 404.
  @rich_media_mocks [
    "https://mastodon.local/ogp",
    "https://mastodon.local/ogp-missing-data",
    "https://mastodon.local/twitter-card"
  ]
  def head(url, _query, _body, _headers) when url in @rich_media_mocks do
    %Tesla.Env{status: 404, body: ""}
  end

  def head(url, query, body, headers) do
    {:error,
     "Mock response not implemented for HEAD #{inspect(url)}, #{query}, #{inspect(body)}, #{inspect(headers)}"}
  end

  # POST Requests
  #

  def post(url, query \\ [], body \\ [], headers \\ [])

  def post("https://relay.mastodon.host/inbox", _, _, _) do
    %Tesla.Env{status: 200, body: ""}
  end

  def post("http://exampleorg.local/needs_refresh", _, _, _) do
    %Tesla.Env{
      status: 200,
      body: ""
    }
  end

  def post("https://mastodon.local/inbox", _, _, _) do
    %Tesla.Env{
      status: 200,
      body: ""
    }
  end

  def post("https://hubzilla.local/inbox", _, _, _) do
    %Tesla.Env{
      status: 200,
      body: ""
    }
  end

  def post("http://gs.local/index.php/main/salmon/user/1", _, _, _) do
    %Tesla.Env{
      status: 200,
      body: ""
    }
  end

  def post("http://200.site" <> _, _, _, _) do
    %Tesla.Env{
      status: 200,
      body: ""
    }
  end

  def post("http://connrefused.site" <> _, _, _, _) do
    {:error, :connrefused}
  end

  def post("http://404.site" <> _, _, _, _) do
    %Tesla.Env{
      status: 404,
      body: ""
    }
  end

  def post(url, query, body, headers) do
    {:error,
     "Mock response not implemented for POST #{inspect(url)}, #{query}, #{inspect(body)}, #{inspect(headers)}"}
  end
end
