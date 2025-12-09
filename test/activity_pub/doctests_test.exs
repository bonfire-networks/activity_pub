defmodule ActivityPub.DocTest do
  use ExUnit.Case

  doctest ActivityPub.Federator.Worker.ReceiverRouter
  doctest ActivityPub.Federator.Workers.PublisherWorker
end
