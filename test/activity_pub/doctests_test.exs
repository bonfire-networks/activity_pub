defmodule ActivityPub.DocTest do
  use ExUnit.Case

  doctest ActivityPub.Federator.Worker.ReceiverRouter
  doctest ActivityPub.Federator.Workers.PublisherWorker
  doctest ActivityPub.Utils, only: [ascii_host: 1]
  # the ex_confusables fork's own suite doesn't run in the umbrella
  doctest ExConfusables, only: [normalize: 1]
end
