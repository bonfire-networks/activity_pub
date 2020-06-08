# MoodleNet: Connecting and empowering educators worldwide
# Copyright © 2018-2020 Moodle Pty Ltd <https://moodle.com/moodlenet/>
# Contains code from Pleroma <https://pleroma.social/> and CommonsPub <https://commonspub.org/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.HTTP.RequestBuilder do
  @moduledoc """
  Helper functions for building HTTP requests
  """

  def method(request, m) do
    Map.put_new(request, :method, m)
  end

  def url(request, u) do
    Map.put_new(request, :url, u)
  end

  def headers(request, header_list) do
    Map.put_new(request, :headers, header_list)
  end

  def opts(request, options) do
    Map.put_new(request, :opts, options)
  end

  def add_param(request, :query, :query, values), do: Map.put(request, :query, values)

  def add_param(request, :body, :body, value), do: Map.put(request, :body, value)
end
