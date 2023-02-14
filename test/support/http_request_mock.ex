defmodule ActivityPub.Test.HttpRequestMock do
  # import Untangle
  import ActivityPub.Test.Helpers
  import Untangle
  require Phoenix.ConnTest
  alias Phoenix.ConnTest

  alias ActivityPub.Utils

  @endpoint endpoint()

  def activitypub_object_headers, do: [{"content-type", "application/activity+json"}]

  def request(
        %Tesla.Env{
          url: url,
          method: method,
          headers: headers,
          query: query,
          body: body
        } = _env
      ) do
    with {:ok, res} <- apply(__MODULE__, method, [url, query, body, headers]) do
      res
    else
      {_, _r} = error ->
        # warn(r)
        error
    end
  end

  # GET Requests
  #
  def get(url, query \\ [], body \\ [], headers \\ [])

  def get(url, _, _, _)
      when url in [
             "https://mastodon.local/@admin/99541947525187367",
             "https://mastodon.local/users/admin/statuses/99541947525187367",
             "https://mastodon.local/users/admin/statuses/99541947525187367/activity"
           ] do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/mastodon/mastodon-post-activity.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get(url, _, _, _)
      when url in [
             "https://mastodon.local/@admin/99512778738411822",
             "https://mastodon.local/users/admin/statuses/99512778738411822",
             "https://mastodon.local/users/admin/statuses/99512778738411822/activity"
           ] do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/mastodon/mastodon-note-object.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://mocked.local/users/karen", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/pleroma_user_actor.json")
     }}
  end

  def get("https://testing.local/users/karen", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/pleroma_user_actor2.json")
     }}
  end

  def get(
        "https://mocked.local/objects/eb3b1181-38cc-4eaf-ba1b-3f5431fa9779",
        _,
        _,
        _
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/pleroma_note.json")
     }}
  end

  def get(
        "https://testing.local/objects/d953809b-d968-49c8-aa8f-7545b9480a12",
        _,
        _,
        _
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/pleroma_private_note.json")
     }}
  end

  def get(
        "https://instance.local/objects/89a60bfd-6b05-42c0-acde-ce73cc9780e6",
        _,
        _,
        _
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/spoofed_pleroma_note.json")
     }}
  end

  def get("https://home.local/1", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/mooglenet_person_actor.json")
     }}
  end

  def get(
        "https://mocked.local/.well-known/webfinger?resource=acct:karen@mocked.local",
        _,
        _,
        _
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/pleroma_webfinger.json")
     }}
  end

  def get(
        "http://mocked.local/.well-known/webfinger?resource=acct:karen@mocked.local",
        _,
        _,
        _
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/pleroma_webfinger.json")
     }}
  end

  def get(
        "https://mastodon.local/.well-known/webfinger?resource=acct:karen@mastodon.local",
        _,
        _,
        _
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/mastodon_webfinger.json")
     }}
  end

  def get(
        "https://mastodon.local/.well-known/webfinger?resource=acct:karen@mastodon.local",
        _,
        _,
        _
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/mastodon_webfinger.json")
     }}
  end

  def get("https://mastodon.local/users/admin", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/mastodon/mastodon-actor.json")
     }}
  end

  def get("https://mastodon.local/@karen", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/mastodon/mastodon-actor.json")
     }}
  end

  def get("https://osada.local/channel/mike", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/https___osada.macgirvin.com_channel_mike.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://sposter.local/users/moonman", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/moonman@shitposter.club.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://mocked.local/users/emelie/statuses/101849165031453009", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/status.emelie.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://mocked.local/users/emelie/statuses/101849165031453404", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 404,
       body: ""
     }}
  end

  def get("https://mocked.local/users/emelie", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/emelie.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://mocked.local/users/not_found", _, _, _) do
    {:ok, %Tesla.Env{status: 404}}
  end

  def get("https://masto.local/users/rinpatch", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/rinpatch.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://masto.local/users/rinpatch/collections/featured", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body:
         file("fixtures/users_mock/masto_featured.json")
         |> String.replace("{{domain}}", "mastodon.sdf.org")
         |> String.replace("{{nickname}}", "rinpatch"),
       headers: [{"content-type", "application/activity+json"}]
     }}
  end

  def get("https://patch.local/objects/tesla_mock/poll_attachment", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/poll_attachment.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get(
        "https://mocked.local/.well-known/webfinger?resource=https://mocked.local/users/emelie",
        _,
        _,
        _
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/webfinger_emelie.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get(
        "https://osada.local/.well-known/webfinger?resource=acct:mike@osada.macgirvin.com",
        _,
        _,
        [{"Accept", "application/xrd+xml,application/jrd+json"}]
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/mike@osada.macgirvin.com.json"),
       headers: [{"content-type", "application/jrd+json"}]
     }}
  end

  def get(
        "https://social.local/.well-known/webfinger?resource=https://social.local/user/29191",
        _,
        _,
        [{"Accept", "application/xrd+xml,application/jrd+json"}]
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/https___social.heldscal.la_user_29191.xml")
     }}
  end

  def get(
        "https://pawoo.local/.well-known/webfinger?resource=acct:https://pawoo.local/users/pekorino",
        _,
        _,
        [{"Accept", "application/xrd+xml,application/jrd+json"}]
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/https___pawoo.net_users_pekorino.xml")
     }}
  end

  def get(
        "https://stopwatchingus.local/.well-known/webfinger?resource=acct:https://stopwatchingus.local/user/18330",
        _,
        _,
        [{"Accept", "application/xrd+xml,application/jrd+json"}]
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/atarifrosch_webfinger.xml")
     }}
  end

  def get(
        "https://social.local/.well-known/webfinger?resource=nonexistant@social.heldscal.la",
        _,
        _,
        [{"Accept", "application/xrd+xml,application/jrd+json"}]
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/nonexistant@social.heldscal.la.xml")
     }}
  end

  def get(
        "https://me.local/xrd/?uri=acct:lain@squeet.me",
        _,
        _,
        [{"Accept", "application/xrd+xml,application/jrd+json"}]
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/lain_squeet.me_webfinger.xml"),
       headers: [{"content-type", "application/xrd+xml"}]
     }}
  end

  def get(
        "https://interlinked.local/users/luciferMysticus",
        _,
        _,
        [{"Accept", "application/activity+json"}]
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/lucifermysticus.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://prismo.local/@mxb", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/https___prismo.news__mxb.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get(
        "https://hubzilla.local/channel/kaniini",
        _,
        _,
        [{"Accept", "application/activity+json"}]
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/kaniini@hubzilla.example.org.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://niu.local/users/rye", _, _, [{"Accept", "application/activity+json"}]) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/rye.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://n1u.moe/users/rye", _, _, [{"Accept", "application/activity+json"}]) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/rye.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://mastodon.local/users/admin/statuses/100787282858396771", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/http___mastodon.example.org_users_admin_status_1234.json")
     }}
  end

  def get("https://puckipedia.local/", _, _, [{"Accept", "application/activity+json"}]) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/puckipedia.com.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://peertube2.local/accounts/7even", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/7even.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://peertube.local/accounts/createurs", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/peertube/actor-person.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://peertube2.local/videos/watch/df5f464b-be8d-46fb-ad81-2d4c2d1630e3", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/peertube.moe-vid.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://framatube.local/accounts/framasoft", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/https___framatube.org_accounts_framasoft.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://framatube.local/videos/watch/6050732a-8a7a-43d4-a6cd-809525a1d206", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/framatube.org-video.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://peertube.local/accounts/craigmaloney", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/craigmaloney.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://peertube.local/videos/watch/278d2b7c-0f38-4aaa-afe6-9ecc0c4a34fe", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/peertube-social.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://mobilizon.local/events/252d5816-00a3-4a89-a66f-15bf65c33e39", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/mobilizon.org-event.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://mobilizon.local/@tcit", _, _, [{"Accept", "application/activity+json"}]) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/mobilizon.org-user.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://xyz.local/@/BaptisteGelez", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/baptiste.gelex.xyz-user.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://xyz.local/~/PlumeDevelopment/this-month-in-plume-june-2018/", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/baptiste.gelex.xyz-article.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://wedistribute.local/wp-json/pterotype/v1/object/85810", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/wedistribute-article.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://wedistribute.local/wp-json/pterotype/v1/actor/-blog", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/wedistribute-user.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://mastodon.local/users/admin", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/admin@mastdon.example.org.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get(
        "https://mastodon.local/users/admin/statuses/99512778738411822/replies?min_id=99512778738411824&page=true",
        _,
        _,
        _
      ) do
    {:ok, %Tesla.Env{status: 404, body: ""}}
  end

  def get("https://mastodon.local/users/relay", _, _, [
        {"Accept", "application/activity+json"}
      ]) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/relay@mastdon.example.org.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://mastodon.local/users/gargron", _, _, [
        {"Accept", "application/activity+json"}
      ]) do
    {:error, :nxdomain}
  end

  def get("https://osada.local/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 404,
       body: ""
     }}
  end

  def get("http://masto.local/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/sdf.org_host_meta")
     }}
  end

  def get("https://masto.local/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/sdf.org_host_meta")
     }}
  end

  def get(
        "https://masto.local/.well-known/webfinger?resource=https://masto.local/users/snowdusk",
        _,
        _,
        _
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/snowdusk@sdf.org_host_meta.json")
     }}
  end

  def get("http://mstdn.local/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/mstdn.jp_host_meta")
     }}
  end

  def get("https://mstdn.local/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/mstdn.jp_host_meta")
     }}
  end

  def get("https://mstdn.local/.well-known/webfinger?resource=kpherox@mstdn.jp", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/kpherox@mstdn.jp.xml")
     }}
  end

  def get("http://mamot.local/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/mamot.fr_host_meta")
     }}
  end

  def get("https://mamot.local/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/mamot.fr_host_meta")
     }}
  end

  def get("http://pawoo.local/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/pawoo.net_host_meta")
     }}
  end

  def get("https://pawoo.local/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/pawoo.net_host_meta")
     }}
  end

  def get(
        "https://pawoo.local/.well-known/webfinger?resource=https://pawoo.local/users/pekorino",
        _,
        _,
        _
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/pekorino@pawoo.net_host_meta.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("http://akkoma.local/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/soykaf.com_host_meta")
     }}
  end

  def get("https://akkoma.local/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/soykaf.com_host_meta")
     }}
  end

  def get("http://stopwatchingus.local/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/stopwatchingus-heidelberg.de_host_meta")
     }}
  end

  def get("https://stopwatchingus.local/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/stopwatchingus-heidelberg.de_host_meta")
     }}
  end

  def get("https://mastodon.local/@admin/99541947525187368", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 404,
       body: ""
     }}
  end

  def get("https://sposter.local/notice/7369654", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/7369654.html")
     }}
  end

  def get("https://mstdn.local/users/mayuutann", _, _, [{"Accept", "application/activity+json"}]) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/mayumayu.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get(
        "https://mstdn.local/users/mayuutann/statuses/99568293732299394",
        _,
        _,
        [{"Accept", "application/activity+json"}]
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/mayumayupost.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get(url, _, _, [{"Accept", "application/xrd+xml,application/jrd+json"}])
      when url in [
             "https://akkoma.local/.well-known/webfinger?resource=acct:https://akkoma.local/users/lain",
             "https://akkoma.local/.well-known/webfinger?resource=https://akkoma.local/users/lain"
           ] do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/https___pleroma.soykaf.com_users_lain.xml")
     }}
  end

  def get(
        "https://sposter.local/.well-known/webfinger?resource=https://sposter.local/user/1",
        _,
        _,
        [{"Accept", "application/xrd+xml,application/jrd+json"}]
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/https___shitposter.club_user_1.xml")
     }}
  end

  def get("https://akkoma.local/objects/b319022a-4946-44c5-9de9-34801f95507b", _, _, _) do
    {:ok, %Tesla.Env{status: 200}}
  end

  def get(
        "https://sposter.local/.well-known/webfinger?resource=https://sposter.local/user/5381",
        _,
        _,
        [{"Accept", "application/xrd+xml,application/jrd+json"}]
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/spc_5381_xrd.xml")
     }}
  end

  def get("http://sposter.local/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/shitposter.club_host_meta")
     }}
  end

  def get("https://sposter.local/notice/4027863", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/7369654.html")
     }}
  end

  def get("http://sakamoto.local/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/social.sakamoto.gq_host_meta")
     }}
  end

  def get(
        "https://sakamoto.local/.well-known/webfinger?resource=https://sakamoto.local/users/eal",
        _,
        _,
        [{"Accept", "application/xrd+xml,application/jrd+json"}]
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/eal_sakamoto.xml")
     }}
  end

  def get("http://mocked.local/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/mastodon.social_host_meta")
     }}
  end

  def get(
        "https://mocked.local/.well-known/webfinger?resource=https://mocked.local/users/lambadalambda",
        _,
        _,
        [{"Accept", "application/xrd+xml,application/jrd+json"}]
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/https___mastodon.social_users_lambadalambda.xml")
     }}
  end

  def get(
        "https://mocked.local/.well-known/webfinger?resource=acct:not_found@mocked.local",
        _,
        _,
        [{"Accept", "application/xrd+xml,application/jrd+json"}]
      ) do
    {:ok, %Tesla.Env{status: 404}}
  end

  def get("http://gs.local/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/gs.example.org_host_meta")
     }}
  end

  def get(
        "http://gs.local/.well-known/webfinger?resource=http://gs.local:4040/index.php/user/1",
        _,
        _,
        [{"Accept", "application/xrd+xml,application/jrd+json"}]
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/http___gs.example.org_4040_index.php_user_1.xml")
     }}
  end

  def get(
        "http://gs.local:4040/index.php/user/1",
        _,
        _,
        [{"Accept", "application/activity+json"}]
      ) do
    {:ok, %Tesla.Env{status: 406, body: ""}}
  end

  def get("https://me.local/.well-known/host-meta", _, _, _) do
    {:ok, %Tesla.Env{status: 200, body: file("fixtures/tesla_mock/squeet.me_host_meta")}}
  end

  def get(
        "https://me.local/xrd?uri=lain@squeet.me",
        _,
        _,
        [{"Accept", "application/xrd+xml,application/jrd+json"}]
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/lain_squeet.me_webfinger.xml")
     }}
  end

  def get(
        "https://social.local/.well-known/webfinger?resource=acct:shp@social.heldscal.la",
        _,
        _,
        [{"Accept", "application/xrd+xml,application/jrd+json"}]
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/shp@social.heldscal.la.xml"),
       headers: [{"content-type", "application/xrd+xml"}]
     }}
  end

  def get(
        "https://social.local/.well-known/webfinger?resource=acct:invalid_content@social.heldscal.la",
        _,
        _,
        [{"Accept", "application/xrd+xml,application/jrd+json"}]
      ) do
    {:ok, %Tesla.Env{status: 200, body: "", headers: [{"content-type", "application/jrd+json"}]}}
  end

  def get("https://framatube.local/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/framatube.org_host_meta")
     }}
  end

  def get(
        "https://framatube.local/main/xrd?uri=acct:framasoft@framatube.org",
        _,
        _,
        [{"Accept", "application/xrd+xml,application/jrd+json"}]
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       headers: [{"content-type", "application/jrd+json"}],
       body: file("fixtures/tesla_mock/framasoft@framatube.org.json")
     }}
  end

  def get("http://gnusocial.local/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/gnusocial.de_host_meta")
     }}
  end

  def get(
        "http://gnusocial.local/main/xrd?uri=winterdienst@gnusocial.local",
        _,
        _,
        [{"Accept", "application/xrd+xml,application/jrd+json"}]
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/winterdienst_webfinger.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://status.alpicola.com/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/status.alpicola.com_host_meta")
     }}
  end

  def get("https://macgirvin.local/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/macgirvin.com_host_meta")
     }}
  end

  def get("https://gerzilla.de/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/gerzilla.de_host_meta")
     }}
  end

  def get(
        "https://gerzilla.de/xrd/?uri=acct:kaniini@gerzilla.de",
        _,
        _,
        [{"Accept", "application/xrd+xml,application/jrd+json"}]
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       headers: [{"content-type", "application/jrd+json"}],
       body: file("fixtures/tesla_mock/kaniini@gerzilla.de.json")
     }}
  end

  def get(
        "https://social.local/.well-known/webfinger?resource=https://social.local/user/23211",
        _,
        _,
        _
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/https___social.heldscal.la_user_23211.xml")
     }}
  end

  def get("http://social.local/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/social.heldscal.la_host_meta")
     }}
  end

  def get("https://social.local/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/social.heldscal.la_host_meta")
     }}
  end

  def get("https://mocked.local/users/lambadalambda", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/lambadalambda.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://mocked.local/users/lambadalambda/collections/featured", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body:
         file("fixtures/users_mock/masto_featured.json")
         |> String.replace("{{domain}}", "mocked.local")
         |> String.replace("{{nickname}}", "lambadalambda"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://apfed.local/channel/indio", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/osada-user-indio.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://social.local/user/23211", _, _, [{"Accept", "application/activity+json"}]) do
    {:ok, Tesla.Mock.json(%{"id" => "https://social.local/user/23211"}, status: 200)}
  end

  def get("http://example.local/ogp", _, _, _) do
    {:ok, %Tesla.Env{status: 200, body: file("fixtures/rich_media/ogp.html")}}
  end

  def get("https://example.local/ogp", _, _, _) do
    {:ok, %Tesla.Env{status: 200, body: file("fixtures/rich_media/ogp.html")}}
  end

  def get("https://akomma.local/notice/9kCP7V", _, _, _) do
    {:ok, %Tesla.Env{status: 200, body: file("fixtures/rich_media/ogp.html")}}
  end

  def get("http://localhost:4001/users/masto_closed/followers", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/users_mock/masto_closed_followers.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("http://localhost:4001/users/masto_closed/followers?page=1", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/users_mock/masto_closed_followers_page.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("http://localhost:4001/users/masto_closed/following", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/users_mock/masto_closed_following.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("http://localhost:4001/users/masto_closed/following?page=1", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/users_mock/masto_closed_following_page.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("http://localhost:8080/followers/fuser3", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/users_mock/friendica_followers.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("http://localhost:8080/following/fuser3", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/users_mock/friendica_following.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("http://localhost:4001/users/fuser2/followers", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/users_mock/pleroma_followers.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("http://localhost:4001/users/fuser2/following", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/users_mock/pleroma_following.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("http://domain-with-errors:4001/users/fuser1/followers", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 504,
       body: ""
     }}
  end

  def get("http://domain-with-errors:4001/users/fuser1/following", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 504,
       body: ""
     }}
  end

  def get("http://example.local/ogp-missing-data", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/rich_media/ogp-missing-data.html")
     }}
  end

  def get("https://example.local/ogp-missing-data", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/rich_media/ogp-missing-data.html")
     }}
  end

  def get("http://example.local/malformed", _, _, _) do
    {:ok, %Tesla.Env{status: 200, body: file("fixtures/rich_media/malformed-data.html")}}
  end

  def get("http://example.local/empty", _, _, _) do
    {:ok, %Tesla.Env{status: 200, body: "hello"}}
  end

  def get("http://404.site" <> _, _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 404,
       body: ""
     }}
  end

  def get(
        "https://zetsubou.xn--q9jyb4c/.well-known/webfinger?resource=acct:lain@zetsubou.xn--q9jyb4c",
        _,
        _,
        [{"Accept", "application/xrd+xml,application/jrd+json"}]
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/lain.xml"),
       headers: [{"content-type", "application/xrd+xml"}]
     }}
  end

  def get(
        "https://zetsubou.xn--q9jyb4c/.well-known/webfinger?resource=acct:https://zetsubou.xn--q9jyb4c/users/lain",
        _,
        _,
        [{"Accept", "application/xrd+xml,application/jrd+json"}]
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/lain.xml"),
       headers: [{"content-type", "application/xrd+xml"}]
     }}
  end

  def get("http://zetsubou.xn--q9jyb4c/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/host-meta-zetsubou.xn--q9jyb4c.xml")
     }}
  end

  def get(
        "https://zetsubou.xn--q9jyb4c/.well-known/host-meta",
        _,
        _,
        _
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/host-meta-zetsubou.xn--q9jyb4c.xml")
     }}
  end

  def get("http://moe.local/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/lm.kazv.moe_host_meta")
     }}
  end

  def get("https://moe.local/.well-known/host-meta", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/lm.kazv.moe_host_meta")
     }}
  end

  def get(
        "https://moe.local/.well-known/webfinger?resource=acct:mewmew@lm.kazv.moe",
        _,
        _,
        [{"Accept", "application/xrd+xml,application/jrd+json"}]
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/https___lm.kazv.moe_users_mewmew.xml"),
       headers: [{"content-type", "application/xrd+xml"}]
     }}
  end

  def get("https://moe.local/users/mewmew", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/mewmew@lm.kazv.moe.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://moe.local/users/mewmew/collections/featured", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body:
         file("fixtures/users_mock/masto_featured.json")
         |> String.replace("{{domain}}", "lm.kazv.moe")
         |> String.replace("{{nickname}}", "mewmew"),
       headers: [{"content-type", "application/activity+json"}]
     }}
  end

  def get("https://akkoma.local/activity.json", _, _, [
        {"Accept", "application/activity+json"}
      ]) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/https__info.pleroma.site_activity.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://akkoma.local/activity.json", _, _, _) do
    {:ok, %Tesla.Env{status: 404, body: ""}}
  end

  def get("https://akkoma.local/activity2.json", _, _, [
        {"Accept", "application/activity+json"}
      ]) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/https__info.pleroma.site_activity2.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://akkoma.local/activity2.json", _, _, _) do
    {:ok, %Tesla.Env{status: 404, body: ""}}
  end

  def get("https://akkoma.local/activity3.json", _, _, [
        {"Accept", "application/activity+json"}
      ]) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/https__info.pleroma.site_activity3.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://akkoma.local/activity3.json", _, _, _) do
    {:ok, %Tesla.Env{status: 404, body: ""}}
  end

  def get("https://mstdn.local/.well-known/webfinger?resource=acct:kpherox@mstdn.jp", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/kpherox@mstdn.jp.xml"),
       headers: [{"content-type", "application/xrd+xml"}]
     }}
  end

  def get("https://10.111.10.1/notice/9kCP7V", _, _, _) do
    {:ok, %Tesla.Env{status: 200, body: ""}}
  end

  def get("https://172.16.32.40/notice/9kCP7V", _, _, _) do
    {:ok, %Tesla.Env{status: 200, body: ""}}
  end

  def get("https://192.168.10.40/notice/9kCP7V", _, _, _) do
    {:ok, %Tesla.Env{status: 200, body: ""}}
  end

  def get("https://www.patreon.com/posts/mastodon-2-9-and-28121681", _, _, _) do
    {:ok, %Tesla.Env{status: 200, body: ""}}
  end

  def get("https://akkoma.local/activity4.json", _, _, _) do
    {:ok, %Tesla.Env{status: 500, body: "Error occurred"}}
  end

  def get("http://example.local/rel_me/anchor", _, _, _) do
    {:ok, %Tesla.Env{status: 200, body: file("fixtures/rel_me_anchor.html")}}
  end

  def get("http://example.local/rel_me/anchor_nofollow", _, _, _) do
    {:ok, %Tesla.Env{status: 200, body: file("fixtures/rel_me_anchor_nofollow.html")}}
  end

  def get("http://example.local/rel_me/link", _, _, _) do
    {:ok, %Tesla.Env{status: 200, body: file("fixtures/rel_me_link.html")}}
  end

  def get("http://example.local/rel_me/null", _, _, _) do
    {:ok, %Tesla.Env{status: 200, body: file("fixtures/rel_me_null.html")}}
  end

  def get("https://miss.local/notes/7x9tmrp97i", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/misskey_poll_no_end_date.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://exampleorg.local/emoji/firedfox.png", _, _, _) do
    {:ok, %Tesla.Env{status: 200, body: file("fixtures/image.jpg")}}
  end

  def get("https://miss.local/users/7v1w1r8ce6", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/sjw.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://patch.local/users/rin", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/rin.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get(
        "https://funkwhale.local/federation/music/uploads/42342395-0208-4fee-a38d-259a6dae0871",
        _,
        _,
        _
      ) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/funkwhale_audio.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://funkwhale.local/federation/actors/compositions", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/funkwhale_channel.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("http://example.local/rel_me/error", _, _, _) do
    {:ok, %Tesla.Env{status: 404, body: ""}}
  end

  def get("https://relay.mastodon.host/actor", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/relay/relay.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("http://localhost:4001/", _, "", [{"Accept", "text/html"}]) do
    {:ok, %Tesla.Env{status: 200, body: file("fixtures/tesla_mock/7369654.html")}}
  end

  def get("https://osada.local/", _, "", [{"Accept", "text/html"}]) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/https___osada.macgirvin.com.html")
     }}
  end

  def get("https://patch.local/objects/a399c28e-c821-4820-bc3e-4afeb044c16f", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/emoji-in-summary.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://mk.local/users/8ozbzjs3o8", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/mametsuko@mk.absturztau.be.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://moe.local/users/helene", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/helene@p.helene.moe.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://mk.local/notes/93e7nm8wqg", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/mk.absturztau.be-93e7nm8wqg.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://moe.local/objects/fd5910ac-d9dc-412e-8d1d-914b203296c4", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/tesla_mock/p.helene.moe-AM7S6vZQmL6pI9TgPY.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get("https://puckipedia.local/ae4ee4e8be/activity", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: file("fixtures/kroeg-post-activity.json"),
       headers: activitypub_object_headers()
     }}
  end

  def get(url, query, body, headers) when is_list(headers) and headers != [] do
    case [{"Accept", headers[:Accept]}] do
      ^headers -> maybe_get_local(url, query, body, headers)
      head -> get(url, query, body, head)
    end
  end

  def get(url, query, body, headers) do
    maybe_get_local(url, query, body, headers)
  end

  def maybe_get_local(url, query, body, headers) do
    # there must be a better way to bypass mocks for local URLs?
    base_url = ActivityPubWeb.base_url()

    if String.starts_with?(url, base_url) do
      # TODO: use headers?
      with %{resp_body: resp_body, status: status} <-
             ConnTest.build_conn()
             |> ConnTest.get(String.trim(url, base_url)) do
        {:ok, %Tesla.Env{status: status, body: resp_body}}
      end
    else
      error(
        "No implemented mock response for get #{inspect(url)}, #{query}, #{inspect(body)}, #{inspect(headers)}"
      )

      {:ok, %Tesla.Env{status: 304, body: "{}"}}
    end
  end

  # POST Requests
  #

  def post(url, query \\ [], body \\ [], headers \\ [])

  def post("https://relay.mastodon.host/inbox", _, _, _) do
    {:ok, %Tesla.Env{status: 200, body: ""}}
  end

  def post("http://exampleorg.local/needs_refresh", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: ""
     }}
  end

  def post("https://mastodon.local/inbox", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: ""
     }}
  end

  def post("https://hubzilla.local/inbox", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: ""
     }}
  end

  def post("http://gs.local/index.php/main/salmon/user/1", _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: ""
     }}
  end

  def post("http://200.site" <> _, _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 200,
       body: ""
     }}
  end

  def post("http://connrefused.site" <> _, _, _, _) do
    {:error, :connrefused}
  end

  def post("http://404.site" <> _, _, _, _) do
    {:ok,
     %Tesla.Env{
       status: 404,
       body: ""
     }}
  end

  def post(url, query, body, headers) do
    {:error,
     "Mock response not implemented for POST #{inspect(url)}, #{query}, #{inspect(body)}, #{inspect(headers)}"}
  end

  # Most of the rich media mocks are missing HEAD requests, so we just return 404.
  @rich_media_mocks [
    "https://example.local/ogp",
    "https://example.local/ogp-missing-data",
    "https://example.local/twitter-card"
  ]
  def head(url, _query, _body, _headers) when url in @rich_media_mocks do
    {:ok, %Tesla.Env{status: 404, body: ""}}
  end

  def head(url, query, body, headers) do
    {:error,
     "Mock response not implemented for HEAD #{inspect(url)}, #{query}, #{inspect(body)}, #{inspect(headers)}"}
  end
end
