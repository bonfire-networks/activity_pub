# MoodleNet: Connecting and empowering educators worldwide
# Copyright © 2018-2020 Moodle Pty Ltd <https://moodle.com/moodlenet/>
# Contains code from Pleroma <https://pleroma.social/> and CommonsPub <https://commonspub.org/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPubWeb.ObjectView do
  use ActivityPubWeb, :view

  alias ActivityPub.Utils
  alias ActivityPubWeb.Transmogrifier

  def render("object.json", %{object: object}) do
    base = Utils.make_json_ld_header()

    {:ok, additional} = Transmogrifier.prepare_outgoing(object.data)
    Map.merge(base, additional)
  end
end
