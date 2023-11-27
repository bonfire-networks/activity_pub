# if Code.ensure_loaded?(Chaperon.Scenario) do
#   defmodule ActivityPub.Web.LoadTesting do
#     defmodule Scenario do
#       use Chaperon.Scenario

#       def init(session) do
#         session
#         |> ok
#       end

#       def run(session) do
#         session
#         |> publish_loop
#       end

#       def publish_loop(session) do
#         session
#         |> publish_loop(session.config.publications_per_loop)
#       end

#       def publish_loop(session, 0) do
#         session
#         <~ publish
#       end

#       def publish_loop(session, publications) do
#         session
#         |> loop(:publish, session.config.duration)
#         |> publish_loop(publications - 1)
#       end

#       def publish(session) do
#         session
#         |> delay(:rand.uniform(session.config.base_interval))
#         ~> publish(session.config.channel)
#       end

#       def publish(session, channel) do
#         ts = Chaperon.Timing.timestamp()

#         session
#         |> post(
#           channel,
#           json: %{
#             "id" => "#{ActivityPub.Utils.ap_base_url()}/#{ts}",
#             "hello" => "world",
#             "time" => ts
#           },
#           headers: %{"X-Firehose-Persist" => true}
#         )
#       end
#     end

#     use Chaperon.LoadTest

#     def default_config,
#       do: %{
#         # scenario_timeout: 12_000,
#         merge_scenario_sessions: true,
#         base_url: ActivityPub.Federator.Adapter.base_url(),
#         timeout: :infinity,
#         channel: "#{System.get_env("AP_BASE_PATH", "/pub")}/shared_inbox"
#       }

#     def scenarios,
#       do: [
#         {Scenario, "p1",
#          %{
#            delay: 1 |> seconds,
#            duration: 1 |> seconds,
#            base_interval: 50,
#            publications_per_loop: 5
#          }},
#         {Scenario, "p2",
#          %{
#            delay: 4 |> seconds,
#            duration: 10 |> seconds,
#            base_interval: 250,
#            publications_per_loop: 1
#          }}
#       ]

#     def run, do: Chaperon.run_load_test(__MODULE__)
#   end
# end
