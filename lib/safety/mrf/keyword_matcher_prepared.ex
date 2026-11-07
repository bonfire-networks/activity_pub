# SPDX-License-Identifier: AGPL-3.0-only

defmodule ActivityPub.MRF.KeywordMatcher.Prepared do
  @moduledoc """
  Some content's visible text, ready for `ActivityPub.MRF.KeywordMatcher.match?/3`: each field's text (HTML left out, entities decoded) and its folded versions (look-alike characters folded). Built once by `ActivityPub.MRF.KeywordMatcher.prepare/2`, so content checked against several lists is read and folded once.
  """

  defstruct texts: [], folded: []

  @type t :: %__MODULE__{texts: [String.t()], folded: [String.t()]}
end
